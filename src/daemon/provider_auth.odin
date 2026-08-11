package daemon

import "base:runtime"
import "core:crypto"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:slice"
import "core:strings"
import "core:time"

import curl "libs:bindings/curl"
import http "libs:http"
import http_server "libs:http/server"
import "libs:offload"
import provider_auth "src:auth"
import "src:secret"
import wire "src:wire"

CONTROL_RESPONSE_MAX_BYTES :: 64 * 1024
AUTH_TOKEN_CONNECT_TIMEOUT :: 15 * time.Second
AUTH_TOKEN_TOTAL_TIMEOUT :: 60 * time.Second
AUTH_REFRESH_INTERVAL :: 1 * time.Minute
AUTH_BROWSER_TIMEOUT :: 10 * time.Minute

// Client-identity value sent to providers (browser `originator` / device `referrer`).
AUTH_ORIGINATOR :: "yuke-odin"

// Seconds added to the device poll interval on an RFC 8628 `slow_down`.
DEVICE_SLOW_DOWN_BUMP_S :: 5

@(rodata)
AUTH_CALLBACK_MIDDLEWARE := [?]Http_Middleware{{auth_callback_admit}}

// Every provider in the closed set supports both login mechanisms. The daemon
// admits browser login only from its local transport.
@(rodata)
LOGIN_FLOWS := [?]wire.Auth_Flow{.Browser, .Device_Code}

// Browser authorization binds a callback on the daemon host and is therefore a
// local-machine capability. Device authorization has no such transport coupling.
provider_login_flow_allowed :: proc(conn: ^Conn, flow: wire.Auth_Flow) -> bool {
    assert(conn != nil, "login flow admission needs a connection")
    assert(conn.tx != nil, "login flow admission needs a transport")

    if flow != .Browser {
        return true
    }

    _, relayed := conn.tx.(^Relay)
    return !relayed
}

Provider_Login_Phase :: enum {
    Browser_Awaiting_Callback,
    Device_Requesting_Code,
    Device_Polling,
    Device_Waiting_Poll,
    Token_Exchanging,
}

// Bounded accumulation buffer for one control-plane response body.
Bounded_Response :: struct {
    bytes:    [CONTROL_RESPONSE_MAX_BYTES]byte,
    filled:   int,
    overflow: bool,
}

// One daemon-owned login attempt; borrows no frame/connection, so it survives
// requester disconnect. `kind` resolves its immutable provider descriptor.
Provider_Login :: struct {
    kind:           provider_auth.Kind,
    id:             wire.Login_Id,
    requested_flow: wire.Auth_Flow,
    phase:          Provider_Login_Phase,
    authorization:  provider_auth.Authorization_Flow,
    request_ticket: Conn_Ticket,
    request_id:     wire.Request_Id,
    device:         provider_auth.Device_Session,
    poll_timer:     ^nbio.Operation,
    deadline_timer: ^nbio.Operation,
    transfer:       curl.Transfer,
    response:       Bounded_Response,
}

// One daemon-owned refresh. `existing` is the snapshot whose refresh token was
// sent, supplying merge defaults; `kind` resolves its immutable descriptor.
Provider_Refresh :: struct {
    kind:     provider_auth.Kind,
    transfer: curl.Transfer,
    existing: provider_auth.OAuth_Credentials,
    response: Bounded_Response,
}

Credential_Job_Kind :: enum {
    Login,
    Refresh,
    Logout,
    Invalidate,
}

// One blocking auth.json replacement. Its worker opens a separate snapshot,
// writes it durably, then the loop adopts it in one pointer swap.
Credential_Job :: struct {
    task:        offload.Task(Credential_Job),
    daemon:      ^Daemon,
    kind:        Credential_Job_Kind,
    provider_id: string,
    ticket:      Conn_Ticket,
    id:          wire.Request_Id,
    auth_path:   string,
    credentials: provider_auth.OAuth_Credentials,
    next_store:  ^provider_auth.Store,
    outcome:     Maybe(provider_auth.Error),
    arena:       mem.Dynamic_Arena,
    allocator:   mem.Allocator,
    login_id:    wire.Login_Id,
    login_flow:  wire.Auth_Flow,
}

// Exactly one interactive login, autonomous refresh, or credential replacement
// may own the auth service at a time.
OAuth_Operation :: union {
    ^Provider_Login,
    ^Provider_Refresh,
    ^Credential_Job,
}

// Provider credential storage, login/refresh state, callback listener, and HTTP client.
// Kept together so the daemon owns one auth subsystem instead of parallel loose fields.
Provider_Auth :: struct {
    path:           string,
    store:          ^provider_auth.Store,
    callback:       http_server.Server,
    router:         Http_Router,
    callback_route: [1]Http_Route,
    curl:           curl.Client,
    curl_ready:     bool,
    operation:      OAuth_Operation,
    refresh_timer:  ^nbio.Operation,
    stopping:       bool,
}

provider_login :: proc(d: ^Daemon) -> ^Provider_Login {
    assert(d != nil, "login lookup needs daemon state")
    login, _ := d.provider_auth.operation.(^Provider_Login)

    return login
}

provider_refresh :: proc(d: ^Daemon) -> ^Provider_Refresh {
    assert(d != nil, "refresh lookup needs daemon state")
    refresh, _ := d.provider_auth.operation.(^Provider_Refresh)

    return refresh
}

credential_job :: proc(d: ^Daemon) -> ^Credential_Job {
    assert(d != nil, "credential job lookup needs daemon state")
    job, _ := d.provider_auth.operation.(^Credential_Job)

    return job
}

// Initialize the optional credential store and bounded HTTP client. A browser
// login binds its loopback callback only for the lifetime of that attempt.
provider_auth_init :: proc(d: ^Daemon) -> Error {
    assert(d != nil, "provider auth init needs daemon state")
    assert(d.provider_auth.store == nil, "provider auth initialized twice")
    assert(
        d.provider_auth.operation == nil && d.provider_auth.refresh_timer == nil && !d.provider_auth.stopping,
        "fresh provider auth has no work",
    )

    if d.provider_auth.path == "" {
        return .None
    }

    opened, open_err := provider_auth.open(d.provider_auth.path, runtime.heap_allocator())
    if open_err != .None {
        log.errorf("daemon: credential store unavailable: %v", open_err)
        return .Auth_Failed
    }
    d.provider_auth.store = opened

    if curl_err := curl.client_init(&d.provider_auth.curl, d.loop, d.allocator); curl_err != .None {
        log.errorf("daemon: OAuth HTTP client unavailable: %v", curl_err)
        return .Auth_Failed
    }
    d.provider_auth.curl_ready = true

    // Pattern is filled per browser login in `auth_callback_open`; the listener
    // only binds during a live attempt, so the empty pattern here is never served.
    d.provider_auth.router = {
        middleware   = AUTH_CALLBACK_MIDDLEWARE[:],
        routes       = d.provider_auth.callback_route[:],
        user_data    = d,
        on_not_found = auth_callback_not_found,
    }
    provider_refresh_schedule(d, 0)

    return .None
}

