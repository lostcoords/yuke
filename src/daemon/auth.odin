package daemon

import "core:crypto"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:slice"
import "core:strings"
import "core:time"

import "libs:bindings/curl"
import "libs:http"
import http_server "libs:http/server"
import ws "libs:websocket"
import "src:daemon/oauth"
import "src:daemon/store"
import "src:wire"

#assert(store.CREDENTIAL_SECRET_MAX_BYTES == wire.LIMITS.max_api_key_bytes)

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

    _, relayed := conn.tx.(Relay_Client)
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
    kind:           oauth.Kind,
    id:             wire.Login_Id,
    requested_flow: wire.Auth_Flow,
    phase:          Provider_Login_Phase,
    authorization:  oauth.Authorization_Flow,
    request_ticket: Conn_Ticket,
    request_id:     wire.Request_Id,
    device:         oauth.Device_Session,
    poll_timer:     ^nbio.Operation,
    deadline_timer: ^nbio.Operation,
    transfer:       curl.Transfer,
    response:       Bounded_Response,
}

// One daemon-owned refresh. `kind` resolves its immutable provider descriptor.
Provider_Refresh :: struct {
    kind:     oauth.Kind,
    transfer: curl.Transfer,
    response: Bounded_Response,
}

// Exactly one interactive login or autonomous refresh may own the auth service.
OAuth_Operation :: union {
    ^Provider_Login,
    ^Provider_Refresh,
}

