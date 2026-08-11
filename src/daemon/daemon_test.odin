package daemon

import "core:crypto"
import "core:encoding/base64"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import curl "libs:bindings/curl"
import http_server "libs:http/server"
import "libs:offload"
import ws "libs:websocket"
import provider_auth "src:auth"
import client "src:client"
import store "src:daemon/store"
import wire "src:wire"

// --- Daemon driver tests ------------------------------------------------------
//
// These drive the EXISTING `src/client` driver against the new `daemon` on ONE
// shared `nbio.Event_Loop`, in-process, no worker threads — accept, upgrade, the
// initialize exchange, and request routing all interleave on a single loop. The
// protocol-error cases (malformed/oversequenced frames, wrong protocol version,
// binary frame, trailing bytes) need a peer the `src/client` driver cannot be —
// it only ever sends a well-formed `initialize` request — so those use a blocking raw
// TCP peer on a worker thread while the daemon drives the loop on the main thread,
// mirroring `libs/websocket/server_test.odin`.
//
// Helpers bind an OS-assigned ephemeral port (port 0); recover it with
// `bound_port` after `start`.

// Bring a daemon all the way down and reclaim it.
test_teardown :: proc(d: ^Daemon) {
    shutdown(d)
    for !shutdown_complete(d) {
        _ = nbio.tick(time.Millisecond)
    }
    destroy(d)
}

// Recover the ephemeral port the daemon's front door bound, for dialing clients.
bound_port :: proc(d: ^Daemon) -> int {
    return http_server.bound_port(&d.front_door)
}

// --- 1 & 2. Hello handshake + request-after-Ready via the real client driver ---

// Observations recorded by the `src/client` callbacks, reached through the driver's
// `user_data`.
Cli_Obs :: struct {
    // Whether to fire a request from `on_ready` (test 2) versus close (test 1).
    send_request_on_ready: bool,

    // Driver reached Ready.
    ready:                 bool,

    // Retained protocol version, read at Ready.
    protocol:              u32,

    // Retained session-index revision, read at Ready.
    session_revision:      wire.Session_Revision,

    // Retained cron-index revision, read at Ready.
    cron_revision:         wire.Cron_Revision,

    // A response frame was delivered.
    got_response:          bool,

    // The delivered response was an `error` frame.
    resp_is_error:         bool,

    // Error code carried by the delivered error response.
    resp_error_code:       wire.Error_Code,

    // Terminal callback fired.
    done:                  bool,

    // Close code reported to the terminal `on_close`.
    close_code:            client.Close_Code,

    // Terminal driver error, if any.
    err:                   client.Protocol_Error,
}

cli_on_ready :: proc(c: ^client.Client, hello: wire.Initialize_Result) {
    o := (^Cli_Obs)(c.user_data)
    o.ready = true
    o.protocol = hello.protocol
    o.session_revision = hello.session_revision
    o.cron_revision = hello.cron_revision

    if o.send_request_on_ready {
        // A method with no dispatch handler; its empty params validate, so the request
        // reaches the router and falls through to the `Unknown_Method` arm.
        client.client_send_request(c, .Session_Create, wire.Create_Session{}, cli_on_response)
    } else {
        client.client_close(c)
    }
}

cli_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Cli_Obs)(c.user_data)
    answered, ok := outcome.(client.Request_Response)
    if !ok {
        o.err = outcome.(client.Request_Failure).error
        return
    }

    resp := answered.response
    o.got_response = true

    #partial switch v in resp {
    case wire.Response_Error:
        o.resp_is_error = true
        o.resp_error_code = v.error.code

    case wire.Response_Ok:
        o.resp_is_error = false
    }

    client.client_close(c)
}

cli_on_close :: proc(c: ^client.Client, code: client.Close_Code) {
    o := (^Cli_Obs)(c.user_data)
    o.close_code = code
    o.done = true
}

cli_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    o := (^Cli_Obs)(c.user_data)
    o.err = err
    o.done = true
}

cli_callbacks :: proc() -> client.Client_Callbacks {
    return client.Client_Callbacks{on_ready = cli_on_ready, on_close = cli_on_close, on_error = cli_on_error}
}

@(test)
test_daemon_hello_handshake_reaches_ready :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, daemon_version = "9.8.7"})
    testing.expect_value(t, derr, Error.None)

    obs: Cli_Obs
    c: client.Client
    transport, terr := client.ws_create(
        loop,
        {host = "127.0.0.1", port = bound_port(&d), path = "/ws"},
        context.temp_allocator,
    )
    testing.expect_value(t, terr, ws.Client_Error.None)

    cerr := client.client_open(&c, transport, "yuke-test", "0.1.0", cli_callbacks(), &obs, context.temp_allocator)
    testing.expect_value(t, cerr, client.Protocol_Error.None)

    nbio.run_until(&obs.done)

    testing.expect(t, obs.ready, "client should reach Ready")
    testing.expect_value(t, obs.protocol, u32(wire.PROTOCOL_VERSION))
    // The retained daemon version is the one the daemon was started with.
    testing.expect_value(t, c.daemon_version, "9.8.7")
    testing.expect_value(t, obs.session_revision, wire.Session_Revision(0))
    testing.expect_value(t, obs.cron_revision, wire.Cron_Revision(0))
    testing.expect_value(t, obs.err, client.Protocol_Error.None)

    client.client_destroy(&c)
    test_teardown(&d)
}

@(test)
test_daemon_request_after_ready_gets_error :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0})
    testing.expect_value(t, derr, Error.None)

    obs := Cli_Obs {
        send_request_on_ready = true,
    }
    c: client.Client
    transport, terr := client.ws_create(
        loop,
        {host = "127.0.0.1", port = bound_port(&d), path = "/ws"},
        context.temp_allocator,
    )
    testing.expect_value(t, terr, ws.Client_Error.None)

    cerr := client.client_open(&c, transport, "yuke-test", "0.1.0", cli_callbacks(), &obs, context.temp_allocator)
    testing.expect_value(t, cerr, client.Protocol_Error.None)

    nbio.run_until(&obs.done)

    testing.expect(t, obs.ready, "client should reach Ready")
    testing.expect(t, obs.got_response, "a request after Ready must be answered, not dropped")
    testing.expect(t, obs.resp_is_error, "the answer must be an error response")
    // `session.create` is a valid method the router does not handle, so it answers
    // with `Unknown_Method` rather than dropping the request.
    testing.expect_value(t, obs.resp_error_code, wire.Error_Code.Unknown_Method)
    testing.expect_value(t, obs.err, client.Protocol_Error.None)

    client.client_destroy(&c)
    test_teardown(&d)
}

// --- Read-only method handlers via the real client driver ---------------------
//
// Each drives one request from `on_ready`, then runs a per-test `check` against the
// delivered response while it is still alive — the driver reclaims its decode arena
// when the callback returns, so every assertion happens inside the callback. A check
// returns whether the exchange is finished; a paginated case sends a follow-up and
// returns false so the loop keeps running.

