package curl

import "core:nbio"
import "core:sync"
import "core:time"

// Connect phase only; a generation may stream for minutes afterwards.
DEFAULT_CONNECT_TIMEOUT :: 30 * time.Second

// Bytes per second below which a transfer counts as stalled.
DEFAULT_LOW_SPEED_LIMIT :: 1

// How long a transfer may stay below `low_speed_limit` before curl aborts it.
// Together with the limit this is an idle-gap timeout, not a total-time cap.
DEFAULT_LOW_SPEED_TIME :: 120 * time.Second

// Hard ceiling on one request-header line (name, `": "`, value, NUL).
// An oversized header is rejected as `Invalid_Request`.
HEADER_LINE_MAX :: 8192

// One request header, name and value unjoined. Declared here rather than borrowed
// from `libs:http` so a binding depends on nothing but its C library.
Header :: struct {
    // Empty not allowed
    name:  string,

    // Empty is permitted: RFC 9110
    value: string,
}

// Request method. Closed set of the everyday REST verbs.
Method :: enum {
    Get,
    Head,
    Post,
    Put,
    Patch,
    Delete,
}

// Why a transfer could not be started, or a client could not be created. Failures
// after a transfer starts are reported as a `Result` through `On_Done`, not here.
// `Invalid_Request` means the request was rejected before any handle existed;
// `Setup_Failed` means libcurl refused to create or configure one.
Error :: enum {
    None,
    Out_Of_Memory,
    Invalid_Request,
    Setup_Failed,
}

// Lifecycle of one run: Created -> Running -> Done (curl ended it) or Canceled
// (caller's own action). A terminal Transfer may be started again.
Transfer_State :: enum {
    Created,
    Running,
    Done,
    Canceled,
}

// One HTTP request. Every field is copied during `transfer_start` and none need
// outlive it. Zero-valued timeout fields take the `DEFAULT_*` values.
Request :: struct {
    // Absolute URL including scheme. Must be nul-terminated.
    url:             cstring,

    // Request headers, joined into curl's own list.
    headers:         []Header,

    // Request body for `.Post`, `.Put`, and `.Patch`. Empty for the others.
    body:            []byte,

    // Request method. `.Post`, `.Put`, and `.Patch` may carry `body`.
    method:          Method,

    // Time allowed for connect only, rounded up to whole seconds.
    connect_timeout: time.Duration,

    // Absolute transfer duration, rounded up to whole seconds. Zero leaves the
    // transfer unbounded for healthy long-lived streams.
    total_timeout:   time.Duration,

    // Bytes per second below which the transfer counts as stalled.
    low_speed_limit: int,

    // How long the transfer may stay stalled, rounded up to whole seconds.
    low_speed_time:  time.Duration,
}

// Terminal outcome of a transfer. `code` and `message` are libcurl's own; mapping
// them onto an application error taxonomy belongs to the caller. `status` is the
// final HTTP status, 0 when no response head arrived. `message` borrows the
// transfer's error buffer and is valid for the call only.
Result :: struct {
    code:    Code,
    message: string,
    status:  int,
}

// Fired when a response header block begins, carrying its status code. A proxy
// `CONNECT` or a `100 Continue` produces more than one block; each begins with a
// fresh call and the last one wins.
On_Status :: #type proc(user: rawptr, status: int)

// One `Name: value` response header line with its line ending stripped. Borrows
// curl's buffer and is valid for the call only. Casing is the server's; the
// caller owns all header comparison.
On_Header :: #type proc(user: rawptr, line: []byte)

// One response body chunk, borrowing curl's buffer for the call only. Return
// false to abort the transfer; it still completes through `On_Done`, with
// `.Write_Error`. This is the only cancellation legal from inside a callback.
On_Body :: #type proc(user: rawptr, chunk: []byte) -> bool

// Fired exactly once, terminal. Never fires after `transfer_cancel`.
On_Done :: #type proc(user: rawptr, result: Result)

// Per-transfer callbacks. Any field may be nil. All fire on the loop thread.
Callbacks :: struct {
    on_status: On_Status,
    on_header: On_Header,
    on_body:   On_Body,
    on_done:   On_Done,
}