// Active startup credentials, staged API-key changes, OAuth work, and HTTP client.
Provider_Auth :: struct {
    credentials:     [oauth.Kind]oauth.OAuth_Credentials,
    api_keys:        map[string]string,
    staged_api_keys: map[string]bool,
    callback:        http_server.Server,
    router:          Http_Router,
    callback_route:  [1]Http_Route,
    curl:            curl.Client,
    curl_ready:      bool,
    operation:       OAuth_Operation,
    refresh_timer:   ^nbio.Operation,
    stopping:        bool,
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

provider_credentials_get :: proc(
    d: ^Daemon,
    kind: oauth.Kind,
) -> (
    credentials: ^oauth.OAuth_Credentials,
    present: bool,
) {
    assert(d != nil, "credential lookup needs daemon state")
    credentials = &d.provider_auth.credentials[kind]

    if credentials.access_token == "" {
        assert(credentials^ == {}, "an absent credential slot is empty")
        return nil, false
    }

    assert(oauth.credentials_valid_for(oauth.provider(kind), credentials^), "live credentials are valid")

    return credentials, true
}

provider_credentials_install :: proc(d: ^Daemon, kind: oauth.Kind, credentials: ^oauth.OAuth_Credentials) {
    assert(d != nil && credentials != nil, "credential install needs owned state")
    assert(oauth.credentials_valid_for(oauth.provider(kind), credentials^), "installed credentials are valid")
    current := &d.provider_auth.credentials[kind]
    assert(credentials != current, "credential install cannot move a slot into itself")

    if current.access_token != "" {
        assert(oauth.credentials_valid_for(oauth.provider(kind), current^), "replaced credentials are valid")
        oauth.credentials_destroy(current, d.allocator)
    } else {
        assert(current^ == {}, "an empty credential slot has no partial state")
    }
    current^ = credentials^
    credentials^ = {}
}

provider_credentials_remove :: proc(d: ^Daemon, kind: oauth.Kind) -> bool {
    assert(d != nil, "credential removal needs daemon state")
    credentials := &d.provider_auth.credentials[kind]

    if credentials.access_token == "" {
        assert(credentials^ == {}, "an absent credential slot is empty")
        return false
    }

    assert(oauth.credentials_valid_for(oauth.provider(kind), credentials^), "removed credentials are valid")
    oauth.credentials_destroy(credentials, d.allocator)

    return true
}

provider_credentials_write :: proc(d: ^Daemon, kind: oauth.Kind, credentials: oauth.OAuth_Credentials) -> store.Error {
    assert(d != nil && d.store != nil, "credential write needs an open daemon store")
    provider := oauth.provider(kind)
    assert(oauth.credentials_valid_for(provider, credentials), "credential write needs valid credentials")

    return store.credential_oauth_upsert(
        d.store,
        provider.id,
        {
            access_token = credentials.access_token,
            refresh_token = credentials.refresh_token,
            expires_at_ms = credentials.expires_at_ms,
            account_id = credentials.account_id,
        },
    )
}

provider_credentials_load :: proc(d: ^Daemon) -> store.Error {
    assert(d != nil && d.store != nil, "credential load needs an open daemon store")
    for credentials in d.provider_auth.credentials {
        assert(credentials == {}, "credential load runs once")
    }

    loaded := store.credentials_load(d.store, d.allocator) or_return
    defer store.credentials_destroy(loaded)

    for &row in loaded {
        if row.kind == .Api_Key {
            if _, oauth_only := oauth.kind_from_id(row.provider_id); oauth_only {
                log.errorf("daemon: OAuth-only provider %s has an API-key credential", row.provider_id)
                return .Invalid_Row
            }

            if map_insert(&d.provider_auth.api_keys, row.provider_id, row.api_key) == nil {
                return .Alloc_Failed
            }
            row.provider_id = ""
            row.api_key = ""
            continue
        }

        kind, known := oauth.kind_from_id(row.provider_id)
        if !known {
            continue
        }

        credentials := oauth.OAuth_Credentials {
            access_token  = row.access_token,
            refresh_token = row.refresh_token,
            expires_at_ms = row.expires_at_ms,
            account_id    = row.account_id,
        }
        if !oauth.credentials_valid_for(oauth.provider(kind), credentials) {
            log.warnf("daemon: ignoring incomplete OAuth credentials for %s", row.provider_id)
            continue
        }

        row.access_token = ""
        row.refresh_token = ""
        row.account_id = ""
        provider_credentials_install(d, kind, &credentials)
    }

    return nil
}

provider_credentials_destroy :: proc(d: ^Daemon) {
    assert(d != nil, "credential cleanup needs daemon state")

    for kind in oauth.Kind {
        _ = provider_credentials_remove(d, kind)
    }

    for provider_id, api_key in d.provider_auth.api_keys {
        key := api_key
        delete(key, d.allocator)
        delete(provider_id, d.allocator)
    }
    delete(d.provider_auth.api_keys)
    d.provider_auth.api_keys = nil

    for provider_id in d.provider_auth.staged_api_keys {
        delete(provider_id, d.allocator)
    }
    delete(d.provider_auth.staged_api_keys)
    d.provider_auth.staged_api_keys = nil
}

// Load durable OAuth credentials and initialize the bounded HTTP client. A browser
// login binds its loopback callback only for the lifetime of that attempt.
provider_auth_init :: proc(d: ^Daemon) -> Error {
    assert(d != nil, "provider auth init needs daemon state")
    assert(d.store != nil, "provider auth needs an open daemon store")
    assert(!d.provider_auth.curl_ready, "provider auth initialized twice")
    assert(
        d.provider_auth.operation == nil && d.provider_auth.refresh_timer == nil && !d.provider_auth.stopping,
        "fresh provider auth has no work",
    )

    api_keys, api_keys_err := make(map[string]string, 8, d.allocator)
    staged, staged_err := make(map[string]bool, 8, d.allocator)
    if api_keys_err != nil || staged_err != nil {
        delete(api_keys)
        delete(staged)
        return .Out_Of_Memory
    }
    d.provider_auth.api_keys = api_keys
    d.provider_auth.staged_api_keys = staged

    if load_err := provider_credentials_load(d); load_err != nil {
        log.errorf("daemon: OAuth credentials could not be loaded: %v", load_err)
        return .Store_Failed
    }

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

auth_callback_open :: proc(d: ^Daemon, provider: ^oauth.Provider) -> Error {
    assert(d != nil && d.store != nil && d.provider_auth.curl_ready, "auth callback needs initialized auth")
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

// Stop callback admission and cancel active provider work.
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

// Release auth resources after the callback listener is closed.
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

    provider_credentials_destroy(d)
    d.provider_auth.router = {}
}

// Remember that API-key storage changed after this process started.
// The owned map key survives the request arena. `added` lets a failed store write roll it back.
provider_api_key_stage :: proc(d: ^Daemon, provider_id: string) -> (added, ok: bool) {
    assert(d != nil, "API-key staging needs daemon state")
    assert(d.provider_auth.staged_api_keys != nil, "API-key staging needs initialized auth")

    if provider_id in d.provider_auth.staged_api_keys {
        return false, true
    }

    owned, clone_err := strings.clone(provider_id, d.allocator)
    if clone_err != nil {
        return false, false
    }
    if map_insert(&d.provider_auth.staged_api_keys, owned, true) == nil {
        delete(owned, d.allocator)
        return false, false
    }

    return true, true
}

// Roll back a marker this request added before a failed store mutation.
provider_api_key_unstage :: proc(d: ^Daemon, provider_id: string) {
    assert(d != nil, "API-key unstaging needs daemon state")
    assert(provider_id in d.provider_auth.staged_api_keys, "API-key unstaging needs a marker")

    owned, _ := delete_key(&d.provider_auth.staged_api_keys, provider_id)
    assert(owned != "", "staged API-key map lost its owned key")

    delete(owned, d.allocator)
}

// The first signed-in provider already inside its proactive refresh window.
// One clock reading, never clones a secret.
provider_refresh_due :: proc(d: ^Daemon) -> (kind: oauth.Kind, found: bool) {
    assert(d != nil && d.provider_auth.curl_ready, "refresh scan needs initialized auth")
    now := now_ms()

    for candidate in oauth.Kind {
        provider := oauth.provider(candidate)
        credentials, present := provider_credentials_get(d, candidate)
        if !present {
            continue
        }

        if oauth.oauth_needs_refresh(provider, credentials.expires_at_ms, now) {
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
    if d.provider_auth.stopping || !d.provider_auth.curl_ready {
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

// Whether a login or refresh is in flight; at most one runs.
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
    assert(d != nil && d.store != nil && d.provider_auth.curl_ready, "refresh needs initialized auth")
    assert(!d.provider_auth.stopping, "refresh cannot start during shutdown")
    assert(!auth_busy(d), "refresh must be single flight")

    kind, found := provider_refresh_due(d)
    if !found {
        return true
    }

    provider := oauth.provider(kind)
    credentials, present := provider_credentials_get(d, kind)
    assert(present, "refresh scan returned a signed-in provider")

    refresh, refresh_aerr := new(Provider_Refresh, d.allocator)
    if refresh_aerr != nil {
        return false
    }
    refresh^ = {}
    refresh.kind = kind

    body, content_type, body_err := oauth.refresh_request_body(provider, credentials.refresh_token, d.allocator)
    if body_err != .None {
        provider_refresh_free(d, refresh)
        return false
    }
    defer delete(body, d.allocator)

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

    provider := oauth.provider(refresh.kind)
    response := bounded_response_body(&refresh.response)
    if result.code != .Ok || result.status < 200 || result.status >= 300 || refresh.response.overflow {
        permanent :=
            (result.status == 400 || result.status == 401) &&
            oauth.refresh_failure_permanent(provider, response, d.allocator)
        if permanent {
            log.warnf("daemon: %s refresh token is no longer usable; interactive login is required", provider.id)
        } else {
            log.warnf("daemon: %s token refresh failed: curl=%v status=%d", provider.id, result.code, result.status)
        }

        if permanent && !d.provider_auth.stopping {
            _, remove_err := store.credential_remove(d.store, provider.id)
            d.provider_auth.operation = nil
            provider_refresh_free(d, refresh)
            if remove_err != nil {
                log.errorf("daemon: %s invalid credentials could not be removed: %v", provider.id, remove_err)
            } else {
                removed := provider_credentials_remove(d, provider.kind)
                assert(removed, "an active refresh has live credentials")
                catalog_feed_invalidate(d)
                auth_changed_broadcast(d, provider.kind)
            }
            provider_refresh_schedule(d)
            return
        }

        d.provider_auth.operation = nil
        provider_refresh_free(d, refresh)
        if !d.provider_auth.stopping {
            provider_refresh_schedule(d)
        }
        return
    }

    existing, present := provider_credentials_get(d, refresh.kind)
    assert(present, "an active refresh has live credentials")

    credentials, parse_err := oauth.refresh_response_parse(provider, response, existing^, now_ms(), d.allocator)
    if parse_err != .None {
        d.provider_auth.operation = nil
        provider_refresh_free(d, refresh)
        log.warnf("daemon: %s token refresh returned an invalid response", provider.id)
        provider_refresh_schedule(d)
        return
    }

    write_err := provider_credentials_write(d, refresh.kind, credentials)

    d.provider_auth.operation = nil
    provider_refresh_free(d, refresh)
    if write_err != nil {
        oauth.credentials_destroy(&credentials, d.allocator)
        log.errorf("daemon: %s refreshed credentials could not be stored: %v", provider.id, write_err)
    } else {
        provider_credentials_install(d, provider.kind, &credentials)
    }
    provider_refresh_schedule(d)
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

    code, decode_err := oauth.query_value_decode(raw_code, d.allocator)
    if decode_err != .None || code == "" || len(code) > oauth.AUTHORIZATION_CODE_MAX_BYTES {
        http_server.respond_text(ctx.conn, .Bad_Request, "invalid authorization code")
        return
    }
    defer delete(code, d.allocator)

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
    provider := oauth.provider(login.kind)

    body, body_err := oauth.authorization_code_body(provider, login.authorization, code, d.allocator)
    if body_err != .None {
        return false
    }
    defer delete(body, d.allocator)

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
    provider := oauth.provider(login.kind)

    bounded_response_reset(&login.response)

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
    provider := oauth.provider(login.kind)

    body, content_type, body_err := oauth.device_auth_body(provider, AUTH_ORIGINATOR, d.allocator)
    if body_err != .None {
        return false
    }
    defer delete(body, d.allocator)

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
    provider := oauth.provider(login.kind)

    body, content_type, body_err := oauth.device_poll_body(provider, login.device, d.allocator)
    if body_err != .None {
        return false
    }
    defer delete(body, d.allocator)

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
    provider := oauth.provider(login.kind)

    bounded_response_reset(&login.response)

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

// Parse and store a login token response. Shared by the browser/device exchange
// and the RFC 8628 poll, whose success body is a token set.
provider_persist_login_response :: proc(d: ^Daemon) {
    login := provider_login(d)
    assert(login != nil, "token persistence needs a pending login")
    provider := oauth.provider(login.kind)

    credentials, parse_err := oauth.token_response_parse(
        provider,
        bounded_response_body(&login.response),
        now_ms(),
        d.allocator,
    )
    if parse_err != .None {
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "token response was invalid"})
        return
    }
    defer oauth.credentials_destroy(&credentials, d.allocator)

    if write_err := provider_credentials_write(d, login.kind, credentials); write_err != nil {
        log.errorf("daemon: %s login credentials could not be stored: %v", provider.id, write_err)
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "credentials could not be stored"})
        return
    }

    provider_credentials_install(d, login.kind, &credentials)
    catalog_feed_invalidate(d)
    provider_login_finish(d, wire.Auth_Login_Outcome_Succeeded{})
}

provider_device_user_code_on_done :: proc(user: rawptr, result: curl.Result) {
    d := (^Daemon)(user)
    login := provider_login(d)
    assert(login != nil, "device-code completion lost its login")
    assert(login.phase == .Device_Requesting_Code, "device-code completion arrived in the wrong phase")
    assert(login.transfer.state == .Done, "device-code completion needs a terminal transfer")
    provider := oauth.provider(login.kind)

    if result.code != .Ok || result.status < 200 || result.status >= 300 || login.response.overflow {
        provider_login_request_error(d, "device-code request failed")
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "device-code request failed"})
        return
    }

    device, parse_err := oauth.device_auth_parse(provider, bounded_response_body(&login.response), d.allocator)
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
    provider := oauth.provider(login.kind)

    if result.code != .Ok || login.response.overflow {
        provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "device approval poll failed"})
        return
    }

    outcome, classify_err := oauth.device_poll_classify(
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
    case oauth.Device_Pending:
        provider_device_poll_wait(d)

    case oauth.Device_Slow_Down:
        login.device.interval_s = min(
            login.device.interval_s + DEVICE_SLOW_DOWN_BUMP_S,
            oauth.DEVICE_POLL_INTERVAL_MAX_S,
        )
        provider_device_poll_wait(d)

    case oauth.Device_Tokens:
        provider_persist_login_response(d)

    case oauth.Device_Exchange:
        grant := step.grant
        defer oauth.device_grant_destroy(&grant, d.allocator)

        body, body_err := oauth.device_grant_body(provider, grant, d.allocator)
        if body_err != .None {
            provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "device token exchange could not start"})
            return
        }
        defer delete(body, d.allocator)

        if !provider_token_request_start(d, body) {
            provider_login_finish(d, wire.Auth_Login_Outcome_Failed{message = "device token exchange could not start"})
        }

    case oauth.Device_Failed:
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
provider_state :: proc(d: ^Daemon, kind: oauth.Kind) -> wire.Auth_Provider {
    assert(d != nil && d.provider_auth.curl_ready, "provider state needs initialized auth")
    provider := oauth.provider(kind)

    pending: Maybe(wire.Auth_Login_Summary)
    if login := provider_login(d); login != nil && login.kind == kind {
        pending = wire.Auth_Login_Summary {
            login_id = login.id,
            flow     = login.requested_flow,
        }
    }

    credential_kind: Maybe(wire.Auth_Credential_Kind)
    if _, present := provider_credentials_get(d, kind); present {
        credential_kind = wire.Auth_Credential_Kind.OAuth
    }

    return {
        provider_id = wire.Provider_Id(provider.id),
        credential_kind = credential_kind,
        restart_required = false,
        login_flows = LOGIN_FLOWS[:],
        pending_login = pending,
    }
}

