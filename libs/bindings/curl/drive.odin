package curl

import "base:runtime"
import "core:c"
import "core:nbio"
import "core:net"
import "core:time"

// Shared nbio drive for a curl multi handle. Curl names the sockets and the
// timeout; this package arms `nbio.poll` / `nbio.timeout` and calls
// `socket_action` when they fire.
@(private)
Drive :: struct {
    loop:       ^nbio.Event_Loop,
    multi:      ^Multi,
    // True across libcurl regions that may call back or touch multi state.
    // Mutating the multi from one of those callbacks is undefined.
    in_libcurl: bool,
    // True inside `drive_pump`. `drive_kick` defers through `need_kick` so
    // after_pump can start another transfer without re-entering.
    pumping:    bool,
    need_kick:  bool,
    timer_op:   ^nbio.Operation,
    timer_ms:   int,
    timer_set:  bool,
    watches:    [dynamic]Watch,
    ctx:        runtime.Context,
    owner:      rawptr,

    // Owner reads `CURLMSG_DONE` here, outside the curl region.
    after_pump: proc(d: ^Drive, owner: rawptr),
}

@(private)
Watch :: struct {
    fd:      Socket_Handle,
    sock:    nbio.Any_Socket,
    want:    Poll,
    recv_op: ^nbio.Operation,
    send_op: ^nbio.Operation,
    // True when `drive_open_socket` created the socket and this drive must close it.
    owned:   bool,
}

@(private)
drive_init :: proc(
    d: ^Drive,
    loop: ^nbio.Event_Loop,
    allocator: runtime.Allocator,
    owner: rawptr,
    after_pump: proc(d: ^Drive, owner: rawptr),
) -> Error {
    assert(d != nil, "drive_init needs a drive")
    assert(loop != nil, "drive_init needs an event loop")
    assert(d.multi == nil, "drive_init on an initialized drive")
    assert(owner != nil, "drive_init needs an owner")
    assert(after_pump != nil, "drive_init needs an after_pump")

    multi := c_multi_init()
    if multi == nil do return .Setup_Failed

    d.loop = loop
    d.multi = multi
    d.ctx = context
    d.owner = owner
    d.after_pump = after_pump
    d.timer_ms = -1
    d.watches.allocator = allocator

    if multi_setopt_ptr(multi, .Socket_Function, rawptr(drive_on_socket)) != .Ok ||
       multi_setopt_ptr(multi, .Socket_Data, d) != .Ok ||
       multi_setopt_ptr(multi, .Timer_Function, rawptr(drive_on_timer)) != .Ok ||
       multi_setopt_ptr(multi, .Timer_Data, d) != .Ok {
        drive_destroy(d)
        return .Setup_Failed
    }

    return .None
}

@(private)
drive_destroy :: proc(d: ^Drive) {
    assert(d != nil, "drive_destroy needs a drive")
    assert(!d.in_libcurl, "drive_destroy must not run inside a curl callback")

    drive_clear_io(d)

    if d.multi != nil {
        d.in_libcurl = true
        _ = c_multi_cleanup(d.multi)
        d.in_libcurl = false
        d.multi = nil
    }

    // `drive_close_socket` should have emptied this. Anything owned and left is
    // still ours to close; borrowed curl sockets are never closed at destroy.
    for watch in d.watches {
        if watch.owned do net.close(watch.sock)
    }

    delete(d.watches)
    d.watches = {}
}

@(private)
drive_clear_io :: proc(d: ^Drive) {
    assert(d != nil, "drive_clear_io needs a drive")

    if d.timer_op != nil {
        nbio.remove(d.timer_op)
        d.timer_op = nil
    }

    i := 0
    for i < len(d.watches) {
        watch := &d.watches[i]
        drive_watch_disarm(watch)
        watch.want = .None

        if !watch.owned {
            unordered_remove(&d.watches, i)
            continue
        }

        i += 1
    }

    d.timer_ms = -1
    d.timer_set = false
}

@(private)
drive_bind_easy :: proc(easy: ^Easy, d: ^Drive) -> Code {
    assert(easy != nil, "drive_bind_easy needs an easy handle")
    assert(d != nil, "drive_bind_easy needs a drive")

    setopt_open_socket_cb(easy, drive_open_socket) or_return
    setopt_ptr(easy, .Open_Socket_Data, d) or_return
    setopt_close_socket_cb(easy, drive_close_socket) or_return
    setopt_ptr(easy, .Close_Socket_Data, d) or_return

    return .Ok
}