auth_callback_open :: proc(d: ^Daemon, provider: ^provider_auth.Provider) -> Error {
    assert(d != nil && d.provider_auth.store != nil, "auth callback needs configured auth")
    assert(d.provider_auth.operation == nil, "auth callback opens before publishing its login")
    assert(provider != nil && len(provider.callback_ports) > 0, "auth callback opens for a browser provider")

    if d.provider_auth.callback.state == .Closed {
        http_server.destroy(&d.provider_auth.callback)
    }

    if d.provider_auth.callback.state != .Idle {
        return .Auth_Failed
    }

    // Serve exactly this provider's registered callback path; the browser is
    // redirected there and the listener rejects anything else.
    d.provider_auth.callback_route[0] = {
        method  = "GET",
        pattern = provider.callback_path,
        handler = route_auth_callback,
    }

    for port in provider.callback_ports {
        listen_err := http_server.router_listen(
            &d.provider_auth.callback,
            d.loop,
            {host = "127.0.0.1", port = port, max_connections = 8, max_body_bytes = 1},
            &d.provider_auth.router,
            d.allocator,
        )
        if listen_err == .None {
            bound_port := http_server.bound_port(&d.provider_auth.callback)
            assert(bound_port > 0, "OAuth callback bound no port")
            assert(port == 0 || bound_port == port, "OAuth callback bound the wrong fixed port")

            return .None
        }

        if listen_err == .Out_Of_Memory {
            return .Out_Of_Memory
        }

        if listen_err == .Invalid_Options {
            assert(false, "static OAuth callback options are invalid")
        }
    }

    return .Auth_Failed
}

auth_callback_close :: proc(d: ^Daemon) {
    assert(d != nil, "auth callback close needs daemon state")

    if d.provider_auth.callback.state == .Serving {
        http_server.shutdown(&d.provider_auth.callback)
    }
}

auth_callback_drain :: proc(d: ^Daemon) {
    assert(d != nil, "auth callback drain needs daemon state")

    if d.provider_auth.callback.state == .Serving {
        http_server.drain(&d.provider_auth.callback)
    }
}

// Stop callback admission and cancel an attempt that has not begun persistence.
provider_auth_shutdown :: proc(d: ^Daemon) {
    assert(d != nil, "provider auth shutdown needs daemon state")
    d.provider_auth.stopping = true

    provider_refresh_timer_cancel(d)
    if provider_refresh(d) != nil {
        provider_refresh_cancel(d)
    } else if provider_login(d) != nil {
        provider_login_discard(d)
    }

    auth_callback_close(d)
}

// Release auth resources after workers have drained and the callback listener is closed.
provider_auth_destroy :: proc(d: ^Daemon) {
    assert(d != nil, "provider auth destroy needs daemon state")
    assert(d.provider_auth.refresh_timer == nil, "provider auth destroyed with a refresh timer")
    assert(d.provider_auth.operation == nil, "provider auth destroyed with active work")

    if d.provider_auth.callback.state == .Closed || d.provider_auth.callback.state == .Idle {
        http_server.destroy(&d.provider_auth.callback)
    }
    if d.provider_auth.curl_ready {
        curl.client_destroy(&d.provider_auth.curl)
        d.provider_auth.curl_ready = false
    }

    if d.provider_auth.store != nil {
        provider_auth.close(d.provider_auth.store)
        d.provider_auth.store = nil
    }

    d.provider_auth.router = {}
}

// The first signed-in provider already inside its proactive refresh window.
// One clock reading, never clones a secret.
provider_refresh_due :: proc(d: ^Daemon) -> (kind: provider_auth.Kind, found: bool) {
    assert(d != nil && d.provider_auth.store != nil, "refresh scan needs configured auth")
    now := now_ms()

    for candidate in provider_auth.Kind {
        provider := provider_auth.provider(candidate)
        expires_at_ms, present := provider_auth.credentials_expiry(d.provider_auth.store, provider.id)
        if !present {
            continue
        }

        if provider_auth.oauth_needs_refresh(provider, expires_at_ms, now) {
            return candidate, true
        }
    }

    return {}, false
}

// Arm the autonomous maintenance tick. Expiry decides whether work is due; it
// does not create provider-specific timers.
provider_refresh_schedule :: proc(d: ^Daemon, delay: time.Duration = AUTH_REFRESH_INTERVAL) {
    assert(d != nil, "refresh scheduling needs daemon state")
    assert(delay >= 0, "refresh scheduling needs a non-negative delay")

    provider_refresh_timer_cancel(d)
    if d.provider_auth.stopping || d.provider_auth.store == nil {
        return
    }

    assert(d.provider_auth.refresh_timer == nil, "refresh timer scheduled twice")

    d.provider_auth.refresh_timer = nbio.timeout_poly(delay, d, provider_refresh_on_timer, d.loop)
    assert(d.provider_auth.refresh_timer != nil, "nbio returns a refresh timer")
}

provider_refresh_timer_cancel :: proc(d: ^Daemon) {
    assert(d != nil, "refresh timer cancellation needs daemon state")

    if d.provider_auth.refresh_timer != nil {
        nbio.remove(d.provider_auth.refresh_timer)
        d.provider_auth.refresh_timer = nil
    }
}

// Whether any login, refresh, or credential write is in flight; at most one runs.
auth_busy :: proc(d: ^Daemon) -> bool {
    assert(d != nil, "auth busy check needs daemon state")

    return d.provider_auth.operation != nil
}

provider_refresh_on_timer :: proc(op: ^nbio.Operation, d: ^Daemon) {
    assert(op != nil && d != nil, "refresh timer lost daemon state")
    assert(d.provider_auth.refresh_timer == op, "refresh timer crossed ownership")
    d.provider_auth.refresh_timer = nil

    if d.provider_auth.stopping {
        return
    }

    if auth_busy(d) {
        provider_refresh_schedule(d)
        return
    }

    _ = provider_refresh_start(d)
    if !auth_busy(d) {
        provider_refresh_schedule(d)
    }
}

