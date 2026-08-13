package daemon

import "core:testing"

import store "src:daemon/store"

@(test)
test_run_model_resolve_finds_exact_and_misses :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)

    provider := state_provider(
        .Models_Dev,
        "openai",
        "openai",
        "OpenAI",
        "https://api.openai.com/v1",
        true,
        STATE_ENV[:],
    )
    model := state_model(.Models_Dev, "openai", "openai/gpt-5", "gpt-5", "https://api.openai.com/v1")
    testing.expect_value(t, store.catalog_imported_replace(s, provider, []store.Catalog_Model{model}), nil)

    effective, resolve_err := catalog_resolve_current(&d, context.allocator)
    testing.expect_value(t, resolve_err, nil)
    defer store.effective_catalog_destroy(&effective)

    hit, found := run_model_resolve(effective, "openai/gpt-5")
    testing.expect(t, found, "the model resolves by its public id")
    testing.expect_value(t, string(hit.info.id), "openai/gpt-5")
    testing.expect_value(t, hit.upstream_id, "gpt-5")
    testing.expect_value(t, hit.endpoint.base_url, "https://api.openai.com/v1")

    _, unknown := run_model_resolve(effective, "openai/nope")
    testing.expect(t, !unknown, "an unknown public id does not resolve")

    _, empty := run_model_resolve({}, "openai/gpt-5")
    testing.expect(t, !empty, "an empty catalog resolves nothing")
}
