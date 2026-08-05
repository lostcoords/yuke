package provider

import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:strings"

// One tool call assembled across an `output_item.added` /
// `function_call_arguments.delta` / `output_item.done` sequence. Its buffers
// live in the decoder's turn allocator.
@(private)
Openai_Responses_Pending_Tool :: struct {
    // Provider-issued call id echoed back on the tool result.
    id:        string,

    // Function name to invoke.
    name:      string,

    // Raw JSON argument fragments streamed by `function_call_arguments.delta`.
    arguments: [dynamic]byte,
}

// Stateful decoder for OpenAI Responses SSE payloads. `allocator` must be the
// owning turn's arena: every retained string is allocated there and nothing is
// freed individually, not even on a partial-failure path. JSON trees use a
// separate per-event allocator that must not alias it. Responses events are
// sequential, so exactly one text or reasoning block is open at a time and at
// most one function call accumulates between its `added` and `done`.
Openai_Responses_Decoder :: struct {
    // Turn-lifetime owner for retained stream data.
    allocator:           runtime.Allocator,

    // Completed tool calls, emitted as blocks at the terminal event.
    tools:               [dynamic]Tool_Call,

    // Function call accumulating between `output_item.added` and `.done`.
    open_tool:           Openai_Responses_Pending_Tool,

    // Encrypted reasoning content captured for the open reasoning block; set on
    // the reasoning item's `added`/`done` and replayed into its terminal block.
    reasoning_signature: string,

    // Stop reason latched from the terminal event's status.
    pending_reason:      Stop_Reason,

    // Usage folded from the terminal event's response object.
    pending_usage:       Usage,

    // Kind of the currently open text or reasoning block.
    open_kind:           Stream_Block_Kind,

    // Turn-local id of the currently open block.
    open_id:             Stream_Block_Id,

    // Next turn-local block id to hand out.
    next_id:             u64,

    // A function call is currently accumulating.
    tool_open:           bool,

    // A text or reasoning block is currently open.
    block_open:          bool,

    // Terminal event or error has already been observed.
    done:                bool,
}

// Initialize an empty decoder. Every later decode allocates its retained output
// into `allocator` and frees none of it.
openai_responses_decoder_init :: proc(allocator := context.allocator) -> Openai_Responses_Decoder {
    assert(allocator.procedure != nil, "OpenAI responses decoder needs a valid turn allocator")

    decoder := Openai_Responses_Decoder {
        allocator      = allocator,
        pending_reason = .End_Turn,
    }
    decoder.tools.allocator = allocator

    return decoder
}

// Decode one SSE `data` payload, appending its neutral events to `events`. Empty
// payloads and payloads after a terminal outcome append nothing. There is no
// `[DONE]` sentinel: `response.completed`/`response.incomplete` is terminal.
// Retained strings live in the decoder's allocator; `scratch_allocator` holds
// only per-call JSON trees and must be a bulk-reclaimable scratch scope the turn
// resets each event.
openai_responses_decoder_decode :: proc(
    decoder: ^Openai_Responses_Decoder,
    data: string,
    events: ^[dynamic]Stream_Event,
    scratch_allocator := context.allocator,
) -> Transport_Error {
    assert(decoder != nil, "OpenAI responses decode needs a decoder")
    assert(events != nil, "OpenAI responses decode needs an event queue")
    assert(decoder.allocator.procedure != nil, "OpenAI responses decoder must be initialized")
    assert(scratch_allocator.procedure != nil, "OpenAI responses decode needs a valid scratch allocator")
    assert(
        scratch_allocator.procedure != decoder.allocator.procedure || scratch_allocator.data != decoder.allocator.data,
        "OpenAI responses event scratch must not alias the turn allocator",
    )
    assert(!decoder.block_open || decoder.next_id > 0, "an open block was handed a turn-local id")
    assert(len(decoder.tools) <= MAX_TOOL_CALLS, "tool count stays within its bound")

    trimmed := strings.trim_space(data)
    if decoder.done || len(trimmed) == 0 {
        return .None
    }

    value, object, parse_err := decode_json_object(data, scratch_allocator)
    if parse_err != .None {
        decoder.done = true
        return parse_err
    }
    defer json.destroy_value(value, scratch_allocator)

    event_type, present, ferr := decode_optional_string(object, "type")
    if ferr != .None {
        decoder.done = true
        return ferr
    }

    if !present {
        return .None
    }

    err: Transport_Error

    switch event_type {
    case "response.output_text.delta":
        err = openai_responses_delta_event(decoder, object, events, .Text)

    case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
        err = openai_responses_delta_event(decoder, object, events, .Reasoning)

    case "response.output_item.added":
        err = openai_responses_item_added(decoder, object)

    case "response.function_call_arguments.delta":
        err = openai_responses_args_delta(decoder, object)

    case "response.output_item.done":
        err = openai_responses_item_done(decoder, object, events, scratch_allocator)

    case "response.completed", "response.incomplete":
        decoder.done = true
        err = openai_responses_terminal(decoder, object, events, event_type)

    case "response.failed", "error":
        decoder.done = true
        return openai_responses_error(object)

    case:
        return .None
    }

    if err != .None {
        decoder.done = true
    }

    return err
}