provider_refresh_start :: proc(d: ^Daemon) -> bool {
    assert(d != nil && d.provider_auth.store != nil, "refresh needs configured auth")
    assert(!d.provider_auth.stopping, "refresh cannot start during shutdown")
    assert(!auth_busy(d), "refresh must be single flight")

    kind, found := provider_refresh_due(d)
    if !found {
        return true
    }

    provider := provider_auth.provider(kind)
    credentials, present, credential_err := provider_auth.credentials_get(
        d.provider_auth.store,
        provider.id,
        d.allocator,
    )
    if credential_err != .None {
        log.errorf("daemon: cannot read %s credentials for refresh: %v", provider.id, credential_err)
        return false
    }
    if !present {
        return true
    }

    refresh, refresh_aerr := new(Provider_Refresh, d.allocator)
    if refresh_aerr != nil {
        provider_auth.credentials_destroy(&credentials, d.allocator)
        return false
    }
    refresh^ = {}
    refresh.kind = kind
    refresh.existing = credentials

    body, content_type, body_err := provider_auth.refresh_request_body(
        provider,
        refresh.existing.refresh_token,
        d.allocator,
    )
    if body_err != .None {
        provider_refresh_free(d, refresh)
        return false
    }
    defer secret.string_destroy(&body, d.allocator)

    d.provider_auth.operation = refresh
    transfer_err := auth_transfer_start(
        d,
        &refresh.transfer,
        provider.token_url,
        body,
        content_type,
        provider_refresh_on_body,
        provider_refresh_on_done,
    )
    if transfer_err != .None {
        log.errorf("daemon: %s refresh setup failed: %v", provider.id, transfer_err)
        d.provider_auth.operation = nil
        provider_refresh_free(d, refresh)
        return false
    }

    assert(refresh.transfer.state == .Running, "started refresh owns a running transfer")

    return true
}

provider_refresh_on_body :: proc(user: rawptr, chunk: []byte) -> bool {
    d := (^Daemon)(user)
    refresh := provider_refresh(d)
    assert(refresh != nil, "refresh response lost its owner")
    assert(refresh.transfer.state == .Running, "refresh body needs a running transfer")

    return bounded_response_accumulate(&refresh.response, chunk)
}

provider_refresh_on_done :: proc(user: rawptr, result: curl.Result) {
    d := (^Daemon)(user)
    refresh := provider_refresh(d)
    assert(refresh != nil, "refresh completion lost its owner")
    assert(refresh.transfer.state == .Done, "refresh completion needs a terminal transfer")

    provider := provider_auth.provider(refresh.kind)
    response := bounded_response_body(&refresh.response)
    if result.code != .Ok || result.status < 200 || result.status >= 300 || refresh.response.overflow {
        permanent :=
            (result.status == 400 || result.status == 401) &&
            provider_auth.refresh_failure_permanent(provider, response, d.allocator)
        if permanent {
            log.warnf("daemon: %s refresh token is no longer usable; interactive login is required", provider.id)
        } else {
            log.warnf("daemon: %s token refresh failed: curl=%v status=%d", provider.id, result.code, result.status)
        }

        if permanent && !d.provider_auth.stopping {
            job := credential_job_create(d, .Invalidate, provider.id, nil, "")
            d.provider_auth.operation = nil
            provider_refresh_free(d, refresh)
            if job == nil {
                provider_refresh_schedule(d)
                return
            }

            credential_job_submit(d, job)
            return
        }

        d.provider_auth.operation = nil
        provider_refresh_free(d, refresh)
        if !d.provider_auth.stopping {
            provider_refresh_schedule(d)
        }
        return
    }

    job := credential_job_create(d, .Refresh, provider.id, nil, "")
    if job == nil {
        d.provider_auth.operation = nil
        provider_refresh_free(d, refresh)
        provider_refresh_schedule(d)
        return
    }

    credentials, parse_err := provider_auth.refresh_response_parse(
        provider,
        response,
        refresh.existing,
        now_ms(),
        job.allocator,
    )
    if parse_err != .None {
        credential_job_free(job)
        d.provider_auth.operation = nil
        provider_refresh_free(d, refresh)
        log.warnf("daemon: %s token refresh returned an invalid response", provider.id)
        provider_refresh_schedule(d)
        return
    }
    job.credentials = credentials

    d.provider_auth.operation = nil
    provider_refresh_free(d, refresh)
    credential_job_submit(d, job)
}

provider_refresh_cancel :: proc(d: ^Daemon) {
    refresh := provider_refresh(d)
    assert(refresh != nil, "refresh cancellation needs a live refresh")
    assert(refresh.transfer.state == .Running, "only a running refresh can be canceled")

    curl.transfer_cancel(&refresh.transfer)
    d.provider_auth.operation = nil
    provider_refresh_free(d, refresh)
}

provider_refresh_free :: proc(d: ^Daemon, refresh: ^Provider_Refresh) {
    assert(d != nil && refresh != nil, "refresh cleanup needs owned state")
    assert(refresh.transfer.state != .Running, "refresh cleanup with a live transfer")

    provider_auth.credentials_destroy(&refresh.existing, d.allocator)
    bounded_response_reset(&refresh.response)
    refresh^ = {}
    free(refresh, d.allocator)
}

// Reject non-loopback/rebound callback requests and make every response private.
auth_callback_admit :: proc(ctx: ^Http_Context) -> http_server.Middleware_Result {
    if !http_server.request_is_local(ctx.conn, ctx.request.head) {
        http_server.respond_text(ctx.conn, .Forbidden, "forbidden")

        return .Stop
    }

    if !http_server.conn_add_header(ctx.conn, "Cache-Control", "no-store") ||
       !http_server.conn_add_header(ctx.conn, "Referrer-Policy", "no-referrer") {
        return .Stop
    }

    return .Continue
}

auth_callback_not_found :: proc(ctx: ^Http_Context) {
    http_server.respond_text(ctx.conn, .Not_Found, "not found")
}

