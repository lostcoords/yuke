package http_server

import "core:log"
import "core:nbio"
import "core:strings"

// Whether a middleware leaves the connection for later steps or has already
// answered it (respond, hijack, or receive_body).
Middleware_Result :: enum {
    // Connection still `Reading`; the router continues.
    Continue,

    // Middleware already took ownership of the connection; the router returns.
    Stop,
}

// Path captures for a matched route. v1 supports one optional rest capture from a
// trailing `/*` pattern (for example `/blob/*` → hash). `Request.path` and
// `Request.query` carry the rest of what was derived from the target.
//
// `path_rest` borrows the request target (connection head buffer) and is valid only
// for the duration of the handler call. Clone before `receive_body` or any other work
// that outlives it.
Params :: struct {
    // Suffix after a `/*` prefix match; empty for an exact pattern, so it does not
    // distinguish "no capture" from "empty capture".
    path_rest: string,
}

// Pre-handler step. Runs in registration order before any route match. Returning
// `.Stop` means the middleware already responded, hijacked, or began a body receive.
// Returning `.Continue` requires the connection still be `Reading`.
Middleware :: #type proc(c: ^Conn, req: Request, user_data: rawptr) -> Middleware_Result

// Matched route entry point. Must respond, hijack, or receive_body before return,
// same contract as `On_Request`. `params` borrows as documented on `Params`.
Handler :: #type proc(c: ^Conn, req: Request, params: Params, user_data: rawptr)

// One method + path pattern → handler. `pattern` is an exact path (`/ws`) or a
// single prefix capture ending in `/*` (`/blob/*`).
Route :: struct {
    method:  string,
    pattern: string,
    handler: Handler,
}

// Unmatched path. Must respond, hijack, or receive_body before return—same connection
// contract as `Handler`. When nil on the router, the default emits plain text.
Not_Found_Handler :: #type proc(c: ^Conn, req: Request, user_data: rawptr)

// Path pattern known, method not. `allow` is the comma-joined method list registered
// for the matched pattern, which RFC 9110 §15.5.6 requires a 405 to carry as `Allow`;
// it borrows router scratch and is valid only for the call. Same connection contract
// as `Handler`. When nil on the router, the default emits plain text plus `Allow`.
Method_Not_Allowed_Handler :: #type proc(c: ^Conn, req: Request, allow: string, user_data: rawptr)

// Ceiling on a rendered `Allow` value. `router_validate` proves the table fits, so the
// render itself cannot truncate — a configuration bug is caught at wiring time, where
// assertions still run, rather than on the request path.
@(private)
ROUTER_ALLOW_MAX :: 256

// Application route table used as `Server.user_data` with `router_on_request`.
// Middleware always runs before match so auth can precede route/method disclosure.
//
// `middleware` and `routes` are borrowed; the `Router` value (and those slices)
// must outlive every connection still served by the owning `Server`. Pass it through
// `router_validate` once before serving.
Router :: struct {
    // Pre-match steps; may be empty.
    middleware:            []Middleware,

    // Registered routes; first method+pattern match wins.
    routes:                []Route,

    // Passed to every middleware, handler, and fallback.
    user_data:             rawptr,

    // Unmatched path after middleware; nil → default `"not found"`.
    on_not_found:          Not_Found_Handler,

    // Path matched a registered pattern but not this method; nil → default
    // `"method not allowed"` with `Allow`.
    on_method_not_allowed: Method_Not_Allowed_Handler,
}

// Check a route table once, before serving. A violation is a wiring bug in the
// application, not anything a request can reach, so these are assertions: without them
// a malformed pattern silently never matches and the route is dead with no diagnostic.
router_validate :: proc(r: ^Router) {
    assert(r != nil, "router_validate needs a router")

    for mw in r.middleware {
        assert(mw != nil, "router middleware slot is nil")
    }

    // Every method could share one pattern, so the widest `Allow` is the whole table.
    allow_width := 0
    for route, i in r.routes {
        assert(route.handler != nil, "router route has no handler")
        assert(len(route.method) > 0, "router route needs a method")
        assert(len(route.pattern) > 0 && route.pattern[0] == '/', "router pattern must start with `/`")

        if strings.index_byte(route.pattern, '*') >= 0 {
            assert(strings.has_suffix(route.pattern, "/*"), "`*` is only valid as a trailing `/*` segment")
        }

        for earlier in r.routes[:i] {
            duplicate := earlier.method == route.method && earlier.pattern == route.pattern
            assert(!duplicate, "duplicate method+pattern: the later route can never match")
        }

        allow_width += len(route.method) + 2
    }

    assert(allow_width <= ROUTER_ALLOW_MAX, "ROUTER_ALLOW_MAX too small for this route table")
}

