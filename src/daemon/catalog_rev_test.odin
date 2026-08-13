package daemon

import "core:testing"

import catalog "src:daemon/catalog"
import store "src:daemon/store"
import wire "src:wire"

@(private, rodata)
REV_LEVELS := [?]string{"low", "medium", "high"}

@(private, rodata)
REV_LEVELS_PERMUTED := [?]string{"high", "medium", "low"}

@(private, rodata)
REV_LEVELS_ALT := [?]string{"low", "high"}

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

// Hash one model against an empty health block.
@(private)
rev_of :: proc(model: wire.Model_Info) -> wire.Catalog_Rev {
    return catalog_rev([]wire.Model_Info{model}, {})
}

@(test)
test_catalog_rev_is_lowercase_hex :: proc(t: ^testing.T) {
    models := []wire.Model_Info{rev_model("openai/gpt-5", "openai", "GPT", REV_LEVELS[:], "medium", 2)}
    rev := catalog_rev(models, {})

    for value in ([64]u8)(rev) {
        is_hex := (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f')
        testing.expectf(t, is_hex, "a revision byte %d must be lowercase hex", value)
    }

    // A real revision must satisfy the wire id contract used by catalog.list.
    full := wire.Catalog_List_Result_Full {
        catalog_rev = rev,
        models      = models,
        health      = {},
    }
    testing.expect_value(t, wire.catalog_list_result_validate(full), wire.Validation_Error.None)
}

@(test)
test_catalog_rev_is_deterministic :: proc(t: ^testing.T) {
    models := []wire.Model_Info {
        rev_model("openai/gpt-5", "openai", "GPT", REV_LEVELS[:], "medium", 2),
        rev_model("openai/o1", "openai", "O1", REV_LEVELS[:], "medium", 3),
    }

    testing.expect(
        t,
        catalog_rev(models, {}) == catalog_rev(models, {}),
        "the same content hashes to the same revision",
    )
}

@(test)
test_catalog_rev_empty_is_stable_and_distinct :: proc(t: ^testing.T) {
    single := []wire.Model_Info{rev_model("openai/gpt-5", "openai", "GPT", REV_LEVELS[:], "medium", 2)}

    testing.expect(t, catalog_rev(nil, {}) == catalog_rev([]wire.Model_Info{}, {}), "an empty catalog hashes stably")
    testing.expect(t, catalog_rev(nil, {}) != catalog_rev(single, {}), "an empty catalog differs from a non-empty one")
}

@(test)
test_catalog_rev_changes_on_every_visible_field :: proc(t: ^testing.T) {
    base := rev_model("openai/gpt-5", "openai", "GPT", REV_LEVELS[:], "medium", 2)
    original := rev_of(base)

    id := base; id.id = "openai/gpt-5x"
    provider := base; provider.provider = "openai2"
    name := base; name.name = "GPT-5"
    window := base; window.context_window = 2000
    output := base; output.max_output_tokens = 200
    vision := base; vision.supports_vision = !base.supports_vision
    tools := base; tools.supports_tools = !base.supports_tools
    default := base; default.default_reasoning = "high"
    levels := base; levels.reasoning_levels = REV_LEVELS_ALT[:]
    permuted := base; permuted.reasoning_levels = REV_LEVELS_PERMUTED[:]
    cost_input := base; cost_input.cost.input = 9
    cost_output := base; cost_output.cost.output = 99
    cost_read := base; cost_read.cost.cache_read = 9
    cost_write := base; cost_write.cost.cache_write = 9

    testing.expect(t, rev_of(id) != original, "id change")
    testing.expect(t, rev_of(provider) != original, "provider change")
    testing.expect(t, rev_of(name) != original, "name change")
    testing.expect(t, rev_of(window) != original, "context_window change")
    testing.expect(t, rev_of(output) != original, "max_output_tokens change")
    testing.expect(t, rev_of(vision) != original, "supports_vision change")
    testing.expect(t, rev_of(tools) != original, "supports_tools change")
    testing.expect(t, rev_of(default) != original, "default_reasoning change")
    testing.expect(t, rev_of(levels) != original, "reasoning_levels change")
    testing.expect(t, rev_of(permuted) != original, "reasoning_levels order change")
    testing.expect(t, rev_of(cost_input) != original, "cost.input change")
    testing.expect(t, rev_of(cost_output) != original, "cost.output change")
    testing.expect(t, rev_of(cost_read) != original, "cost.cache_read change")
    testing.expect(t, rev_of(cost_write) != original, "cost.cache_write change")
}

@(test)
test_catalog_rev_changes_on_add_and_remove :: proc(t: ^testing.T) {
    one := []wire.Model_Info{rev_model("openai/gpt-5", "openai", "GPT", REV_LEVELS[:], "medium", 2)}
    two := []wire.Model_Info {
        rev_model("openai/gpt-5", "openai", "GPT", REV_LEVELS[:], "medium", 2),
        rev_model("openai/o1", "openai", "O1", REV_LEVELS[:], "medium", 3),
    }

    testing.expect(t, catalog_rev(one, {}) != catalog_rev(two, {}), "adding a model changes the revision")
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

@(test)
test_catalog_models_view_flattens_in_order_and_feeds_rev :: proc(t: ^testing.T) {
    effective: store.Effective_Catalog
    effective.providers.allocator = context.allocator
    defer {
        for &provider in effective.providers {
            delete(provider.models)
        }
        delete(effective.providers)
    }

    provider: catalog.Provider
    provider.id = "openai"
    provider.models.allocator = context.allocator
    first: catalog.Model
    first.info = rev_model("openai/gpt-5", "openai", "GPT", REV_LEVELS[:], "medium", 2)
    second: catalog.Model
    second.info = rev_model("openai/o1", "openai", "O1", REV_LEVELS[:], "medium", 3)
    append(&provider.models, first)
    append(&provider.models, second)
    append(&effective.providers, provider)

    view, ok := catalog_models_view(effective)
    defer delete(view)
    testing.expect(t, ok, "the view allocates")
    testing.expect_value(t, len(view), 2)
    testing.expect_value(t, string(view[0].id), "openai/gpt-5")
    testing.expect_value(t, string(view[1].id), "openai/o1")

    direct := []wire.Model_Info {
        rev_model("openai/gpt-5", "openai", "GPT", REV_LEVELS[:], "medium", 2),
        rev_model("openai/o1", "openai", "O1", REV_LEVELS[:], "medium", 3),
    }
    testing.expect(
        t,
        catalog_rev(view, {}) == catalog_rev(direct, {}),
        "the view hashes identically to its equivalent list",
    )
}