// Receive a state-matched OAuth redirect, then start a bounded token exchange.
route_auth_callback :: proc(ctx: ^Http_Context) {
    d := ctx.user_data
    login := provider_login(d)

    if ctx.request.pipelined {
        http_server.respond_text(ctx.conn, .Bad_Request, "pipelining not supported")
        return
    }

    if login == nil || login.phase != .Browser_Awaiting_Callback {
        http_server.respond_text(ctx.conn, .Gone, "no login is waiting")
        return
    }

    state, state_lookup := http.query_value(ctx.request.query, "state")
    if state_lookup != .One ||
       crypto.compare_constant_time(transmute([]byte)state, transmute([]byte)login.authorization.state) != 1 {
        http_server.respond_text(ctx.conn, .Bad_Request, "invalid login state")
        return
    }

    _, oauth_error_lookup := http.query_value(ctx.request.query, "error")
    if oauth_error_lookup == .Duplicate {
        http_server.respond_text(ctx.conn, .Bad_Request, "invalid OAuth response")
        return
    }

    if oauth_error_lookup == .One {
        http_server.respond_text(ctx.conn, .Bad_Request, "authorization was not completed")
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "authorization was not completed"})
        return
    }

    raw_code, code_lookup := http.query_value(ctx.request.query, "code")
    if code_lookup != .One {
        http_server.respond_text(ctx.conn, .Bad_Request, "missing authorization code")
        return
    }

    code, decode_err := provider_auth.query_value_decode(raw_code, d.allocator)
    if decode_err != .None || code == "" || len(code) > provider_auth.AUTHORIZATION_CODE_MAX_BYTES {
        http_server.respond_text(ctx.conn, .Bad_Request, "invalid authorization code")
        return
    }
    defer secret.string_destroy(&code, d.allocator)

    if !provider_token_exchange_start(d, code) {
        http_server.respond_text(ctx.conn, .Service_Unavailable, "cannot start token exchange")
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "token exchange could not start"})
        return
    }

    http_server.respond_text(ctx.conn, .Ok, "Authorization received. You may return to yuke.")
}

// Start the form-encoded authorization-code exchange. Curl copies every request
// field before this returns; the code and form body are then explicitly cleared.
provider_token_exchange_start :: proc(d: ^Daemon, code: string) -> bool {
    login := provider_login(d)
    assert(login != nil, "token exchange needs a pending login")
    assert(login.phase == .Browser_Awaiting_Callback, "token exchange started in the wrong phase")
    assert(login.transfer.state != .Running, "pending login already has a transfer")
    provider := provider_auth.provider(login.kind)

    body, body_err := provider_auth.authorization_code_body(provider, login.authorization, code, d.allocator)
    if body_err != .None {
        return false
    }
    defer secret.string_destroy(&body, d.allocator)

    return provider_token_request_start(d, body)
}

// Start one bounded OAuth control-plane POST on the daemon curl client. Curl copies
// every request field before returning, so the caller clears the secret body after.
auth_transfer_start :: proc(
    d: ^Daemon,
    transfer: ^curl.Transfer,
    url: cstring,
    body: string,
    content_type: string,
    on_body: curl.On_Body,
    on_done: curl.On_Done,
) -> curl.Error {
    assert(d != nil && d.provider_auth.curl_ready, "auth transfer needs a ready curl client")
    assert(transfer != nil && url != nil, "auth transfer needs a transfer and url")
    assert(body != "" && content_type != "" && on_done != nil, "auth transfer needs a body and completion")

    headers := [?]curl.Header {
        {name = "content-type", value = content_type},
        {name = "accept", value = "application/json"},
    }
    request := curl.Request {
        url             = url,
        headers         = headers[:],
        body            = transmute([]byte)body,
        method          = .Post,
        connect_timeout = AUTH_TOKEN_CONNECT_TIMEOUT,
        total_timeout   = AUTH_TOKEN_TOTAL_TIMEOUT,
    }
    callbacks := curl.Callbacks {
        on_body = on_body,
        on_done = on_done,
    }

    return curl.transfer_start(transfer, &d.provider_auth.curl, request, callbacks, d)
}

provider_token_request_start :: proc(d: ^Daemon, body: string) -> bool {
    login := provider_login(d)
    assert(login != nil, "token request needs a pending login")
    assert(login.transfer.state != .Running, "pending login already has a transfer")
    provider := provider_auth.provider(login.kind)

    provider_response_reset(login)

    transfer_err := auth_transfer_start(
        d,
        &login.transfer,
        provider.token_url,
        body,
        "application/x-www-form-urlencoded",
        provider_token_on_body,
        provider_token_on_done,
    )
    if transfer_err != .None {
        log.errorf("daemon: %s token exchange setup failed: %v", provider.id, transfer_err)
        return false
    }

    login.phase = .Token_Exchanging

    return true
}

provider_device_user_code_start :: proc(d: ^Daemon) -> bool {
    login := provider_login(d)
    assert(login != nil, "device-code request needs a pending login")
    assert(login.requested_flow == .Device_Code, "device-code request needs the device flow")
    assert(login.transfer.state != .Running, "device-code request raced another transfer")
    provider := provider_auth.provider(login.kind)

    body, content_type, body_err := provider_auth.device_auth_body(provider, AUTH_ORIGINATOR, d.allocator)
    if body_err != .None {
        return false
    }
    defer secret.string_destroy(&body, d.allocator)

    return provider_device_request_start(
        d,
        provider.device_user_code_url,
        body,
        content_type,
        provider_device_user_code_on_done,
        .Device_Requesting_Code,
    )
}

provider_device_poll_start :: proc(d: ^Daemon) -> bool {
    login := provider_login(d)
    assert(login != nil, "device poll needs a pending login")
    assert(login.requested_flow == .Device_Code, "device poll needs the device flow")
    assert(login.poll_timer == nil, "device poll started with a live timer")
    assert(login.transfer.state != .Running, "device poll raced another transfer")
    provider := provider_auth.provider(login.kind)

    body, content_type, body_err := provider_auth.device_poll_body(provider, login.device, d.allocator)
    if body_err != .None {
        return false
    }
    defer secret.string_destroy(&body, d.allocator)

    return provider_device_request_start(
        d,
        provider.device_token_url,
        body,
        content_type,
        provider_device_poll_on_done,
        .Device_Polling,
    )
}

provider_device_request_start :: proc(
    d: ^Daemon,
    url: cstring,
    body: string,
    content_type: string,
    on_done: curl.On_Done,
    phase: Provider_Login_Phase,
) -> bool {
    login := provider_login(d)
    assert(login != nil, "device request needs a pending login")
    assert(url != nil && body != "" && content_type != "" && on_done != nil, "device request needs complete input")
    assert(phase == .Device_Requesting_Code || phase == .Device_Polling, "device request has the wrong phase")
    assert(login.transfer.state != .Running, "device request raced another transfer")
    provider := provider_auth.provider(login.kind)

    provider_response_reset(login)

    transfer_err := auth_transfer_start(d, &login.transfer, url, body, content_type, provider_token_on_body, on_done)
    if transfer_err != .None {
        log.errorf("daemon: %s device request setup failed: %v", provider.id, transfer_err)
        return false
    }

    login.phase = phase

    return true
}

