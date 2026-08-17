package daemon

import "core:mem"
import "core:mem/virtual"
import "core:nbio"
import "core:testing"

import "libs:bindings/curl"
import "src:client"
import "src:daemon/catalog"
import "src:daemon/store"
import "src:wire"

@(private, rodata)
REV_LEVELS := [?]string{"low", "medium", "high"}

@(private)
rev_model :: proc(id, provider, name: string, levels: []string, default: string, cost_in: f64) -> wire.Model_Info {
    return {
        id = wire.Model_Id(id),
        provider = provider,
        name = name,
        context_window = 1000,
        max_output_tokens = 100,
        reasoning_levels = levels,
        default_reasoning = default,
        supports_tools = true,
        cost = {input = cost_in, output = 10, cache_read = 0.5, cache_write = 1},
    }
}

@(test)
test_catalog_rev_changes_on_health :: proc(t: ^testing.T) {
    models := []wire.Model_Info{rev_model("openai/gpt-5", "openai", "GPT", REV_LEVELS[:], "medium", 2)}
    healthy := catalog_rev(models, {})

    // A load error with an unchanged model set must still change the revision.
    errored := catalog_rev(models, {load_error = "models.dev unreachable"})
    testing.expect(t, errored != healthy, "a load_error changes the revision")

    // A skipped provider that contributed no visible models must still change it.
    skipped := catalog_rev(
        models,
        {skipped = []wire.Skipped_Provider{{provider = "xai", reason = wire.Skip_Reason_Missing_Credential{}}}},
    )
    testing.expect(t, skipped != healthy, "a skipped provider changes the revision")

    // The same skipped provider with a different reason is a different revision.
    reasoned := catalog_rev(
        models,
        {skipped = []wire.Skipped_Provider{{provider = "xai", reason = wire.Skip_Reason_Invalid_Config{}}}},
    )
    testing.expect(t, reasoned != skipped, "a skip-reason change changes the revision")
}

@(test)
test_catalog_rev_boundary_between_adjacent_fields :: proc(t: ^testing.T) {
    // Length-prefixing must keep "ab"+"c" distinct from "a"+"bc" across adjacent
    // string fields (id then provider here).
    a := []wire.Model_Info{rev_model("ab", "c", "n", REV_LEVELS[:], "medium", 2)}
    b := []wire.Model_Info{rev_model("a", "bc", "n", REV_LEVELS[:], "medium", 2)}

    testing.expect(t, catalog_rev(a, {}) != catalog_rev(b, {}), "adjacent string fields do not run together")
}

@(private, rodata)
STATE_LEVELS := [?]string{"low", "medium", "high"}

@(private, rodata)
STATE_ENV := [?]string{"OPENAI_API_KEY"}

// One provider carrying a model per public id. Models allocate into the temp allocator, so
// a caller may edit them before writing.
@(private)
state_provider :: proc(t: ^testing.T, id, base_url: string, public_ids: ..string) -> catalog.Provider {
    item := catalog.Provider {
        id = wire.Provider_Id(id),
        source_id = id,
        name = "OpenAI",
        endpoint = {base_url = base_url, protocol = .Openai_Responses},
        credential_env = STATE_ENV[:],
    }
    item.models.allocator = context.temp_allocator

    for public_id in public_ids {
        _, append_err := append(&item.models, state_model(id, public_id, base_url))
        testing.expect_value(t, append_err, nil)
    }

    return item
}

@(private)
state_model :: proc(provider_id, public_id, base_url: string) -> catalog.Model {
    return catalog.Model {
        info = {
            id = wire.Model_Id(public_id),
            provider = provider_id,
            name = "Model",
            context_window = 1000,
            max_output_tokens = 100,
            reasoning_levels = STATE_LEVELS[:],
            default_reasoning = "medium",
            supports_tools = true,
        },
        upstream_id = "upstream",
        endpoint = {base_url = base_url, protocol = .Openai_Responses},
        supports_temperature = true,
        reasoning_replay = .None,
        thinking_format = .None,
        max_tokens_field = .Max_Tokens,
    }
}

