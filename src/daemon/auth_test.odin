package daemon

import "core:nbio"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "libs:bindings/curl"
import ws "libs:websocket"
import "src:client"
import "src:daemon/oauth"
import "src:daemon/store"
import "src:wire"

test_oauth_store_write :: proc(
    t: ^testing.T,
    path: string,
    kind: oauth.Kind,
    credentials: oauth.OAuth_Credentials,
) -> bool {
    opened, open_err := store.open(path)
    if !testing.expect_value(t, open_err, nil) do return false
    defer store.close(opened)

    provider := oauth.provider(kind)
    write_err := store.credential_oauth_upsert(
        opened,
        provider.id,
        {
            access_token = credentials.access_token,
            refresh_token = credentials.refresh_token,
            expires_at_ms = credentials.expires_at_ms,
            account_id = credentials.account_id,
        },
    )

    return testing.expect_value(t, write_err, nil)
}

test_store_credential_present :: proc(t: ^testing.T, s: ^store.Store, provider_id: string) -> bool {
    credentials, load_err := store.credentials_load(s)
    if !testing.expect_value(t, load_err, nil) do return false
    defer store.credentials_destroy(credentials)

    for credential in credentials {
        if credential.provider_id == provider_id do return true
    }

    return false
}

test_api_key_store_write :: proc(t: ^testing.T, path, provider_id, api_key: string) -> bool {
    opened, open_err := store.open(path)
    if !testing.expect_value(t, open_err, nil) do return false
    defer store.close(opened)

    return testing.expect_value(t, store.credential_api_key_upsert(opened, provider_id, api_key), nil)
}

// A name 270 UTF-8 bytes long (90 repeated 3-byte "あ" runes) but only 90 characters:
// over the wire's 256-byte `Dir_Entry.name`/`Workspace.title` bound, yet well within

check_auth_list :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "auth.list should succeed") do return true

    result, is_list := ok.result.(wire.Auth_List_Result)
    if !testing.expect(t, is_list, "result is an auth provider list") do return true

    if !testing.expect_value(t, len(result.providers), 2) do return true

    codex_entry: Maybe(wire.Auth_Provider)
    xai_entry: Maybe(wire.Auth_Provider)
    for entry in result.providers {
        switch string(entry.provider_id) {
        case oauth.CODEX_PROVIDER_ID:
            codex_entry = entry

        case oauth.XAI_PROVIDER_ID:
            xai_entry = entry
        }
    }

    codex, codex_ok := codex_entry.?
    if !testing.expect(t, codex_ok, "codex provider is listed") do return true
    testing.expect(t, codex.credential_kind == nil, "fresh Codex auth has no credential")
    testing.expect(t, !codex.restart_required, "OAuth state applies immediately")
    _, codex_pending := codex.pending_login.?
    testing.expect(t, !codex_pending, "fresh auth has no pending login")

    codex_device := false
    for flow in codex.login_flows {
        codex_device = codex_device || flow == .Device_Code
    }
    testing.expect(t, codex_device, "codex device login remains available without a callback port")

    xai, xai_ok := xai_entry.?
    if !testing.expect(t, xai_ok, "xai provider is listed") do return true
    testing.expect(t, xai.credential_kind == nil, "fresh xAI auth has no credential")

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
test_daemon_auth_list_uses_the_daemon_store :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Handler_Obs {
        method = .Auth_List,
        params = wire.Empty{},
        check  = check_auth_list,
    }
    run_handler(t, &obs)
}

test_auth_provider_find :: proc(providers: []wire.Auth_Provider, provider_id: string) -> (wire.Auth_Provider, bool) {
    for provider in providers {
        if provider.provider_id == wire.Provider_Id(provider_id) do return provider, true
    }

    return {}, false
}