// Append a response chunk under the fixed bound; false marks overflow and stops.
bounded_response_accumulate :: proc(response: ^Bounded_Response, chunk: []byte) -> bool {
    assert(response != nil, "response accumulation needs a buffer")
    assert(response.filled >= 0 && response.filled <= len(response.bytes), "response length stays bounded")

    available := len(response.bytes) - response.filled
    if len(chunk) > available {
        response.overflow = true
        return false
    }

    copied := copy(response.bytes[response.filled:], chunk)
    assert(copied == len(chunk), "bounded response copy was short")
    response.filled += copied

    return true
}

// Wipe the accumulated secret bytes and reset for reuse.
bounded_response_reset :: proc(response: ^Bounded_Response) {
    assert(response != nil, "response reset needs a buffer")
    assert(response.filled >= 0 && response.filled <= len(response.bytes), "response length stays bounded")

    if response.filled > 0 {
        crypto.zero_explicit(&response.bytes[0], response.filled)
    }
    response.filled = 0
    response.overflow = false
}

// The accumulated body as a view; valid until the next reset.
bounded_response_body :: proc(response: ^Bounded_Response) -> string {
    assert(response != nil, "response body needs a buffer")

    return string(response.bytes[:response.filled])
}

provider_response_reset :: proc(login: ^Provider_Login) {
    assert(login != nil, "OAuth response reset needs a login")
    assert(login.transfer.state != .Running, "OAuth response reset raced a transfer")

    bounded_response_reset(&login.response)
}

provider_token_on_body :: proc(user: rawptr, chunk: []byte) -> bool {
    d := (^Daemon)(user)
    login := provider_login(d)
    assert(login != nil, "token response lost its login")
    assert(
        login.phase == .Device_Requesting_Code || login.phase == .Device_Polling || login.phase == .Token_Exchanging,
        "OAuth body arrived in a non-transfer phase",
    )

    return bounded_response_accumulate(&login.response, chunk)
}

provider_token_on_done :: proc(user: rawptr, result: curl.Result) {
    d := (^Daemon)(user)
    login := provider_login(d)
    assert(login != nil, "token completion lost its login")
    assert(login.phase == .Token_Exchanging, "token completion arrived in the wrong phase")
    assert(login.transfer.state == .Done, "token completion needs a terminal transfer")

    if result.code != .Ok || result.status < 200 || result.status >= 300 || login.response.overflow {
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "token exchange failed"})
        return
    }

    provider_persist_login_response(d)
}

// Parse the login's token response and hand it to a Login write. Shared by the
// browser/device exchange and the RFC 8628 poll, whose success body is a token set.
provider_persist_login_response :: proc(d: ^Daemon) {
    login := provider_login(d)
    assert(login != nil, "token persistence needs a pending login")
    provider := provider_auth.provider(login.kind)

    job := credential_job_create(d, .Login, provider.id, nil, "")
    if job == nil {
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "out of memory storing credentials"})
        return
    }

    credentials, parse_err := provider_auth.token_response_parse(
        provider,
        bounded_response_body(&login.response),
        now_ms(),
        job.allocator,
    )
    if parse_err != .None {
        credential_job_free(job)
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "token response was invalid"})
        return
    }
    job.credentials = credentials
    job.login_id = login.id
    job.login_flow = login.requested_flow

    d.provider_auth.operation = nil
    provider_login_release(d, login, true)
    credential_job_submit(d, job)
}

provider_device_user_code_on_done :: proc(user: rawptr, result: curl.Result) {
    d := (^Daemon)(user)
    login := provider_login(d)
    assert(login != nil, "device-code completion lost its login")
    assert(login.phase == .Device_Requesting_Code, "device-code completion arrived in the wrong phase")
    assert(login.transfer.state == .Done, "device-code completion needs a terminal transfer")
    provider := provider_auth.provider(login.kind)

    if result.code != .Ok || result.status < 200 || result.status >= 300 || login.response.overflow {
        provider_login_request_error(d, "device-code request failed")
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "device-code request failed"})
        return
    }

    device, parse_err := provider_auth.device_auth_parse(provider, bounded_response_body(&login.response), d.allocator)
    if parse_err != .None {
        provider_login_request_error(d, "device-code response was invalid")
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "device-code response was invalid"})
        return
    }
    login.device = device
    provider_login_deadline_arm(d, time.Duration(login.device.expires_in_s) * time.Second)

    conn := conn_resolve(d, login.request_ticket)
    if conn == nil {
        provider_login_finish(
            d,
            wire.Auth_Login_Outcome_Failed{message = "login requester disconnected before receiving the device code"},
        )
        return
    }

    result_value := wire.Auth_Login_Result_Device_Code {
        login_id         = login.id,
        verification_url = login.device.verification_uri,
        user_code        = login.device.user_code,
    }
    if !send_result(conn, login.request_id, result_value, d.allocator) {
        provider_login_request_clear(d, login)
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "device code could not be delivered"})
        return
    }
    provider_login_request_clear(d, login)
    auth_changed_broadcast(d, login.kind)

    started := false
    if provider.kind == .Xai {
        provider_device_poll_wait(d)
        started = true
    } else {
        started = provider_device_poll_start(d)
    }
    if !started {
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "device approval poll could not start"})
    }
}

provider_device_poll_on_done :: proc(user: rawptr, result: curl.Result) {
    d := (^Daemon)(user)
    login := provider_login(d)
    assert(login != nil, "device poll completion lost its login")
    assert(login.phase == .Device_Polling, "device poll completion arrived in the wrong phase")
    assert(login.transfer.state == .Done, "device poll completion needs a terminal transfer")
    provider := provider_auth.provider(login.kind)

    if result.code != .Ok || login.response.overflow {
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "device approval poll failed"})
        return
    }

    outcome, classify_err := provider_auth.device_poll_classify(
        provider,
        result.status,
        bounded_response_body(&login.response),
        d.allocator,
    )
    if classify_err != .None {
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "device approval response was invalid"})
        return
    }

    switch step in outcome {
    case provider_auth.Device_Pending:
        provider_device_poll_wait(d)

    case provider_auth.Device_Slow_Down:
        login.device.interval_s = min(
            login.device.interval_s + DEVICE_SLOW_DOWN_BUMP_S,
            provider_auth.DEVICE_POLL_INTERVAL_MAX_S,
        )
        provider_device_poll_wait(d)

    case provider_auth.Device_Tokens:
        provider_persist_login_response(d)

    case provider_auth.Device_Exchange:
        grant := step.grant
        defer provider_auth.device_grant_destroy(&grant, d.allocator)

        body, body_err := provider_auth.device_grant_body(provider, grant, d.allocator)
        if body_err != .None {
            provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "device token exchange could not start"})
            return
        }
        defer secret.string_destroy(&body, d.allocator)

        if !provider_token_request_start(d, body) {
            provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "device token exchange could not start"})
        }

    case provider_auth.Device_Failed:
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = step.message})
    }
}