// One HTTP request/streaming response. Caller-allocated and caller-owned: this
// package never frees the struct. It only creates the easy handle and header list
// at `transfer_start` and releases them at `On_Done` or `transfer_cancel`. After
// that the same struct may be started again. Do not move it while `.Running`.
Transfer :: struct {
    // @private
    // Client this transfer was started on; nil before the first `transfer_start`.
    client:  ^Client,

    // @private
    // The easy handle while the transfer holds one.
    easy:    ^Easy,

    // @private
    // Owned request-header list; not copied by curl, so it lives as long as the handle.
    headers: ^Slist,

    // @private
    user:    rawptr,

    // @private
    cbs:     Callbacks,

    // Lifecycle of this transfer, readable by callers that keep one across loop ticks.
    state:   Transfer_State,

    // @private
    // Status of the most recent header block, used when curl reports none.
    status:  int,

    // @private
    // `Option.Error_Buffer` storage; curl writes a NUL-terminated reason here.
    errbuf:  [ERROR_SIZE]byte,
}

// A transfer curl reported as finished during the current tick.
@(private)
Completion :: struct {
    transfer: ^Transfer,
    code:     Code,
}

// Drives libcurl's multi handle on one nbio event loop. Every callback it makes
// runs on that loop's thread. Address-pinned after `client_init`: the drive and
// every live transfer hold it by address.
Client :: struct {
    using drive: Drive,

    // @private
    // True while On_Done is running. client_destroy must not free `completed`
    // under that loop.
    in_on_done:  bool,

    // @private
    // Transfers currently added to the multi handle.
    live:        [dynamic]^Transfer,

    // @private
    // Reused per-tick scratch for transfers curl reported as finished.
    completed:   [dynamic]Completion,
}

// libcurl's global state is refcounted process-wide.
@(private)
global_init_once: sync.Once

// Outcome of the one `curl_global_init`, reused by every later `client_init`.
@(private)
global_init_code: Code

// One-time process init; never cleaned up so a second client in the same process keeps working.
@(private)
global_init :: proc() {
    global_init_code = c_global_init(GLOBAL_DEFAULT)
}

// Creates a client bound to `loop`. Dynamic state comes from `allocator`, which
// must outlive the client.
client_init :: proc(c: ^Client, loop: ^nbio.Event_Loop, allocator := context.allocator) -> Error {
    assert(c != nil, "client_init needs a client")
    assert(loop != nil, "client_init needs an event loop")
    assert(c.multi == nil, "client_init on an initialized client")

    sync.once_do(&global_init_once, global_init)
    if global_init_code != .Ok do return .Setup_Failed

    c^ = {}
    if drive_init(&c.drive, loop, allocator, c, client_after_pump) != .None do return .Setup_Failed

    // Both registers stay empty until `transfer_start` reserves them.
    c.live.allocator = allocator
    c.completed.allocator = allocator

    return .None
}

// Releases the multi handle. Every transfer must have completed or been canceled.
client_destroy :: proc(c: ^Client) {
    assert(c != nil, "client_destroy needs a client")
    assert(c.multi != nil, "client_destroy on an uninitialized client")
    assert(!c.in_libcurl, "client_destroy must not run inside a curl callback")
    assert(!c.in_on_done, "client_destroy must not run inside On_Done")
    assert(len(c.live) == 0, "client_destroy with live transfers")
    assert(c.timer_op == nil, "client_destroy with an armed pump timer")

    drive_destroy(&c.drive)
    delete(c.live)
    delete(c.completed)
    c^ = {}
}

// True while the client holds at least one live transfer.
client_busy :: proc(c: ^Client) -> bool {
    assert(c != nil, "client_busy needs a client")
    return len(c.live) > 0
}

@(private)
client_after_pump :: proc(d: ^Drive, owner: rawptr) {
    c := (^Client)(owner)
    assert(c != nil, "client_after_pump needs a client")
    assert(&c.drive == d, "client_after_pump received the wrong drive")
    assert(!d.in_libcurl, "client_after_pump entered from inside curl")

    clear(&c.completed)
    d.in_libcurl = true
    for {
        msg, _ := multi_info_read(c.multi)
        if msg == nil do break
        if msg.kind != .Done do continue

        transfer := client_find(c, msg.easy)
        assert(transfer != nil, "multi_info_read reported an easy handle no transfer owns")
        assert(len(c.completed) < cap(c.completed), "the completion scratch was not reserved for every live transfer")

        append(&c.completed, Completion{transfer = transfer, code = msg.data.result})
    }
    d.in_libcurl = false

    c.in_on_done = true
    defer c.in_on_done = false

    count := len(c.completed)
    for i in 0 ..< count {
        done := c.completed[i]
        if done.transfer.state != .Running do continue

        transfer_complete(done.transfer, done.code)
    }

    if len(c.live) == 0 {
        d.timer_ms = -1
        d.timer_set = true
    }
}