// Stored and wire credential kinds are separate closed sets that correspond. Indexed by the enum,
// so a new stored kind fails the build rather than defaulting silently.
@(private = "file", rodata)
CREDENTIAL_KIND_WIRE := [store.Credential_Kind]wire.Auth_Credential_Kind {
    .Api_Key = .Api_Key,
    .OAuth   = .OAuth,
}

provider_credential_status :: proc(
    statuses: []store.Credential_Status,
    provider_id: string,
) -> (
    kind: store.Credential_Kind,
    found: bool,
) {
    for status in statuses {
        if status.provider_id == provider_id {
            return status.kind, true
        }
    }

    return {}, false
}

provider_public_count :: proc(d: ^Daemon, statuses: []store.Credential_Status) -> int {
    assert(d != nil, "provider count needs daemon state")

    count := len(statuses)
    for kind in oauth.Kind {
        if _, found := provider_credential_status(statuses, oauth.provider(kind).id); !found {
            count += 1
        }
    }
    for provider_id in d.provider_auth.api_keys {
        if _, found := provider_credential_status(statuses, provider_id); !found {
            count += 1
        }
    }

    return count
}

provider_stored_state :: proc(
    d: ^Daemon,
    provider_id: string,
    credential_kind: Maybe(wire.Auth_Credential_Kind),
) -> wire.Auth_Provider {
    assert(d != nil, "stored credential state needs daemon state")

    return {
        provider_id = wire.Provider_Id(provider_id),
        credential_kind = credential_kind,
        restart_required = provider_id in d.provider_auth.staged_api_keys,
    }
}

