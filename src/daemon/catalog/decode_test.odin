package catalog

import "core:mem"
import "core:slice"
import "core:testing"

import testsupport "libs:testsupport"
import provider "src:provider"
import wire "src:wire"

@(test)
test_max_tokens_field_from_npm :: proc(t: ^testing.T) {
    // Real OpenAI chat counts output with max_completion_tokens; compatible chat uses max_tokens.
    openai_chat := max_tokens_field_resolve("@ai-sdk/openai", .Openai_Chat)
    testing.expect_value(t, openai_chat, provider.Openai_Max_Tokens_Field.Max_Completion_Tokens)

    compatible_chat := max_tokens_field_resolve("@ai-sdk/openai-compatible", .Openai_Chat)
    testing.expect_value(t, compatible_chat, provider.Openai_Max_Tokens_Field.Max_Tokens)

    // Non-chat protocols do not use the field; it defaults.
    responses := max_tokens_field_resolve("@ai-sdk/openai", .Openai_Responses)
    testing.expect_value(t, responses, provider.Openai_Max_Tokens_Field.Max_Tokens)
}

@(test)
test_reasoning_names_are_closed_and_round_trip :: proc(t: ^testing.T) {
    for value in Reasoning_Replay {
        name := reasoning_replay_string[value]
        decoded, ok := reasoning_replay_from_string(name)
        testing.expect(t, ok, "every replay value has a name")
        testing.expect_value(t, decoded, value)
    }
    _, replay_ok := reasoning_replay_from_string("future")
    testing.expect(t, !replay_ok, "unknown replay names remain closed")

    for value in Reasoning_Format {
        name := reasoning_format_string[value]
        decoded, ok := reasoning_format_from_string(name)
        testing.expect(t, ok, "every format value has a name")
        testing.expect_value(t, decoded, value)
    }
    _, format_ok := reasoning_format_from_string("future")
    testing.expect(t, !format_ok, "unknown format names remain closed")

    testing.expect(t, reasoning_format_compatible(.Anthropic_Messages, .Anthropic_Adaptive), "adaptive is Anthropic")
    testing.expect(
        t,
        !reasoning_format_compatible(.Openai_Responses, .Anthropic_Adaptive),
        "adaptive is not Responses",
    )
    testing.expect(t, reasoning_format_compatible(.Openai_Chat, .Qwen_Thinking), "Qwen is OpenAI-compatible")
}

@(test)
test_decode_materializes_only_selected_provider :: proc(t: ^testing.T) {
    feed := `{
        "ignored":{"this":"is not a provider","large":[1,2,{"nested":true}]},
        "openai":{
            "id":"openai",
            "env":["OPENAI_API_KEY"],
            "npm":"@ai-sdk/openai",
            "name":"OpenAI",
            "models":{
                "gpt-test":{
                    "id":"gpt-test",
                    "name":"GPT Test",
                    "tool_call":true,
                    "temperature":false,
                    "interleaved":true,
                    "reasoning_options":[{"type":"effort","values":[null,"default","medium","future","high"]}],
                    "modalities":{"input":["text","image"],"output":["text"]},
                    "limit":{"context":128000,"output":16384},
                    "cost":{"input":2.5,"output":10,"cache_read":0.25}
                }
            }
        }
    }`
    selections := [?]Selection{{provider_id = "openai", source_id = "openai"}}
    result, err := decode(transmute([]byte)feed, selections[:])
    testing.expect_value(t, err, Error.None)
    if err != .None {
        return
    }
    defer result_destroy(&result)

    testing.expect_value(t, len(result.providers), 1)
    testing.expect_value(t, len(result.issues), 0)
    item := &result.providers[0]
    testing.expect_value(t, item.id, wire.Provider_Id("openai"))
    testing.expect_value(t, item.source_id, "openai")
    testing.expect_value(t, item.endpoint.base_url, OPENAI_BASE_URL)
    testing.expect_value(t, item.endpoint.protocol, wire.Provider_Protocol.Openai_Responses)
    testing.expect_value(t, len(item.credential_env), 1)
    testing.expect_value(t, item.credential_env[0], "OPENAI_API_KEY")
    testing.expect_value(t, len(item.models), 1)

    model := &item.models[0]
    testing.expect_value(t, model.info.id, wire.Model_Id("openai/gpt-test"))
    testing.expect_value(t, model.info.provider, "openai")
    testing.expect_value(t, model.upstream_id, "gpt-test")
    testing.expect_value(t, model.endpoint.protocol, wire.Provider_Protocol.Openai_Responses)
    testing.expect_value(t, model.reasoning_format, Reasoning_Format.Native)
    testing.expect_value(t, model.reasoning_replay, Reasoning_Replay.Reasoning_Content)
    test_expect_levels(t, model.info.reasoning_levels, {"off", "high", "medium"})
    testing.expect_value(t, model.info.default_reasoning, "medium")
    testing.expect(t, model.info.supports_vision, "image input should project to vision")
    testing.expect(t, model.info.supports_tools, "tool_call should project to tools")
    testing.expect(t, !model.supports_temperature, "temperature false should be retained")
    testing.expect_value(t, model.info.cost.input, 2.5)
    testing.expect_value(t, model.info.cost.cache_write, 0.0)
}