// The failure reason curl left behind, preferring its own buffer over the generic text
// for the code. Borrows `errbuf`, so it is valid for the call only.
@(private)
curl_message :: proc(errbuf: ^[ERROR_SIZE]byte, code: Code) -> string {
    assert(errbuf != nil, "curl_message needs an error buffer")

    if errbuf[0] != 0 do return string(cstring(&errbuf[0]))
    return string(c_easy_strerror(code))
}

@(private)
client_find :: proc(c: ^Client, easy: ^Easy) -> ^Transfer {
    assert(c != nil, "client_find needs a client")
    assert(easy != nil, "client_find needs an easy handle")

    for transfer in c.live {
        if transfer.easy == easy do return transfer
    }

    return nil
}

// True for methods that send `Request.body`. The others reject a non-empty body.
@(private)
method_carries_body :: proc(method: Method) -> (carries: bool) {
    switch method {
    case .Post, .Put, .Patch:
        carries = true

    case .Get, .Head, .Delete:
        carries = false
    }

    return
}

// Starts `request` on `client`. `.None` means success: the transfer is live until `On_Done`.
// The caller owns `transfer`; this does not allocate or free it.
transfer_start :: proc(transfer: ^Transfer, c: ^Client, req: Request, cbs: Callbacks, user: rawptr) -> (err: Error) {
    assert(transfer != nil, "transfer_start needs a transfer")
    assert(c != nil, "transfer_start needs a client")
    assert(c.multi != nil, "transfer_start needs an initialized client")
    // Adding a handle from inside a curl callback is as illegal as removing one.
    assert(!c.in_libcurl, "transfer_start must not run inside a curl callback")
    assert(transfer.state != .Running, "transfer_start on a transfer that is already running")

    if len(req.url) == 0 do return .Invalid_Request
    if !method_carries_body(req.method) && len(req.body) > 0 do return .Invalid_Request
    if len(req.body) > LONG_MAX do return .Invalid_Request

    headers := build_headers(req.headers) or_return
    easy := c_easy_init()
    if easy == nil {
        c_slist_free_all(headers)
        return .Setup_Failed
    }

    transfer^ = {}
    transfer.client = c
    transfer.easy = easy
    transfer.headers = headers
    transfer.user = user
    transfer.cbs = cbs
    defer if err != .None do transfer_abandon(transfer)

    code := easy_configure(transfer, req)
    if code != .Ok do return .Out_Of_Memory if code == .Out_Of_Memory else .Setup_Failed

    // Both registers grow before the handle joins the multi, so neither the append
    // below nor the pump's completion drain can fail on allocation, and running out
    // here unwinds through `transfer_abandon` with nothing registered to remove.
    if reserve(&c.live, len(c.live) + 1) != nil || reserve(&c.completed, len(c.live) + 1) != nil do return .Out_Of_Memory

    if c_multi_add_handle(c.multi, easy) != .Ok do return .Setup_Failed

    append(&c.live, transfer)

    transfer.state = .Running
    drive_kick(&c.drive)

    return .None
}

// Ends a running transfer immediately. No `On_Done`. Must not run inside a callback.
transfer_cancel :: proc(transfer: ^Transfer) {
    assert(transfer != nil, "transfer_cancel needs a transfer")
    assert(transfer.client != nil, "transfer_cancel on a transfer that was never started")
    assert(!transfer.client.in_libcurl, "transfer_cancel must not run inside a curl callback")
    assert(transfer.state == .Running, "transfer_cancel on a transfer that is not running")

    c := transfer.client
    transfer.state = .Canceled
    transfer_release(transfer)
    drive_apply(&c.drive)
}