// Per-test observation and context reached through the driver's `user_data`.
Handler_Obs :: struct {
    // Method the request drives.
    method:     wire.Method_Name,

    // Params for that request.
    params:     wire.Request_Params,

    // Assertions run against each delivered response; returns true when finished.
    check:      proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool,

    // A filesystem path the test set up, read by describe/browse checks.
    dir:        string,

    // Response counter, for multi-page exchanges.
    page:       int,

    // The active testing context, so checks can assert from inside the callback.
    t:          ^testing.T,

    // Terminal callback fired.
    done:       bool,

    // The check declared the exchange complete and initiated the client close.
    finished:   bool,

    // Either a terminal callback or the harness timeout fired.
    wait_done:  bool,

    // The harness timeout fired before a terminal callback.
    timed_out:  bool,

    // At least one response was delivered to `handler_on_response`. Without this, a
    // daemon that closes the connection instead of answering would still leave
    // `done` set (by `handler_on_close`) and no `check` ever runs, so the test would
    // vacuously pass.
    responded:  bool,

    // Terminal driver error, if any.
    err:        client.Protocol_Error,

    // Multi-request auth test state.
    auth_stage: int,
}

handler_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    o := (^Handler_Obs)(c.user_data)
    client.client_send_request(c, o.method, o.params, handler_on_response)
}

handler_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Handler_Obs)(c.user_data)
    answered, ok := outcome.(client.Request_Response)
    if !ok {
        o.err = outcome.(client.Request_Failure).error
        return
    }

    resp := answered.response
    o.responded = true

    // `done` is latched by the terminal callback, not here: destroying a client with
    // its close frame still in flight would free buffers the loop still owns.
    if o.check(c, resp, o) {
        o.finished = true
        client.client_close(c)
    }
}

handler_on_close :: proc(c: ^client.Client, code: client.Close_Code) {
    o := (^Handler_Obs)(c.user_data)
    o.done = true
    o.wait_done = true
}

handler_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    o := (^Handler_Obs)(c.user_data)
    o.err = err
    o.done = true
    o.wait_done = true
}

handler_on_timeout :: proc(_: ^nbio.Operation, o: ^Handler_Obs) {
    o.timed_out = true
    o.wait_done = true
}

handler_callbacks :: proc() -> client.Client_Callbacks {
    return client.Client_Callbacks {
        on_ready = handler_on_ready,
        on_close = handler_on_close,
        on_error = handler_on_error,
    }
}

// Bring up a daemon, drive `obs`'s single request through the client driver, and run its
// check(s). `db_path` selects a file store; an empty path uses the in-memory store.
run_handler :: proc(t: ^testing.T, obs: ^Handler_Obs, db_path := "", auth_path := "", sessions: ..wire.Session) {
    obs.t = t

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, db_path = db_path, auth_path = auth_path})
    testing.expect_value(t, derr, Error.None)

    for session in sessions {
        testing.expect_value(t, store.session_create(d.store, session, nil), nil)
    }

    c: client.Client
    transport, terr := client.ws_create(
        loop,
        {host = "127.0.0.1", port = bound_port(&d), path = "/ws"},
        context.temp_allocator,
    )
    testing.expect_value(t, terr, ws.Client_Error.None)

    cerr := client.client_open(&c, transport, "yuke-test", "0.1.0", handler_callbacks(), obs, context.temp_allocator)
    testing.expect_value(t, cerr, client.Protocol_Error.None)

    timeout_op := nbio.timeout_poly(2 * time.Second, obs, handler_on_timeout, loop)
    nbio.run_until(&obs.wait_done)

    if !obs.timed_out {
        nbio.remove(timeout_op)
    } else {
        // Force a terminal callback before destroying the client; the timeout only
        // bounds the request exchange, not the transport's buffer lifetime.
        shutdown(&d)
        nbio.run_until(&obs.done)
    }

    // A daemon that closes or errors the connection instead of answering must not
    // pass silently: without a delivered response, `check` (and every expectation it
    // holds) never ran.
    testing.expect(t, !obs.timed_out, "the daemon request should terminate before the harness timeout")
    testing.expect(t, obs.done, "the client terminal callback should fire")
    testing.expect(t, obs.responded, "the daemon should have answered the request")
    testing.expect(t, obs.finished, "the response check should run to completion")
    testing.expect_value(t, obs.err, client.Protocol_Error.None)

    client.client_destroy(&c)
    test_teardown(&d)
}

// Create a fresh, empty directory under the temp root, removing any stale copy first.
test_make_dir :: proc(name: string) -> string {
    base, has := os.lookup_env("TMPDIR", context.temp_allocator)
    if !has {
        base = "/tmp"
    }

    dir, _ := os.join_path({base, name}, context.temp_allocator)
    os.remove_all(dir)
    os.make_directory_all(dir)

    return dir
}

// A name 270 UTF-8 bytes long (90 repeated 3-byte "あ" runes) but only 90 characters:
// over the wire's 256-byte `Dir_Entry.name`/`Workspace.title` bound, yet well within
// APFS's 255-character filename limit — the overlong-name regression fixture.
test_overlong_name :: proc() -> string {
    b := strings.builder_make(context.temp_allocator)
    for _ in 0 ..< 90 {
        strings.write_string(&b, "あ")
    }

    return strings.to_string(b)
}

check_session_list_empty :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "session.list should succeed") {
        return true
    }

    page, is_page := ok.result.(wire.Session_List_Result)
    if !testing.expect(t, is_page, "result is a session.list page") {
        return true
    }

    testing.expect_value(t, page.revision, wire.Session_Revision(0))
    testing.expect_value(t, len(page.items), 0)
    testing.expect_value(t, page.total, u64(0))
    _, has_cursor := page.next_cursor.?
    testing.expect(t, !has_cursor, "the only page carries a null next_cursor")

    return true
}

@(test)
test_daemon_session_list_empty :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Handler_Obs {
        method = .Session_List,
        params = wire.Session_List_Params {
            scope = wire.Session_Scope_All{},
            population = wire.Session_Population_Top_Level{},
            view = .Active_Recent,
        },
        check = check_session_list_empty,
    }
    run_handler(t, &obs)
}

check_catalog_full :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "catalog.list should succeed") {
        return true
    }

    result, is_cat := ok.result.(wire.Catalog_List_Result)
    if !testing.expect(t, is_cat, "result is a catalog.list result") {
        return true
    }

    full, is_full := result.(wire.Catalog_List_Result_Full)
    if !testing.expect(t, is_full, "an absent since_rev yields a full snapshot") {
        return true
    }

    testing.expect_value(t, len(full.models), 0)
    testing.expect_value(t, len(full.health.skipped), 0)

    return true
}

@(test)
test_daemon_catalog_list_full_when_no_since_rev :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Handler_Obs {
        method = .Catalog_List,
        params = wire.Catalog_List_Params{},
        check  = check_catalog_full,
    }
    run_handler(t, &obs)
}

check_catalog_unchanged :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "catalog.list should succeed") {
        return true
    }

    result, is_cat := ok.result.(wire.Catalog_List_Result)
    if !testing.expect(t, is_cat, "result is a catalog.list result") {
        return true
    }

    _, is_unchanged := result.(wire.Catalog_List_Result_Unchanged)
    testing.expect(t, is_unchanged, "a since_rev equal to the current rev yields unchanged")

    return true
}

@(test)
test_daemon_catalog_list_unchanged_when_since_rev_matches :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Handler_Obs {
        method = .Catalog_List,
        params = wire.Catalog_List_Params{since_rev = empty_catalog_rev()},
        check = check_catalog_unchanged,
    }
    run_handler(t, &obs)
}