@(test)
test_reasoning_normalization_by_protocol :: proc(t: ^testing.T) {
    feed := `{
        "anthropic":{
            "id":"anthropic","env":["ANTHROPIC_API_KEY"],"npm":"@ai-sdk/anthropic","name":"Anthropic",
            "models":{
                "a-budget":{"id":"a-budget","name":"Budget","tool_call":true,"reasoning_options":[{"type":"budget_tokens","min":1024,"max":8192}],"modalities":{"input":["text"],"output":["text"]},"limit":{"context":200000,"output":8192}},
                "a-effort":{"id":"a-effort","name":"Effort","tool_call":true,"reasoning_options":[{"type":"effort","values":["low","default","max",null]}],"modalities":{"input":["text"],"output":["text"]},"limit":{"context":200000,"output":8192}},
                "a-empty":{"id":"a-empty","name":"Empty","tool_call":false,"reasoning_options":[],"modalities":{"input":["text"],"output":["text"]},"limit":{"context":200000,"output":8192}},
                "a-none":{"id":"a-none","name":"None","tool_call":false,"modalities":{"input":["text"],"output":["text"]},"limit":{"context":200000,"output":8192}},
                "a-toggle":{"id":"a-toggle","name":"Toggle","tool_call":true,"reasoning_options":[{"type":"toggle"}],"modalities":{"input":["text"],"output":["text"]},"limit":{"context":200000,"output":8192}}
            }
        },
        "chat":{
            "id":"chat","env":["CHAT_KEY"],"npm":"@ai-sdk/openai-compatible","api":"https://chat.example/v1","name":"Chat",
            "models":{
                "c-effort":{"id":"c-effort","name":"Effort Toggle","tool_call":true,"interleaved":false,"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["low","medium"]}],"modalities":{"input":["text"],"output":["text"]},"limit":{"context":64000,"output":4096}},
                "c-toggle":{"id":"c-toggle","name":"Toggle","family":"glm","tool_call":true,"reasoning_options":[{"type":"toggle"}],"modalities":{"input":["text"],"output":["text"]},"limit":{"context":64000,"output":4096}},
                "c-qwen":{"id":"c-qwen","name":"Qwen Toggle","family":"qwen","tool_call":true,"reasoning_options":[{"type":"toggle"}],"modalities":{"input":["text"],"output":["text"]},"limit":{"context":64000,"output":4096}},
                "c-replay":{"id":"c-replay","name":"Replay Without Knob","tool_call":true,"interleaved":true,"modalities":{"input":["text"],"output":["text"]},"limit":{"context":64000,"output":4096}}
            }
        },
        "openrouter":{
            "id":"openrouter","env":["OPENROUTER_API_KEY"],"npm":"@openrouter/ai-sdk-provider","api":"https://openrouter.ai/api/v1","name":"OpenRouter",
            "models":{
                "or-model":{"id":"or-model","name":"OpenRouter Model","tool_call":true,"interleaved":{"field":"reasoning_details"},"reasoning_options":[{"type":"effort","values":["low","high"]}],"modalities":{"input":["text"],"output":["text"]},"limit":{"context":64000,"output":4096}}
            }
        }
    }`
    selections := [?]Selection {
        {provider_id = "anthropic", source_id = "anthropic"},
        {provider_id = "chat", source_id = "chat"},
        {provider_id = "openrouter", source_id = "openrouter"},
    }
    result, err := decode(transmute([]byte)feed, selections[:])
    testing.expect_value(t, err, Error.None)
    if err != .None {
        return
    }
    defer result_destroy(&result)

    testing.expect_value(t, len(result.providers), 3)
    anthropic := &result.providers[0]
    testing.expect_value(t, anthropic.endpoint.protocol, wire.Provider_Protocol.Anthropic_Messages)

    budget := test_model(anthropic, "anthropic/a-budget")
    test_expect_levels(t, budget.info.reasoning_levels, {"off", "high", "max"})
    testing.expect_value(t, budget.info.default_reasoning, "high")
    testing.expect_value(t, budget.reasoning_format, Reasoning_Format.Native)
    budget_min, has_min := budget.reasoning_budget_min.?
    budget_max, has_max := budget.reasoning_budget_max.?
    testing.expect(t, has_min && has_max, "budget bounds should be retained")
    testing.expect_value(t, budget_min, i64(1024))
    testing.expect_value(t, budget_max, u64(8192))

    effort := test_model(anthropic, "anthropic/a-effort")
    test_expect_levels(t, effort.info.reasoning_levels, {"off", "low", "high", "max"})
    testing.expect_value(t, effort.info.default_reasoning, "high")
    testing.expect_value(t, effort.reasoning_format, Reasoning_Format.Native)

    empty := test_model(anthropic, "anthropic/a-empty")
    test_expect_levels(t, empty.info.reasoning_levels, {})
    testing.expect_value(t, empty.info.default_reasoning, "")
    testing.expect_value(t, empty.reasoning_format, Reasoning_Format.Native)

    none := test_model(anthropic, "anthropic/a-none")
    test_expect_levels(t, none.info.reasoning_levels, {})
    testing.expect_value(t, none.reasoning_format, Reasoning_Format.Native)

    toggle := test_model(anthropic, "anthropic/a-toggle")
    test_expect_levels(t, toggle.info.reasoning_levels, {"off", "high"})
    testing.expect_value(t, toggle.info.default_reasoning, "high")
    testing.expect_value(t, toggle.reasoning_format, Reasoning_Format.Anthropic_Adaptive)

    chat := &result.providers[1]
    chat_effort := test_model(chat, "chat/c-effort")
    test_expect_levels(t, chat_effort.info.reasoning_levels, {"off", "low", "medium"})
    testing.expect_value(t, chat_effort.info.default_reasoning, "medium")
    testing.expect_value(t, chat_effort.reasoning_format, Reasoning_Format.Openai_Effort_Toggle_Off)
    testing.expect_value(t, chat_effort.reasoning_replay, Reasoning_Replay.None)

    chat_toggle := test_model(chat, "chat/c-toggle")
    test_expect_levels(t, chat_toggle.info.reasoning_levels, {"off", "high"})
    testing.expect_value(t, chat_toggle.reasoning_format, Reasoning_Format.Zai_Toggle)

    chat_qwen := test_model(chat, "chat/c-qwen")
    test_expect_levels(t, chat_qwen.info.reasoning_levels, {"off", "high"})
    testing.expect_value(t, chat_qwen.reasoning_format, Reasoning_Format.Qwen_Thinking)

    chat_replay := test_model(chat, "chat/c-replay")
    test_expect_levels(t, chat_replay.info.reasoning_levels, {})
    testing.expect_value(t, chat_replay.reasoning_replay, Reasoning_Replay.Reasoning_Content)

    openrouter := &result.providers[2]
    routed := test_model(openrouter, "openrouter/or-model")
    test_expect_levels(t, routed.info.reasoning_levels, {"off", "low", "high"})
    testing.expect_value(t, routed.info.default_reasoning, "low")
    testing.expect_value(t, routed.reasoning_format, Reasoning_Format.Openrouter_Effort)
    testing.expect_value(t, routed.reasoning_replay, Reasoning_Replay.None)
}