provider_state_less :: proc(a, b: wire.Auth_Provider) -> bool {
    return a.provider_id < b.provider_id
}

method_auth_list :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil && conn.state == .Ready, "auth.list needs a Ready connection")
    assert(req.method == .Auth_List, "auth.list received another method")

    d := conn.daemon
    statuses, load_err := store.credential_statuses_load(d.store, sa)
    if load_err != nil {
        log.errorf("daemon: credential status could not be read: %v", load_err)
        send_error(conn, req.id, .Internal, "credential status could not be read", sa)
        return
    }
    defer store.credential_statuses_destroy(statuses)

    count := provider_public_count(d, statuses[:])
    if count > wire.LIMITS.max_auth_providers {
        log.errorf("daemon: %d credential providers exceed the wire limit", count)
        send_error(conn, req.id, .Internal, "too many credential providers", sa)
        return
    }

    providers, make_err := make([dynamic]wire.Auth_Provider, 0, count, sa)
    if make_err != nil {
        conn_abort(conn, .Out_Of_Memory)
        return
    }

    for status in statuses {
        if kind, known := oauth.kind_from_id(status.provider_id); known {
            assert(status.kind == .OAuth, "OAuth-only provider retained an API-key row")
            append(&providers, provider_state(d, kind))
            continue
        }

        append(&providers, provider_stored_state(d, status.provider_id, CREDENTIAL_KIND_WIRE[status.kind]))
    }
    for kind in oauth.Kind {
        provider := oauth.provider(kind)
        if _, found := provider_credential_status(statuses[:], provider.id); !found {
            append(&providers, provider_state(d, kind))
        }
    }
    for provider_id in d.provider_auth.api_keys {
        if _, found := provider_credential_status(statuses[:], provider_id); found {
            continue
        }

        assert(provider_id in d.provider_auth.staged_api_keys, "an active removed API key needs restart")
        append(&providers, provider_stored_state(d, provider_id, nil))
    }

    assert(len(providers) == count, "provider status count diverged from its projection")
    slice.sort_by(providers[:], provider_state_less)
    send_result(conn, req.id, wire.Auth_List_Result{providers = providers[:]}, sa)
}