// Drops a handle that was never added to the multi, leaving the transfer as if
// `transfer_start` had never touched it.
@(private)
transfer_abandon :: proc(transfer: ^Transfer) {
    assert(transfer != nil, "transfer_abandon needs a transfer")
    assert(transfer.easy != nil, "transfer_abandon on a transfer that owns no handle")
    assert(transfer.state == .Created, "transfer_abandon on a registered transfer")

    c_easy_cleanup(transfer.easy)
    if transfer.headers != nil do c_slist_free_all(transfer.headers)
    transfer^ = {}
}

// Releases a registered transfer's curl resources and unlinks it from its client.
@(private)
transfer_release :: proc(transfer: ^Transfer) {
    assert(transfer != nil, "transfer_release needs a transfer")
    assert(transfer.client != nil, "transfer_release needs a started transfer")
    assert(!transfer.client.in_libcurl, "transfer_release must not run inside a curl callback")
    assert(transfer.easy != nil, "transfer_release on a transfer that owns no handle")
    assert(transfer.state == .Done || transfer.state == .Canceled, "transfer_release on a transfer that is still live")

    c := transfer.client

    // Defence in depth: `on_write` / `on_header` assert `.Running`, so a stray
    // callback here would abort instead of touching a half-freed handle.
    c.in_libcurl = true

    // Release has no error channel and the handle is destroyed either way; a refused
    // removal is libcurl's code to report, not ours to assert on.
    _ = c_multi_remove_handle(c.multi, transfer.easy)
    c_easy_cleanup(transfer.easy)

    c.in_libcurl = false
    transfer.easy = nil

    if transfer.headers != nil {
        c_slist_free_all(transfer.headers)
        transfer.headers = nil
    }

    index := -1
    for live, i in c.live {
        if live == transfer {
            index = i
            break
        }
    }

    assert(index >= 0, "a live transfer was missing from its client")
    unordered_remove(&c.live, index)
}

// Finishes a transfer curl reported as done and fires `On_Done` exactly once.
@(private)
transfer_complete :: proc(transfer: ^Transfer, code: Code) {
    assert(transfer != nil, "transfer_complete needs a transfer")
    assert(transfer.client != nil, "transfer_complete needs a started transfer")
    assert(!transfer.client.in_libcurl, "transfer_complete must not run inside a curl callback")
    assert(transfer.state == .Running, "transfer_complete on a transfer that is not running")

    status, info_code := getinfo_long(transfer.easy, .Response_Code)
    if info_code != .Ok || status == 0 do status = transfer.status

    // Read before the handle goes away; the buffer itself is the transfer's own.
    result := Result {
        code    = code,
        message = transfer_message(transfer, code),
        status  = status,
    }

    cbs := transfer.cbs
    user := transfer.user
    transfer.state = .Done
    transfer_release(transfer)

    if cbs.on_done != nil do cbs.on_done(user, result)
}

// curl's own reason text: the per-transfer error buffer when it filled one,
// otherwise the generic string for the code.
@(private)
transfer_message :: proc(transfer: ^Transfer, code: Code) -> string {
    assert(transfer != nil, "transfer_message needs a transfer")
    return curl_message(&transfer.errbuf, code)
}

// Whether `name` is a valid field name. Rejecting a colon here is what stops a
// caller from smuggling a second header into one name.
@(private)
field_name_valid :: proc(name: string) -> bool {
    if len(name) == 0 do return false

    for i in 0 ..< len(name) {
        c := name[i]
        switch c {
        case '0' ..= '9', 'A' ..= 'Z', 'a' ..= 'z':
        case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
        // RFC 9110 §5.6.2 token byte; everything else is rejected.
        case:
            return false
        }
    }

    return true
}

// Whether `value` is safe to emit as one field value. CR, LF, NUL, and other
// controls are rejected; horizontal tab is the sole permitted control byte. This
// is the check that prevents request splitting.
@(private)
field_value_valid :: proc(value: string) -> bool {
    for i in 0 ..< len(value) {
        c := value[i]
        if c < 0x20 && c != '\t' || c == 0x7f do return false
    }

    return true
}