@(test)
test_catalog_state_holds_the_snapshot_it_revised :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    // An empty store loads to a valid, stable, model-free revision.
    testing.expect_value(t, catalog_state_load(&d), nil)
    empty_rev := d.catalog.rev
    for value in ([64]u8)(empty_rev) {
        is_hex := (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f')
        testing.expect(t, is_hex, "the empty revision is lowercase hex")
    }
    testing.expect_value(t, len(d.catalog.health.skipped), 0)
    testing.expect_value(t, empty_rev, catalog_rev(nil, {}))
    testing.expect_value(t, len(d.catalog.snapshot.providers), 0)

    item := state_provider(t, "openai", "https://api.openai.com/v1", "openai/gpt-5")
    testing.expect_value(t, store.catalog_imported_replace(s, item, `"e"`), nil)

    // Reloading moves the revision, holds the new snapshot, and carries the feed's ETag.
    testing.expect_value(t, catalog_state_load(&d), nil)
    testing.expect(t, d.catalog.rev != empty_rev, "adding a model changes the revision")
    testing.expect_value(t, d.catalog.snapshot.feed_etag, `"e"`)

    view, ok := catalog_models_view(d.catalog.snapshot, context.allocator)
    defer delete(view)
    testing.expect(t, ok, "the view allocates")
    if testing.expect_value(t, len(view), 1) {
        testing.expect_value(t, string(view[0].id), "openai/gpt-5")
    }

    // The held revision covers the held snapshot — the invariant `catalog.list` relies on
    // when it answers with the held rev and a view built from the same rows.
    testing.expect_value(t, d.catalog.rev, catalog_rev(view, d.catalog.health))

    // The run path resolves against the same snapshot rather than reading the store.
    found := catalog_model_find(&d, "openai/gpt-5")
    if testing.expect(t, found != nil, "the held snapshot resolves a model by public id") {
        testing.expect_value(t, found.upstream_id, "upstream")
    }

    testing.expect(t, catalog_model_find(&d, "openai/absent") == nil, "an unknown id resolves to nothing")
}

@(test)
test_catalog_state_reload_replaces_the_snapshot :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    testing.expect_value(
        t,
        store.catalog_imported_replace(
            s,
            state_provider(t, "openai", "https://api.openai.com/v1", "openai/gpt-5"),
            "",
        ),
        nil,
    )
    testing.expect_value(t, catalog_state_load(&d), nil)
    first := d.catalog.rev

    // A second load frees the snapshot it replaces rather than accumulating them, which
    // the leak check on this package's tests is what actually proves.
    testing.expect_value(
        t,
        store.catalog_imported_replace(
            s,
            state_provider(t, "openai", "https://api.openai.com/v1", "openai/gpt-6"),
            "",
        ),
        nil,
    )
    testing.expect_value(t, catalog_state_load(&d), nil)

    testing.expect(t, d.catalog.rev != first, "replacing the model changes the revision")
    testing.expect(t, catalog_model_find(&d, "openai/gpt-5") == nil, "the replaced model is gone")
    testing.expect(t, catalog_model_find(&d, "openai/gpt-6") != nil, "the replacement is held")
}

@(private, rodata)
REFRESH_FEED := `{"openai":{"id":"openai","env":["OPENAI_API_KEY"],"npm":"@ai-sdk/openai","name":"OpenAI","models":{"gpt":{"id":"gpt","name":"GPT","tool_call":true,"reasoning_options":[{"type":"effort","values":["low","medium","high"]}],"modalities":{"input":["text"],"output":["text"]},"limit":{"context":1000,"output":100}}}}}`