// Finish at transport EOF. Responses has no `[DONE]` sentinel and no other
// terminator than `response.completed`/`response.incomplete`; EOF before one is
// a truncated answer. Responses appends nothing on finish.
openai_responses_decoder_finish :: proc(
    decoder: ^Openai_Responses_Decoder,
    events: ^[dynamic]Stream_Event,
    scratch_allocator := context.allocator,
) -> Transport_Error {
    assert(decoder != nil, "OpenAI responses finish needs a decoder")
    assert(events != nil, "OpenAI responses finish needs an event queue")
    assert(decoder.allocator.procedure != nil, "OpenAI responses decoder must be initialized")

    if decoder.done {
        return .None
    }

    decoder.done = true

    return .Stream_Truncated
}

// Append a text or reasoning delta from a `*.delta` event, skipping an empty or
// absent fragment.
@(private)
openai_responses_delta_event :: proc(
    decoder: ^Openai_Responses_Decoder,
    object: json.Object,
    events: ^[dynamic]Stream_Event,
    kind: Stream_Block_Kind,
) -> Transport_Error {
    delta, present, derr := decode_optional_string(object, "delta")
    if derr != .None {
        return derr
    }

    if !present || len(delta) == 0 {
        return .None
    }

    return openai_responses_emit_delta(decoder, events, kind, delta)
}

// Append a text or reasoning delta, opening a fresh block or closing the open
// block of the other kind first. Enforces one open block at a time.
@(private)
openai_responses_emit_delta :: proc(
    decoder: ^Openai_Responses_Decoder,
    events: ^[dynamic]Stream_Event,
    kind: Stream_Block_Kind,
    text: string,
) -> Transport_Error {
    assert(kind == .Text || kind == .Reasoning, "OpenAI responses only streams text and reasoning deltas")
    assert(len(text) > 0, "a neutral delta is never empty")

    if decoder.block_open && decoder.open_kind != kind {
        openai_responses_close_block(decoder, events) or_return
    }

    if !decoder.block_open {
        id := Stream_Block_Id(decoder.next_id)
        decoder.next_id += 1
        assert(decoder.next_id <= MAX_EXACT_JSON_INTEGER + 1, "the next block id stays exactly representable")

        if _, aerr := append(events, Stream_Block_Started{block_id = id, kind = kind}); aerr != nil {
            return .Resource_Exhausted
        }

        decoder.open_kind = kind
        decoder.open_id = id
        decoder.block_open = true
    }

    owned, clone_err := strings.clone(text, decoder.allocator)
    if clone_err != nil {
        return .Resource_Exhausted
    }

    event: Stream_Event
    switch kind {
    case .Text:
        event = Stream_Text_Delta {
            block_id = decoder.open_id,
            text     = owned,
        }

    case .Reasoning:
        event = Stream_Reasoning_Delta {
            block_id = decoder.open_id,
            text     = owned,
        }

    case .Redacted_Reasoning, .Tool:
        unreachable()
    }

    if _, aerr := append(events, event); aerr != nil {
        return .Resource_Exhausted
    }

    return .None
}

// Close the open text or reasoning block with its terminal metadata. A reasoning
// block carries the captured encrypted signature, which is consumed here.
@(private)
openai_responses_close_block :: proc(
    decoder: ^Openai_Responses_Decoder,
    events: ^[dynamic]Stream_Event,
) -> Transport_Error {
    assert(decoder.block_open, "closing a block requires an open block")

    result: Stream_Block_Result
    switch decoder.open_kind {
    case .Text:
        result = Stream_Text_Block{}

    case .Reasoning:
        result = Stream_Reasoning_Block {
            signature = decoder.reasoning_signature,
        }

    case .Redacted_Reasoning, .Tool:
        unreachable()
    }

    if _, aerr := append(events, Stream_Block_Stopped{block_id = decoder.open_id, result = result}); aerr != nil {
        return .Resource_Exhausted
    }

    decoder.block_open = false
    decoder.reasoning_signature = ""

    return .None
}