check_auth_list :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "auth.list should succeed") {
        return true
    }

    result, is_list := ok.result.(wire.Auth_List_Result)
    if !testing.expect(t, is_list, "result is an auth provider list") {
        return true
    }

    if !testing.expect_value(t, len(result.providers), 2) {
        return true
    }

    codex_entry: Maybe(wire.Auth_Provider)
    xai_entry: Maybe(wire.Auth_Provider)
    for entry in result.providers {
        switch string(entry.provider_id) {
        case provider_auth.CODEX_PROVIDER_ID:
            codex_entry = entry

        case provider_auth.XAI_PROVIDER_ID:
            xai_entry = entry
        }
    }

    codex, codex_ok := codex_entry.?
    if !testing.expect(t, codex_ok, "codex provider is listed") {
        return true
    }
    testing.expect_value(t, codex.state, wire.Auth_State.Signed_Out)
    _, codex_pending := codex.pending_login.?
    testing.expect(t, !codex_pending, "fresh auth has no pending login")

    codex_device := false
    for flow in codex.login_flows {
        codex_device = codex_device || flow == .Device_Code
    }
    testing.expect(t, codex_device, "codex device login remains available without a callback port")

    xai, xai_ok := xai_entry.?
    if !testing.expect(t, xai_ok, "xai provider is listed") {
        return true
    }
    testing.expect_value(t, xai.state, wire.Auth_State.Signed_Out)

    // xAI offers both browser (PKCE) and device (RFC 8628) login.
    xai_browser := false
    xai_device := false
    for flow in xai.login_flows {
        xai_browser = xai_browser || flow == .Browser
        xai_device = xai_device || flow == .Device_Code
    }
    testing.expect(t, xai_browser, "xai browser login is available")
    testing.expect(t, xai_device, "xai device login is available")

    return true
}

@(test)
test_daemon_auth_list_uses_configured_auth_json :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-daemon-auth-list")
    defer os.remove_all(dir)
    testing.expect(t, os.chmod(dir, provider_auth.AUTH_DIR_PERMISSIONS) == nil, "secure auth directory")
    path, _ := os.join_path({dir, "auth.json"}, context.temp_allocator)

    obs := Handler_Obs {
        method = .Auth_List,
        params = wire.Empty{},
        check  = check_auth_list,
    }
    run_handler(t, &obs, auth_path = path)
}

@(test)
test_daemon_oauth_refresh_timer_is_owned_by_shutdown :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-daemon-auth-refresh-timer")
    defer os.remove_all(dir)
    testing.expect(t, os.chmod(dir, provider_auth.AUTH_DIR_PERMISSIONS) == nil, "secure auth directory")
    path, _ := os.join_path({dir, "auth.json"}, context.temp_allocator)

    auth_store, open_err := provider_auth.open(path)
    testing.expect_value(t, open_err, provider_auth.Error.None)
    credentials := provider_auth.OAuth_Credentials {
        access_token  = "access",
        refresh_token = "refresh",
        expires_at_ms = now_ms() + u64(time.Hour / time.Millisecond),
        account_id    = "account",
    }
    testing.expect_value(
        t,
        provider_auth.credentials_put(auth_store, provider_auth.CODEX_PROVIDER_ID, credentials),
        provider_auth.Error.None,
    )
    provider_auth.close(auth_store)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, auth_path = path}), Error.None)
    testing.expect(t, d.provider_auth.refresh_timer != nil, "future credentials arm proactive refresh")
    testing.expect(t, provider_refresh(&d) == nil, "future credentials do not refresh early")

    shutdown(&d)
    testing.expect(t, d.provider_auth.refresh_timer == nil, "shutdown cancels proactive refresh")
    for !shutdown_complete(&d) {
        _ = nbio.tick(time.Millisecond)
    }
    destroy(&d)
}

@(test)
test_daemon_login_deadline_releases_the_attempt :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-daemon-auth-login-deadline")
    defer os.remove_all(dir)
    testing.expect(t, os.chmod(dir, provider_auth.AUTH_DIR_PERMISSIONS) == nil, "secure auth directory")
    path, _ := os.join_path({dir, "auth.json"}, context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, auth_path = path}), Error.None)
    defer test_teardown(&d)

    login, aerr := new(Provider_Login, d.allocator)
    testing.expect(t, aerr == nil, "allocate login attempt")
    login^ = {
        kind           = .Xai,
        id             = login_id_create(),
        requested_flow = .Device_Code,
        phase          = .Device_Waiting_Poll,
    }
    d.provider_auth.operation = login
    provider_login_deadline_arm(&d, time.Millisecond)

    for provider_login(&d) != nil {
        _ = nbio.tick(time.Millisecond)
    }

    testing.expect(t, provider_login(&d) == nil, "deadline owns terminal attempt cleanup")
}

@(test)
test_daemon_login_summary_survives_credential_persistence :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-daemon-auth-login-persistence")
    defer os.remove_all(dir)
    testing.expect(t, os.chmod(dir, provider_auth.AUTH_DIR_PERMISSIONS) == nil, "secure auth directory")
    path, _ := os.join_path({dir, "auth.json"}, context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, auth_path = path}), Error.None)
    defer test_teardown(&d)

    login_id := login_id_create()
    job := Credential_Job {
        daemon      = &d,
        kind        = .Login,
        provider_id = provider_auth.XAI_PROVIDER_ID,
        login_id    = login_id,
        login_flow  = .Device_Code,
    }
    d.provider_auth.operation = &job

    state := provider_state(&d, .Xai)
    summary, pending := state.pending_login.?
    if testing.expect(t, pending, "credential persistence retains the public login summary") {
        testing.expect_value(t, summary.login_id, login_id)
        testing.expect_value(t, summary.flow, wire.Auth_Flow.Device_Code)
    }

    d.provider_auth.operation = nil
}

@(test)
test_daemon_terminal_refresh_invalidates_credentials :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-daemon-auth-refresh-invalidate")
    defer os.remove_all(dir)
    testing.expect(t, os.chmod(dir, provider_auth.AUTH_DIR_PERMISSIONS) == nil, "secure auth directory")
    path, _ := os.join_path({dir, "auth.json"}, context.temp_allocator)

    initial, open_err := provider_auth.open(path)
    testing.expect_value(t, open_err, provider_auth.Error.None)
    credentials := provider_auth.OAuth_Credentials {
        access_token  = "access",
        refresh_token = "refresh",
        expires_at_ms = now_ms() + u64(time.Hour / time.Millisecond),
        account_id    = "account",
    }
    testing.expect_value(
        t,
        provider_auth.credentials_put(initial, provider_auth.XAI_PROVIDER_ID, credentials),
        provider_auth.Error.None,
    )
    provider_auth.close(initial)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, auth_path = path}), Error.None)
    defer test_teardown(&d)
    provider_refresh_timer_cancel(&d)

    existing, found, read_err := provider_auth.credentials_get(
        d.provider_auth.store,
        provider_auth.XAI_PROVIDER_ID,
        d.allocator,
    )
    testing.expect_value(t, read_err, provider_auth.Error.None)
    testing.expect(t, found, "refresh fixture is signed in")

    refresh, aerr := new(Provider_Refresh, d.allocator)
    testing.expect(t, aerr == nil, "allocate refresh attempt")
    refresh^ = {
        kind = .Xai,
        transfer = {state = .Done},
        existing = existing,
    }
    testing.expect(
        t,
        bounded_response_accumulate(&refresh.response, transmute([]byte)string(`{"error":"invalid_grant"}`)),
        "terminal response fits",
    )
    d.provider_auth.operation = refresh

    provider_refresh_on_done(&d, curl.Result{code = .Ok, status = 400})
    testing.expect(t, provider_refresh(&d) == nil, "terminal response releases the refresh")
    testing.expect(t, credential_job(&d) != nil, "terminal response queues durable invalidation")

    for credential_job(&d) != nil {
        _ = nbio.tick(time.Millisecond)
    }

    testing.expect(
        t,
        !provider_auth.credentials_present(d.provider_auth.store, provider_auth.XAI_PROVIDER_ID),
        "terminal refresh removes the unusable credential",
    )
}

