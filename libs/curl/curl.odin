package curl

import "base:runtime"
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

// Poll cadence for the multi handle, clamping `multi_timeout`. The ceiling is
// the worst-case chunk latency; the floor keeps a "call me now" answer from
// spinning the loop.

@(private)
TICK_MIN :: 1 * time.Millisecond

@(private)
TICK_MAX :: 10 * time.Millisecond

// Request method. Closed: this transport posts JSON bodies and fetches with GET,
// nothing else.
Method :: enum {
    Get,
    Post,
}

// Why a turn could not be started, or a client could not be created. Failures
// after a turn starts are reported as a `Result` through `On_Done`, not here.
// `Invalid_Request` means the request was rejected before any handle existed;
// `Setup_Failed` means libcurl refused to create or configure one.
Error :: enum {
    None,
    Out_Of_Memory,
    Invalid_Request,
    Setup_Failed,
}

// Lifecycle of one turn: Created -> Running -> Done (transfer ended) or
// Canceled (caller's own action). Both terminal states are final.
Turn_State :: enum {
    Created,
    Running,
    Done,
    Canceled,
}

// One HTTP request. Zero-valued timeout fields take the `DEFAULT_*` values.
Request :: struct {
    // Absolute URL including scheme. Must be nul-terminated.
    url:             cstring,

    // Full `Name: value` request header lines, each nul-terminated. Copied into
    // curl's own list during `turn_start`; the caller need not keep them.
    headers:         []cstring,

    // Request body for `.Post`. libcurl does NOT copy it: the caller keeps the
    // bytes alive until `On_Done` fires or the turn is canceled.
    body:            []byte,

    // Whether the request carries a body at all.
    method:          Method,

    // Time allowed for connect only, rounded up to whole seconds.
    connect_timeout: time.Duration,

    // Bytes per second below which the transfer counts as stalled.
    low_speed_limit: int,

    // How long the transfer may stay stalled, rounded up to whole seconds.
    low_speed_time:  time.Duration,
}

// Terminal outcome of a turn. `code` and `message` are libcurl's own; mapping
// them onto an application error taxonomy belongs to the caller. `status` is the
// final HTTP status, 0 when no response head arrived. `message` borrows the
// turn's error buffer and is valid for the call only.
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
// false to abort the transfer; the turn still completes through `On_Done`, with
// `.Write_Error`. This is the only cancellation legal from inside a callback.
On_Body :: #type proc(user: rawptr, chunk: []byte) -> bool

// Fired exactly once, terminal. Never fires after `turn_cancel`.
On_Done :: #type proc(user: rawptr, result: Result)

// Per-turn callbacks. Any field may be nil. All fire on the loop thread.
Callbacks :: struct {
    on_status: On_Status,
    on_header: On_Header,
    on_body:   On_Body,
    on_done:   On_Done,
}

// One HTTP request/streaming response. Caller-allocated; `turn_start` takes over
// the contents and `turn_cancel` or `On_Done` releases them. libcurl holds this
// struct's address from `turn_start` until it is released, so a live turn must
// never be moved, copied, or reallocated.
Turn :: struct {
    // @private
    // Client this turn was started on; nil before the first `turn_start`.
    client:  ^Client,

    // @private
    // The easy handle while the turn holds one.
    easy:    ^Easy,

    // @private
    // Owned request-header list; not copied by curl, so it lives as long as the handle.
    headers: ^Slist,

    // @private
    // Borrowed request body; `POSTFIELDS` does not copy.
    body:    []byte,

    // @private
    user:    rawptr,

    // @private
    cbs:     Callbacks,

    // @private
    state:   Turn_State,

    // @private
    // Status of the most recent header block, used when curl reports none.
    status:  int,

    // @private
    // `CURLOPT_ERRORBUFFER` storage; curl writes a NUL-terminated reason here.
    errbuf:  [ERROR_SIZE]byte,
}

// A transfer curl reported as finished during the current tick.
@(private)
Completion :: struct {
    turn: ^Turn,
    code: Code,
}

// Drives libcurl's multi handle on one nbio event loop. Every callback it makes
// runs on that loop's thread. Its address is captured by the pump timer and by
// every turn it owns, so it must never be moved or copied after `client_init`.
Client :: struct {
    // @private
    loop:        ^nbio.Event_Loop,

    // @private
    multi:       ^Multi,

    // @private
    // The re-armed pump timer; nil exactly when no turn is live.
    timer_op:    ^nbio.Operation,

    // @private
    // Set across every curl call region and every curl-to-Odin trampoline.
    // Removing a handle or adding one from inside that region is undefined
    // behaviour in libcurl, so the mutating entry points assert on it.
    in_curl:     bool,

    // @private
    // Set while `On_Done` callbacks are being dispatched, so `client_destroy`
    // cannot free the scratch below out from under the dispatch loop.
    dispatching: bool,

    // @private
    // Turns currently added to the multi handle.
    live:        [dynamic]^Turn,

    // @private
    // Reused per-tick scratch for transfers curl reported as finished.
    completed:   [dynamic]Completion,

    // @private
    // Context restored inside curl's C callbacks, captured at `client_init`.
    ctx:         runtime.Context,
}

