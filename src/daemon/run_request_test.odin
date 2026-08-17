package daemon

import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "src:daemon/catalog"
import "src:daemon/store"
import "src:provider"
import "src:wire"

@(private = "file")
request_test_model :: proc(
    protocol: wire.Provider_Protocol,
    levels: []string,
    format: provider.Openai_Thinking_Format = .None,
    adaptive := false,
) -> catalog.Model {
    return catalog.Model {
        info = {
            id = "minimax/MiniMax-M3",
            provider = "minimax",
            name = "MiniMax-M3",
            context_window = 1_000_000,
            max_output_tokens = 128_000,
            reasoning_levels = levels,
            default_reasoning = catalog.default_reasoning_level(levels),
            supports_tools = true,
        },
        upstream_id = "MiniMax-M3",
        endpoint = {base_url = "https://api.minimax.io/anthropic/v1", protocol = protocol},
        supports_temperature = true,
        thinking_format = format,
        anthropic_adaptive = adaptive,
    }
}

@(private = "file")
request_test_build :: proc(
    t: ^testing.T,
    model: ^catalog.Model,
    reasoning: string,
    temperature: Maybe(f64) = nil,
    tools: []provider.Tool_Definition = nil,
) -> string {
    arena: virtual.Arena
    testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
    scratch := virtual.arena_allocator(&arena)

    messages := [?]wire.Message {
        wire.User_Message{id = 1, content = []wire.Content_Part{wire.Content_Text{text = "hi"}}, input_id = 1},
    }
    request := provider.Request {
        messages    = messages[:],
        temperature = temperature,
        tools       = tools,
    }

    body, err := run_request_build(model, nil, reasoning, request, context.allocator, scratch)
    testing.expect_value(t, err, provider.Transport_Error.None)
    virtual.arena_destroy(&arena)

    return body
}

@(test)
test_run_request_omits_thinking_for_a_model_without_levels :: proc(t: ^testing.T) {
    // MiniMax M2.x: models.dev reports no reasoning options, so we send no thinking field
    // and the endpoint keeps its own default.
    model := request_test_model(.Anthropic_Messages, nil)
    model.info.id = "minimax/MiniMax-M2.7"
    model.upstream_id = "MiniMax-M2.7"

    body := request_test_build(t, &model, "high")
    defer delete(body)

    testing.expect(t, !strings.contains(body, `"thinking"`), "a model with no levels sends no thinking control")
    testing.expect(t, strings.contains(body, `"model":"MiniMax-M2.7"`), "the upstream id is sent, not the public id")
    testing.expect(t, strings.contains(body, `"max_tokens":128000`), "the row supplies the output ceiling")
}

@(test)
test_run_request_encodes_the_adaptive_thinking_levels :: proc(t: ^testing.T) {
    // MiniMax M3: models.dev reports a toggle, which the decoder stores as
    // `anthropic_adaptive` with off/high. Both shapes were verified against the live API.
    levels := [?]string{"off", "high"}
    model := request_test_model(.Anthropic_Messages, levels[:], adaptive = true)

    on := request_test_build(t, &model, "high")
    defer delete(on)
    testing.expect(t, strings.contains(on, `"thinking":{"type":"adaptive"}`), "high enables adaptive thinking")

    off := request_test_build(t, &model, "off")
    defer delete(off)
    testing.expect(t, strings.contains(off, `"thinking":{"type":"disabled"}`), "off disables thinking")

    // An unknown level falls back to the row's derived default rather than being sent on.
    unknown := request_test_build(t, &model, "banana")
    defer delete(unknown)
    testing.expect(t, strings.contains(unknown, `"thinking":{"type":"adaptive"}`), "an unknown level uses the default")
}

@(test)
test_run_request_drops_temperature_when_thinking_is_on :: proc(t: ^testing.T) {
    levels := [?]string{"off", "high"}
    model := request_test_model(.Anthropic_Messages, levels[:], adaptive = true)

    // Anthropic rejects a sampling control alongside thinking, so the body must omit it
    // even though the row reports temperature support.
    thinking := request_test_build(t, &model, "high", 0.7)
    defer delete(thinking)
    testing.expect(t, !strings.contains(thinking, `"temperature"`), "thinking on drops temperature")

    // With thinking off the same row still sends it.
    sampled := request_test_build(t, &model, "off", 0.7)
    defer delete(sampled)
    testing.expect(t, strings.contains(sampled, `"temperature":0.7`), "thinking off keeps temperature")
}