check_auth_set_api_key_stages_until_restart :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t

    if o.auth_stage == 0 {
        ok, is_ok := resp.(wire.Response_Ok)
        if !testing.expect(t, is_ok, "auth.set_api_key should succeed over loopback") do return true

        result, is_result := ok.result.(wire.Auth_Set_Api_Key_Result)
        if testing.expect(t, is_result, "auth.set_api_key returns its write-only result") do testing.expect(t, result.restart_required, "API-key writes require restart")
        testing.expect(t, "openai" not_in o.daemon.provider_auth.api_keys, "write does not change active keys")
        testing.expect(t, test_store_credential_present(t, o.daemon.store, "openai"), "write is durable")

        o.auth_stage = 1
        client.client_send_request(c, .Auth_List, wire.Empty{}, handler_on_response)
        return false
    }

    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "auth.list should succeed after an API-key write") do return true

    result, is_list := ok.result.(wire.Auth_List_Result)
    if !testing.expect(t, is_list, "auth.list returns provider statuses") do return true

    provider, found := test_auth_provider_find(result.providers, "openai")
    if testing.expect(t, found, "saved API-key provider is listed") {
        kind, has_kind := provider.credential_kind.?
        testing.expect(t, has_kind && kind == .Api_Key, "list reveals only the credential kind")
        testing.expect(t, provider.restart_required, "list reports the staged restart")
        testing.expect_value(t, len(provider.login_flows), 0)
    }

    return true
}

check_auth_api_key_active_after_restart :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    active, found_active := o.daemon.provider_auth.api_keys["openai"]
    testing.expect(t, found_active && active == "test-api-key", "restart activates the saved API key")

    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "auth.list should succeed after restart") do return true

    result, is_list := ok.result.(wire.Auth_List_Result)
    if !testing.expect(t, is_list, "auth.list returns provider statuses") do return true

    provider, found := test_auth_provider_find(result.providers, "openai")
    if testing.expect(t, found, "active API-key provider is listed") {
        kind, has_kind := provider.credential_kind.?
        testing.expect(t, has_kind && kind == .Api_Key, "active provider retains its credential kind")
        testing.expect(t, !provider.restart_required, "restart clears the staged status")
    }

    return true
}

@(test)
test_daemon_auth_set_api_key_applies_only_after_restart :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-daemon-auth-set-api-key")
    defer os.remove_all(dir)
    path, _ := os.join_path({dir, "yuked.db"}, context.temp_allocator)

    write_obs := Handler_Obs {
        method = .Auth_Set_Api_Key,
        params = wire.Auth_Set_Api_Key_Params{provider_id = "openai", api_key = "test-api-key"},
        check = check_auth_set_api_key_stages_until_restart,
    }
    run_handler(t, &write_obs, db_path = path)

    restart_obs := Handler_Obs {
        method = .Auth_List,
        params = wire.Empty{},
        check  = check_auth_api_key_active_after_restart,
    }
    run_handler(t, &restart_obs, db_path = path)
}

check_auth_api_key_remove_stages_until_restart :: proc(
    c: ^client.Client,
    resp: wire.Response,
    o: ^Handler_Obs,
) -> bool {
    t := o.t

    if o.auth_stage == 0 {
        ok, is_ok := resp.(wire.Response_Ok)
        if !testing.expect(t, is_ok, "auth.logout should remove an API key") do return true
        _, is_empty := ok.result.(wire.Empty)
        testing.expect(t, is_empty, "auth.logout returns an empty result")

        active, found_active := o.daemon.provider_auth.api_keys["openai"]
        testing.expect(t, found_active && active == "test-api-key", "removal keeps the active startup key")
        testing.expect(t, !test_store_credential_present(t, o.daemon.store, "openai"), "removal is durable")

        o.auth_stage = 1
        client.client_send_request(c, .Auth_List, wire.Empty{}, handler_on_response)
        return false
    }

    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "auth.list should succeed after API-key removal") do return true

    result, is_list := ok.result.(wire.Auth_List_Result)
    if !testing.expect(t, is_list, "auth.list returns provider statuses") do return true

    provider, found := test_auth_provider_find(result.providers, "openai")
    if testing.expect(t, found, "active removed provider remains listed until restart") {
        testing.expect(t, provider.credential_kind == nil, "removed provider has no saved credential")
        testing.expect(t, provider.restart_required, "removal requires restart")
    }

    return true
}

@(test)
test_daemon_auth_remove_api_key_applies_only_after_restart :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-daemon-auth-remove-api-key")
    defer os.remove_all(dir)
    path, _ := os.join_path({dir, "yuked.db"}, context.temp_allocator)
    if !test_api_key_store_write(t, path, "openai", "test-api-key") do return

    obs := Handler_Obs {
        method = .Auth_Logout,
        params = wire.Auth_Logout_Params{provider_id = "openai"},
        check = check_auth_api_key_remove_stages_until_restart,
    }
    run_handler(t, &obs, db_path = path)
}

