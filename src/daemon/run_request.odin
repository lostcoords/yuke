package daemon

import "base:runtime"
import "core:mem"
import "core:net"
import "core:strings"

import http_server "libs:http/server"
import "src:daemon/catalog"
import "src:daemon/oauth"
import "src:provider"

// Build the provider request body: `request` carries the conversation half, the resolved row the
// model half. `reasoning` is a level the row advertises; an empty one keeps the provider default.
run_request_build :: proc(
    model: ^catalog.Model,
    auth: provider.Auth,
    reasoning: string,
    request: provider.Request,
    allocator: mem.Allocator,
    scratch_allocator: runtime.Allocator,
) -> (
    body: string,
    err: provider.Transport_Error,
) {
    assert(model != nil, "request assembly needs a resolved model")
    assert(allocator.procedure != nil && scratch_allocator.procedure != nil, "request assembly needs allocators")

    turn := request
    turn.model = model.upstream_id
    turn.provenance_model = string(model.info.id)
    turn.max_output_tokens = model.info.max_output_tokens

    // A model that rejects sampling controls never receives one, whatever the caller asked.
    if !model.supports_temperature do turn.temperature = nil

    // Same for tools: a row that cannot call them fails the turn on the definitions rather
    // than ignoring them, so the registry stops here instead of at the provider.
    if !model.info.supports_tools do turn.tools = nil

    level := run_reasoning_level(model, reasoning)

    switch model.endpoint.protocol {
    case .Anthropic_Messages:
        options := run_anthropic_options(model, level)

        // Anthropic refuses a sampling control while thinking is on, whatever the model
        // otherwise supports, so the resolved thinking mode has the last word.
        if run_anthropic_thinking_on(options.thinking) do turn.temperature = nil

        return provider.anthropic_request_body(turn, options, allocator, scratch_allocator)

    case .Openai_Chat:
        return provider.openai_chat_request_body(
            turn,
            run_openai_chat_options(model, level),
            allocator,
            scratch_allocator,
        )

    case .Openai_Responses:
        options := provider.Openai_Responses_Options {
            dialect = run_responses_dialect(auth),
            effort  = run_openai_effort(level),
        }

        return provider.openai_responses_request_body(turn, options, allocator, scratch_allocator)
    }

    return "", .Invalid_Request
}

// The level a turn actually runs at: the requested one when the row offers it, otherwise
// the row's derived default. An unknown level is never forwarded to a provider.
@(private)
run_reasoning_level :: proc(model: ^catalog.Model, reasoning: string) -> string {
    if len(model.info.reasoning_levels) == 0 do return ""

    for level in model.info.reasoning_levels {
        if level == reasoning do return level
    }

    return model.info.default_reasoning
}

// Anthropic splits the reasoning knob in two: `thinking` carries the request shape, `effort` the
// whole-request effort. Only one applies to a row — a budget row has bounds, an effort row not.
@(private)
run_anthropic_options :: proc(model: ^catalog.Model, level: string) -> provider.Anthropic_Options {
    if level == "" do return {}
    if level == "off" do return {thinking = provider.Anthropic_Thinking_Disabled{}}

    if model.anthropic_adaptive do return {thinking = provider.Anthropic_Thinking_Adaptive{}}

    if budget, budgeted := run_anthropic_budget(model, level); budgeted do return {thinking = provider.Anthropic_Thinking_Enabled{budget_tokens = budget}}

    return {effort = run_anthropic_effort(level)}
}

@(private)
run_anthropic_thinking_on :: proc(thinking: provider.Anthropic_Thinking) -> bool {
    #partial switch _ in thinking {
    case provider.Anthropic_Thinking_Adaptive, provider.Anthropic_Thinking_Enabled:
        return true
    }

    return false
}

// Token budget for a level on a budget-shaped row, the only kind the decoder bounds. It shares
// one ceiling with the answer, so even `max` leaves a quarter; a rejected budget yields false.
@(private)
run_anthropic_budget :: proc(model: ^catalog.Model, level: string) -> (budget: u64, budgeted: bool) {
    minimum, has_minimum := model.reasoning_budget_min.?
    maximum, has_maximum := model.reasoning_budget_max.?
    if !has_minimum && !has_maximum do return 0, false

    cap := model.info.max_output_tokens
    budget = (cap / 4) * 3 if level == "max" else cap / 2
    if has_maximum && maximum < budget do budget = maximum
    if has_minimum && minimum > 0 && u64(minimum) > budget do budget = u64(minimum)
    budget = max(budget, provider.ANTHROPIC_THINKING_BUDGET_MIN)

    if budget >= cap do return 0, false

    return budget, true
}