// Handle `response.output_item.added`: start accumulating a function call, or
// capture a reasoning item's encrypted content when it arrives early. Other item
// kinds contribute nothing.
@(private)
openai_responses_item_added :: proc(decoder: ^Openai_Responses_Decoder, object: json.Object) -> Transport_Error {
    item, present, ierr := decode_optional_object(object, "item")
    if ierr != .None {
        return ierr
    }

    if !present {
        return .None
    }

    item_type, _, terr := decode_optional_string(item, "type")
    if terr != .None {
        return terr
    }

    switch item_type {
    case "function_call":
        call_id, _, cerr := decode_optional_string(item, "call_id")
        if cerr != .None {
            return cerr
        }

        name, _, nerr := decode_optional_string(item, "name")
        if nerr != .None {
            return nerr
        }

        owned_id, id_err := openai_responses_clone(decoder, call_id)
        if id_err != .None {
            return id_err
        }

        owned_name, name_err := openai_responses_clone(decoder, name)
        if name_err != .None {
            return name_err
        }

        arguments, arguments_err := make([dynamic]byte, 0, decoder.allocator)
        if arguments_err != nil {
            return .Resource_Exhausted
        }

        decoder.open_tool = Openai_Responses_Pending_Tool {
            id        = owned_id,
            name      = owned_name,
            arguments = arguments,
        }
        decoder.tool_open = true

    case "reasoning":
        return openai_responses_capture_signature(decoder, item)
    }

    return .None
}

// Append one `function_call_arguments.delta` fragment to the open function
// call, enforcing the per-call byte bound. A delta with no open call is ignored.
@(private)
openai_responses_args_delta :: proc(decoder: ^Openai_Responses_Decoder, object: json.Object) -> Transport_Error {
    if !decoder.tool_open {
        return .None
    }

    delta, present, derr := decode_optional_string(object, "delta")
    if derr != .None {
        return derr
    }

    if !present || len(delta) == 0 {
        return .None
    }

    assert(len(decoder.open_tool.arguments) <= MAX_TOOL_CALL_BYTES, "retained arguments start bounded")

    if len(delta) > MAX_TOOL_CALL_BYTES - len(decoder.open_tool.arguments) {
        return .Tool_Call_Too_Large
    }

    if _, aerr := append(&decoder.open_tool.arguments, delta); aerr != nil {
        return .Resource_Exhausted
    }

    assert(len(decoder.open_tool.arguments) <= MAX_TOOL_CALL_BYTES, "retained arguments remain bounded")

    return .None
}

// Handle `response.output_item.done`: finalize a function call into a completed
// tool call, or close the open reasoning block carrying its captured signature.
@(private)
openai_responses_item_done :: proc(
    decoder: ^Openai_Responses_Decoder,
    object: json.Object,
    events: ^[dynamic]Stream_Event,
    scratch_allocator: runtime.Allocator,
) -> Transport_Error {
    item, present, ierr := decode_optional_object(object, "item")
    if ierr != .None {
        return ierr
    }

    if !present {
        return .None
    }

    item_type, _, terr := decode_optional_string(item, "type")
    if terr != .None {
        return terr
    }

    switch item_type {
    case "function_call":
        return openai_responses_finalize_tool(decoder, item, scratch_allocator)

    case "reasoning":
        return openai_responses_finalize_reasoning(decoder, item, events)
    }

    return .None
}