// libcurl's global state is refcounted process-wide.
@(private)
global_init_once: sync.Once

// Outcome of the one `curl_global_init`, latched for every later `client_init`.
// Allocation and TLS-backend startup can fail there, which is an operating
// error and not ours to assert on.
@(private)
global_init_code: Code

// Initialized exactly once per process and never cleaned up: `curl_global_cleanup`
// would tear the library down under a second client living in the same process,
// which is exactly what a test binary has.
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

    if global_init_code != .Ok {
        return .Setup_Failed
    }

    live, live_err := make([dynamic]^Turn, allocator)
    if live_err != nil {
        return .Out_Of_Memory
    }

    completed, completed_err := make([dynamic]Completion, allocator)
    if completed_err != nil {
        delete(live)
        return .Out_Of_Memory
    }

    multi := c_multi_init()
    if multi == nil {
        delete(live)
        delete(completed)
        return .Setup_Failed
    }

    c^ = Client {
        loop      = loop,
        multi     = multi,
        live      = live,
        completed = completed,
        ctx       = context,
    }

    return .None
}

// Releases the multi handle. Every turn must have completed or been canceled.
client_destroy :: proc(c: ^Client) {
    assert(c != nil, "client_destroy needs a client")
    assert(c.multi != nil, "client_destroy on an uninitialized client")
    assert(!c.in_curl, "client_destroy must not run inside a curl callback")
    assert(!c.dispatching, "client_destroy must not run inside On_Done")
    assert(len(c.live) == 0, "client_destroy with live turns")
    assert(c.timer_op == nil, "client_destroy with an armed pump timer")

    mc := c_multi_cleanup(c.multi)
    assert(mc == .Ok, "curl_multi_cleanup rejected the client's own handle")

    delete(c.live)
    delete(c.completed)
    c^ = {}
}

// True while the client holds at least one live turn.
client_busy :: proc(c: ^Client) -> bool {
    assert(c != nil, "client_busy needs a client")
    return len(c.live) > 0
}

// Arms the pump timer exactly when a turn is live and disarms it otherwise, so an
// idle client costs nothing on the loop.
@(private)
client_sync_timer :: proc(c: ^Client) {
    assert(c != nil, "client_sync_timer needs a client")
    assert(!c.in_curl, "the pump timer must not be changed inside a curl callback")

    if len(c.live) == 0 {
        // The tick that completed the last turn already cleared `timer_op`; only
        // a disarm from outside the pump has one left to remove.
        if c.timer_op != nil {
            nbio.remove(c.timer_op)
            c.timer_op = nil
        }
    } else if c.timer_op == nil {
        c.timer_op = nbio.timeout_poly(client_period(c), c, client_on_tick, c.loop)
    }

    assert((c.timer_op != nil) == (len(c.live) > 0), "pump timer state disagrees with the live-turn count")
}

// Delay until the next pump, clamped into the poll window.
@(private)
client_period :: proc(c: ^Client) -> time.Duration {
    assert(c != nil, "client_period needs a client")

    ms, code := multi_timeout_ms(c.multi)
    if code != .Ok || ms < 0 {
        return TICK_MAX
    }

    return clamp(time.Duration(ms) * time.Millisecond, TICK_MIN, TICK_MAX)
}

@(private)
client_on_tick :: proc(op: ^nbio.Operation, c: ^Client) {
    assert(c != nil, "the pump tick needs a client")
    assert(c.timer_op == op, "the pump tick fired for an operation the client does not own")
    assert(!c.in_curl, "the pump tick re-entered the curl region")

    c.timer_op = nil
    client_pump(c)
    client_sync_timer(c)
}