check_auth_logout :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "auth.logout should succeed") {
        return true
    }

    _, is_empty := ok.result.(wire.Empty)
    testing.expect(t, is_empty, "auth.logout returns an empty result")

    return true
}

@(test)
test_daemon_auth_logout_durably_removes_credentials :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-daemon-auth-logout")
    defer os.remove_all(dir)
    testing.expect(t, os.chmod(dir, provider_auth.AUTH_DIR_PERMISSIONS) == nil, "secure auth directory")
    path, _ := os.join_path({dir, "auth.json"}, context.temp_allocator)

    auth_store, open_err := provider_auth.open(path)
    testing.expect_value(t, open_err, provider_auth.Error.None)
    credentials := provider_auth.OAuth_Credentials {
        access_token  = "access",
        refresh_token = "refresh",
        expires_at_ms = 1_900_000_000_000,
        account_id    = "account",
    }
    testing.expect_value(
        t,
        provider_auth.credentials_put(auth_store, provider_auth.CODEX_PROVIDER_ID, credentials),
        provider_auth.Error.None,
    )
    provider_auth.close(auth_store)

    obs := Handler_Obs {
        method = .Auth_Logout,
        params = wire.Auth_Logout_Params{provider_id = provider_auth.CODEX_PROVIDER_ID},
        check = check_auth_logout,
    }
    run_handler(t, &obs, auth_path = path)

    reopened, reopen_err := provider_auth.open(path)
    testing.expect_value(t, reopen_err, provider_auth.Error.None)
    defer provider_auth.close(reopened)
    testing.expect(
        t,
        !provider_auth.credentials_present(reopened, provider_auth.CODEX_PROVIDER_ID),
        "logout is durable before its response",
    )
}

check_auth_browser_start_cancel :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t

    if o.auth_stage == 0 {
        if unavailable, is_error := resp.(wire.Response_Error); is_error {
            testing.expect_value(t, unavailable.error.code, wire.Error_Code.Overloaded)
            return true
        }

        ok, is_ok := resp.(wire.Response_Ok)
        if !testing.expect(t, is_ok, "browser auth.login should succeed") {
            return true
        }

        login_result, is_login := ok.result.(wire.Auth_Login_Result)
        if !testing.expect(t, is_login, "auth.login returns login details") {
            return true
        }

        result, is_browser := login_result.(wire.Auth_Login_Result_Browser)
        if !testing.expect(t, is_browser, "auth.login returns browser details") {
            return true
        }
        testing.expect(
            t,
            strings.has_prefix(result.auth_url, provider_auth.CODEX_AUTHORIZE_URL),
            "Codex authorize URL",
        )
        testing.expect(t, strings.contains(result.auth_url, "code_challenge_method=S256"), "browser login uses PKCE")

        o.auth_stage = 1
        client.client_send_request(
            c,
            .Auth_Cancel_Login,
            wire.Auth_Cancel_Login_Params{login_id = result.login_id},
            handler_on_response,
        )
        return false
    }

    testing.expect_value(t, o.auth_stage, 1)
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "auth.cancel_login should succeed") {
        return true
    }
    _, is_empty := ok.result.(wire.Empty)
    testing.expect(t, is_empty, "auth.cancel_login returns an empty result")

    return true
}

@(test)
test_daemon_browser_login_starts_and_cancels_over_websocket :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-daemon-auth-browser")
    defer os.remove_all(dir)
    testing.expect(t, os.chmod(dir, provider_auth.AUTH_DIR_PERMISSIONS) == nil, "secure auth directory")
    path, _ := os.join_path({dir, "auth.json"}, context.temp_allocator)

    obs := Handler_Obs {
        method = .Auth_Login,
        params = wire.Auth_Login_Params{provider_id = provider_auth.CODEX_PROVIDER_ID, flow = .Browser},
        check = check_auth_browser_start_cancel,
    }
    run_handler(t, &obs, auth_path = path)
}

@(test)
test_browser_login_is_local_only :: proc(t: ^testing.T) {
    local_tx: ws.Server_Conn
    local := Conn {
        tx = &local_tx,
    }
    testing.expect(t, provider_login_flow_allowed(&local, .Browser), "local browser login is admitted")
    testing.expect(t, provider_login_flow_allowed(&local, .Device_Code), "local device login is admitted")

    relay_tx: Relay
    remote := Conn {
        tx = &relay_tx,
    }
    testing.expect(t, !provider_login_flow_allowed(&remote, .Browser), "relay browser login is refused")
    testing.expect(t, provider_login_flow_allowed(&remote, .Device_Code), "relay device login is admitted")
}

check_describe_non_git :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "describe should succeed") {
        return true
    }

    result, is_desc := ok.result.(wire.Workspace_Describe_Result)
    if !testing.expect(t, is_desc, "result is a describe result") {
        return true
    }

    _, has_git := result.git.?
    testing.expect(t, !has_git, "a plain directory has no git info")

    canonical, cerr := os.get_absolute_path(o.dir, context.temp_allocator)
    testing.expect(t, cerr == nil, "the temp dir canonicalizes")
    testing.expect_value(t, result.workspace.root, canonical)
    testing.expect_value(t, result.workspace.id, workspace_id(canonical))
    testing.expect_value(t, result.workspace.title, os.base(canonical))
    testing.expect(t, result.last_modified_ms > 0, "mtime is populated")
    _, has_model := result.last_used_model.?
    testing.expect(t, !has_model, "no store means no last_used_model")

    return true
}

@(test)
test_daemon_workspace_describe_non_git :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-odin-describe-nongit")
    defer os.remove_all(dir)

    obs := Handler_Obs {
        method = .Workspace_Describe,
        params = wire.Workspace_Describe_Params{path = dir},
        check = check_describe_non_git,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_describe_git :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "describe should succeed") {
        return true
    }

    result, is_desc := ok.result.(wire.Workspace_Describe_Result)
    if !testing.expect(t, is_desc, "result is a describe result") {
        return true
    }

    git, has_git := result.git.?
    if !testing.expect(t, has_git, "a directory with a .git is a repo") {
        return true
    }

    testing.expect_value(t, git.branch, "feature-x")
    testing.expect(t, !git.dirty, "dirty is not detected without the git binary")

    return true
}

@(test)
test_daemon_workspace_describe_git :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-odin-describe-git")
    defer os.remove_all(dir)

    git_dir, _ := os.join_path({dir, ".git"}, context.temp_allocator)
    os.make_directory_all(git_dir)
    head, _ := os.join_path({git_dir, "HEAD"}, context.temp_allocator)
    _ = os.write_entire_file(head, "ref: refs/heads/feature-x\n")

    obs := Handler_Obs {
        method = .Workspace_Describe,
        params = wire.Workspace_Describe_Params{path = dir},
        check = check_describe_git,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_describe_invalid_utf8_branch :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "describe should succeed with a non-UTF-8 branch") {
        return true
    }

    result, is_desc := ok.result.(wire.Workspace_Describe_Result)
    if !testing.expect(t, is_desc, "result is a describe result") {
        return true
    }

    git, has_git := result.git.?
    if !testing.expect(t, has_git, "a directory with a .git is a repo") {
        return true
    }

    // A `.git/HEAD` ref whose branch component is not valid UTF-8 degrades to the same
    // empty branch as a detached or unreadable HEAD; it never rides an invalid frame.
    testing.expect_value(t, git.branch, "")

    return true
}