// Finalize the completed function call. `arguments` on the done item is
// authoritative when present; otherwise the accumulated delta fragments are
// used. Empty arguments normalize to `{}`, and the whole is structurally
// validated. A call missing its id or name is dropped.
@(private)
openai_responses_finalize_tool :: proc(
    decoder: ^Openai_Responses_Decoder,
    item: json.Object,
    scratch_allocator: runtime.Allocator,
) -> Transport_Error {
    call_id := decoder.open_tool.id if decoder.tool_open else ""
    if value, present, err := decode_optional_string(item, "call_id"); err != .None {
        return err
    } else if present && len(value) > 0 {
        owned, cerr := openai_responses_clone(decoder, value)
        if cerr != .None {
            return cerr
        }

        call_id = owned
    }

    name := decoder.open_tool.name if decoder.tool_open else ""
    if value, present, err := decode_optional_string(item, "name"); err != .None {
        return err
    } else if present && len(value) > 0 {
        owned, cerr := openai_responses_clone(decoder, value)
        if cerr != .None {
            return cerr
        }

        name = owned
    }

    arguments: []byte
    if value, present, err := decode_optional_string(item, "arguments"); err != .None {
        return err
    } else if present {
        if len(value) > MAX_TOOL_CALL_BYTES {
            return .Tool_Call_Too_Large
        }

        owned, cerr := strings.clone(value, decoder.allocator)
        if cerr != nil {
            return .Resource_Exhausted
        }

        arguments = transmute([]byte)owned
    } else if decoder.tool_open {
        arguments = decoder.open_tool.arguments[:]
    }

    decoder.open_tool = {}
    decoder.tool_open = false

    // A completed call without both a call id and a name has nothing to invoke.
    if len(call_id) == 0 || len(name) == 0 {
        return .None
    }

    validated, validate_err := openai_tool_arguments(arguments, scratch_allocator)
    if validate_err != .None {
        return validate_err
    }

    if len(decoder.tools) >= MAX_TOOL_CALLS {
        return .Too_Many_Tool_Calls
    }

    call := Tool_Call {
        id        = call_id,
        name      = name,
        arguments = validated,
    }
    if _, aerr := append(&decoder.tools, call); aerr != nil {
        return .Resource_Exhausted
    }

    return .None
}

// Capture the reasoning item's `encrypted_content` and close the open reasoning
// block with it. An encrypted-only item whose summary text never streamed still
// yields a signed reasoning block so replay can persist the signature.
@(private)
openai_responses_finalize_reasoning :: proc(
    decoder: ^Openai_Responses_Decoder,
    item: json.Object,
    events: ^[dynamic]Stream_Event,
) -> Transport_Error {
    openai_responses_capture_signature(decoder, item) or_return

    if decoder.block_open && decoder.open_kind == .Reasoning {
        return openai_responses_close_block(decoder, events)
    }

    if !decoder.block_open && len(decoder.reasoning_signature) > 0 {
        id := Stream_Block_Id(decoder.next_id)
        decoder.next_id += 1
        assert(decoder.next_id <= MAX_EXACT_JSON_INTEGER + 1, "the next block id stays exactly representable")

        if _, aerr := append(events, Stream_Block_Started{block_id = id, kind = .Reasoning}); aerr != nil {
            return .Resource_Exhausted
        }

        stopped := Stream_Block_Stopped {
            block_id = id,
            result = Stream_Reasoning_Block{signature = decoder.reasoning_signature},
        }
        if _, aerr := append(events, stopped); aerr != nil {
            return .Resource_Exhausted
        }

        decoder.reasoning_signature = ""
    }

    return .None
}

// Retain a reasoning item's `encrypted_content`, when present, as the signature
// for its block.
@(private)
openai_responses_capture_signature :: proc(decoder: ^Openai_Responses_Decoder, item: json.Object) -> Transport_Error {
    encrypted, present, err := decode_optional_string(item, "encrypted_content")
    if err != .None {
        return err
    }

    if present && len(encrypted) > 0 {
        owned, cerr := strings.clone(encrypted, decoder.allocator)
        if cerr != nil {
            return .Resource_Exhausted
        }

        decoder.reasoning_signature = owned
    }

    return .None
}