// Joins `headers` into a curl list, freeing the partial list on failure. Empty
// values are accepted. (RFC 9110).
@(private)
build_headers :: proc(headers: []Header) -> (out: ^Slist, err: Error) {
    line: [HEADER_LINE_MAX]byte

    // Cleanup tracks the local: `return nil, err` clears the named result first.
    list: ^Slist
    defer if err != .None do c_slist_free_all(list)

    for header in headers {
        if !field_name_valid(header.name) || !field_value_valid(header.value) do return nil, .Invalid_Request

        // Empty values use `;` so libcurl sees `Name;` ("send empty value")
        // rather than `Name:` ("suppress this header").
        at: int
        if len(header.value) == 0 {
            // `;` and the nul terminator. (+2)
            if len(header.name) + 2 > len(line) do return nil, .Invalid_Request

            at = copy(line[:], header.name)
            at += copy(line[at:], ";")
        } else {
            // `: ` and the nul terminator. (+3)
            if len(header.name) + len(header.value) + 3 > len(line) do return nil, .Invalid_Request

            at = copy(line[:], header.name)
            at += copy(line[at:], ": ")
            at += copy(line[at:], header.value)
        }
        line[at] = 0

        // A failed append leaves the previous list intact and still owned here.
        next := c_slist_append(list, cstring(&line[0]))
        if next == nil do return nil, .Out_Of_Memory

        list = next
    }

    return list, .None
}

// Applies every option a transfer needs. Nothing in `req` is retained past these
// calls; the header list and error buffer stay owned by the transfer.
@(private)
easy_configure :: proc(transfer: ^Transfer, req: Request) -> Code {
    assert(transfer != nil, "easy_configure needs a transfer")
    assert(transfer.easy != nil, "easy_configure needs an easy handle")

    e := transfer.easy

    // Refuse every libcurl protocol handler except the two this client implements.
    setopt_str(e, .Protocols_Str, "http,https") or_return
    setopt_str(e, .Url, req.url) or_return
    setopt_ptr(e, .Error_Buffer, &transfer.errbuf[0]) or_return

    // libcurl otherwise uses signals and alarm() for its own DNS timeouts, which
    // is unsafe in a process with worker threads.
    setopt_long(e, .No_Signal, 1) or_return

    // Provider streams leave the total timeout at zero; bounded control-plane
    // requests opt in explicitly.
    setopt_long(e, .Connect_Timeout, seconds_ceil(req.connect_timeout, DEFAULT_CONNECT_TIMEOUT)) or_return
    if req.total_timeout > 0 do setopt_long(e, .Timeout, seconds_ceil(req.total_timeout, req.total_timeout)) or_return

    setopt_long(
        e,
        .Low_Speed_Limit,
        req.low_speed_limit if req.low_speed_limit > 0 else DEFAULT_LOW_SPEED_LIMIT,
    ) or_return
    setopt_long(e, .Low_Speed_Time, seconds_ceil(req.low_speed_time, DEFAULT_LOW_SPEED_TIME)) or_return

    // Let concurrent transfers to one host multiplex over one HTTP/2 connection
    // instead of racing several open.
    setopt_long(e, .Pipe_Wait, 1) or_return

    // Redirects stay off: following one would replay credential headers and the
    // request body onto a host the caller never chose.
    setopt_long(e, .Follow_Location, 0) or_return

    // SSL_VERIFYPEER, SSL_VERIFYHOST, CAINFO and CAPATH are deliberately never
    // touched — the system trust store is the only trust decision this makes.
    // ACCEPT_ENCODING is likewise unset, so responses arrive identity-coded.

    drive_bind_easy(e, &transfer.client.drive) or_return
    setopt_write_cb(e, .Write_Function, on_write) or_return
    setopt_ptr(e, .Write_Data, transfer) or_return
    setopt_write_cb(e, .Header_Function, on_header) or_return
    setopt_ptr(e, .Header_Data, transfer) or_return

    if transfer.headers != nil do setopt_ptr(e, .Http_Header, transfer.headers) or_return

    switch req.method {
    case .Get:
        setopt_long(e, .Http_Get, 1) or_return

    case .Head:
        setopt_long(e, .No_Body, 1) or_return

    case .Post:
        setopt_long(e, .Post, 1) or_return
        set_request_body(e, req.body) or_return

    case .Put:
        // Body first: `Copy_Post_Fields` implies POST, then the verb overrides it.
        set_request_body(e, req.body) or_return
        setopt_str(e, .Custom_Request, "PUT") or_return

    case .Patch:
        set_request_body(e, req.body) or_return
        setopt_str(e, .Custom_Request, "PATCH") or_return

    case .Delete:
        setopt_str(e, .Custom_Request, "DELETE") or_return
    }

    return .Ok
}

