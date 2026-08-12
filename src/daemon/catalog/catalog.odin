package catalog

import "core:mem"

import provider "src:provider"
import wire "src:wire"

FEED_MAX_BYTES :: 8 * mem.Megabyte
SELECTIONS_MAX :: 256
PROVIDER_NAME_MAX_BYTES :: 128
PACKAGE_MAX_BYTES :: 128
BASE_URL_MAX_BYTES :: 4096

Selection :: struct {
    // Public provider identity used by Yuke.
    provider_id: wire.Provider_Id,

    // Root models.dev provider key to import.
    source_id:   string,
}

// Errors that invalidate the complete refresh attempt.
Error :: enum {
    None,
    Invalid_Selection,
    Response_Too_Large,
    Invalid_Json,
    Too_Many_Models,
    Out_Of_Memory,
}

// Outcome for one selected provider. Other selections may still normalize.
Provider_Error :: enum {
    None,
    Missing,
    Unsupported,
    Invalid,
}

// Assistant field used to replay reasoning across a tool-use round.
Reasoning_Replay :: enum {
    None,
    Reasoning_Content,
    Reasoning_Details,
}

// Exceptions to the ordinary request-body control implied by the protocol.
Reasoning_Format :: enum {
    Native,
    Openai_Effort_Toggle_Off,
    Openrouter_Effort,
    Zai_Toggle,
    Qwen_Thinking,
    Anthropic_Adaptive,
}

#assert(len(Reasoning_Replay) == 3)
#assert(len(Reasoning_Format) == 6)

// One normalized models.dev model. Every string and slice is owned.
Model :: struct {
    info:                 wire.Model_Info,
    upstream_id:          string,
    endpoint:             provider.Endpoint,
    temperature:          bool,
    reasoning_replay:     Reasoning_Replay,
    reasoning_format:     Reasoning_Format,
    reasoning_budget_min: Maybe(i64),
    reasoning_budget_max: Maybe(u64),
}

// One selected and normalized models.dev provider. Every string and slice is owned.
Provider :: struct {
    id:             wire.Provider_Id,
    source_id:      string,
    name:           string,
    endpoint:       provider.Endpoint,
    credential_env: []string,
    models:         [dynamic]Model,
}

// A selected provider that could not produce a replacement snapshot. Owned.
Issue :: struct {
    provider_id: wire.Provider_Id,
    source_id:   string,
    error:       Provider_Error,
}

// Owned output of decode. Provider order and issue order follow Selection order.
Result :: struct {
    providers: [dynamic]Provider,
    issues:    [dynamic]Issue,
    allocator: mem.Allocator,
}

result_destroy :: proc(result: ^Result) {
    assert(result != nil, "catalog result cleanup needs a result")
    assert(result.allocator.procedure != nil, "an owned catalog result carries its allocator")

    for &item in result.providers {
        provider_destroy(&item, result.allocator)
    }
    delete(result.providers)

    for &issue in result.issues {
        delete(issue.provider_id, result.allocator)
        delete(issue.source_id, result.allocator)
    }
    delete(result.issues)
    result^ = {}
}

@(private)
provider_destroy :: proc(item: ^Provider, allocator: mem.Allocator) {
    assert(item != nil, "catalog provider cleanup needs a provider")

    for &model in item.models {
        assert(model.info.provider == item.id, "a catalog model borrows its owning provider id")
        model_destroy(&model, allocator)
    }
    delete(item.models)
    for name in item.credential_env {
        delete(name, allocator)
    }
    delete(item.credential_env, allocator)
    delete(item.endpoint.base_url, allocator)
    delete(item.name, allocator)
    delete(item.source_id, allocator)
    delete(item.id, allocator)
    item^ = {}
}

@(private)
model_destroy :: proc(model: ^Model, allocator: mem.Allocator) {
    assert(model != nil, "catalog model cleanup needs a model")

    delete(model.info.id, allocator)
    delete(model.info.name, allocator)
    for level in model.info.reasoning_levels {
        delete(level, allocator)
    }
    delete(model.info.reasoning_levels, allocator)
    delete(model.info.default_reasoning, allocator)
    delete(model.upstream_id, allocator)
    delete(model.endpoint.base_url, allocator)
    model^ = {}
}