check_auth_set_api_key_rejects_oauth_provider :: proc(
    c: ^client.Client,
    resp: wire.Response,
    o: ^Handler_Obs,
) -> bool {
    t := o.t
    rejected, is_error := resp.(wire.Response_Error)
    if testing.expect(t, is_error, "OAuth-only provider rejects an API key") do testing.expect_value(t, rejected.error.code, wire.Error_Code.Bad_Request)
    testing.expect(
        t,
        !test_store_credential_present(t, o.daemon.store, oauth.CODEX_PROVIDER_ID),
        "rejection is durable",
    )
    testing.expect(t, oauth.CODEX_PROVIDER_ID not_in o.daemon.provider_auth.staged_api_keys, "rejection is not staged")

    return true
}

@(test)
test_daemon_auth_set_api_key_rejects_oauth_only_provider :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Handler_Obs {
        method = .Auth_Set_Api_Key,
        params = wire.Auth_Set_Api_Key_Params{provider_id = oauth.CODEX_PROVIDER_ID, api_key = "test-api-key"},
        check = check_auth_set_api_key_rejects_oauth_provider,
    }
    run_handler(t, &obs)
}

@(test)
test_daemon_oauth_refresh_timer_is_owned_by_shutdown :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-daemon-auth-refresh-timer")
    defer os.remove_all(dir)
    path, _ := os.join_path({dir, "yuked.db"}, context.temp_allocator)

    credentials := oauth.OAuth_Credentials {
        access_token  = "access",
        refresh_token = "refresh",
        expires_at_ms = now_ms() + u64(time.Hour / time.Millisecond),
        account_id    = "account",
    }
    if !test_oauth_store_write(t, path, .Codex, credentials) do return

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    _, signed_in := provider_credentials_get(&d, .Codex)
    testing.expect(t, signed_in, "startup loads OAuth credentials from the daemon store")
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
test_daemon_successful_refresh_updates_the_daemon_store :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-daemon-auth-refresh-success")
    defer os.remove_all(dir)
    path, _ := os.join_path({dir, "yuked.db"}, context.temp_allocator)

    credentials := oauth.OAuth_Credentials {
        access_token  = "access",
        refresh_token = "refresh",
        expires_at_ms = 1,
        account_id    = "account",
    }
    if !test_oauth_store_write(t, path, .Codex, credentials) do return

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    defer test_teardown(&d)
    provider_refresh_timer_cancel(&d)

    refresh, aerr := new(Provider_Refresh, d.allocator)
    if !testing.expect(t, aerr == nil, "allocate refresh attempt") do return
    refresh^ = {
        kind = .Codex,
        transfer = {state = .Done},
    }
    testing.expect(
        t,
        bounded_response_accumulate(&refresh.response, transmute([]byte)string(`{}`)),
        "refresh response fits",
    )
    d.provider_auth.operation = refresh

    provider_refresh_on_done(&d, curl.Result{code = .Ok, status = 200})
    testing.expect(t, provider_refresh(&d) == nil, "successful refresh releases the operation")

    live, signed_in := provider_credentials_get(&d, .Codex)
    if testing.expect(t, signed_in, "successful refresh keeps the provider signed in") do testing.expect(t, live.expires_at_ms > credentials.expires_at_ms, "live expiry was refreshed")

    rows, load_err := store.credentials_load(d.store)
    if !testing.expect_value(t, load_err, nil) do return
    defer store.credentials_destroy(rows)

    stored := false
    for row in rows {
        if row.provider_id == oauth.CODEX_PROVIDER_ID {
            stored = true
            testing.expect(t, row.expires_at_ms > credentials.expires_at_ms, "stored expiry was refreshed")
        }
    }
    testing.expect(t, stored, "refreshed credentials remain durable")
}