@(test)
test_run_request_drops_temperature_for_a_model_that_rejects_it :: proc(t: ^testing.T) {
    model := request_test_model(.Anthropic_Messages, nil)
    model.supports_temperature = false

    body := request_test_build(t, &model, "", 0.5)
    defer delete(body)

    testing.expect(t, !strings.contains(body, `"temperature"`), "a row without temperature support sends none")
}

@(test)
test_run_request_maps_openai_chat_reasoning_formats :: proc(t: ^testing.T) {
    Case :: struct {
        format:   provider.Openai_Thinking_Format,
        level:    string,
        expected: string,
    }

    cases := [?]Case {
        {.Openai, "high", `"reasoning_effort":"high"`},
        {.Openrouter, "low", `"reasoning":{"effort":"low"}`},
        {.Deepseek, "medium", `"thinking":{"type":"enabled"},"reasoning_effort":"medium"`},
        {.Deepseek, "off", `"thinking":{"type":"disabled"}`},
        {.Zai, "high", `"thinking":{"type":"enabled","clear_thinking":false}`},
        {.Qwen, "off", `"enable_thinking":false`},
        // gpt-5.6 added max; a row only offers it when the model advertises it.
        {.Openai, "max", `"reasoning_effort":"max"`},
    }

    levels := [?]string{"off", "low", "medium", "high", "max"}
    for c in cases {
        model := request_test_model(.Openai_Chat, levels[:], c.format)
        body := request_test_build(t, &model, c.level)
        defer delete(body)

        testing.expectf(
            t,
            strings.contains(body, c.expected),
            "%v/%s should emit %s in %s",
            c.format,
            c.level,
            c.expected,
            body,
        )
    }
}

@(test)
test_run_request_budgets_thinking_below_the_output_cap :: proc(t: ^testing.T) {
    // Shape of the real anthropic/claude-sonnet-4-5 row: budget_tokens with min=1024,
    // no max, and a 64000 output cap. The budget shares that cap with the answer.
    levels := [?]string{"off", "high", "max"}
    model := request_test_model(.Anthropic_Messages, levels[:])
    model.info.max_output_tokens = 64_000
    model.reasoning_budget_min = i64(1024)

    high := request_test_build(t, &model, "high")
    defer delete(high)
    testing.expect(t, strings.contains(high, `"thinking":{"type":"enabled","budget_tokens":32000}`), high)

    maxed := request_test_build(t, &model, "max")
    defer delete(maxed)
    testing.expect(t, strings.contains(maxed, `"thinking":{"type":"enabled","budget_tokens":48000}`), maxed)

    // Even at max the answer keeps room; a budget at or above the cap is refused.
    testing.expect(t, !strings.contains(maxed, `"budget_tokens":64000`), "max never spends the whole cap")

    off := request_test_build(t, &model, "off")
    defer delete(off)
    testing.expect(t, strings.contains(off, `"thinking":{"type":"disabled"}`), "off disables thinking")

    // A row with no bounds is not budget-shaped and takes the effort control instead.
    effort_row := request_test_model(.Anthropic_Messages, levels[:])
    effort := request_test_build(t, &effort_row, "max")
    defer delete(effort)
    testing.expect(t, strings.contains(effort, `"output_config":{"effort":"max"}`), effort)
}

@(test)
test_run_request_uses_the_rows_max_tokens_field :: proc(t: ^testing.T) {
    levels := [?]string{"high"}
    model := request_test_model(.Openai_Chat, levels[:], .Openai)

    model.max_tokens_field = .Max_Tokens
    compatible := request_test_build(t, &model, "high")
    defer delete(compatible)
    testing.expect(t, strings.contains(compatible, `"max_tokens":128000`), "compatible endpoints use max_tokens")

    model.max_tokens_field = .Max_Completion_Tokens
    openai := request_test_build(t, &model, "high")
    defer delete(openai)
    testing.expect(
        t,
        strings.contains(openai, `"max_completion_tokens":128000`),
        "real OpenAI chat uses max_completion_tokens",
    )
}