// API keys may cross only a loopback socket or the end-to-end encrypted relay.
provider_api_key_transport_allowed :: proc(conn: ^Conn) -> bool {
    assert(conn != nil && conn.tx != nil, "API-key admission needs a transport")

    switch t in conn.tx {
    case Relay_Client:
        peer := &t.relay.peers[t.channel]
        assert(peer.conn == conn && peer.established, "API-key relay admission needs an established peer")
        return true

    case ^ws.Server_Conn:
        endpoint, endpoint_err := net.peer_endpoint(t.socket)
        if endpoint_err != .None {
            return false
        }

        return http_server.address_is_loopback(endpoint.address)
    }

    unreachable()
}

method_auth_set_api_key :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil && conn.state == .Ready, "auth.set_api_key needs a Ready connection")
    assert(req.method == .Auth_Set_Api_Key, "auth.set_api_key received another method")

    if !provider_api_key_transport_allowed(conn) {
        send_error(conn, req.id, .Bad_Request, "API keys may be changed only over loopback or relay", sa)
        return
    }

    d := conn.daemon
    params := req.params.(wire.Auth_Set_Api_Key_Params)
    provider_id := string(params.provider_id)
    if _, oauth_only := oauth.kind_from_id(provider_id); oauth_only {
        send_error(conn, req.id, .Bad_Request, "provider accepts OAuth credentials only", sa)
        return
    }

    statuses, load_err := store.credential_statuses_load(d.store, sa)
    if load_err != nil {
        log.errorf("daemon: credential status could not be read: %v", load_err)
        send_error(conn, req.id, .Internal, "credential status could not be read", sa)
        return
    }
    defer store.credential_statuses_destroy(statuses)

    existing_kind, exists := provider_credential_status(statuses[:], provider_id)
    if exists && existing_kind == .OAuth {
        send_error(conn, req.id, .Bad_Request, "provider accepts OAuth credentials only", sa)
        return
    }
    if !exists &&
       provider_id not_in d.provider_auth.api_keys &&
       provider_public_count(d, statuses[:]) >= wire.LIMITS.max_auth_providers {
        send_error(conn, req.id, .Overloaded, "too many credential providers", sa)
        return
    }

    api_key, clone_err := strings.clone(params.api_key, d.allocator)
    if clone_err != nil {
        conn_abort(conn, .Out_Of_Memory)
        return
    }
    defer delete(api_key, d.allocator)

    staged, stage_ok := provider_api_key_stage(d, provider_id)
    if !stage_ok {
        conn_abort(conn, .Out_Of_Memory)
        return
    }

    if write_err := store.credential_api_key_upsert(d.store, provider_id, api_key); write_err != nil {
        if staged {
            provider_api_key_unstage(d, provider_id)
        }
        log.errorf("daemon: %s API key could not be stored: %v", provider_id, write_err)
        send_error(conn, req.id, .Internal, "API key could not be stored", sa)
        return
    }

    catalog_feed_invalidate(d)
    send_result(conn, req.id, wire.Auth_Set_Api_Key_Result{restart_required = true}, sa)
    _ = broadcast(
        d,
        wire.Auth_Changed_Data{provider = provider_stored_state(d, provider_id, wire.Auth_Credential_Kind.Api_Key)},
    )
}