@(test)
test_daemon_login_deadline_releases_the_attempt :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0}), Error.None)
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
test_daemon_login_summary_tracks_the_live_attempt :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0}), Error.None)
    defer test_teardown(&d)

    login_id := login_id_create()
    login := Provider_Login {
        kind           = .Xai,
        id             = login_id,
        requested_flow = .Device_Code,
    }
    d.provider_auth.operation = &login

    state := provider_state(&d, .Xai)
    summary, pending := state.pending_login.?
    if testing.expect(t, pending, "live login exposes its public summary") {
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
    path, _ := os.join_path({dir, "yuked.db"}, context.temp_allocator)

    credentials := oauth.OAuth_Credentials {
        access_token  = "access",
        refresh_token = "refresh",
        expires_at_ms = now_ms() + u64(time.Hour / time.Millisecond),
        account_id    = "",
    }
    if !test_oauth_store_write(t, path, .Xai, credentials) do return

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    defer test_teardown(&d)
    provider_refresh_timer_cancel(&d)

    _, found := provider_credentials_get(&d, .Xai)
    testing.expect(t, found, "refresh fixture is signed in")

    refresh, aerr := new(Provider_Refresh, d.allocator)
    if !testing.expect(t, aerr == nil, "allocate refresh attempt") do return
    refresh^ = {
        kind = .Xai,
        transfer = {state = .Done},
    }
    testing.expect(
        t,
        bounded_response_accumulate(&refresh.response, transmute([]byte)string(`{"error":"invalid_grant"}`)),
        "terminal response fits",
    )
    d.provider_auth.operation = refresh

    provider_refresh_on_done(&d, curl.Result{code = .Ok, status = 400})
    testing.expect(t, provider_refresh(&d) == nil, "terminal response releases the refresh")
    _, signed_in := provider_credentials_get(&d, .Xai)
    testing.expect(t, !signed_in, "terminal refresh signs the provider out")
    testing.expect(t, !test_store_credential_present(t, d.store, oauth.XAI_PROVIDER_ID), "removal is durable")
}

check_auth_logout :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "auth.logout should succeed") do return true

    _, is_empty := ok.result.(wire.Empty)
    testing.expect(t, is_empty, "auth.logout returns an empty result")

    return true
}

@(test)
test_daemon_auth_logout_durably_removes_credentials :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-daemon-auth-logout")
    defer os.remove_all(dir)
    path, _ := os.join_path({dir, "yuked.db"}, context.temp_allocator)

    credentials := oauth.OAuth_Credentials {
        access_token  = "access",
        refresh_token = "refresh",
        expires_at_ms = 1_900_000_000_000,
        account_id    = "account",
    }
    if !test_oauth_store_write(t, path, .Codex, credentials) do return

    obs := Handler_Obs {
        method = .Auth_Logout,
        params = wire.Auth_Logout_Params{provider_id = oauth.CODEX_PROVIDER_ID},
        check = check_auth_logout,
    }
    run_handler(t, &obs, db_path = path)

    reopened, reopen_err := store.open(path)
    if !testing.expect_value(t, reopen_err, nil) do return
    defer store.close(reopened)
    testing.expect(
        t,
        !test_store_credential_present(t, reopened, oauth.CODEX_PROVIDER_ID),
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
        if !testing.expect(t, is_ok, "browser auth.login should succeed") do return true

        login_result, is_login := ok.result.(wire.Auth_Login_Result)
        if !testing.expect(t, is_login, "auth.login returns login details") do return true

        result, is_browser := login_result.(wire.Auth_Login_Result_Browser)
        if !testing.expect(t, is_browser, "auth.login returns browser details") do return true
        testing.expect(t, strings.has_prefix(result.auth_url, oauth.CODEX_AUTHORIZE_URL), "Codex authorize URL")
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
    if !testing.expect(t, is_ok, "auth.cancel_login should succeed") do return true
    _, is_empty := ok.result.(wire.Empty)
    testing.expect(t, is_empty, "auth.cancel_login returns an empty result")

    return true
}

@(test)
test_daemon_browser_login_starts_and_cancels_over_websocket :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Handler_Obs {
        method = .Auth_Login,
        params = wire.Auth_Login_Params{provider_id = oauth.CODEX_PROVIDER_ID, flow = .Browser},
        check = check_auth_browser_start_cancel,
    }
    run_handler(t, &obs)
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
        tx = Relay_Client{relay = &relay_tx},
    }
    testing.expect(t, !provider_login_flow_allowed(&remote, .Browser), "relay browser login is refused")
    testing.expect(t, provider_login_flow_allowed(&remote, .Device_Code), "relay device login is admitted")
}

@(test)
test_api_key_write_is_admitted_over_established_relay :: proc(t: ^testing.T) {
    relay_tx: Relay
    relay_tx.peers[0].established = true
    conn := Conn {
        tx = Relay_Client{relay = &relay_tx, channel = 0},
    }
    relay_tx.peers[0].conn = &conn

    testing.expect(t, provider_api_key_transport_allowed(&conn), "encrypted relay admits API keys")
}
