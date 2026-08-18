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

// Per-request state handed to every middleware, handler, and fallback.
//
// Each callback must respond, hijack, or `receive_body` before returning — the same
// connection contract `On_Request` carries.
//
// Owned by `router_dispatch`'s frame and valid only for that call: never store or
// capture a `^Context`. Work that answers later keeps a `^Conn` or a `Ticket`
// instead, which is why the `respond*` helpers take a connection rather than a
// context.
//
// `request` is read-only. The router matched on the target and asserts it is
// unchanged once middleware has run.
Context :: struct($T: typeid) {
    // Connection to answer. Never nil: dispatch owns it before building a context.
    conn:      ^Conn,

    // Validated request. Every field borrows the connection head buffer and is valid
    // only for the call.
    request:   Request,

    // Path captures; meaningful only inside a matched route's handler, zero in
    // middleware and in both fallbacks.
    params:    Params,

    // Comma-joined method list for the matched pattern, which RFC 9110 §15.5.6
    // requires a 405 to carry as `Allow`. Set only for `on_method_not_allowed` and
    // empty everywhere else; borrows dispatch scratch, so it too lasts only the call.
    allow:     string,

    // The application, as `Router.user_data`. Never nil: `router_validate` proves it.
    user_data: ^T,
}

// Pre-handler step. Runs in registration order before any route match, so auth can
// precede route and method disclosure. Returning `.Stop` means it already responded,
// hijacked, or began a body receive; `.Continue` requires the connection still be
// `Reading`.
Middleware :: struct($T: typeid) {
    run: proc(ctx: ^Context(T)) -> Middleware_Result,
}

// One method + path pattern → handler. `pattern` is an exact path (`/ws`) or a
// single prefix capture ending in `/*` (`/blob/*`).
Route :: struct($T: typeid) {
    method:  string,
    pattern: string,
    handler: proc(ctx: ^Context(T)),
}

// Ceiling on a rendered `Allow` value. `router_validate` proves the table fits, so the
// render itself cannot truncate — a configuration bug is caught at wiring time, where
// assertions still run, rather than on the request path.
@(private)
ROUTER_ALLOW_MAX :: 256

// Application route table, stored as `Server.user_data` by `router_listen`.
// Middleware always runs before match so auth can precede route/method disclosure.
//
// `middleware` and `routes` are borrowed; the `Router` value (and those slices)
// must outlive every connection still served by the owning `Server`. `router_listen`
// validates it once before serving.
Router :: struct($T: typeid) {
    // Pre-match steps; may be empty.
    middleware:            []Middleware(T),

    // Registered routes; first method+pattern match wins.
    routes:                []Route(T),

    // The application, reaching every callback as `Context.user_data`.
    user_data:             ^T,

    // Unmatched path after middleware; nil → default `"not found"`.
    on_not_found:          proc(ctx: ^Context(T)),

    // Path matched a registered pattern but not this method; nil → default
    // `"method not allowed"` with `Allow`. Reads `Context.allow`.
    on_method_not_allowed: proc(ctx: ^Context(T)),
}

// Check a route table once, before serving. A violation is a wiring bug in the
// application, not anything a request can reach, so these are assertions: without them
// a malformed pattern silently never matches and the route is dead with no diagnostic.
router_validate :: proc(r: ^Router($T)) {
    assert(r != nil, "router_validate needs a router")
    assert(r.user_data != nil, "router needs its application; every callback dereferences it")

    for mw in r.middleware {
        assert(mw.run != nil, "router middleware slot is nil")
    }

    // Every method could share one pattern, so the widest `Allow` is the whole table.
    allow_width := 0
    for route, i in r.routes {
        assert(route.handler != nil, "router route has no handler")
        assert(len(route.method) > 0, "router route needs a method")
        assert(len(route.pattern) > 0 && route.pattern[0] == '/', "router pattern must start with `/`")

        if strings.index_byte(route.pattern, '*') >= 0 do assert(strings.has_suffix(route.pattern, "/*"), "`*` is only valid as a trailing `/*` segment")

        for earlier in r.routes[:i] {
            duplicate := earlier.method == route.method && earlier.pattern == route.pattern
            assert(!duplicate, "duplicate method+pattern: the later route can never match")
        }

        allow_width += len(route.method) + 2
    }

    assert(allow_width <= ROUTER_ALLOW_MAX, "ROUTER_ALLOW_MAX too small for this route table")
}