// Regression for invalid UTF-8 in filesystem bytes: a `.git/HEAD` whose branch is not
// valid UTF-8 must not produce a TEXT frame the WebSocket peer would reject; the
// branch comes back empty.
@(test)
test_daemon_workspace_describe_invalid_utf8_branch :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-odin-describe-badbranch")
    defer os.remove_all(dir)

    git_dir, _ := os.join_path({dir, ".git"}, context.temp_allocator)
    os.make_directory_all(git_dir)
    head, _ := os.join_path({git_dir, "HEAD"}, context.temp_allocator)

    head_bytes := make([dynamic]u8, context.temp_allocator)
    append(&head_bytes, ..transmute([]u8)string("ref: refs/heads/"))
    append(&head_bytes, 0xFF, 0xFE)
    append(&head_bytes, '\n')
    _ = os.write_entire_file(head, head_bytes[:])

    obs := Handler_Obs {
        method = .Workspace_Describe,
        params = wire.Workspace_Describe_Params{path = dir},
        check = check_describe_invalid_utf8_branch,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_describe_missing :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    e, is_err := resp.(wire.Response_Error)
    if !testing.expect(t, is_err, "a missing path is an error response") {
        return true
    }

    testing.expect_value(t, e.error.code, wire.Error_Code.Bad_Request)

    return true
}

@(test)
test_daemon_workspace_describe_missing_path :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Handler_Obs {
        method = .Workspace_Describe,
        params = wire.Workspace_Describe_Params{path = "/no/such/path/yuke-odin-xyz"},
        check = check_describe_missing,
    }
    run_handler(t, &obs)
}

check_describe_overlong_basename :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "describe should succeed even with an over-bound basename") {
        return true
    }

    result, is_desc := ok.result.(wire.Workspace_Describe_Result)
    if !testing.expect(t, is_desc, "result is a describe result") {
        return true
    }

    testing.expect(t, len(result.workspace.title) <= 256, "the title is clamped to the wire bound")
    testing.expect(t, utf8.valid_string(result.workspace.title), "a clamped title is still valid UTF-8")

    return true
}

// Regression for the daemon abort fixed by clamping `Workspace.title`: a directory
// whose basename exceeds the 256-byte wire bound (but is a legal APFS name) must not
// crash `describe` when it builds the result frame.
@(test)
test_daemon_workspace_describe_overlong_basename :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parent := test_make_dir("yuke-odin-describe-overlong")
    defer os.remove_all(parent)

    dir, _ := os.join_path({parent, test_overlong_name()}, context.temp_allocator)
    if merr := os.make_directory_all(dir); merr != nil {
        fmt.printfln("skipping: filesystem rejected an overlong-basename directory: %v", merr)
        return
    }
    defer os.remove_all(dir)

    obs := Handler_Obs {
        method = .Workspace_Describe,
        params = wire.Workspace_Describe_Params{path = dir},
        check = check_describe_overlong_basename,
        dir = dir,
    }
    run_handler(t, &obs)
}

// Populate a browse fixture: subdirectories `alpha`, `beta`, and `repo` (a git repo),
// plus a plain file that must be omitted from the listing.
test_make_browse_dir :: proc(name: string) -> string {
    dir := test_make_dir(name)

    for sub in ([]string{"alpha", "beta", "repo"}) {
        p, _ := os.join_path({dir, sub}, context.temp_allocator)
        os.make_directory_all(p)
    }

    repo_git, _ := os.join_path({dir, "repo", ".git"}, context.temp_allocator)
    os.make_directory_all(repo_git)
    file, _ := os.join_path({dir, "zeta.txt"}, context.temp_allocator)
    _ = os.write_entire_file(file, "x")

    return dir
}

check_browse_listing :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "browse should succeed") {
        return true
    }

    result, is_browse := ok.result.(wire.Workspace_Browse_Result)
    if !testing.expect(t, is_browse, "result is a browse result") {
        return true
    }

    if testing.expect_value(t, len(result.entries), 3) {
        // Directories only, `.git` and files omitted, sorted case-insensitively.
        testing.expect_value(t, result.entries[0].name, "alpha")
        testing.expect_value(t, result.entries[1].name, "beta")
        testing.expect_value(t, result.entries[2].name, "repo")
        testing.expect(t, result.entries[2].is_git_repo, "repo carries a .git")
        testing.expect(t, !result.entries[0].is_git_repo, "alpha carries no .git")
    }

    _, has_parent := result.parent.?
    testing.expect(t, has_parent, "a temp dir has a parent")
    _, has_cursor := result.next_cursor.?
    testing.expect(t, !has_cursor, "a single full page has a null next_cursor")

    return true
}

@(test)
test_daemon_workspace_browse_lists_directories :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_browse_dir("yuke-odin-browse-list")
    defer os.remove_all(dir)

    obs := Handler_Obs {
        method = .Workspace_Browse,
        params = wire.Workspace_Browse_Params{path = dir},
        check = check_browse_listing,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_browse_paginated :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "browse should succeed") {
        return true
    }

    result, is_browse := ok.result.(wire.Workspace_Browse_Result)
    if !testing.expect(t, is_browse, "result is a browse result") {
        return true
    }

    if o.page == 0 {
        testing.expect_value(t, len(result.entries), 2)

        cursor, has := result.next_cursor.?
        if !testing.expect(t, has, "a 3-entry dir paged by 2 has a next_cursor") {
            return true
        }
        testing.expect_value(t, cursor, "beta")

        // The cursor is borrowed for this callback only; `client_send_request` copies
        // it into the outbound frame synchronously, so it is safe to forward here.
        o.page = 1
        client.client_send_request(
            c,
            .Workspace_Browse,
            wire.Workspace_Browse_Params{path = o.dir, limit = 2, cursor = cursor},
            handler_on_response,
        )

        return false
    }

    testing.expect_value(t, len(result.entries), 1)
    _, has := result.next_cursor.?
    testing.expect(t, !has, "the final page has a null next_cursor")

    return true
}

@(test)
test_daemon_workspace_browse_paginates :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_browse_dir("yuke-odin-browse-page")
    defer os.remove_all(dir)

    obs := Handler_Obs {
        method = .Workspace_Browse,
        params = wire.Workspace_Browse_Params{path = dir, limit = 2},
        check = check_browse_paginated,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_browse_missing :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    e, is_err := resp.(wire.Response_Error)
    if !testing.expect(t, is_err, "a missing path is an error response") {
        return true
    }

    testing.expect_value(t, e.error.code, wire.Error_Code.Bad_Request)

    return true
}

@(test)
test_daemon_workspace_browse_missing_path :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Handler_Obs {
        method = .Workspace_Browse,
        params = wire.Workspace_Browse_Params{path = "/no/such/path/yuke-odin-xyz"},
        check = check_browse_missing,
    }
    run_handler(t, &obs)
}

check_browse_name_cursor :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "an opaque name cursor is accepted") {
        return true
    }

    result, is_browse := ok.result.(wire.Workspace_Browse_Result)
    if !testing.expect(t, is_browse, "result is a browse result") {
        return true
    }

    if testing.expect_value(t, len(result.entries), 1) {
        testing.expect_value(t, result.entries[0].name, "repo")
    }
    _, has_cursor := result.next_cursor.?
    testing.expect(t, !has_cursor, "the name boundary reaches the final page")

    return true
}

