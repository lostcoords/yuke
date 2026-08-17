package catalog

import "core:mem"
import "core:strings"

import "src:provider"
import "src:wire"

FEED_MAX_BYTES :: 8 * mem.Megabyte
SELECTIONS_MAX :: 256
PROVIDER_NAME_MAX_BYTES :: 128
PACKAGE_MAX_BYTES :: 128
BASE_URL_MAX_BYTES :: 4096
ENV_NAME_MAX_BYTES :: 128

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
}

// Outcome for one selected provider. Other selections may still normalize.
Provider_Error :: enum {
    None,
    Missing,
    Unsupported,
    Invalid,
}

// A row stores the request builder's own value rather than a second vocabulary that has to
// be translated on the way out, which is how `max_tokens_field` has always worked.
#assert(len(provider.Openai_Thinking_Format) == 9)
#assert(len(provider.Openai_Reasoning_Replay) == 4)
#assert(len(provider.Openai_Max_Tokens_Field) == 2)

// Persisted names for the closed enums the store keeps on a model row.
@(rodata)
reasoning_replay_string := [provider.Openai_Reasoning_Replay]string {
    .None              = "none",
    .Reasoning         = "reasoning",
    .Reasoning_Content = "reasoning-content",
    .Reasoning_Details = "reasoning-details",
}

@(rodata)
thinking_format_string := [provider.Openai_Thinking_Format]string {
    .None            = "none",
    .Openai          = "openai",
    .Openrouter      = "openrouter",
    .Deepseek        = "deepseek",
    .Zai             = "zai",
    .Qwen            = "qwen",
    .Together        = "together",
    .String_Thinking = "string-thinking",
    .Ant_Ling        = "ant-ling",
}

@(rodata)
max_tokens_field_string := [provider.Openai_Max_Tokens_Field]string {
    .Max_Completion_Tokens = "max-completion-tokens",
    .Max_Tokens            = "max-tokens",
}

reasoning_replay_from_string :: proc(name: string) -> (provider.Openai_Reasoning_Replay, bool) {
    for candidate, value in reasoning_replay_string {
        if candidate == name {
            return value, true
        }
    }

    return {}, false
}

thinking_format_from_string :: proc(name: string) -> (provider.Openai_Thinking_Format, bool) {
    for candidate, value in thinking_format_string {
        if candidate == name {
            return value, true
        }
    }

    return {}, false
}

max_tokens_field_from_string :: proc(name: string) -> (provider.Openai_Max_Tokens_Field, bool) {
    for candidate, value in max_tokens_field_string {
        if candidate == name {
            return value, true
        }
    }

    return {}, false
}

// The thinking format and replay field are OpenAI-chat body shapes; adaptive thinking is
// Anthropic's. A row may only carry what its protocol accepts.
reasoning_shape_compatible :: proc(model: Model) -> bool {
    switch model.endpoint.protocol {
    case .Anthropic_Messages:
        return model.thinking_format == .None && model.reasoning_replay == .None

    case .Openai_Chat:
        return !model.anthropic_adaptive

    case .Openai_Responses:
        return model.thinking_format == .None && model.reasoning_replay == .None && !model.anthropic_adaptive
    }

    return false
}

// A provider credential environment-variable name: a non-empty ASCII identifier
// within the shared bound. Shared by the decoder and the store.
env_name_valid :: proc(name: string) -> bool {
    if len(name) == 0 || len(name) > ENV_NAME_MAX_BYTES {
        return false
    }

    for byte, i in transmute([]byte)name {
        if i == 0 {
            if byte != '_' && !(byte >= 'a' && byte <= 'z') && !(byte >= 'A' && byte <= 'Z') {
                return false
            }
        } else if byte != '_' &&
           !(byte >= 'a' && byte <= 'z') &&
           !(byte >= 'A' && byte <= 'Z') &&
           !(byte >= '0' && byte <= '9') {
            return false
        }
    }

    return true
}

// One normalized models.dev model. Every string and slice is owned.
Model :: struct {
    info:                 wire.Model_Info,
    upstream_id:          string,
    endpoint:             provider.Endpoint,
    supports_temperature: bool,

    // The body shapes this endpoint expects. The first two are OpenAI-chat; the third marks
    // an Anthropic row that takes `thinking:{adaptive}` over a budget or an effort.
    reasoning_replay:     provider.Openai_Reasoning_Replay,
    thinking_format:      provider.Openai_Thinking_Format,
    anthropic_adaptive:   bool,
    reasoning_budget_min: Maybe(i64),
    reasoning_budget_max: Maybe(u64),
    max_tokens_field:     provider.Openai_Max_Tokens_Field,
}

// Real OpenAI chat counts output with `max_completion_tokens`; every other
// OpenAI-compatible endpoint uses `max_tokens`. Consulted only by the chat protocol.
max_tokens_field_resolve :: proc(npm: string, protocol: wire.Provider_Protocol) -> provider.Openai_Max_Tokens_Field {
    if protocol == .Openai_Chat && npm == "@ai-sdk/openai" {
        return .Max_Completion_Tokens
    }

    return .Max_Tokens
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

// Deep-clone a model. `info.provider` borrows `provider_id` instead of cloning it,
// because a provider owns the id its models point at.
model_clone :: proc(src: Model, provider_id: wire.Provider_Id, allocator: mem.Allocator) -> (model: Model) {
    model = src
    model.info.provider = string(provider_id)
    model.info.id = wire.Model_Id(strings.clone(string(src.info.id), allocator))
    model.info.name = strings.clone(src.info.name, allocator)
    model.info.reasoning_levels = string_slice_clone(src.info.reasoning_levels, allocator)
    model.info.default_reasoning = strings.clone(src.info.default_reasoning, allocator)
    model.upstream_id = strings.clone(src.upstream_id, allocator)
    model.endpoint.base_url = strings.clone(src.endpoint.base_url, allocator)

    return model
}

// Clone a bounded slice of owned strings. An empty input yields nil, not an allocation.
@(private)
string_slice_clone :: proc(values: []string, allocator: mem.Allocator) -> (owned: []string) {
    if len(values) == 0 {
        return nil
    }

    owned = make([]string, len(values), allocator)

    for value, index in values {
        owned[index] = strings.clone(value, allocator)
    }

    return owned
}

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