@(test)
test_model_routes_override_and_filters_without_partial_semantic_data :: proc(t: ^testing.T) {
    feed := `{
        "gateway":{
            "id":"gateway","env":["GATEWAY_KEY"],"npm":"@ai-sdk/openai-compatible","api":"https://gateway.example/v1/","name":"Gateway",
            "models":{
                "body":{"id":"body","name":"Body","tool_call":true,"provider":{"body":{"service_tier":"fast"}},"modalities":{"input":["text"],"output":["text"]},"limit":{"context":1000,"output":100}},
                "image":{"id":"image","name":"Image","tool_call":false,"modalities":{"input":["image"],"output":["image"]},"limit":{"context":1000,"output":100}},
                "responses":{"id":"responses","name":"Responses","tool_call":true,"provider":{"npm":"@ai-sdk/openai","shape":"responses"},"modalities":{"input":["text"],"output":["text"]},"limit":{"context":1000,"output":100}},
                "unknown-shape":{"id":"unknown-shape","name":"Unknown Shape Package","tool_call":true,"provider":{"npm":"@ai-sdk/amazon-bedrock/mantle","shape":"responses"},"modalities":{"input":["text"],"output":["text"]},"limit":{"context":1000,"output":100}},
                "zero":{"id":"zero","name":"Zero","tool_call":false,"modalities":{"input":["text"],"output":["text"]},"limit":{"context":0,"output":100}}
            }
        }
    }`
    selections := [?]Selection{{provider_id = "gateway", source_id = "gateway"}}
    result, err := decode(transmute([]byte)feed, selections[:])
    testing.expect_value(t, err, Error.None)
    if err != .None {
        return
    }
    defer result_destroy(&result)

    testing.expect_value(t, len(result.providers), 1)
    item := &result.providers[0]
    testing.expect_value(t, item.endpoint.base_url, "https://gateway.example/v1")
    testing.expect_value(t, item.endpoint.protocol, wire.Provider_Protocol.Openai_Chat)
    testing.expect_value(t, len(item.models), 1)
    model := &item.models[0]
    testing.expect_value(t, model.info.id, wire.Model_Id("gateway/responses"))
    testing.expect_value(t, model.endpoint.base_url, "https://gateway.example/v1")
    testing.expect_value(t, model.endpoint.protocol, wire.Provider_Protocol.Openai_Responses)
}