// Close any open block, append each accumulated tool call as a start/stop pair,
// then the one terminal `Stream_Done`. The stop reason comes from the response
// status but is overridden to `Tool_Calls` when any call was assembled.
@(private)
openai_responses_terminal :: proc(
    decoder: ^Openai_Responses_Decoder,
    object: json.Object,
    events: ^[dynamic]Stream_Event,
    event_type: string,
) -> Transport_Error {
    reason := Stop_Reason.Max_Tokens if event_type == "response.incomplete" else Stop_Reason.End_Turn

    if response, present, rerr := decode_optional_object(object, "response"); rerr != .None {
        return rerr
    } else if present {
        if status, spresent, serr := decode_optional_string(response, "status"); serr != .None {
            return serr
        } else if spresent {
            reason = openai_responses_stop_reason(status)
        }

        if usage, upresent, uerr := decode_optional_object(response, "usage"); uerr != .None {
            return uerr
        } else if upresent {
            openai_responses_fold_usage(decoder, usage)
        }
    }

    decoder.pending_reason = reason

    if decoder.block_open {
        openai_responses_close_block(decoder, events) or_return
    }

    for call in decoder.tools {
        id := Stream_Block_Id(decoder.next_id)
        decoder.next_id += 1

        if _, aerr := append(events, Stream_Block_Started{block_id = id, kind = .Tool}); aerr != nil {
            return .Resource_Exhausted
        }

        stopped := Stream_Block_Stopped {
            block_id = id,
            result = Stream_Tool_Block{call = call},
        }
        if _, aerr := append(events, stopped); aerr != nil {
            return .Resource_Exhausted
        }
    }

    final_reason := decoder.pending_reason
    if len(decoder.tools) > 0 {
        final_reason = .Tool_Calls
    }

    if _, aerr := append(events, Stream_Done{reason = final_reason, usage = decoder.pending_usage}); aerr != nil {
        return .Resource_Exhausted
    }

    return .None
}

// Fold the token accounting from a terminal response's usage object. Counters
// are read permissively so malformed usage never invalidates a usable answer.
@(private)
openai_responses_fold_usage :: proc(decoder: ^Openai_Responses_Decoder, usage: json.Object) {
    input := decode_usage_u64(usage, "input_tokens")
    output := decode_usage_u64(usage, "output_tokens")
    provider_total := decode_usage_u64(usage, "total_tokens")

    cache_read: u64
    if details, present, err := decode_optional_object(usage, "input_tokens_details"); err == .None && present {
        cache_read = decode_usage_u64(details, "cached_tokens")
    }

    reasoning: u64
    if details, present, err := decode_optional_object(usage, "output_tokens_details"); err == .None && present {
        reasoning = decode_usage_u64(details, "reasoning_tokens")
    }

    decoder.pending_usage = Usage {
        input      = input,
        output     = output,
        reasoning  = reasoning,
        cache_read = cache_read,
        total      = max(provider_total, intrinsics.saturating_add(input, output)),
    }
}

// Map a terminal response status to a neutral stop reason.
@(private)
openai_responses_stop_reason :: proc(status: string) -> Stop_Reason {
    switch status {
    case "incomplete":
        return .Max_Tokens

    case:
        return .End_Turn
    }
}

// Classify a `response.failed`/`error` terminal. The discriminator is the error
// object's `code`, then its `type`, then a top-level `code`. Quota types are
// terminal; any other discriminator is a rate limit; none is a server error.
@(private)
openai_responses_error :: proc(object: json.Object) -> Transport_Error {
    discriminator := openai_responses_error_discriminator(object)

    for quota in QUOTA_ERROR_TYPES {
        if discriminator == quota {
            return .Quota_Exhausted
        }
    }

    if len(discriminator) > 0 {
        return .Rate_Limited
    }

    return .Server_Error
}

// Extract the error discriminator, preferring the nested `response.error`
// object's `code` then `type`, then a top-level `code`. The top-level `type` is
// the event discriminator, never an error code, so it is not consulted.
@(private)
openai_responses_error_discriminator :: proc(object: json.Object) -> string {
    if response, present, err := decode_optional_object(object, "response"); err == .None && present {
        if error_object, epresent, eerr := decode_optional_object(response, "error"); eerr == .None && epresent {
            if code, cpresent, _ := decode_optional_string(error_object, "code"); cpresent && len(code) > 0 {
                return code
            }

            if kind, kpresent, _ := decode_optional_string(error_object, "type"); kpresent && len(kind) > 0 {
                return kind
            }
        }
    }

    if code, present, _ := decode_optional_string(object, "code"); present && len(code) > 0 {
        return code
    }

    return ""
}

// Clone a possibly-empty borrowed string into the turn allocator; an empty
// source stays the empty string without allocating.
@(private)
openai_responses_clone :: proc(
    decoder: ^Openai_Responses_Decoder,
    value: string,
) -> (
    owned: string,
    err: Transport_Error,
) {
    if len(value) == 0 {
        return "", .None
    }

    cloned, clone_err := strings.clone(value, decoder.allocator)
    if clone_err != nil {
        return "", .Resource_Exhausted
    }

    return cloned, .None
}