// The row already stores the builder's own vocabulary, so this only decides whether the
// reasoning controls are asked for at all.
@(private)
run_openai_chat_options :: proc(model: ^catalog.Model, level: string) -> provider.Openai_Chat_Options {
    options := provider.Openai_Chat_Options {
        max_tokens_field = model.max_tokens_field,
        reasoning_replay = model.reasoning_replay,
        thinking_format  = .None,
    }
    if level == "" do return options

    options.thinking_format = model.thinking_format
    options.effort = run_openai_effort(level)

    return options
}

// `off` is the effort literal `none`, which every format above turns into its own
// disabled shape. A level only reaches here when the resolved row advertises it.
@(private)
run_openai_effort :: proc(level: string) -> Maybe(provider.Openai_Effort) {
    switch level {
    case "off":
        return provider.Openai_Effort.None

    case "minimal":
        return provider.Openai_Effort.Minimal

    case "low":
        return provider.Openai_Effort.Low

    case "medium":
        return provider.Openai_Effort.Medium

    case "high":
        return provider.Openai_Effort.High

    case "xhigh":
        return provider.Openai_Effort.Xhigh

    case "max":
        return provider.Openai_Effort.Max
    }

    return nil
}

// Anthropic's scale has no `minimal`, so the lowest on-level saturates at `low`.
@(private)
run_anthropic_effort :: proc(level: string) -> Maybe(provider.Anthropic_Effort) {
    switch level {
    case "minimal", "low":
        return provider.Anthropic_Effort.Low

    case "medium":
        return provider.Anthropic_Effort.Medium

    case "high":
        return provider.Anthropic_Effort.High

    case "xhigh":
        return provider.Anthropic_Effort.Xhigh

    case "max":
        return provider.Anthropic_Effort.Max
    }

    return nil
}

// Why a resolved model could not become a live provider connection.
Run_Bind_Error :: enum {
    None,
    Invalid_Endpoint,
    Missing_Credential,
}

// The endpoint validates before any credential is attached. A missing credential is a
// normal error, never an assertion.
run_connection_build :: proc(d: ^Daemon, model: ^catalog.Model) -> (provider.Connection, Run_Bind_Error) {
    assert(d != nil && model != nil, "connection build needs a daemon and a model")

    endpoint := model.endpoint
    if provider.endpoint_validate(endpoint) != .None do return {}, .Invalid_Endpoint

    auth, bind_err := run_credential_bind(d, model.info.provider)

    // A model server on this machine authenticates nothing, so a missing credential is
    // not an error there. Every routable endpoint still requires one.
    if bind_err == .Missing_Credential && endpoint_is_loopback(endpoint) do auth, bind_err = nil, .None
    if bind_err != .None do return {}, bind_err

    return {endpoint = endpoint, auth = auth}, .None
}

// Whether an endpoint addresses this machine. `localhost` and the reserved `.localhost`
// suffix count without a lookup; anything else must parse as a loopback IP literal.
endpoint_is_loopback :: proc(endpoint: provider.Endpoint) -> bool {
    host := provider.url_host(endpoint.base_url)
    if host == "" do return false

    if strings.has_suffix(host, ".") do host = host[:len(host) - 1]
    if strings.equal_fold(host, "localhost") ||
       strings.has_suffix(strings.to_lower(host, context.temp_allocator), ".localhost") {
        return true
    }

    address := net.parse_address(host)
    if address == nil do return false

    return http_server.address_is_loopback(address)
}

// The ChatGPT-account Codex backend rejects the sampling limits an OpenAI API key
// accepts, so the Responses dialect follows the bound credential, not model metadata.
run_responses_dialect :: proc(auth: provider.Auth) -> provider.Openai_Responses_Dialect {
    if _, codex := auth.(provider.Codex_OAuth); codex do return .Codex

    return .Standard
}

// Resolve the credential for a logical provider: its saved API key, else its OAuth
// tokens, else missing. The credential is bound to this provider only.
@(private)
run_credential_bind :: proc(d: ^Daemon, provider_id: string) -> (provider.Auth, Run_Bind_Error) {
    if key, present := d.provider_auth.api_keys[provider_id]; present do return provider.Api_Key{key = key}, .None

    if kind, known := oauth.kind_from_id(provider_id); known {
        if credentials, present := provider_credentials_get(d, kind); present {
            switch kind {
            case .Codex:
                return provider.Codex_OAuth {
                        access_token = credentials.access_token,
                        account_id = credentials.account_id,
                    },
                    .None

            case .Xai:
                return provider.Xai_OAuth{access_token = credentials.access_token}, .None
            }
        }
    }

    return nil, .Missing_Credential
}