@(test)
test_provider_defaults_to_chat_and_allows_no_credential_env :: proc(t: ^testing.T) {
    feed := `{
        "local":{
            "id":"local","env":[],"api":"http://127.0.0.1:11434/v1","name":"Local",
            "models":{
                "unknown":{"id":"unknown","name":"Unknown Modalities","tool_call":true,"limit":{"context":1000,"output":100}},
                "text":{"id":"text","name":"Text","tool_call":true,"modalities":{"input":["text"],"output":["text"]},"limit":{"context":1000,"output":100}}
            }
        }
    }`
    selections := [?]Selection{{provider_id = "local", source_id = "local"}}
    result, err := decode(transmute([]byte)feed, selections[:])
    testing.expect_value(t, err, Error.None)
    if err != .None {
        return
    }
    defer result_destroy(&result)

    testing.expect_value(t, len(result.providers), 1)
    item := &result.providers[0]
    testing.expect_value(t, len(item.credential_env), 0)
    testing.expect_value(t, item.endpoint.protocol, wire.Provider_Protocol.Openai_Chat)
    testing.expect_value(t, len(item.models), 1)
    testing.expect_value(t, item.models[0].info.id, wire.Model_Id("local/text"))
}

@(test)
test_selected_provider_failures_are_isolated_and_ordered :: proc(t: ^testing.T) {
    feed := `{
        "invalid":[],
        "unsupported":{"id":"unsupported","env":["KEY"],"npm":"@ai-sdk/google","name":"Unsupported","models":{}}
    }`
    selections := [?]Selection {
        {provider_id = "missing-local", source_id = "missing"},
        {provider_id = "invalid-local", source_id = "invalid"},
        {provider_id = "unsupported-local", source_id = "unsupported"},
    }
    result, err := decode(transmute([]byte)feed, selections[:])
    testing.expect_value(t, err, Error.None)
    if err != .None {
        return
    }
    defer result_destroy(&result)

    testing.expect_value(t, len(result.providers), 0)
    testing.expect_value(t, len(result.issues), 3)
    testing.expect_value(t, result.issues[0].provider_id, wire.Provider_Id("missing-local"))
    testing.expect_value(t, result.issues[0].error, Provider_Error.Missing)
    testing.expect_value(t, result.issues[1].provider_id, wire.Provider_Id("invalid-local"))
    testing.expect_value(t, result.issues[1].error, Provider_Error.Invalid)
    testing.expect_value(t, result.issues[2].provider_id, wire.Provider_Id("unsupported-local"))
    testing.expect_value(t, result.issues[2].error, Provider_Error.Unsupported)
}