// Arm the next device poll. The independent login deadline owns expiry.
provider_device_poll_wait :: proc(d: ^Daemon) {
    login := provider_login(d)
    assert(login != nil, "device poll wait needs a pending login")
    assert(login.poll_timer == nil, "device poll wait raced a live timer")

    assert(login.deadline_timer != nil, "device poll wait needs an expiry deadline")
    delay := time.Duration(login.device.interval_s) * time.Second
    login.phase = .Device_Waiting_Poll
    login.poll_timer = nbio.timeout_poly(delay, d, provider_device_poll_on_timer, d.loop)
    assert(login.poll_timer != nil, "nbio returns a device poll timer")
}

provider_device_poll_on_timer :: proc(op: ^nbio.Operation, d: ^Daemon) {
    login := provider_login(d)
    assert(op != nil && login != nil, "device poll timer lost its login")
    assert(login.phase == .Device_Waiting_Poll, "device poll timer fired in the wrong phase")
    assert(login.poll_timer == op, "device poll timer crossed attempt ownership")
    login.poll_timer = nil

    if !provider_device_poll_start(d) {
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "device approval poll could not start"})
    }
}

provider_login_deadline_arm :: proc(d: ^Daemon, timeout: time.Duration) {
    login := provider_login(d)
    assert(login != nil, "login deadline needs a pending attempt")
    assert(timeout > 0, "login deadline needs a positive timeout")
    assert(login.deadline_timer == nil, "login deadline armed twice")

    login.deadline_timer = nbio.timeout_poly(timeout, d, provider_login_on_deadline, d.loop)
    assert(login.deadline_timer != nil, "nbio returns a login deadline timer")
}

provider_login_deadline_cancel :: proc(login: ^Provider_Login) {
    assert(login != nil, "login deadline cancellation needs an attempt")

    if login.deadline_timer != nil {
        nbio.remove(login.deadline_timer)
        login.deadline_timer = nil
    }
}

provider_login_on_deadline :: proc(op: ^nbio.Operation, d: ^Daemon) {
    login := provider_login(d)
    assert(op != nil && login != nil, "login deadline lost its attempt")
    assert(login.deadline_timer == op, "login deadline crossed attempt ownership")
    login.deadline_timer = nil

    message := "browser login timed out"
    if login.requested_flow == .Device_Code {
        message = "device login timed out"
    }
    provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = message})
}

// Public current state for one authentication-capable provider.
provider_state :: proc(d: ^Daemon, kind: provider_auth.Kind) -> wire.Auth_Provider {
    assert(d != nil && d.provider_auth.store != nil, "provider state needs configured auth")
    provider := provider_auth.provider(kind)

    pending: Maybe(wire.Auth_Login_Summary)
    if login := provider_login(d); login != nil && login.kind == kind {
        pending = wire.Auth_Login_Summary {
            login_id = login.id,
            flow     = login.requested_flow,
        }
    } else if job := credential_job(d); job != nil && job.kind == .Login {
        login_kind, ok := provider_auth.kind_from_id(job.provider_id)
        assert(ok, "login job retained an unknown provider")

        if login_kind == kind {
            pending = wire.Auth_Login_Summary {
                login_id = job.login_id,
                flow     = job.login_flow,
            }
        }
    }

    state := wire.Auth_State.Signed_Out
    if provider_auth.credentials_present(d.provider_auth.store, provider.id) {
        state = .Signed_In
    }

    return {
        provider_id = wire.Provider_Id(provider.id),
        state = state,
        login_flows = LOGIN_FLOWS[:],
        pending_login = pending,
    }
}

method_auth_list :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil && conn.state == .Ready, "auth.list needs a Ready connection")
    assert(req.method == .Auth_List, "auth.list received another method")

    if conn.daemon.provider_auth.store == nil {
        send_result(conn, req.id, wire.Auth_List_Result{providers = nil}, sa)
        return
    }

    providers: [provider_auth.Kind]wire.Auth_Provider
    for kind in provider_auth.Kind {
        providers[kind] = provider_state(conn.daemon, kind)
    }
    send_result(conn, req.id, wire.Auth_List_Result{providers = slice.enumerated_array(&providers)}, sa)
}

method_auth_login :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil && conn.state == .Ready, "auth.login needs a Ready connection")
    assert(req.method == .Auth_Login, "auth.login received another method")
    d := conn.daemon
    params := req.params.(wire.Auth_Login_Params)

    if d.provider_auth.store == nil {
        send_error(conn, req.id, .Bad_Request, "provider authentication is not configured", sa)
        return
    }

    kind, kind_ok := provider_auth.kind_from_id(string(params.provider_id))
    if !kind_ok {
        send_error(conn, req.id, .Bad_Request, "unknown authentication provider", sa)
        return
    }
    provider := provider_auth.provider(kind)

    if params.flow != .Browser && params.flow != .Device_Code {
        send_error(conn, req.id, .Bad_Request, "provider does not support the requested login flow", sa)
        return
    }

    if !provider_login_flow_allowed(conn, params.flow) {
        send_error(conn, req.id, .Bad_Request, "browser login is available only over a local connection", sa)
        return
    }

    if auth_busy(d) {
        send_error(conn, req.id, .Overloaded, "provider authentication is busy", sa)
        return
    }

    login, aerr := new(Provider_Login, d.allocator)
    if aerr != nil {
        conn_abort(conn, .Out_Of_Memory)
        return
    }
    login^ = {}

    login.kind = kind
    login.id = login_id_create()
    login.requested_flow = params.flow

    switch params.flow {
    case .Browser:
        callback_err := auth_callback_open(d, provider)
        if callback_err != .None {
            free(login, d.allocator)
            if callback_err == .Out_Of_Memory {
                conn_abort(conn, .Out_Of_Memory)
            } else {
                send_error(conn, req.id, .Overloaded, "browser callback ports are unavailable", sa)
            }
            return
        }

        callback_port := http_server.bound_port(&d.provider_auth.callback)
        authorization, flow_err := provider_auth.authorization_flow_create(
            provider,
            callback_port,
            AUTH_ORIGINATOR,
            d.allocator,
        )
        if flow_err != .None {
            auth_callback_close(d)
            free(login, d.allocator)
            send_error(conn, req.id, .Internal, "cannot create authorization flow", sa)
            return
        }

        login.authorization = authorization
        login.phase = .Browser_Awaiting_Callback
        d.provider_auth.operation = login
        provider_login_deadline_arm(d, AUTH_BROWSER_TIMEOUT)

        result := wire.Auth_Login_Result_Browser {
            login_id = login.id,
            auth_url = login.authorization.auth_url,
        }
        if !send_result(conn, req.id, result, sa) {
            provider_login_finish(
                d,
                wire.Auth_Login_Outcome_Failed{message = "authorization URL could not be delivered"},
            )
            return
        }
        auth_changed_broadcast(d, kind)

    case .Device_Code:
        request_id, id_aerr := strings.clone(string(req.id), d.allocator)
        if id_aerr != nil {
            free(login, d.allocator)
            conn_abort(conn, .Out_Of_Memory)
            return
        }
        login.request_ticket = conn.ticket
        login.request_id = wire.Request_Id(request_id)
        d.provider_auth.operation = login

        if !provider_device_user_code_start(d) {
            d.provider_auth.operation = nil
            provider_login_free(d, login)
            send_error(conn, req.id, .Internal, "cannot start device-code login", sa)
        }
    }
}