// Bind a server that dispatches through `r`. Deriving both the stored pointer and the
// request callback from one `T` is what makes a mismatched pair unrepresentable, so
// this is the only way to bind a router.
router_listen :: proc(
    s: ^Server,
    loop: ^nbio.Event_Loop,
    options: Options,
    r: ^Router($T),
    allocator := context.allocator,
) -> Error {
    assert(r != nil, "router_listen needs a router")

    router_validate(r)

    return listen(s, loop, options, router_on_request(T), r, allocator)
}

// `On_Request` entry for a `Server` whose `user_data` is a `^Router(T)`, monomorphized
// per `T`. The one unsafe load the router needs, generated inside the library.
@(private)
router_on_request :: proc($T: typeid) -> On_Request {
    return proc(c: ^Conn, req: Request) {
            assert(c != nil && c.server != nil, "router needs an owned connection")

            router_dispatch((^Router(T))(c.server.user_data), c, req)
        }
}

// Middleware, then first method+pattern match, then a fallback. `req` stays the
// pristine copy the driver parsed, so it is what the post-middleware assertions
// compare against.
@(private)
router_dispatch :: proc(r: ^Router($T), c: ^Conn, req: Request) {
    assert(r != nil, "dispatch needs Server.user_data as ^Router(T)")
    assert(r.user_data != nil, "router_validate should have rejected a router with no application")
    assert(req.head.consumed == len(req.head.bytes), "router received an inconsistent parsed head")

    path := req.path
    method := req.head.method

    ctx := Context(T) {
        conn      = c,
        request   = req,
        user_data = r.user_data,
    }

    for mw in r.middleware {
        switch mw.run(&ctx) {
        case .Stop:
            assert(c.state != .Reading, "middleware returned Stop without answering the connection")
            return

        case .Continue:
            assert(c.state == .Reading, "middleware returned Continue after answering the connection")
        }
    }

    // `^Context` makes the request mutable where the old by-value argument did not,
    // and these two fields are what dispatch matches on.
    assert(ctx.request.path == path, "middleware must not rewrite the request path")
    assert(ctx.request.head.method == method, "middleware must not rewrite the request method")

    path_matched := false
    for route in r.routes {
        rest, path_ok := match_route_path(route.pattern, path)
        if !path_ok do continue

        path_matched = true
        if route.method != method do continue

        assert(ctx.allow == "", "`allow` belongs to the 405 fallback alone")

        ctx.params = Params {
            path_rest = rest,
        }
        route.handler(&ctx)

        return
    }

    assert(ctx.params == {}, "no route matched, so nothing may have captured params")

    if path_matched {
        allow_buf: [ROUTER_ALLOW_MAX]byte
        ctx.allow = router_allow_value(r, path, allow_buf[:])

        log.debugf("http_server: method not allowed %s %s", method, path)
        if r.on_method_not_allowed != nil {
            r.on_method_not_allowed(&ctx)
            return
        }

        // RFC 9110 §15.5.6: a 405 names the methods the path does route, so one that
        // cannot carry `Allow` is torn down rather than sent without it.
        if !conn_add_header(c, "Allow", ctx.allow) do return

        conn_respond_error(c, .Method_Not_Allowed, "method not allowed")

        return
    }

    log.debugf("http_server: not found %s", path)
    if r.on_not_found != nil {
        r.on_not_found(&ctx)
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

        if !strings.has_prefix(path, prefix) do return "", false

        return path[len(prefix):], true
    }

    if path == pattern do return "", true

    return "", false
}

// Every method reachable at `path` — across all patterns that match it — comma-joined
// into `buf` as an `Allow` value. Only called once a pattern has matched, so the result
// is never empty, and `router_validate` proves `buf` fits and that no method repeats.
@(private)
router_allow_value :: proc(r: ^Router($T), path: string, buf: []byte) -> string {
    assert(r != nil && len(buf) > 0, "Allow rendering needs a router and a buffer")

    n := 0
    for route in r.routes {
        if _, ok := match_route_path(route.pattern, path); !ok do continue

        if n > 0 do n += copy(buf[n:], ", ")

        n += copy(buf[n:], route.method)
    }

    assert(n > 0, "a 405 needs at least one method registered for the path")

    return string(buf[:n])
}