@(test)
test_catalog_refresh_apply_imports_and_moves_rev :: proc(t: ^testing.T) {
    d: Daemon
    s := refresh_op_daemon(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    empty_rev := d.catalog.rev

    selections := []catalog.Selection{{provider_id = "openai", source_id = "openai"}}
    changed, err := catalog_refresh_apply(&d, transmute([]byte)REFRESH_FEED, `"feed-1"`, selections)
    testing.expect_value(t, err, nil)
    testing.expect(t, changed, "importing a provider moves the revision")
    testing.expect(t, d.catalog.rev != empty_rev, "the held revision moved")

    view, ok := catalog_models_view(d.catalog.snapshot, context.allocator)
    defer delete(view)
    testing.expect(t, ok, "the view allocates")
    testing.expect_value(t, len(view), 1)
    testing.expect_value(t, view[0].provider, "openai")

    // Applying the same feed again changes nothing.
    changed_again, again_err := catalog_refresh_apply(&d, transmute([]byte)REFRESH_FEED, `"feed-1"`, selections)
    testing.expect_value(t, again_err, nil)
    testing.expect(t, !changed_again, "re-importing identical content leaves the revision unchanged")
}

@(test)
test_catalog_refresh_apply_preserves_snapshot_on_decode_error :: proc(t: ^testing.T) {
    d: Daemon
    s := refresh_op_daemon(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    selections := []catalog.Selection{{provider_id = "openai", source_id = "openai"}}
    _, import_err := catalog_refresh_apply(&d, transmute([]byte)REFRESH_FEED, `"feed-1"`, selections)
    testing.expect_value(t, import_err, nil)
    imported_rev := d.catalog.rev

    // A malformed feed replaces nothing and preserves the previous snapshot.
    changed, err := catalog_refresh_apply(&d, transmute([]byte)string("this is not json"), `"feed-2"`, selections)
    testing.expect(t, err != nil, "a malformed feed is rejected")
    testing.expect(t, !changed, "a rejected feed does not move the revision")
    testing.expect_value(t, d.catalog.rev, imported_rev)
}

@(test)
test_catalog_feed_invalidate_clears_the_held_etag :: proc(t: ^testing.T) {
    d: Daemon
    s := refresh_op_daemon(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    selections := []catalog.Selection{{provider_id = "openai", source_id = "openai"}}
    _, err := catalog_refresh_apply(&d, transmute([]byte)REFRESH_FEED, `"feed-1"`, selections)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, d.catalog.snapshot.feed_etag, `"feed-1"`)

    rev_before := d.catalog.rev
    catalog_feed_invalidate(&d)

    // etag drops; revision unchanged.
    testing.expect_value(t, d.catalog.snapshot.feed_etag, "")
    testing.expect_value(t, d.catalog.rev, rev_before)
}

@(test)
test_catalog_selections_build_from_credentials :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)

    testing.expect_value(t, store.credential_api_key_upsert(s, "openai", "sk-test"), nil)
    testing.expect_value(t, store.credential_api_key_upsert(s, "anthropic", "sk-test-2"), nil)

    // xai-grok overrides its source to "xai"; openai-codex declares none and drops out.
    oauth_cred := store.OAuth_Credential {
        access_token  = "a-token",
        refresh_token = "r-token",
        expires_at_ms = 1,
    }
    testing.expect_value(t, store.credential_oauth_upsert(s, "xai-grok", oauth_cred), nil)
    testing.expect_value(t, store.credential_oauth_upsert(s, "openai-codex", oauth_cred), nil)

    arena: virtual.Arena
    testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
    defer virtual.arena_destroy(&arena)

    selections, err := catalog_selections_build(&d, virtual.arena_allocator(&arena))
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(selections), 3)

    found_anthropic := false
    found_openai := false
    found_xai := false
    for selection in selections {
        switch string(selection.provider_id) {
        case "anthropic":
            found_anthropic = true
            testing.expect_value(t, selection.source_id, "anthropic")

        case "openai":
            found_openai = true
            testing.expect_value(t, selection.source_id, "openai")

        case "xai-grok":
            found_xai = true
            testing.expect_value(t, selection.source_id, "xai")

        case "openai-codex":
            testing.expect(t, false, "Codex declares no models.dev source and must not be selected")
        }
    }

    testing.expect(t, found_anthropic, "a provider with a saved credential is selected")
    testing.expect(t, found_openai, "a provider with a saved credential is selected")
    testing.expect(t, found_xai, "an OAuth provider is selected under its declared source")
}