// Starts or continues the multi. Defers if a pump is already running so On_Done
// can start the next transfer without re-entering the pump.
@(private)
drive_kick :: proc(d: ^Drive) {
    assert(d != nil, "drive_kick needs a drive")
    assert(d.multi != nil, "drive_kick needs an initialized drive")

    if d.pumping {
        d.need_kick = true
        return
    }

    drive_pump(d, SOCKET_TIMEOUT, {})
}

@(private)
drive_pump :: proc(d: ^Drive, fd: Socket_Handle, mask: Cselect_Bits) {
    assert(d != nil, "drive_pump needs a drive")
    assert(d.multi != nil, "drive_pump needs an initialized drive")
    assert(d.after_pump != nil, "drive_pump needs an after_pump")
    assert(!d.in_libcurl, "drive_pump re-entered the curl region")
    assert(!d.pumping, "drive_pump re-entered itself")

    d.pumping = true
    defer d.pumping = false
    next_fd := fd
    next_mask := mask
    for {
        d.need_kick = false
        d.in_libcurl = true
        code := multi_socket_action(d.multi, next_fd, next_mask)
        assert(code == .Ok || code == .Bad_Socket, "curl_multi_socket_action failed on a handle this package owns")
        d.in_libcurl = false

        d.after_pump(d, d.owner)

        if d.multi == nil do return

        if !d.need_kick {
            drive_apply(d)
            return
        }

        next_fd = SOCKET_TIMEOUT
        next_mask = {}
    }
}

@(private)
drive_apply :: proc(d: ^Drive) {
    assert(d != nil, "drive_apply needs a drive")
    assert(!d.in_libcurl, "drive_apply must not run inside a curl callback")

    i := 0
    for i < len(d.watches) {
        watch := &d.watches[i]
        if watch.want == .None || watch.want == .Remove {
            drive_watch_disarm(watch)

            if !watch.owned {
                unordered_remove(&d.watches, i)
                continue
            }

            watch.want = .None
            i += 1
            continue
        }

        want_recv := watch.want == .In || watch.want == .In_Out
        want_send := watch.want == .Out || watch.want == .In_Out

        if want_recv && watch.recv_op == nil {
            watch.recv_op = nbio.poll_poly(watch.sock, .Receive, d, drive_on_recv, nbio.NO_TIMEOUT, d.loop)
        } else if !want_recv && watch.recv_op != nil {
            nbio.remove(watch.recv_op)
            watch.recv_op = nil
        }

        if want_send && watch.send_op == nil {
            watch.send_op = nbio.poll_poly(watch.sock, .Send, d, drive_on_send, nbio.NO_TIMEOUT, d.loop)
        } else if !want_send && watch.send_op != nil {
            nbio.remove(watch.send_op)
            watch.send_op = nil
        }

        i += 1
    }

    if !d.timer_set do return

    d.timer_set = false

    if d.timer_op != nil {
        nbio.remove(d.timer_op)
        d.timer_op = nil
    }

    if d.timer_ms < 0 do return

    delay := time.Duration(d.timer_ms) * time.Millisecond
    d.timer_op = nbio.timeout_poly(delay, d, drive_on_timeout, d.loop)
}

@(private)
drive_watch_disarm :: proc(watch: ^Watch) {
    assert(watch != nil, "drive_watch_disarm needs a watch")

    if watch.recv_op != nil {
        nbio.remove(watch.recv_op)
        watch.recv_op = nil
    }

    if watch.send_op != nil {
        nbio.remove(watch.send_op)
        watch.send_op = nil
    }
}

@(private)
drive_watch_set :: proc(d: ^Drive, fd: Socket_Handle, want: Poll) -> bool {
    assert(d != nil, "drive_watch_set needs a drive")
    assert(fd != SOCKET_BAD, "drive_watch_set needs a real socket")

    for &watch in d.watches {
        if watch.fd == fd {
            watch.want = want
            return true
        }
    }

    if want == .None || want == .Remove do return true

    if reserve(&d.watches, len(d.watches) + 1) != nil do return false

    // Resolver or Happy-Eyeballs sockets curl created itself. Poll them, but do
    // not take ownership: `drive_close_socket` is not called for these.
    sock: nbio.Any_Socket = nbio.TCP_Socket(fd)
    if nbio.associate_socket(sock, d.loop) != nil do return false

    append(&d.watches, Watch{fd = fd, sock = sock, want = want})

    return true
}

@(private)
drive_on_socket :: proc "c" (easy: ^Easy, fd: Socket_Handle, what: Poll, user: rawptr, socketp: rawptr) -> c.int {
    d := (^Drive)(user)
    context = d.ctx
    _ = easy
    _ = socketp
    assert(d != nil, "drive_on_socket needs a drive")

    switch what {
    case .None, .In, .Out, .In_Out, .Remove:
        if !drive_watch_set(d, fd, what) do return -1

    case:
        return -1
    }

    return 0
}