@(test)
test_daemon_workspace_browse_uses_name_cursor :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_browse_dir("yuke-odin-browse-name-cursor")
    defer os.remove_all(dir)

    obs := Handler_Obs {
        method = .Workspace_Browse,
        params = wire.Workspace_Browse_Params{path = dir, cursor = "beta"},
        check = check_browse_name_cursor,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_browse_skips_overlong_name :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "browse should succeed even with an unrepresentable entry name") {
        return true
    }

    result, is_browse := ok.result.(wire.Workspace_Browse_Result)
    if !testing.expect(t, is_browse, "result is a browse result") {
        return true
    }

    found_normal := false
    for entry in result.entries {
        testing.expect(t, len(entry.name) <= 256, "every emitted entry name is within the wire bound")
        if entry.name == "normal" {
            found_normal = true
        }
    }

    testing.expect(t, found_normal, "the normal sibling entry is still listed")

    return true
}

// Regression for the daemon abort fixed by skipping over-bound directory entries: a
// subdirectory whose name exceeds the 256-byte wire bound (but is a legal APFS name)
// must not crash `browse` when it builds the result frame; it is simply omitted.
@(test)
test_daemon_workspace_browse_skips_overlong_name :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-odin-browse-overlong")
    defer os.remove_all(dir)

    normal, _ := os.join_path({dir, "normal"}, context.temp_allocator)
    os.make_directory_all(normal)

    overlong, _ := os.join_path({dir, test_overlong_name()}, context.temp_allocator)
    if merr := os.make_directory_all(overlong); merr != nil {
        fmt.printfln("skipping: filesystem rejected an overlong-name directory: %v", merr)
        return
    }

    obs := Handler_Obs {
        method = .Workspace_Browse,
        params = wire.Workspace_Browse_Params{path = dir},
        check = check_browse_skips_overlong_name,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_browse_skips_non_utf8_name :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "browse should succeed even with a non-UTF-8 entry name") {
        return true
    }

    result, is_browse := ok.result.(wire.Workspace_Browse_Result)
    if !testing.expect(t, is_browse, "result is a browse result") {
        return true
    }

    found_normal := false
    for entry in result.entries {
        testing.expect(t, utf8.valid_string(entry.name), "every emitted entry name is valid UTF-8")
        testing.expect(t, utf8.valid_string(entry.path), "every emitted entry path is valid UTF-8")
        if entry.name == "normal" {
            found_normal = true
        }
    }

    testing.expect(t, found_normal, "the normal sibling entry is still listed")

    return true
}

// Regression for invalid UTF-8 in filesystem bytes: a subdirectory whose name is not
// valid UTF-8 cannot ride a WebSocket TEXT frame, so `browse` omits it rather than
// emitting a frame the peer would reject; the valid sibling is still listed.
@(test)
test_daemon_workspace_browse_skips_non_utf8_name :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-odin-browse-nonutf8")
    defer os.remove_all(dir)

    normal, _ := os.join_path({dir, "normal"}, context.temp_allocator)
    os.make_directory_all(normal)

    // A subdirectory name built from raw bytes (0xFF 0xFE) that are not valid UTF-8.
    // Some filesystems reject such names, in which case the case skips like the
    // overlong-name fixture.
    name := [?]u8{0xFF, 0xFE}
    path_bytes := make([]u8, len(dir) + 1 + len(name), context.temp_allocator)
    copy(path_bytes[:], transmute([]u8)dir)
    path_bytes[len(dir)] = '/'
    copy(path_bytes[len(dir) + 1:], name[:])
    invalid := string(path_bytes)
    if merr := os.make_directory_all(invalid); merr != nil {
        fmt.printfln("skipping: filesystem rejected a non-UTF-8 directory name: %v", merr)
        return
    }
    defer os.remove_all(invalid)

    obs := Handler_Obs {
        method = .Workspace_Browse,
        params = wire.Workspace_Browse_Params{path = dir},
        check = check_browse_skips_non_utf8_name,
        dir = dir,
    }
    run_handler(t, &obs)
}

// --- Raw blocking TCP peer harness (worker thread) ----------------------------

// A raw peer that upgrades, sends one hand-built frame, then reads back the
// server's reaction (a Close frame with its code, or a bare socket close).
Raw_Peer :: struct {
    // Port to connect to.
    port:          int,

    // Opcode of the single frame the peer sends after upgrading.
    opcode:        ws.Op_Code,

    // Payload of that frame (borrowed static bytes; read-only across the thread).
    payload:       []byte,

    // The peer ran its script to completion.
    ok:            bool,

    // The server closed the TCP connection.
    server_closed: bool,

    // The server sent a WebSocket Close frame before closing.
    got_close:     bool,

    // Close code carried by that Close frame.
    close_code:    u16,
}

// Connect a blocking TCP socket to loopback:port.
raw_dial :: proc(port: int) -> (net.TCP_Socket, bool) {
    endpoint := net.Endpoint {
        address = net.IP4_Loopback,
        port    = port,
    }

    sock, err := net.dial_tcp(endpoint)
    if err != nil {
        return {}, false
    }

    return sock, true
}

// Perform the client half of the WebSocket upgrade and validate the 101.
raw_upgrade :: proc(sock: net.TCP_Socket) -> bool {
    key_raw: [ws.SEC_WEBSOCKET_KEY_BYTES]byte
    crypto.rand_bytes(key_raw[:])
    key_encoded: [ws.SEC_WEBSOCKET_KEY_ENCODED_BYTES]byte
    base64.encode_into_buf(key_encoded[:], key_raw[:])

    request := ws.build_upgrade_request("/ws", "127.0.0.1", key_encoded[:], "", context.temp_allocator)
    if _, serr := net.send_tcp(sock, request); serr != nil {
        return false
    }

    buf: [4096]byte
    n := 0
    for n < len(buf) {
        got, rerr := net.recv_tcp(sock, buf[n:])
        if rerr != nil || got == 0 {
            return false
        }

        n += got
        result, _, status := ws.parse_upgrade_response(buf[:n], key_encoded[:])
        if status == .Ready {
            return result == .Ok
        }
    }

    return false
}

// Upgrade, send the configured (masked, as a real client) frame, then read back the
// server's Close frame or observe the socket close.
raw_peer :: proc(p: ^Raw_Peer) {
    defer free_all(context.temp_allocator)

    sock, ok := raw_dial(p.port)
    if !ok {
        return
    }
    defer net.close(sock)

    if !raw_upgrade(sock) {
        return
    }

    key: [ws.MASK_KEY_BYTES]byte
    crypto.rand_bytes(key[:])
    frame := ws.encode_frame(true, p.opcode, p.payload, key, context.temp_allocator)
    if _, serr := net.send_tcp(sock, frame); serr != nil {
        return
    }

    // Read with a client-role decoder (rejects masking, which a server never applies).
    dec: ws.Decoder
    ws.decoder_init(&dec, 1 << 20, 1 << 20, .Client, context.temp_allocator)
    defer ws.decoder_destroy(&dec)

    buf: [4096]byte
    for {
        msg, has, derr := ws.decoder_next(&dec, context.temp_allocator)
        if derr != .None {
            break
        }

        if has {
            if msg.kind == .Close {
                parsed, _ := ws.parse_close(msg.data)
                p.got_close = true
                p.close_code = u16(parsed.code)
                break
            }

            continue
        }

        got, rerr := net.recv_tcp(sock, buf[:])
        if rerr != nil || got == 0 {
            p.server_closed = true
            break
        }

        ws.decoder_feed(&dec, buf[:got])
    }

    p.ok = true
}