// Advances every live transfer, then completes the ones curl reported as finished.
@(private)
client_pump :: proc(c: ^Client) {
    assert(c != nil, "client_pump needs a client")
    assert(!c.in_curl, "client_pump re-entered the curl region")
    assert(len(c.live) > 0, "client_pump ran with no live turns")

    clear(&c.completed)
    c.in_curl = true

    for {
        _, code := multi_perform(c.multi)
        if code == .Call_Multi_Perform {
            continue
        }

        assert(code == .Ok, "curl_multi_perform failed on the client's own handle")
        break
    }

    for {
        msg, _ := multi_info_read(c.multi)
        if msg == nil {
            break
        }

        if msg.kind != .Done {
            continue
        }

        t := client_find(c, msg.easy)
        assert(t != nil, "multi_info_read reported an easy handle no turn owns")
        assert(len(c.completed) < cap(c.completed), "the completion scratch was not reserved for every live turn")
        append(&c.completed, Completion{turn = t, code = msg.data.result})
    }

    c.in_curl = false

    // Everything below leaves the curl region first: `multi_remove_handle` from
    // inside a curl callback is undefined behaviour, and `On_Done` may start or
    // cancel turns.
    c.dispatching = true
    defer c.dispatching = false

    // A `turn_start` from inside `On_Done` reserves this scratch again, so the
    // loop is only safe while its backing array cannot move: capacity is
    // monotone and already covers every turn ever live at once.
    reserved := cap(c.completed)

    for done in c.completed {
        // An earlier `On_Done` may have canceled this turn already.
        if done.turn.state != .Running {
            continue
        }

        turn_complete(done.turn, done.code)
    }

    assert(cap(c.completed) == reserved, "the completion scratch was reallocated during dispatch")
}

@(private)
client_find :: proc(c: ^Client, easy: ^Easy) -> ^Turn {
    assert(c != nil, "client_find needs a client")
    assert(easy != nil, "client_find needs an easy handle")

    for t in c.live {
        if t.easy == easy {
            return t
        }
    }

    return nil
}

// Starts `req` on `c`. On `.None` the turn is live and exactly one `On_Done`
// follows unless `turn_cancel` intervenes; on any other result nothing was
// registered and no callback ever fires.
turn_start :: proc(t: ^Turn, c: ^Client, req: Request, cbs: Callbacks, user: rawptr) -> Error {
    assert(t != nil, "turn_start needs a turn")
    assert(c != nil, "turn_start needs a client")
    assert(c.multi != nil, "turn_start needs an initialized client")
    // Adding a handle from inside a curl callback is as illegal as removing one.
    assert(!c.in_curl, "turn_start must not run inside a curl callback")
    assert(t.state != .Running, "turn_start on a turn that is already running")
    assert(req.method == .Post || len(req.body) == 0, "a GET carries no body")

    if len(req.url) == 0 {
        return .Invalid_Request
    }

    headers := build_headers(req.headers) or_return

    easy := c_easy_init()
    if easy == nil {
        c_slist_free_all(headers)
        return .Setup_Failed
    }

    t^ = {}
    t.client = c
    t.easy = easy
    t.headers = headers
    t.body = req.body
    t.user = user
    t.cbs = cbs

    if easy_configure(t, req) != .Ok {
        turn_abandon(t)
        return .Setup_Failed
    }

    if c_multi_add_handle(c.multi, easy) != .Ok {
        turn_abandon(t)
        return .Setup_Failed
    }

    // Both registers grow before the handle joins the multi, so neither the
    // append below nor the pump's completion drain can fail on allocation.
    if reserve(&c.live, len(c.live) + 1) != nil || reserve(&c.completed, len(c.live) + 1) != nil {
        mc := c_multi_remove_handle(c.multi, easy)
        assert(mc == .Ok, "multi_remove_handle rejected a handle just added")
        turn_abandon(t)
        return .Out_Of_Memory
    }

    append(&c.live, t)

    t.state = .Running
    client_sync_timer(c)

    return .None
}

// Ends a running turn immediately: the handle leaves the multi, is destroyed, and
// no callback fires. Terminal by the caller's own action, mirroring `nbio.remove`.
// Calling this from inside any curl callback is a programmer error — libcurl
// forbids `multi_remove_handle` there, so `On_Body` returning false is the only
// in-callback way to stop a transfer.
turn_cancel :: proc(t: ^Turn) {
    assert(t != nil, "turn_cancel needs a turn")
    assert(t.client != nil, "turn_cancel on a turn that was never started")
    assert(!t.client.in_curl, "turn_cancel must not run inside a curl callback")
    assert(t.state == .Running, "turn_cancel on a turn that is not running")

    c := t.client
    t.state = .Canceled
    turn_release(t)
    client_sync_timer(c)
}

// State of a turn, for callers that keep one across loop turns.
turn_state :: proc(t: ^Turn) -> Turn_State {
    assert(t != nil, "turn_state needs a turn")
    return t.state
}