@(test)
test_run_request_responses_dialect_follows_the_credential :: proc(t: ^testing.T) {
    levels := [?]string{"low", "high"}
    model := request_test_model(.Openai_Responses, levels[:])

    arena: virtual.Arena
    testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
    defer virtual.arena_destroy(&arena)
    scratch := virtual.arena_allocator(&arena)

    messages := [?]wire.Message {
        wire.User_Message{id = 1, content = []wire.Content_Part{wire.Content_Text{text = "hi"}}, input_id = 1},
    }
    request := provider.Request {
        messages = messages[:],
    }

    // An API key takes the standard dialect, which carries the API-only sampling limits.
    standard, standard_err := run_request_build(
        &model,
        provider.Api_Key{key = "sk-test"},
        "high",
        request,
        context.allocator,
        scratch,
    )
    testing.expect_value(t, standard_err, provider.Transport_Error.None)
    defer delete(standard)
    testing.expect(t, strings.contains(standard, `"max_output_tokens"`), "the standard dialect sends the ceiling")

    // The ChatGPT-account backend rejects them, so binding Codex OAuth omits them.
    codex, codex_err := run_request_build(
        &model,
        provider.Codex_OAuth{access_token = "t", account_id = "a"},
        "high",
        request,
        context.allocator,
        scratch,
    )
    testing.expect_value(t, codex_err, provider.Transport_Error.None)
    defer delete(codex)
    testing.expect(t, !strings.contains(codex, `"max_output_tokens"`), "the codex dialect omits the ceiling")
}

// The registry reaches the wire, and a row that cannot call tools never receives them: the
// provider fails a turn on unexpected definitions rather than ignoring them.
@(test)
test_run_request_sends_tools_only_to_a_model_that_supports_them :: proc(t: ^testing.T) {
    tools := [?]provider.Tool_Definition {
        {
            name = "read",
            description = "Read a file",
            input_schema = `{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}`,
        },
    }

    for protocol in ([?]wire.Provider_Protocol{.Anthropic_Messages, .Openai_Chat, .Openai_Responses}) {
        model := request_test_model(protocol, nil)

        body := request_test_build(t, &model, "", nil, tools[:])
        defer delete(body)

        testing.expectf(t, strings.contains(body, `"read"`), "%v should carry the tool name: %s", protocol, body)
        testing.expectf(t, strings.contains(body, `"path"`), "%v should carry the schema: %s", protocol, body)

        model.info.supports_tools = false

        without := request_test_build(t, &model, "", nil, tools[:])
        defer delete(without)

        testing.expectf(t, !strings.contains(without, `"read"`), "%v should drop the tools: %s", protocol, without)
    }
}

// Persist one provider and hold the resulting snapshot, the way a started daemon does.
@(private)
run_test_catalog :: proc(t: ^testing.T, d: ^Daemon, s: ^store.Store) {
    item := state_provider(t, "openai", "https://api.openai.com/v1", "openai/gpt-5")
    testing.expect_value(t, store.catalog_imported_replace(s, item, ""), nil)
    testing.expect_value(t, catalog_state_load(d), nil)
}

@(test)
test_run_connection_build_binds_the_provider_credential :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)

    defer catalog_state_destroy(&d)
    run_test_catalog(t, &d, s)

    row := catalog_model_find(&d, "openai/gpt-5")
    testing.expect(t, row != nil, "the model resolves")

    d.provider_auth.api_keys = make(map[string]string, 2, context.allocator)
    defer delete(d.provider_auth.api_keys)

    // No credential for this provider yet.
    _, missing := run_connection_build(&d, row)
    testing.expect_value(t, missing, Run_Bind_Error.Missing_Credential)

    // Another provider's key does not bind.
    d.provider_auth.api_keys["xai"] = "other"
    _, isolated := run_connection_build(&d, row)
    testing.expect_value(t, isolated, Run_Bind_Error.Missing_Credential)

    // The provider's own key binds, after the endpoint validates.
    d.provider_auth.api_keys["openai"] = "sk-test"
    connection, ok := run_connection_build(&d, row)
    testing.expect_value(t, ok, Run_Bind_Error.None)
    testing.expect_value(t, connection.endpoint.base_url, "https://api.openai.com/v1")
    api_key, is_api := connection.auth.(provider.Api_Key)
    testing.expect(t, is_api, "an api-key provider binds an Api_Key auth")
    testing.expect_value(t, api_key.key, "sk-test")
}