method_auth_cancel_login :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil && conn.state == .Ready, "auth.cancel_login needs a Ready connection")
    assert(req.method == .Auth_Cancel_Login, "auth.cancel_login received another method")
    d := conn.daemon
    params := req.params.(wire.Auth_Cancel_Login_Params)
    login := provider_login(d)

    if login != nil && login.id == params.login_id {
        send_result(conn, req.id, wire.Empty{}, sa)
        provider_login_finish(d, wire.Auth_Login_Outcome_Canceled{})
        return
    }

    if job := credential_job(d); job != nil && job.kind == .Login && job.login_id == params.login_id {
        send_error(conn, req.id, .Overloaded, "login is completing", sa)
        return
    }

    send_error(conn, req.id, .Bad_Request, "unknown login attempt", sa)
}

method_auth_logout :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil && conn.state == .Ready, "auth.logout needs a Ready connection")
    assert(req.method == .Auth_Logout, "auth.logout received another method")
    d := conn.daemon
    params := req.params.(wire.Auth_Logout_Params)

    kind, kind_ok := provider_auth.kind_from_id(string(params.provider_id))
    if d.provider_auth.store == nil || !kind_ok {
        send_error(conn, req.id, .Bad_Request, "unknown authentication provider", sa)
        return
    }
    provider := provider_auth.provider(kind)

    if auth_busy(d) {
        send_error(conn, req.id, .Overloaded, "provider authentication is busy", sa)
        return
    }

    if !provider_auth.credentials_present(d.provider_auth.store, provider.id) {
        send_result(conn, req.id, wire.Empty{}, sa)
        return
    }

    job := credential_job_create(d, .Logout, provider.id, conn, req.id)
    if job == nil {
        conn_abort(conn, .Out_Of_Memory)
        return
    }

    provider_refresh_timer_cancel(d)
    credential_job_submit(d, job)
}

credential_job_submit :: proc(d: ^Daemon, job: ^Credential_Job) {
    assert(d != nil && job != nil, "credential submission needs owned state")
    assert(job.daemon == d, "credential job belongs to another daemon")
    assert(d.provider_auth.operation == nil, "credential jobs are single flight")

    d.provider_auth.operation = job
    offload.submit(&d.workers, job, credential_job_run, credential_job_done)
}

// Build a credential job with a worker-safe arena. Request identity is retained
// only for logout; login completion is reported by broadcasts and refresh is private.
credential_job_create :: proc(
    d: ^Daemon,
    kind: Credential_Job_Kind,
    provider_id: string,
    conn: ^Conn,
    id: wire.Request_Id,
) -> ^Credential_Job {
    assert(d != nil && d.provider_auth.store != nil, "credential job needs configured auth")
    assert(d.provider_auth.path != "", "credential job needs a store path")
    assert(provider_id != "", "credential job needs a provider id")

    job, aerr := new(Credential_Job, d.allocator)
    if aerr != nil {
        return nil
    }
    job^ = {}
    job.daemon = d
    job.kind = kind
    // A descriptor id is program-lifetime rodata, so it is shared, not cloned.
    job.provider_id = provider_id
    mem.dynamic_arena_init(&job.arena, runtime.heap_allocator(), runtime.heap_allocator())
    job.allocator = mem.dynamic_arena_allocator(&job.arena)

    path, path_aerr := strings.clone(d.provider_auth.path, job.allocator)
    if path_aerr != nil {
        credential_job_free(job)
        return nil
    }
    job.auth_path = path

    if kind == .Logout {
        assert(conn != nil && conn.ticket != 0, "logout job needs a requester")
        request_id, id_aerr := strings.clone(string(id), job.allocator)
        if id_aerr != nil {
            credential_job_free(job)
            return nil
        }
        job.ticket = conn.ticket
        job.id = wire.Request_Id(request_id)
    } else {
        assert(conn == nil && id == "", "login and refresh persistence have no pending request")
    }

    return job
}

credential_job_run :: proc(job: ^Credential_Job) {
    assert(job != nil && job.daemon != nil, "credential worker lost its job")
    assert(job.outcome == nil && job.next_store == nil, "credential worker ran twice")

    opened, open_err := provider_auth.open(job.auth_path, runtime.heap_allocator())
    if open_err != .None {
        job.outcome = open_err
        return
    }

    mutation_err := provider_auth.Error.None
    switch job.kind {
    case .Login, .Refresh:
        assert(provider_auth.credentials_valid(job.credentials), "credential write needs complete OAuth credentials")
        mutation_err = provider_auth.credentials_put(opened, job.provider_id, job.credentials)

    case .Logout, .Invalidate:
        _, mutation_err = provider_auth.provider_remove(opened, job.provider_id)
    }

    applied := mutation_err == .None || mutation_err == .Durability_Uncertain
    if !applied {
        provider_auth.close(opened)
        job.outcome = mutation_err
        return
    }

    job.next_store = opened
    job.outcome = mutation_err
}