// Bind a server that dispatches through `r`. Validates the table, then listens — so no
// caller has to remember `router_validate`.
router_listen :: proc(
    s: ^Server,
    loop: ^nbio.Event_Loop,
    options: Options,
    r: ^Router,
    allocator := context.allocator,
) -> Error {
    assert(r != nil, "router_listen needs a router")

    router_validate(r)

    return listen(s, loop, options, router_on_request, r, allocator)
}

// `On_Request` entry for a `Server` whose `user_data` is a `^Router`.
router_on_request :: proc(c: ^Conn, req: Request) {
    assert(c != nil && c.server != nil, "router needs an owned connection")
    assert(req.head.consumed == len(req.head.bytes), "router received an inconsistent parsed head")

    r := (^Router)(c.server.user_data)
    assert(r != nil, "router_on_request needs Server.user_data as ^Router")

    path := req.path

    for mw in r.middleware {
        switch mw(c, req, r.user_data) {
        case .Stop:
            assert(c.state != .Reading, "middleware returned Stop without answering the connection")
            return

        case .Continue:
            assert(c.state == .Reading, "middleware returned Continue after answering the connection")
        }
    }

    method := req.head.method

    path_matched := false
    for route in r.routes {
        rest, path_ok := match_route_path(route.pattern, path)
        if !path_ok {
            continue
        }

        path_matched = true
        if route.method != method {
            continue
        }

        route.handler(c, req, Params{path_rest = rest}, r.user_data)

        return
    }

    if path_matched {
        allow_buf: [ROUTER_ALLOW_MAX]byte
        allow := router_allow_value(r, path, allow_buf[:])

        log.debugf("http_server: method not allowed %s %s", method, path)
        if r.on_method_not_allowed != nil {
            r.on_method_not_allowed(c, req, allow, r.user_data)
        } else {
            headers := [1]Header{{name = "Allow", value = allow}}
            conn_respond_error(c, .Method_Not_Allowed, "method not allowed", headers[:])
        }

        return
    }

    log.debugf("http_server: not found %s", path)
    if r.on_not_found != nil {
        r.on_not_found(c, req, r.user_data)
    } else {
        conn_respond_error(c, .Not_Found, "not found")
    }
}

// Exact path, or prefix capture when `pattern` ends with `/*`. The prefix includes
// the slash before `*` (`/blob/*` matches `/blob/abc` with rest `abc`). `path_rest` is
// raw target bytes: never percent-decoded, and it can span `/`.
@(private)
match_route_path :: proc(pattern: string, path: string) -> (rest: string, ok: bool) {
    if strings.has_suffix(pattern, "/*") {
        // Drop the trailing `*`; keep the slash so `/blob/*` → prefix `/blob/`.
        prefix := pattern[:len(pattern) - 1]

        if !strings.has_prefix(path, prefix) {
            return "", false
        }

        return path[len(prefix):], true
    }

    if path == pattern {
        return "", true
    }

    return "", false
}

// Every method reachable at `path` — across all patterns that match it — comma-joined
// into `buf` as an `Allow` value. Only called once a pattern has matched, so the result
// is never empty, and `router_validate` proves `buf` fits and that no method repeats.
@(private)
router_allow_value :: proc(r: ^Router, path: string, buf: []byte) -> string {
    assert(r != nil && len(buf) > 0, "Allow rendering needs a router and a buffer")

    n := 0
    for route in r.routes {
        if _, ok := match_route_path(route.pattern, path); !ok {
            continue
        }

        if n > 0 {
            n += copy(buf[n:], ", ")
        }

        n += copy(buf[n:], route.method)
    }

    assert(n > 0, "a 405 needs at least one method registered for the path")

    return string(buf[:n])
}