@(private)
catalog_test_store :: proc(t: ^testing.T, d: ^Daemon) -> ^store.Store {
    d.allocator = context.allocator
    s, open_err := store.open_memory()
    testing.expect_value(t, open_err, nil)
    d.store = s
    return s
}

refresh_op_daemon :: proc(t: ^testing.T, d: ^Daemon) -> ^store.Store {
    s := catalog_test_store(t, d)
    testing.expect_value(t, catalog_state_load(d), nil)
    return s
}

@(test)
test_catalog_refresh_settle_applies_on_200 :: proc(t: ^testing.T) {
    d: Daemon
    s := refresh_op_daemon(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    // A saved credential makes openai a selected provider.
    testing.expect_value(t, store.credential_api_key_upsert(s, "openai", "sk-test"), nil)
    old_rev := d.catalog.rev

    outcome := catalog_refresh_settle(&d, .Ok, 200, false, transmute([]byte)REFRESH_FEED, `"etag-1"`)
    testing.expect(t, outcome.ok, "a 200 with a selected provider succeeds")
    testing.expect(t, outcome.changed, "importing new models moves the revision")
    testing.expect(t, d.catalog.rev != old_rev, "the held revision moved")
}

@(test)
test_catalog_refresh_settle_noop_on_304 :: proc(t: ^testing.T) {
    d: Daemon
    s := refresh_op_daemon(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    old_rev := d.catalog.rev
    outcome := catalog_refresh_settle(&d, .Ok, 304, false, nil, "")
    testing.expect(t, outcome.ok, "not-modified is a success")
    testing.expect(t, !outcome.changed, "not-modified changes nothing")
    testing.expect_value(t, d.catalog.rev, old_rev)
}

@(test)
test_catalog_refresh_settle_rejects_a_failed_fetch :: proc(t: ^testing.T) {
    d: Daemon
    s := refresh_op_daemon(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    old_rev := d.catalog.rev
    Case :: struct {
        code:     curl.Code,
        status:   int,
        overflow: bool,
    }
    cases := [?]Case{{.Ok, 503, false}, {.Write_Error, 0, true}, {.Couldnt_Connect, 0, false}}
    for c in cases {
        outcome := catalog_refresh_settle(&d, c.code, c.status, c.overflow, nil, "")
        testing.expect(t, !outcome.ok, "a failed fetch is an error")
        testing.expect(t, !outcome.changed, "a rejected fetch changes nothing")
        testing.expect_value(t, d.catalog.rev, old_rev)
    }
}

// The in-flight fetch owns its request id: the inbound frame's arena is reset and wiped
// when the request returns, long before the fetch completes.
@(test)
test_catalog_refresh_owns_its_request_id :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    d: Daemon
    d.loop = nbio.current_thread_event_loop()
    s := refresh_op_daemon(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    testing.expect_value(t, catalog_refresh_init(&d), Error.None)
    defer catalog_refresh_destroy(&d)

    // Stands in for the frame arena: the bytes the id points at are reused and wiped as
    // soon as the request that carried it returns.
    borrowed: [7]byte
    copy(borrowed[:], `"req-1"`)

    testing.expect(t, catalog_refresh_begin(&d, 7, wire.Request_Id(string(borrowed[:]))), "the fetch starts")
    defer catalog_refresh_shutdown(&d)

    mem.zero_slice(borrowed[:])

    op := d.catalog_refresh.operation
    if testing.expect(t, op != nil, "the started fetch is the live operation") {
        testing.expect_value(t, string(op.request_id), `"req-1"`)
        testing.expect_value(t, wire.req_id_validate(op.request_id), wire.Validation_Error.None)
    }
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
        params = wire.Catalog_List_Params{since_rev = catalog_rev(nil, {})},
        check = check_catalog_unchanged,
    }
    run_handler(t, &obs)
}