credential_job_done :: proc(job: ^Credential_Job) {
    assert(job != nil && job.daemon != nil, "credential completion lost its job")
    d := job.daemon
    assert(credential_job(d) == job, "credential completion crossed write ownership")
    d.provider_auth.operation = nil
    defer credential_job_free(job)

    outcome, decided := job.outcome.?
    assert(decided, "credential worker completed without an outcome")
    applied := outcome == .None || outcome == .Durability_Uncertain
    kind, known := provider_auth.kind_from_id(job.provider_id)
    assert(known, "credential job retained an unknown provider")

    if applied {
        assert(job.next_store != nil, "published credential write has no snapshot")
        previous := d.provider_auth.store
        d.provider_auth.store = job.next_store
        job.next_store = nil
        provider_auth.close(previous)
        if outcome == .Durability_Uncertain {
            log.warn("daemon: credential replacement was published, but directory durability is uncertain")
        }
    } else {
        assert(job.next_store == nil, "failed credential write published a snapshot")
        log.errorf("daemon: credential store replacement failed: %v", outcome)
    }

    switch job.kind {
    case .Login:
        if applied {
            provider_login_finished(d, kind, job.login_id, wire.Auth_Login_Outcome_Succeeded{})
        } else {
            provider_login_finished(
                d,
                kind,
                job.login_id,
                wire.Auth_Login_Outcome_Failed{message = "credentials could not be stored"},
            )
        }

    case .Refresh:
        provider_refresh_schedule(d)

    case .Logout:
        conn := conn_resolve(d, job.ticket)
        if conn != nil {
            if applied {
                send_result(conn, job.id, wire.Empty{}, job.allocator)
            } else {
                send_error(conn, job.id, .Internal, "credentials could not be removed", job.allocator)
            }
        }

        if applied {
            auth_changed_broadcast(d, kind)
        }

        // Re-arm for whatever providers remain signed in; a single logout must
        // not disarm another provider's refresh.
        provider_refresh_schedule(d)

    case .Invalidate:
        if applied {
            auth_changed_broadcast(d, kind)
            provider_refresh_schedule(d)
        } else if !d.provider_auth.stopping {
            provider_refresh_schedule(d)
        }
    }
}

credential_job_free :: proc(job: ^Credential_Job) {
    assert(job != nil && job.daemon != nil, "credential cleanup needs job state")

    if job.next_store != nil {
        provider_auth.close(job.next_store)
        job.next_store = nil
    }

    provider_auth.credentials_destroy(&job.credentials, job.allocator)
    mem.dynamic_arena_destroy(&job.arena)
    free(job, job.daemon.allocator)
}

// Complete an interactive attempt. Credential persistence uses the smaller
// summary retained by its job and calls `provider_login_finished` directly.
provider_login_finish :: proc(d: ^Daemon, outcome: wire.Auth_Login_Outcome) {
    login := provider_login(d)
    assert(login != nil, "login finish needs a pending attempt")
    assert(wire.auth_login_outcome_validate(outcome) == .None, "daemon built an invalid auth outcome")

    provider_login_request_error(d, "login attempt ended before the device code was returned")

    kind := login.kind
    login_id := login.id
    d.provider_auth.operation = nil
    provider_login_release(d, login, true)
    provider_login_finished(d, kind, login_id, outcome)
}

provider_login_finished :: proc(
    d: ^Daemon,
    kind: provider_auth.Kind,
    login_id: wire.Login_Id,
    outcome: wire.Auth_Login_Outcome,
) {
    assert(d != nil && d.provider_auth.store != nil, "login completion needs configured auth")
    assert(wire.auth_login_outcome_validate(outcome) == .None, "daemon built an invalid auth outcome")
    provider := provider_auth.provider(kind)
    finished := wire.Auth_Login_Finished_Data {
        login_id    = login_id,
        provider_id = wire.Provider_Id(provider.id),
        outcome     = outcome,
    }
    _ = broadcast(d, finished)

    auth_changed_broadcast(d, kind)
    provider_refresh_schedule(d)
}

auth_changed_broadcast :: proc(d: ^Daemon, kind: provider_auth.Kind) {
    assert(d != nil && d.provider_auth.store != nil, "auth.changed needs configured auth")
    _ = broadcast(d, wire.Auth_Changed_Data{provider = provider_state(d, kind)})
}

// Shutdown-only cleanup: no terminal broadcast is promised after the daemon has
// stopped accepting work.
provider_login_discard :: proc(d: ^Daemon) {
    login := provider_login(d)
    assert(login != nil, "login discard needs a pending attempt")

    d.provider_auth.operation = nil
    provider_login_release(d, login, false)
}

provider_login_release :: proc(d: ^Daemon, login: ^Provider_Login, drain_callback: bool) {
    assert(d != nil && login != nil, "login release needs owned state")

    if login.requested_flow == .Browser {
        if drain_callback {
            auth_callback_drain(d)
        } else {
            auth_callback_close(d)
        }
    }

    if login.transfer.state == .Running {
        curl.transfer_cancel(&login.transfer)
    }
    if login.poll_timer != nil {
        nbio.remove(login.poll_timer)
        login.poll_timer = nil
    }
    provider_login_deadline_cancel(login)

    provider_login_free(d, login)
}

provider_login_free :: proc(d: ^Daemon, login: ^Provider_Login) {
    assert(d != nil && login != nil, "login cleanup needs owned state")
    assert(login.transfer.state != .Running, "login cleanup with a live transfer")

    assert(login.poll_timer == nil, "login cleanup with a live poll timer")
    assert(login.deadline_timer == nil, "login cleanup with a live deadline timer")
    provider_auth.authorization_flow_destroy(&login.authorization, d.allocator)
    provider_auth.device_session_destroy(&login.device, d.allocator)
    provider_login_request_clear(d, login)
    bounded_response_reset(&login.response)
    login^ = {}
    free(login, d.allocator)
}

provider_login_request_error :: proc(d: ^Daemon, message: string) {
    login := provider_login(d)
    assert(login != nil, "login request error needs a pending attempt")

    if login.request_ticket != 0 {
        assert(login.request_id != "", "retained login requester needs an id")

        if conn := conn_resolve(d, login.request_ticket); conn != nil {
            send_error(conn, login.request_id, .Internal, message, d.allocator)
        }
        provider_login_request_clear(d, login)
    } else {
        assert(login.request_id == "", "cleared login requester retained an id")
    }
}

provider_login_request_clear :: proc(d: ^Daemon, login: ^Provider_Login) {
    assert(d != nil && login != nil, "login requester cleanup needs owned state")

    if login.request_id != "" {
        delete(string(login.request_id), d.allocator)
    }
    login.request_ticket = 0
    login.request_id = ""
}

login_id_create :: proc() -> wire.Login_Id {
    random: [16]byte
    crypto.rand_bytes(random[:])

    out: [32]byte
    lower := "0123456789abcdef"
    for value, index in random {
        out[index * 2] = lower[value >> 4]
        out[index * 2 + 1] = lower[value & 0x0f]
    }

    return wire.Login_Id(out)
}