// Copies `body` into libcurl. Empty still needs a non-nil pointer or libcurl
// reads through `Option.Read_Function`.
@(private)
set_request_body :: proc(easy: ^Easy, body: []byte) -> Code {
    assert(easy != nil, "set_request_body needs an easy handle")

    // A C long on Windows, and must precede the copy or libcurl looks for a
    // nul terminator instead of this count.
    assert(len(body) <= LONG_MAX, "request body does not fit Option.Post_Field_Size")
    setopt_long(easy, .Post_Field_Size, len(body)) or_return

    ptr := rawptr(&EMPTY_BODY[0]) if len(body) == 0 else rawptr(raw_data(body))
    return setopt_ptr(easy, .Copy_Post_Fields, ptr)
}

// Stand-in target for a zero-length request body.
@(private)
@(rodata)
EMPTY_BODY := [1]byte{0}

// Whole seconds, rounding up so a sub-second request never reads as "no limit".
@(private)
seconds_ceil :: proc(d: time.Duration, fallback: time.Duration) -> int {
    value := d if d > 0 else fallback
    assert(value > 0, "a timeout fallback must be positive")
    return int((value + time.Second - 1) / time.Second)
}

// `Option.Write_Function`. Runs on the loop thread, inside the curl region.
@(private)
on_write :: proc "c" (buffer: [^]byte, size: uint, nitems: uint, user: rawptr) -> uint {
    transfer := (^Transfer)(user)
    context = transfer.client.ctx

    assert(transfer.client.in_libcurl, "a curl callback ran outside a curl call region")
    assert(transfer.state == .Running, "a body chunk arrived for a transfer that is not running")

    n := size * nitems
    if n == 0 || transfer.cbs.on_body == nil do return n

    if !transfer.cbs.on_body(transfer.user, buffer[:n]) do return WRITEFUNC_ERROR

    return n
}

// `Option.Header_Function`. Delivers raw response header bytes one line at a
// time, including the status line and the blank line that ends each block.
@(private)
on_header :: proc "c" (buffer: [^]byte, size: uint, nitems: uint, user: rawptr) -> uint {
    transfer := (^Transfer)(user)
    context = transfer.client.ctx

    assert(transfer.client.in_libcurl, "a curl callback ran outside a curl call region")
    assert(transfer.state == .Running, "a header line arrived for a transfer that is not running")

    n := size * nitems
    line := trim_eol(buffer[:n])

    // The blank line ends a block and carries nothing to deliver.
    if len(line) == 0 do return n

    // A status line starts a new block: a proxy CONNECT or a 100 Continue puts
    // more than one in front of the real response, and the last one wins.
    if status, is_status := parse_status_line(line); is_status {
        transfer.status = status
        if transfer.cbs.on_status != nil do transfer.cbs.on_status(transfer.user, status)
        return n
    }

    if transfer.cbs.on_header != nil do transfer.cbs.on_header(transfer.user, line)

    return n
}

// Drops a trailing CRLF, LF, or lone CR.
@(private)
trim_eol :: proc(line: []byte) -> []byte {
    end := len(line)
    if end > 0 && line[end - 1] == '\n' do end -= 1
    if end > 0 && line[end - 1] == '\r' do end -= 1

    return line[:end]
}

// Reads the numeric status out of an `HTTP/x.y NNN reason` line. Never asserts:
// these are peer bytes.
@(private)
parse_status_line :: proc(line: []byte) -> (status: int, ok: bool) {
    if len(line) < 5 || string(line[:5]) != "HTTP/" do return 0, false

    i := 5
    for i < len(line) && line[i] != ' ' {
        i += 1
    }

    for i < len(line) && line[i] == ' ' {
        i += 1
    }

    digits := 0
    for i < len(line) && line[i] >= '0' && line[i] <= '9' {
        status = status * 10 + int(line[i] - '0')
        digits += 1
        i += 1

        if digits > 3 do return 0, false
    }

    return status, digits == 3
}
