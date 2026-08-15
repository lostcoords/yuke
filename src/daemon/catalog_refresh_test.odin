package daemon

import "core:mem/virtual"
import "core:testing"

import catalog "src:daemon/catalog"
import store "src:daemon/store"

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