method_auth_login :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil && conn.state == .Ready, "auth.login needs a Ready connection")
    assert(req.method == .Auth_Login, "auth.login received another method")
    d := conn.daemon
    params := req.params.(wire.Auth_Login_Params)

    kind, kind_ok := oauth.kind_from_id(string(params.provider_id))
    if !kind_ok {
        send_error(conn, req.id, .Bad_Request, "unknown authentication provider", sa)
        return
    }
    provider := oauth.provider(kind)

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
        authorization, flow_err := oauth.authorization_flow_create(
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

    send_error(conn, req.id, .Bad_Request, "unknown login attempt", sa)
}

method_auth_logout :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil && conn.state == .Ready, "auth.logout needs a Ready connection")
    assert(req.method == .Auth_Logout, "auth.logout received another method")
    d := conn.daemon
    params := req.params.(wire.Auth_Logout_Params)
    provider_id := string(params.provider_id)

    kind, kind_ok := oauth.kind_from_id(provider_id)
    if !kind_ok {
        statuses, load_err := store.credential_statuses_load(d.store, sa)
        if load_err != nil {
            log.errorf("daemon: credential status could not be read: %v", load_err)
            send_error(conn, req.id, .Internal, "credential status could not be read", sa)
            return
        }
        defer store.credential_statuses_destroy(statuses)

        credential_kind, found := provider_credential_status(statuses[:], provider_id)
        if !found {
            send_result(conn, req.id, wire.Empty{}, sa)
            return
        }
        if credential_kind != .Api_Key {
            send_error(conn, req.id, .Bad_Request, "unknown authentication provider", sa)
            return
        }

        staged, stage_ok := provider_api_key_stage(d, provider_id)
        if !stage_ok {
            conn_abort(conn, .Out_Of_Memory)
            return
        }

        removed, remove_err := store.credential_remove(d.store, provider_id)
        if remove_err != nil {
            if staged {
                provider_api_key_unstage(d, provider_id)
            }
            log.errorf("daemon: %s API key could not be removed: %v", provider_id, remove_err)
            send_error(conn, req.id, .Internal, "API key could not be removed", sa)
            return
        }
        assert(removed, "saved API-key status must remove one row")

        if provider_id not_in d.provider_auth.api_keys {
            provider_api_key_unstage(d, provider_id)
        }

        catalog_feed_invalidate(d)
        send_result(conn, req.id, wire.Empty{}, sa)
        _ = broadcast(d, wire.Auth_Changed_Data{provider = provider_stored_state(d, provider_id, nil)})
        return
    }
    provider := oauth.provider(kind)

    if auth_busy(d) {
        send_error(conn, req.id, .Overloaded, "provider authentication is busy", sa)
        return
    }

    if _, present := provider_credentials_get(d, kind); !present {
        send_result(conn, req.id, wire.Empty{}, sa)
        return
    }

    _, remove_err := store.credential_remove(d.store, provider.id)
    if remove_err != nil {
        log.errorf("daemon: %s credentials could not be removed: %v", provider.id, remove_err)
        send_error(conn, req.id, .Internal, "credentials could not be removed", sa)
        return
    }

    provider_refresh_timer_cancel(d)
    removed := provider_credentials_remove(d, kind)
    assert(removed, "signed-in provider has live credentials")
    catalog_feed_invalidate(d)
    send_result(conn, req.id, wire.Empty{}, sa)
    auth_changed_broadcast(d, kind)
    provider_refresh_schedule(d)
}

// Complete an interactive attempt and publish its terminal state.
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
    kind: oauth.Kind,
    login_id: wire.Login_Id,
    outcome: wire.Auth_Login_Outcome,
) {
    assert(d != nil && d.provider_auth.curl_ready, "login completion needs initialized auth")
    assert(wire.auth_login_outcome_validate(outcome) == .None, "daemon built an invalid auth outcome")
    provider := oauth.provider(kind)
    finished := wire.Auth_Login_Finished_Data {
        login_id    = login_id,
        provider_id = wire.Provider_Id(provider.id),
        outcome     = outcome,
    }
    _ = broadcast(d, finished)

    auth_changed_broadcast(d, kind)
    provider_refresh_schedule(d)
}

auth_changed_broadcast :: proc(d: ^Daemon, kind: oauth.Kind) {
    assert(d != nil && d.provider_auth.curl_ready, "auth.changed needs initialized auth")
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
    oauth.authorization_flow_destroy(&login.authorization, d.allocator)
    oauth.device_session_destroy(&login.device, d.allocator)
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