// Drive the loop while `peer` runs its blocking script, then assert the observed
// close. Shared by the protocol-error cases; each supplies a peer and the expected
// close code. Binds an OS-assigned ephemeral port.
run_raw :: proc(t: ^testing.T, opcode: ws.Op_Code, payload: string, expect_code: u16) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0})
    testing.expect_value(t, derr, Error.None)

    p := Raw_Peer {
        port    = bound_port(&d),
        opcode  = opcode,
        payload = transmute([]byte)payload,
    }
    peer := thread.create_and_start_with_poly_data(&p, raw_peer)
    defer {
        thread.join(peer)
        thread.destroy(peer)
    }

    for _ in 0 ..< 2000 {
        nbio.tick(time.Millisecond)
        if sync.atomic_load(&p.ok) && len(d.ws_server.conns) == 0 {
            break
        }
    }

    thread.join(peer)

    testing.expect(t, p.got_close, "server should send a Close frame")
    testing.expect_value(t, p.close_code, expect_code)

    test_teardown(&d)
}

@(test)
test_daemon_malformed_first_frame_closes :: proc(t: ^testing.T) {
    // A text frame that is not a valid `initialize` request (invalid JSON) is a protocol error.
    run_raw(t, .Text, "not json at all", wire.CLOSE.protocol_error)
}

@(test)
test_daemon_wrong_protocol_closes :: proc(t: ^testing.T) {
    // A well-formed `initialize` request with an unsupported protocol closes with the
    // dedicated code.
    hello := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol":2,"client":{"name":"x","version":"y"}}}`
    run_raw(t, .Text, hello, wire.CLOSE.unsupported_protocol)
}

@(test)
test_daemon_non_initialize_first_frame_closes :: proc(t: ^testing.T) {
    // The other half of the state-machine XOR: a well-formed request for a method
    // other than `initialize` is refused as a protocol error when sent first.
    req := `{"jsonrpc":"2.0","id":1,"method":"session.list","params":{}}`
    run_raw(t, .Text, req, wire.CLOSE.protocol_error)
}

@(test)
test_daemon_binary_frame_closes :: proc(t: ^testing.T) {
    // The v1 protocol carries only text frames; a binary frame is a protocol error
    // regardless of content.
    hello := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol":1,"client":{"name":"x","version":"y"}}}`
    run_raw(t, .Binary, hello, wire.CLOSE.protocol_error)
}

@(test)
test_daemon_trailing_bytes_closes :: proc(t: ^testing.T) {
    // One JSON value per frame: a valid `initialize` request followed by a trailing
    // token is rejected by `dec_finish` before it takes effect.
    hello := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol":1,"client":{"name":"x","version":"y"}}} 5`
    run_raw(t, .Text, hello, wire.CLOSE.protocol_error)
}

// `initialize` is the only method accepted before Ready, and the only one refused
// after it: a second `initialize` once Ready is a protocol error.
@(test)
test_daemon_second_initialize_after_ready_closes :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0})
    testing.expect_value(t, derr, Error.None)

    second := `{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocol":1,"client":{"name":"x","version":"y"}}}`

    p := Sub_Peer {
        port  = bound_port(&d),
        frame = second,
    }
    peer := thread.create_and_start_with_poly_data(&p, sub_peer)
    defer {
        thread.join(peer)
        thread.destroy(peer)
    }

    for _ in 0 ..< 2000 {
        nbio.tick(time.Millisecond)
        if sync.atomic_load(&p.ok) && len(d.ws_server.conns) == 0 {
            break
        }
    }

    thread.join(peer)

    testing.expect(t, p.got_close, "a second initialize after Ready should close the connection")
    testing.expect_value(t, p.close_code, wire.CLOSE.protocol_error)

    test_teardown(&d)
}

// --- Offloaded workspace work outliving its request and its connection --------

// Observations for the two-browses-in-flight test. Both requests are sent from the same
// `on_ready` turn, so the daemon has two filesystem passes outstanding on one connection.
Concurrent_Obs :: struct {
    // The active testing context, so checks can assert from inside the callback.
    t:         ^testing.T,

    // Fixture with three subdirectories; the first request browses it.
    dir:       string,

    // Fixture with one subdirectory; the second request browses it.
    other:     string,

    // Entry counts keyed by the browsed path, so each response is matched to its own
    // request rather than to arrival order.
    counts:    map[string]int,

    // Responses delivered.
    answered:  int,

    // Terminal callback fired.
    done:      bool,

    // Either a terminal callback or the harness timeout fired.
    wait_done: bool,

    // The harness timeout fired before both responses arrived.
    timed_out: bool,
}

concurrent_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    o := (^Concurrent_Obs)(c.user_data)
    client.client_send_request(
        c,
        .Workspace_Browse,
        wire.Workspace_Browse_Params{path = o.dir},
        concurrent_on_response,
    )
    client.client_send_request(
        c,
        .Workspace_Browse,
        wire.Workspace_Browse_Params{path = o.other},
        concurrent_on_response,
    )
}

concurrent_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Concurrent_Obs)(c.user_data)
    answered, has_response := outcome.(client.Request_Response)
    if !testing.expect(o.t, has_response, "browse request should receive a response") {
        client.client_close(c)
        return
    }

    resp := answered.response
    o.answered += 1

    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(o.t, is_ok, "both browses should succeed") {
        client.client_close(c)
        return
    }

    result, is_browse := ok.result.(wire.Workspace_Browse_Result)
    if !testing.expect(o.t, is_browse, "result is a browse result") {
        client.client_close(c)
        return
    }

    // The result path is borrowed for this callback only, so each response is recorded
    // under the matching fixture string the test owns for the whole run. A path matching
    // neither fixture is a failure in its own right: silently attributing it to one of
    // them would report a wrong entry count somewhere else instead.
    switch result.path {
    case o.dir:
        o.counts[o.dir] = len(result.entries)

    case o.other:
        o.counts[o.other] = len(result.entries)

    case:
        testing.expectf(o.t, false, "browse answered for an unrequested path %q", result.path)
        client.client_close(c)

        return
    }

    if o.answered == 2 {
        client.client_close(c)
    }
}

concurrent_on_close :: proc(c: ^client.Client, code: client.Close_Code) {
    o := (^Concurrent_Obs)(c.user_data)
    o.done = true
    o.wait_done = true
}

concurrent_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    o := (^Concurrent_Obs)(c.user_data)
    o.done = true
    o.wait_done = true
}

concurrent_on_timeout :: proc(_: ^nbio.Operation, o: ^Concurrent_Obs) {
    o.timed_out = true
    o.wait_done = true
}

