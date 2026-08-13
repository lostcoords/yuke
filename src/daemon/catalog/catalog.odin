package catalog

import "core:mem"

import provider "src:provider"
import wire "src:wire"

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

@(rodata)
reasoning_replay_string := [Reasoning_Replay]string {
    .None              = "none",
    .Reasoning_Content = "reasoning-content",
    .Reasoning_Details = "reasoning-details",
}

@(rodata)
reasoning_format_string := [Reasoning_Format]string {
    .Native                   = "native",
    .Openai_Effort_Toggle_Off = "openai-effort-toggle-off",
    .Openrouter_Effort        = "openrouter-effort",
    .Zai_Toggle               = "zai-toggle",
    .Qwen_Thinking            = "qwen-thinking",
    .Anthropic_Adaptive       = "anthropic-adaptive",
}

reasoning_replay_valid :: proc(value: Reasoning_Replay) -> bool {
    return int(value) >= 0 && int(value) < len(reasoning_replay_string)
}

reasoning_replay_to_string :: proc(value: Reasoning_Replay) -> string {
    assert(reasoning_replay_valid(value), "a reasoning replay value is closed")

    return reasoning_replay_string[value]
}

reasoning_replay_from_string :: proc(name: string) -> (Reasoning_Replay, bool) {
    for candidate, value in reasoning_replay_string {
        if candidate == name {
            return value, true
        }
    }

    return {}, false
}

reasoning_format_valid :: proc(value: Reasoning_Format) -> bool {
    return int(value) >= 0 && int(value) < len(reasoning_format_string)
}

reasoning_format_to_string :: proc(value: Reasoning_Format) -> string {
    assert(reasoning_format_valid(value), "a reasoning format value is closed")

    return reasoning_format_string[value]
}

reasoning_format_from_string :: proc(name: string) -> (Reasoning_Format, bool) {
    for candidate, value in reasoning_format_string {
        if candidate == name {
            return value, true
        }
    }

    return {}, false
}

// A custom model's request format must match its resolved provider protocol.
reasoning_format_compatible :: proc(protocol: wire.Provider_Protocol, format: Reasoning_Format) -> bool {
    switch protocol {
    case .Anthropic_Messages:
        return format == .Native || format == .Anthropic_Adaptive

    case .Openai_Chat:
        #partial switch format {
        case .Native, .Openai_Effort_Toggle_Off, .Openrouter_Effort, .Zai_Toggle, .Qwen_Thinking:
            return true
        }

        return false

    case .Openai_Responses:
        return format == .Native
    }

    return false
}

// A provider credential environment-variable name: a non-empty ASCII identifier
// within the shared bound. Shared by the decoder, the store, and JavaScript config.
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
    reasoning_replay:     Reasoning_Replay,
    reasoning_format:     Reasoning_Format,
    reasoning_budget_min: Maybe(i64),
    reasoning_budget_max: Maybe(u64),
    max_tokens_field:     provider.Openai_Max_Tokens_Field,
    responses_dialect:    provider.Openai_Responses_Dialect,
}

// Request wire-shape facts from the models.dev npm package: real OpenAI chat counts output
// with `max_completion_tokens`, every other OpenAI-compatible endpoint with `max_tokens`.
// Only the field matching the resolved protocol is consulted at request assembly.
transport_flavor :: proc(
    npm: string,
    protocol: wire.Provider_Protocol,
) -> (
    provider.Openai_Max_Tokens_Field,
    provider.Openai_Responses_Dialect,
) {
    max_tokens := provider.Openai_Max_Tokens_Field.Max_Tokens
    if protocol == .Openai_Chat && npm == "@ai-sdk/openai" {
        max_tokens = .Max_Completion_Tokens
    }

    return max_tokens, .Standard
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