// Drops a handle that was never added to the multi, leaving the turn as if
// `turn_start` had never touched it.
@(private)
turn_abandon :: proc(t: ^Turn) {
    assert(t != nil, "turn_abandon needs a turn")
    assert(t.easy != nil, "turn_abandon on a turn that owns no handle")
    assert(t.state == .Created, "turn_abandon on a registered turn")

    c_easy_cleanup(t.easy)

    if t.headers != nil {
        c_slist_free_all(t.headers)
    }

    t^ = {}
}

// Releases a registered turn's curl resources and unlinks it from its client.
@(private)
turn_release :: proc(t: ^Turn) {
    assert(t != nil, "turn_release needs a turn")
    assert(t.client != nil, "turn_release needs a started turn")
    assert(!t.client.in_curl, "turn_release must not run inside a curl callback")
    assert(t.easy != nil, "turn_release on a turn that owns no handle")
    assert(t.state == .Done || t.state == .Canceled, "turn_release on a turn that is still live")

    c := t.client

    // Defence in depth: libcurl makes no callbacks from these two, but if that
    // ever changed the trampolines would land on a turn that is no longer
    // Running and abort there instead of touching a half-freed handle.
    c.in_curl = true
    mc := c_multi_remove_handle(c.multi, t.easy)
    assert(mc == .Ok, "multi_remove_handle rejected a handle the client added")

    c_easy_cleanup(t.easy)
    c.in_curl = false
    t.easy = nil

    if t.headers != nil {
        c_slist_free_all(t.headers)
        t.headers = nil
    }

    index := -1
    for live, i in c.live {
        if live == t {
            index = i
            break
        }
    }

    assert(index >= 0, "a live turn was missing from its client")
    unordered_remove(&c.live, index)
}

// Finishes a transfer curl reported as done and fires `On_Done` exactly once.
@(private)
turn_complete :: proc(t: ^Turn, code: Code) {
    assert(t != nil, "turn_complete needs a turn")
    assert(t.client != nil, "turn_complete needs a started turn")
    assert(!t.client.in_curl, "turn_complete must not run inside a curl callback")
    assert(t.state == .Running, "turn_complete on a turn that is not running")

    status, info_code := getinfo_long(t.easy, .Response_Code)
    if info_code != .Ok || status == 0 {
        status = t.status
    }

    // Read before the handle goes away; the buffer itself is the turn's own.
    result := Result {
        code    = code,
        message = turn_message(t, code),
        status  = status,
    }

    cbs := t.cbs
    user := t.user
    t.state = .Done
    turn_release(t)

    if cbs.on_done != nil {
        cbs.on_done(user, result)
    }
}

// curl's own reason text: the per-transfer error buffer when it filled one,
// otherwise the generic string for the code.
@(private)
turn_message :: proc(t: ^Turn, code: Code) -> string {
    assert(t != nil, "turn_message needs a turn")

    if t.errbuf[0] != 0 {
        return string(cstring(&t.errbuf[0]))
    }

    return string(c_easy_strerror(code))
}

// Copies `headers` into a curl list. On failure the partial list is freed.
@(private)
build_headers :: proc(headers: []cstring) -> (list: ^Slist, err: Error) {
    for header in headers {
        assert(header != nil, "a request header line must not be nil")

        // A failed append leaves the previous list intact and still owned here.
        next := c_slist_append(list, header)
        if next == nil {
            c_slist_free_all(list)
            return nil, .Out_Of_Memory
        }

        list = next
    }

    return list, .None
}

