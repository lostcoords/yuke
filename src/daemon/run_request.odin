package daemon

import "base:runtime"
import "core:mem"

import catalog "src:daemon/catalog"
import provider "src:provider"

// Build the provider request body for one turn. `request` carries the conversation half —
// system prompt, messages, tools — and the resolved row supplies the model half: upstream
// id, output ceiling, temperature gating, and every reasoning control.
//
// `reasoning` is a level from the row's own `reasoning_levels`; an empty level, or a row
// with no levels, leaves the provider's default in place.
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
    turn.max_output_tokens = model.info.max_output_tokens

    // A model that rejects sampling controls never receives one, whatever the caller asked.
    if !model.supports_temperature {
        turn.temperature = nil
    }

    level := run_reasoning_level(model, reasoning)

    switch model.endpoint.protocol {
    case .Anthropic_Messages:
        options := run_anthropic_options(model, level)

        // Anthropic refuses a sampling control while thinking is on, whatever the model
        // otherwise supports, so the resolved thinking mode has the last word.
        if run_anthropic_thinking_on(options.thinking) {
            turn.temperature = nil
        }

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
    if len(model.info.reasoning_levels) == 0 {
        return ""
    }

    for level in model.info.reasoning_levels {
        if level == reasoning {
            return level
        }
    }

    return model.info.default_reasoning
}

// Anthropic splits the reasoning knob in two: `thinking` carries the request shape and
// `output_config.effort` the whole-request effort. Only one of them applies to a row —
// a budget row has budget bounds, an effort row does not.
@(private)
run_anthropic_options :: proc(model: ^catalog.Model, level: string) -> provider.Anthropic_Options {
    if level == "" {
        return {}
    }
    if level == "off" {
        return {thinking = provider.Anthropic_Thinking_Disabled{}}
    }

    if model.anthropic_adaptive {
        return {thinking = provider.Anthropic_Thinking_Adaptive{}}
    }

    if budget, budgeted := run_anthropic_budget(model, level); budgeted {
        return {thinking = provider.Anthropic_Thinking_Enabled{budget_tokens = budget}}
    }

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

// Token budget for a level on a budget-shaped row, which is the only kind the decoder
// gives bounds to. The budget shares one ceiling with the answer, so even `max` leaves
// the response a quarter of it. A budget the row or the builder rejects yields `false`.
@(private)
run_anthropic_budget :: proc(model: ^catalog.Model, level: string) -> (budget: u64, budgeted: bool) {
    minimum, has_minimum := model.reasoning_budget_min.?
    maximum, has_maximum := model.reasoning_budget_max.?
    if !has_minimum && !has_maximum {
        return 0, false
    }

    cap := model.info.max_output_tokens
    budget = (cap / 4) * 3 if level == "max" else cap / 2
    if has_maximum && maximum < budget {
        budget = maximum
    }
    if has_minimum && minimum > 0 && u64(minimum) > budget {
        budget = u64(minimum)
    }
    budget = max(budget, provider.ANTHROPIC_THINKING_BUDGET_MIN)

    if budget >= cap {
        return 0, false
    }

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
    if level == "" {
        return options
    }

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