@(test)
test_xai_defaults_to_responses :: proc(t: ^testing.T) {
    feed := `{"xai":{"id":"xai","env":["XAI_API_KEY"],"npm":"@ai-sdk/xai","name":"xAI","models":{"grok":{"id":"grok","name":"Grok","tool_call":true,"reasoning_options":[{"type":"effort","values":["low","medium","high"]}],"modalities":{"input":["text"],"output":["text"]},"limit":{"context":1000,"output":100}}}}}`
    selections := [?]Selection{{provider_id = "xai", source_id = "xai"}}
    result, err := decode(transmute([]byte)feed, selections[:])
    testing.expect_value(t, err, Error.None)
    if err != .None {
        return
    }
    defer result_destroy(&result)

    model := &result.providers[0].models[0]
    testing.expect_value(t, model.endpoint.base_url, "https://api.x.ai/v1")
    testing.expect_value(t, model.endpoint.protocol, wire.Provider_Protocol.Openai_Responses)
    testing.expect_value(t, model.reasoning_format, Reasoning_Format.Native)
    test_expect_levels(t, model.info.reasoning_levels, {"low", "medium", "high"})
    testing.expect_value(t, model.info.default_reasoning, "medium")
}

@(test)
test_decode_rejects_global_boundaries_and_selected_duplicates :: proc(t: ^testing.T) {
    selection := [?]Selection{{provider_id = "openai", source_id = "openai"}}

    trailing := `{}[]`
    _, trailing_err := decode(transmute([]byte)trailing, selection[:])
    testing.expect_value(t, trailing_err, Error.Invalid_Json)

    duplicate := `{"openai":{},"openai":{}}`
    _, duplicate_err := decode(transmute([]byte)duplicate, selection[:])
    testing.expect_value(t, duplicate_err, Error.Invalid_Json)

    oversized := make([]byte, FEED_MAX_BYTES + 1, context.temp_allocator)
    defer free_all(context.temp_allocator)
    _, oversized_err := decode(oversized, selection[:])
    testing.expect_value(t, oversized_err, Error.Response_Too_Large)

    too_many := make([]Selection, SELECTIONS_MAX + 1, context.temp_allocator)
    empty := `{}`
    _, selection_err := decode(transmute([]byte)empty, too_many)
    testing.expect_value(t, selection_err, Error.Invalid_Selection)
}

@(test)
test_decode_releases_every_owned_allocation_on_oom :: proc(t: ^testing.T) {
    feed := `{"openai":{"id":"openai","env":["OPENAI_API_KEY"],"npm":"@ai-sdk/openai","name":"OpenAI","models":{"gpt":{"id":"gpt","name":"GPT","tool_call":true,"reasoning_options":[{"type":"effort","values":["low","medium","high"]}],"modalities":{"input":["text"],"output":["text"]},"limit":{"context":1000,"output":100}}}}}`
    selections := [?]Selection{{provider_id = "openai", source_id = "openai"}}

    completed := false
    for fail_at in 0 ..< 64 {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        tracked := mem.tracking_allocator(&track)

        failing: testsupport.Failing_Allocator
        testsupport.failing_allocator_init(&failing, tracked, fail_at)
        result, err := decode(transmute([]byte)feed, selections[:], testsupport.failing_allocator(&failing))
        if err == .None {
            completed = true
            result_destroy(&result)
        } else {
            testing.expect_value(t, err, Error.Out_Of_Memory)
            testing.expect_value(t, len(result.providers), 0)
            testing.expect_value(t, len(result.issues), 0)
        }

        testing.expectf(
            t,
            len(track.allocation_map) == 0,
            "fail_at %d leaked %d allocations",
            fail_at,
            len(track.allocation_map),
        )
        testing.expectf(
            t,
            len(track.bad_free_array) == 0,
            "fail_at %d made %d bad frees",
            fail_at,
            len(track.bad_free_array),
        )
        mem.tracking_allocator_destroy(&track)

        if completed {
            break
        }
    }

    testing.expect(t, completed, "fault sweep must eventually pass every catalog allocation")
}

@(private)
test_model :: proc(item: ^Provider, id: wire.Model_Id) -> ^Model {
    assert(item != nil, "test model lookup needs a provider")

    for &model in item.models {
        if model.info.id == id {
            return &model
        }
    }

    assert(false, "test fixture model is missing")
    return nil
}

@(private)
test_expect_levels :: proc(t: ^testing.T, actual, expected: []string) {
    testing.expectf(t, slice.equal(actual, expected), "reasoning levels differ: %v != %v", actual, expected)
}