// Two `workspace.browse` requests in flight on one connection are both answered, each
// against its own directory. Responses correlate by request id, so the offloaded passes
// may complete in either order.
@(test)
test_daemon_workspace_browse_two_in_flight :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_browse_dir("yuke-odin-browse-concurrent-a")
    defer os.remove_all(dir)

    other := test_make_dir("yuke-odin-browse-concurrent-b")
    defer os.remove_all(other)
    only, _ := os.join_path({other, "solo"}, context.temp_allocator)
    os.make_directory_all(only)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0})
    testing.expect_value(t, derr, Error.None)

    // Browse answers with the canonical path, so the correlation keys must be canonical
    // too: on macOS the temp fixtures live under `/var/...`, which resolves to
    // `/private/var/...` and would never match the raw fixture string.
    canonical_dir, dir_err := os.get_absolute_path(dir, context.temp_allocator)
    testing.expect(t, dir_err == nil, "the browse fixture canonicalizes")
    canonical_other, other_err := os.get_absolute_path(other, context.temp_allocator)
    testing.expect(t, other_err == nil, "the second fixture canonicalizes")

    obs := Concurrent_Obs {
        t     = t,
        dir   = canonical_dir,
        other = canonical_other,
    }
    obs.counts = make(map[string]int, 4, context.temp_allocator)

    c: client.Client
    transport, terr := client.ws_create(
        loop,
        {host = "127.0.0.1", port = bound_port(&d), path = "/ws"},
        context.temp_allocator,
    )
    testing.expect_value(t, terr, ws.Client_Error.None)

    cerr := client.client_open(
        &c,
        transport,
        "yuke-test",
        "0.1.0",
        client.Client_Callbacks {
            on_ready = concurrent_on_ready,
            on_close = concurrent_on_close,
            on_error = concurrent_on_error,
        },
        &obs,
        context.temp_allocator,
    )
    testing.expect_value(t, cerr, client.Protocol_Error.None)

    timeout_op := nbio.timeout_poly(2 * time.Second, &obs, concurrent_on_timeout, loop)
    nbio.run_until(&obs.wait_done)

    if !obs.timed_out {
        nbio.remove(timeout_op)
    } else {
        shutdown(&d)
        nbio.run_until(&obs.done)
    }

    testing.expect(t, !obs.timed_out, "both browses should answer before the harness timeout")
    testing.expect_value(t, obs.answered, 2)
    testing.expect_value(t, obs.counts[canonical_dir], 3)
    testing.expect_value(t, obs.counts[canonical_other], 1)

    client.client_destroy(&c)
    test_teardown(&d)
}

// Observations for the browse-then-close soak: the connection is closed in the same turn
// the request is sent, so the filesystem pass is still on a worker when its `Conn` goes.
Detach_Obs :: struct {
    // Directory the browse targets.
    dir:  string,

    // Terminal callback fired.
    done: bool,
}

detach_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    o := (^Detach_Obs)(c.user_data)
    client.client_send_request(c, .Workspace_Browse, wire.Workspace_Browse_Params{path = o.dir}, detach_on_response)
    client.client_close(c)
}

// The connection is closed in the same turn the request was sent, so this may never run.
detach_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
}

detach_on_close :: proc(c: ^client.Client, code: client.Close_Code) {
    o := (^Detach_Obs)(c.user_data)
    o.done = true
}

detach_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    o := (^Detach_Obs)(c.user_data)
    o.done = true
}

// A `workspace.browse` whose connection closes while its filesystem pass is still on a
// worker must neither crash nor leak: the completion resolves a ticket rather than a
// `^Conn`, finds nobody to answer, and frees the job. Repeated so the close lands both
// before and after the pass finishes.
@(test)
test_daemon_workspace_browse_close_during_pass_no_leak :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_browse_dir("yuke-odin-browse-detach")
    defer os.remove_all(dir)

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0}, tracked)
    testing.expect_value(t, derr, Error.None)

    port := bound_port(&d)
    ITERATIONS :: 32

    for i in 0 ..< ITERATIONS {
        obs := Detach_Obs {
            dir = dir,
        }

        c: client.Client
        transport, terr := client.ws_create(loop, {host = "127.0.0.1", port = port, path = "/ws"}, tracked)
        testing.expect_value(t, terr, ws.Client_Error.None)

        cerr := client.client_open(
            &c,
            transport,
            "yuke-test",
            "0.1.0",
            client.Client_Callbacks {
                on_ready = detach_on_ready,
                on_close = detach_on_close,
                on_error = detach_on_error,
            },
            &obs,
            tracked,
        )
        testing.expect_value(t, cerr, client.Protocol_Error.None)

        nbio.run_until(&obs.done)
        client.client_destroy(&c)

        // Let the daemon-side release and any finished pass land before the next cycle,
        // so completions interleave with fresh accepts instead of batching at teardown.
        for _ in 0 ..< 64 {
            if len(d.ws_server.conns) == 0 && offload.pool_outstanding(&d.workers) == 0 {
                break
            }

            nbio.tick(time.Millisecond)
        }

        testing.expectf(t, obs.done, "cycle %d should reach a terminal callback", i)
    }

    test_teardown(&d)

    testing.expectf(t, len(track.allocation_map) == 0, "expected zero leaks, got %d", len(track.allocation_map))
    testing.expectf(t, len(track.bad_free_array) == 0, "expected zero bad frees, got %d", len(track.bad_free_array))
}

// A response the emitter could not finish is protocol damage, not a smaller response:
// the peer would read a partial JSON value and lose framing for good. `send_response`
// aborts the connection rather than shipping the prefix.
@(test)
test_daemon_truncated_response_aborts_the_connection :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0})
    testing.expect_value(t, derr, Error.None)

    obs: Pump_Obs
    pump_obs_init(&obs, nil)
    c: client.Client
    pump_client_arm(t, &c, loop, bound_port(&d), &obs)

    conn: ^Conn
    for _, live in d.conns {
        conn = live
    }

    testing.expect(t, conn != nil, "the armed client has a daemon-side connection")

    // The refused encode is logged as an error, which the runner would otherwise count
    // as a test failure; the assertions below are the check.
    context.logger = log.nil_logger()

    // Smaller than the shortest response text, so the encode latches its truncation.
    backing: [16]byte
    arena: mem.Arena
    mem.arena_init(&arena, backing[:])

    send_result(conn, wire.Request_Id("1"), wire.Empty{}, mem.arena_allocator(&arena))

    testing.expect_value(t, conn.state, Protocol_State.Closed)
    testing.expect(t, pump_tick_until(&obs.done), "the aborted connection should terminate the client")
    testing.expect_value(t, len(obs.names), 0)

    client.client_destroy(&c)
    test_teardown(&d)
}

// --- Lifecycle soak under a tracking allocator (leak hunt) --------------------

// Repeated connect -> initialize -> Ready -> close cycles must leave zero leaked
// allocations and zero bad frees: the daemon's per-connection lifecycle (accept,
// allocate `Conn`, open, initialize, retain identity, close, release) frees everything
// it allocates on every cycle, mirroring the WebSocket package's soak rigor.
@(test)
test_daemon_lifecycle_no_leak :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0, daemon_version = "1.0.0"}, tracked)
    testing.expect_value(t, derr, Error.None)

    port := bound_port(&d)
    ITERATIONS :: 32

    for i in 0 ..< ITERATIONS {
        obs: Cli_Obs
        c: client.Client
        transport, terr := client.ws_create(loop, {host = "127.0.0.1", port = port, path = "/ws"}, tracked)
        testing.expect_value(t, terr, ws.Client_Error.None)

        cerr := client.client_open(&c, transport, "yuke-test", "0.1.0", cli_callbacks(), &obs, tracked)
        testing.expect_value(t, cerr, client.Protocol_Error.None)

        nbio.run_until(&obs.done)
        client.client_destroy(&c)

        // Drain the daemon-side connection's deferred teardown before the next cycle
        // so releases interleave with fresh accepts, not batch at the end.
        for _ in 0 ..< 64 {
            if len(d.ws_server.conns) == 0 {
                break
            }

            nbio.tick(time.Millisecond)
        }

        testing.expectf(t, obs.ready, "cycle %d should reach Ready", i)
    }

    test_teardown(&d)

    testing.expectf(t, len(track.allocation_map) == 0, "expected zero leaks, got %d", len(track.allocation_map))
    testing.expectf(t, len(track.bad_free_array) == 0, "expected zero bad frees, got %d", len(track.bad_free_array))
}