@(private)
drive_on_timer :: proc "c" (multi: ^Multi, timeout_ms: c.long, user: rawptr) -> c.int {
    d := (^Drive)(user)
    context = d.ctx
    _ = multi
    assert(d != nil, "drive_on_timer needs a drive")
    d.timer_ms = int(timeout_ms)
    d.timer_set = true

    return 0
}

@(private)
drive_on_timeout :: proc(op: ^nbio.Operation, d: ^Drive) {
    assert(d != nil, "drive_on_timeout needs a drive")
    assert(d.timer_op == op, "drive_on_timeout fired for an operation the drive does not own")

    d.timer_op = nil
    drive_pump(d, SOCKET_TIMEOUT, {})
}

@(private)
drive_on_recv :: proc(op: ^nbio.Operation, d: ^Drive) {
    assert(d != nil, "drive_on_recv needs a drive")

    watch := drive_watch_by_recv(d, op)
    if watch == nil do return

    watch.recv_op = nil
    mask: Cselect_Bits = {.In} if op.poll.result == .Ready else {.Err}
    drive_pump(d, watch.fd, mask)
}

@(private)
drive_on_send :: proc(op: ^nbio.Operation, d: ^Drive) {
    assert(d != nil, "drive_on_send needs a drive")

    watch := drive_watch_by_send(d, op)
    if watch == nil do return

    watch.send_op = nil
    mask: Cselect_Bits = {.Out} if op.poll.result == .Ready else {.Err}
    drive_pump(d, watch.fd, mask)
}

@(private)
drive_watch_by_recv :: proc(d: ^Drive, op: ^nbio.Operation) -> ^Watch {
    for &watch in d.watches {
        if watch.recv_op == op do return &watch
    }

    return nil
}

@(private)
drive_watch_by_send :: proc(d: ^Drive, op: ^nbio.Operation) -> ^Watch {
    for &watch in d.watches {
        if watch.send_op == op do return &watch
    }

    return nil
}

@(private)
drive_open_socket :: proc "c" (user: rawptr, purpose: Socket_Purpose, addr: ^Curl_Sockaddr) -> Socket_Handle {
    d := (^Drive)(user)
    context = d.ctx
    assert(d != nil, "drive_open_socket needs a drive")
    if purpose != .Connect || addr == nil do return SOCKET_BAD

    family, protocol, ok := drive_sock_kind(addr)
    if !ok do return SOCKET_BAD

    sock, err := nbio.create_socket(family, protocol, d.loop)
    if err != nil do return SOCKET_BAD

    fd := drive_fd(sock)
    assert(fd != SOCKET_BAD, "nbio.create_socket returned an empty socket")
    if reserve(&d.watches, len(d.watches) + 1) != nil {
        net.close(sock)
        return SOCKET_BAD
    }

    append(&d.watches, Watch{fd = fd, sock = sock, owned = true})

    return fd
}

@(private)
drive_close_socket :: proc "c" (user: rawptr, fd: Socket_Handle) -> c.int {
    d := (^Drive)(user)
    context = d.ctx
    assert(d != nil, "drive_close_socket needs a drive")

    // Must `net.close` the fd before returning: curl's closesocket callback
    // contract. Disarm first so a pending poll does not sit on a closed socket.
    // `nbio.close` only queues a close until the next tick.
    for &watch, i in d.watches {
        if watch.fd != fd do continue

        drive_watch_disarm(&watch)
        net.close(watch.sock)
        unordered_remove(&d.watches, i)

        return 0
    }

    // The close callback replaces libcurl's close for every socket, including a
    // socket that stopped being polled before this callback arrived.
    net.close(nbio.TCP_Socket(fd))

    return 0
}

@(private)
drive_fd :: proc(sock: nbio.Any_Socket) -> Socket_Handle {
    switch s in sock {
    case nbio.TCP_Socket:
        return Socket_Handle(s)

    case nbio.UDP_Socket:
        return Socket_Handle(s)
    }

    return SOCKET_BAD
}

@(private)
drive_sock_kind :: proc(
    addr: ^Curl_Sockaddr,
) -> (
    family: nbio.Address_Family,
    protocol: nbio.Socket_Protocol,
    ok: bool,
) {
    assert(addr != nil, "drive_sock_kind needs a curl_sockaddr")

    switch addr.family {
    case .Inet:
        family = .IP4

    case .Inet6:
        family = .IP6

    case:
        return
    }

    switch addr.socktype {
    case .Stream:
        protocol = .TCP

    case .Dgram:
        protocol = .UDP

    case:
        return
    }

    return family, protocol, true
}