@(test)
test_catalog_model_find_matches_the_whole_public_id :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    // Two providers held at once; resolving one must not surface the other's model.
    testing.expect_value(
        t,
        store.catalog_imported_replace(
            s,
            state_provider(t, "openai", "https://api.openai.com/v1", "openai/gpt-5"),
            "",
        ),
        nil,
    )
    testing.expect_value(
        t,
        store.catalog_imported_replace(s, state_provider(t, "xai", "https://api.x.ai/v1", "xai/grok-4"), ""),
        nil,
    )
    testing.expect_value(t, catalog_state_load(&d), nil)

    row := catalog_model_find(&d, "openai/gpt-5")
    if testing.expect(t, row != nil, "the model resolves by its public id") {
        testing.expect_value(t, string(row.info.id), "openai/gpt-5")
        testing.expect_value(t, row.upstream_id, "upstream")
        testing.expect_value(t, row.endpoint.base_url, "https://api.openai.com/v1")
        testing.expect_value(t, row.max_tokens_field, provider.Openai_Max_Tokens_Field.Max_Tokens)
    }

    // The id is a key, never a prefix or an index: only an exact match resolves.
    for id in ([?]string{"openai/grok-4", "openai/nope", "", "gpt-5", "/gpt-5", "openai/", "openai"}) {
        testing.expectf(t, catalog_model_find(&d, id) == nil, "%q should not resolve", id)
    }
}

@(test)
test_endpoint_is_loopback :: proc(t: ^testing.T) {
    Case :: struct {
        base_url: string,
        loopback: bool,
    }

    cases := [?]Case {
        {"http://127.0.0.1:11434/v1", true},
        {"http://127.5.6.7:8080/v1", true},
        {"http://localhost:1234/v1", true},
        {"http://LOCALHOST:1234/v1", true},
        {"http://ollama.localhost:1234/v1", true},
        {"http://[::1]:1234/v1", true},
        {"https://api.openai.com/v1", false},
        {"https://api.minimax.io/anthropic/v1", false},
        {"http://10.0.0.4:11434/v1", false},
        {"http://notlocalhost.example.com/v1", false},
    }
    for c in cases {
        endpoint := provider.Endpoint {
            base_url = c.base_url,
            protocol = .Openai_Chat,
        }
        testing.expectf(
            t,
            endpoint_is_loopback(endpoint) == c.loopback,
            "%s loopback should be %v",
            c.base_url,
            c.loopback,
        )
    }
}

@(test)
test_run_connection_build_allows_an_unauthenticated_local_endpoint :: proc(t: ^testing.T) {
    d: Daemon
    s := catalog_test_store(t, &d)
    defer store.close(s)

    defer catalog_state_destroy(&d)

    local := state_provider(t, "ollama", "http://127.0.0.1:11434/v1", "ollama/llama")
    testing.expect_value(t, store.catalog_imported_replace(s, local, ""), nil)
    testing.expect_value(t, catalog_state_load(&d), nil)

    row := catalog_model_find(&d, "ollama/llama")
    testing.expect(t, row != nil, "the local model resolves")

    d.provider_auth.api_keys = make(map[string]string, 2, context.allocator)
    defer delete(d.provider_auth.api_keys)

    // No credential is saved for this provider, but the endpoint is on this machine.
    connection, bind_err := run_connection_build(&d, row)
    testing.expect_value(t, bind_err, Run_Bind_Error.None)
    testing.expect(t, connection.auth == nil, "a local endpoint binds no credential")
    testing.expect_value(t, connection.endpoint.base_url, "http://127.0.0.1:11434/v1")
}

@(test)
test_run_responses_dialect_follows_the_credential :: proc(t: ^testing.T) {
    testing.expect_value(t, run_responses_dialect(nil), provider.Openai_Responses_Dialect.Standard)
    testing.expect_value(
        t,
        run_responses_dialect(provider.Api_Key{key = "sk-test"}),
        provider.Openai_Responses_Dialect.Standard,
    )
    testing.expect_value(
        t,
        run_responses_dialect(provider.Xai_OAuth{access_token = "token"}),
        provider.Openai_Responses_Dialect.Standard,
    )

    // Only the ChatGPT-account backend takes the restricted dialect.
    testing.expect_value(
        t,
        run_responses_dialect(provider.Codex_OAuth{access_token = "token", account_id = "acct"}),
        provider.Openai_Responses_Dialect.Codex,
    )
}