// Applies every option a turn needs. `url` and the header strings are copied by
// libcurl during these calls; the body, the header list, and the error buffer are
// not, and stay owned by the turn until it is released.
@(private)
easy_configure :: proc(t: ^Turn, req: Request) -> Code {
    assert(t != nil, "easy_configure needs a turn")
    assert(t.easy != nil, "easy_configure needs an easy handle")

    e := t.easy

    setopt_str(e, .Url, req.url) or_return
    setopt_ptr(e, .Error_Buffer, &t.errbuf[0]) or_return

    // libcurl otherwise uses signals and alarm() for its own DNS timeouts, which
    // is unsafe in a process with worker threads.
    setopt_long(e, .No_Signal, 1) or_return

    // Never CURLOPT_TIMEOUT: it would kill a long but healthy generation. The
    // low-speed pair bounds idle gaps instead.
    setopt_long(e, .Connect_Timeout, seconds_ceil(req.connect_timeout, DEFAULT_CONNECT_TIMEOUT)) or_return
    setopt_long(
        e,
        .Low_Speed_Limit,
        req.low_speed_limit if req.low_speed_limit > 0 else DEFAULT_LOW_SPEED_LIMIT,
    ) or_return
    setopt_long(e, .Low_Speed_Time, seconds_ceil(req.low_speed_time, DEFAULT_LOW_SPEED_TIME)) or_return

    // Let concurrent turns to one host multiplex over one HTTP/2 connection
    // instead of racing several open.
    setopt_long(e, .Pipe_Wait, 1) or_return

    // Redirects stay off: following one would replay credential headers and the
    // request body onto a host the caller never chose.
    setopt_long(e, .Follow_Location, 0) or_return

    // SSL_VERIFYPEER, SSL_VERIFYHOST, CAINFO and CAPATH are deliberately never
    // touched — the system trust store is the only trust decision this makes.
    // ACCEPT_ENCODING is likewise unset, so responses arrive identity-coded.

    setopt_write_cb(e, .Write_Function, on_write) or_return
    setopt_ptr(e, .Write_Data, t) or_return
    setopt_write_cb(e, .Header_Function, on_header) or_return
    setopt_ptr(e, .Header_Data, t) or_return

    if t.headers != nil {
        setopt_ptr(e, .Http_Header, t.headers) or_return
    }

    switch req.method {
    case .Get:
        setopt_long(e, .Http_Get, 1) or_return

    case .Post:
        setopt_long(e, .Post, 1) or_return

        // `CURLOPT_POSTFIELDSIZE` is a C long, which is 32-bit on Windows.
        assert(len(t.body) <= LONG_MAX, "request body does not fit CURLOPT_POSTFIELDSIZE")
        setopt_long(e, .Post_Field_Size, len(t.body)) or_return

        // POSTFIELDS must be non-nil even for an empty body, or libcurl falls
        // back to reading the body through CURLOPT_READFUNCTION.
        body := rawptr(&EMPTY_BODY[0]) if len(t.body) == 0 else rawptr(raw_data(t.body))
        setopt_ptr(e, .Post_Fields, body) or_return
    }

    return .Ok
}

// Stand-in target for a zero-length POST body.
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

// `CURLOPT_WRITEFUNCTION`. Runs on the loop thread, inside the curl region.
@(private)
on_write :: proc "c" (buffer: [^]byte, size: uint, nitems: uint, user: rawptr) -> uint {
    t := (^Turn)(user)
    context = t.client.ctx

    prev := t.client.in_curl
    t.client.in_curl = true
    defer t.client.in_curl = prev

    assert(prev, "a curl callback ran outside a curl call region")
    assert(t.state == .Running, "a body chunk arrived for a turn that is not running")

    n := size * nitems
    if n == 0 || t.cbs.on_body == nil {
        return n
    }

    if !t.cbs.on_body(t.user, buffer[:n]) {
        return WRITEFUNC_ERROR
    }

    return n
}

// `CURLOPT_HEADERFUNCTION`. Delivers raw response header bytes one line at a
// time, including the status line and the blank line that ends each block.
@(private)
on_header :: proc "c" (buffer: [^]byte, size: uint, nitems: uint, user: rawptr) -> uint {
    t := (^Turn)(user)
    context = t.client.ctx

    prev := t.client.in_curl
    t.client.in_curl = true
    defer t.client.in_curl = prev

    assert(prev, "a curl callback ran outside a curl call region")
    assert(t.state == .Running, "a header line arrived for a turn that is not running")

    n := size * nitems
    line := trim_eol(buffer[:n])

    // The blank line ends a block and carries nothing to deliver.
    if len(line) == 0 {
        return n
    }

    // A status line starts a new block: a proxy CONNECT or a 100 Continue puts
    // more than one in front of the real response, and the last one wins.
    if status, is_status := parse_status_line(line); is_status {
        t.status = status

        if t.cbs.on_status != nil {
            t.cbs.on_status(t.user, status)
        }

        return n
    }

    if t.cbs.on_header != nil {
        t.cbs.on_header(t.user, line)
    }

    return n
}

// Drops a trailing CRLF, LF, or lone CR.
@(private)
trim_eol :: proc(line: []byte) -> []byte {
    end := len(line)

    if end > 0 && line[end - 1] == '\n' {
        end -= 1
    }

    if end > 0 && line[end - 1] == '\r' {
        end -= 1
    }

    return line[:end]
}

// Reads the numeric status out of an `HTTP/x.y NNN reason` line. Never asserts:
// these are peer bytes.
@(private)
parse_status_line :: proc(line: []byte) -> (status: int, ok: bool) {
    if len(line) < 5 || string(line[:5]) != "HTTP/" {
        return 0, false
    }

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

        if digits > 3 {
            return 0, false
        }
    }

    return status, digits == 3
}
