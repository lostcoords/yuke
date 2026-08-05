package provider

import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:strings"

// One tool call assembled across streamed deltas, keyed by its provider slot
// index. Every buffer lives in the decoder's turn allocator.
@(private)
Openai_Pending_Tool :: struct {
    // Provider-issued id fragments.
    id:        [dynamic]byte,

    // Function-name fragments.
    name:      [dynamic]byte,

    // Raw JSON argument fragments.
    arguments: [dynamic]byte,
}

// Stateful decoder for OpenAI Chat Completions SSE payloads. `allocator` must be
// the owning turn's arena: every retained string is allocated there and nothing
// is freed individually, not even on a partial-failure path. The flat delta
// stream is synthesized into the block-structured neutral model, so exactly one
// text or reasoning block is open at a time.
Openai_Chat_Decoder :: struct {
    // Turn-lifetime owner for retained stream data.
    allocator:      runtime.Allocator,

    // Tool calls accumulated across deltas, indexed by provider slot.
    pending_tools:  [dynamic]Openai_Pending_Tool,

    // Last normalized reason seen on a `finish_reason`.
    pending_reason: Stop_Reason,

    // Usage folded from the latest usage-bearing chunk.
    pending_usage:  Usage,

    // Kind of the currently open text or reasoning block.
    open_kind:      Stream_Block_Kind,

    // Turn-local id of the currently open block.
    open_id:        Stream_Block_Id,

    // Next turn-local block id to hand out.
    next_id:        u64,

    // A text or reasoning block is currently open.
    block_open:     bool,

    // A `finish_reason` has been observed.
    reason_seen:    bool,

    // Terminal event or error has already been observed.
    done:           bool,
}

// Initialize an empty decoder. Every later decode allocates its retained output
// into `allocator` and frees none of it.
openai_chat_decoder_init :: proc(allocator := context.allocator) -> Openai_Chat_Decoder {
    assert(allocator.procedure != nil, "OpenAI chat decoder needs a valid turn allocator")

    decoder := Openai_Chat_Decoder {
        allocator      = allocator,
        pending_reason = .End_Turn,
    }
    decoder.pending_tools.allocator = allocator

    return decoder
}

// Decode one SSE `data` payload, appending its neutral events to `events`. Empty
// payloads and payloads after a terminal outcome append nothing. The `[DONE]`
// sentinel closes any open block and emits the terminal events. Retained strings
// live in the decoder's allocator; `scratch_allocator` holds only per-call JSON
// trees and must be a bulk-reclaimable scratch scope the turn resets each event.
openai_chat_decoder_decode :: proc(
    decoder: ^Openai_Chat_Decoder,
    data: string,
    events: ^[dynamic]Stream_Event,
    scratch_allocator := context.allocator,
) -> Transport_Error {
    assert(decoder != nil, "OpenAI chat decode needs a decoder")
    assert(events != nil, "OpenAI chat decode needs an event queue")
    assert(decoder.allocator.procedure != nil, "OpenAI chat decoder must be initialized")
    assert(scratch_allocator.procedure != nil, "OpenAI chat decode needs a valid scratch allocator")
    assert(
        scratch_allocator.procedure != decoder.allocator.procedure || scratch_allocator.data != decoder.allocator.data,
        "OpenAI chat event scratch must not alias the turn allocator",
    )
    assert(!decoder.block_open || decoder.next_id > 0, "an open block was handed a turn-local id")

    trimmed := strings.trim_space(data)
    if decoder.done || len(trimmed) == 0 {
        return .None
    }

    if trimmed == "[DONE]" {
        decoder.done = true
        return openai_chat_terminal(decoder, events, scratch_allocator)
    }

    value, object, parse_err := decode_json_object(data, scratch_allocator)
    if parse_err != .None {
        decoder.done = true
        return parse_err
    }
    defer json.destroy_value(value, scratch_allocator)

    if usage, present, uerr := decode_optional_object(object, "usage"); uerr != .None {
        decoder.done = true
        return uerr
    } else if present {
        openai_fold_usage(decoder, usage)
    }

    if err := openai_decode_choices(decoder, object, events); err != .None {
        decoder.done = true
        return err
    }

    return .None
}

// Finish at transport EOF. A seen `finish_reason` without a `[DONE]` sentinel is
// a complete stream (some providers omit the sentinel); EOF with no terminal
// signal at all is a truncated answer.
openai_chat_decoder_finish :: proc(
    decoder: ^Openai_Chat_Decoder,
    events: ^[dynamic]Stream_Event,
    scratch_allocator := context.allocator,
) -> Transport_Error {
    assert(decoder != nil, "OpenAI chat finish needs a decoder")
    assert(events != nil, "OpenAI chat finish needs an event queue")
    assert(decoder.allocator.procedure != nil, "OpenAI chat decoder must be initialized")

    if decoder.done {
        return .None
    }

    decoder.done = true
    if !decoder.reason_seen {
        return .Stream_Truncated
    }

    return openai_chat_terminal(decoder, events, scratch_allocator)
}

// Fold the token accounting from one usage-bearing chunk. Counters are read
// permissively so malformed usage never invalidates an otherwise usable answer.
@(private)
openai_fold_usage :: proc(decoder: ^Openai_Chat_Decoder, usage: json.Object) {
    assert(decoder != nil, "usage folding needs a decoder")

    input := decode_usage_u64(usage, "prompt_tokens")
    output := decode_usage_u64(usage, "completion_tokens")
    provider_total := decode_usage_u64(usage, "total_tokens")

    cache_read: u64
    if details, present, err := decode_optional_object(usage, "prompt_tokens_details"); err == .None && present {
        cache_read = decode_usage_u64(details, "cached_tokens")
    }

    decoder.pending_usage = Usage {
        input      = input,
        output     = output,
        cache_read = cache_read,
        total      = max(provider_total, intrinsics.saturating_add(input, output)),
    }
}

// Walk the `choices` array, emitting reasoning and text deltas, accumulating tool
// calls, and latching a `finish_reason`. The neutral event carries no choice
// index, so at most the first non-empty reasoning and content fragments across
// choices are surfaced, reasoning first.
@(private)
openai_decode_choices :: proc(
    decoder: ^Openai_Chat_Decoder,
    object: json.Object,
    events: ^[dynamic]Stream_Event,
) -> Transport_Error {
    assert(decoder != nil, "choice decoding needs a decoder")
    assert(!decoder.done, "choice decoding cannot run after completion")

    field, found := object["choices"]
    if !found {
        return .None
    }

    if _, is_null := field.(json.Null); is_null {
        return .None
    }

    choices, ok := field.(json.Array)
    if !ok {
        return .Parse_Error
    }

    content: string
    reasoning: string

    for element in choices {
        choice, choice_ok := element.(json.Object)
        if !choice_ok {
            return .Parse_Error
        }

        delta, delta_present, derr := decode_optional_object(choice, "delta")
        if derr != .None {
            return derr
        }

        if delta_present {
            fragment_content, _, cerr := decode_optional_string(delta, "content")
            if cerr != .None {
                return cerr
            }

            if len(content) == 0 && len(fragment_content) > 0 {
                content = fragment_content
            }

            fragment_reasoning, _, rerr := decode_optional_string(delta, "reasoning_content")
            if rerr != .None {
                return rerr
            }

            if len(reasoning) == 0 && len(fragment_reasoning) > 0 {
                reasoning = fragment_reasoning
            }

            openai_accumulate_tool_calls(decoder, delta) or_return
        }

        reason, reason_present, freason_err := decode_optional_string(choice, "finish_reason")
        if freason_err != .None {
            return freason_err
        }

        if reason_present {
            decoder.pending_reason = openai_stop_reason(reason)
            decoder.reason_seen = true
        }
    }

    if len(reasoning) > 0 {
        openai_emit_delta(decoder, events, .Reasoning, reasoning) or_return
    }

    if len(content) > 0 {
        openai_emit_delta(decoder, events, .Text, content) or_return
    }

    return .None
}

// Append a text or reasoning delta, opening a fresh block or closing the open
// block of the other kind first. Enforces one open block at a time.
@(private)
openai_emit_delta :: proc(
    decoder: ^Openai_Chat_Decoder,
    events: ^[dynamic]Stream_Event,
    kind: Stream_Block_Kind,
    text: string,
) -> Transport_Error {
    assert(kind == .Text || kind == .Reasoning, "OpenAI chat only streams text and reasoning deltas")
    assert(len(text) > 0, "a neutral delta is never empty")

    if decoder.block_open && decoder.open_kind != kind {
        openai_close_block(decoder, events) or_return
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

// Close the open text or reasoning block with its terminal metadata.
@(private)
openai_close_block :: proc(decoder: ^Openai_Chat_Decoder, events: ^[dynamic]Stream_Event) -> Transport_Error {
    assert(decoder.block_open, "closing a block requires an open block")

    result: Stream_Block_Result
    switch decoder.open_kind {
    case .Text:
        result = Stream_Text_Block{}

    case .Reasoning:
        result = Stream_Reasoning_Block{}

    case .Redacted_Reasoning, .Tool:
        unreachable()
    }

    if _, aerr := append(events, Stream_Block_Stopped{block_id = decoder.open_id, result = result}); aerr != nil {
        return .Resource_Exhausted
    }

    decoder.block_open = false

    return .None
}

// Accumulate one `delta.tool_calls` array into the indexed pending entries. A
// missing, null, or non-array value contributes nothing; a slot index at or past
// `MAX_TOOL_CALLS` fails the turn.
@(private)
openai_accumulate_tool_calls :: proc(decoder: ^Openai_Chat_Decoder, delta: json.Object) -> Transport_Error {
    field, found := delta["tool_calls"]
    if !found {
        return .None
    }

    if _, is_null := field.(json.Null); is_null {
        return .None
    }

    calls, ok := field.(json.Array)
    if !ok {
        return .Parse_Error
    }

    for element in calls {
        call, call_ok := element.(json.Object)
        if !call_ok {
            return .Parse_Error
        }

        index, index_present, ierr := decode_optional_u64(call, "index")
        if ierr != .None {
            return ierr
        }

        slot := index_present ? index : 0
        if slot >= MAX_TOOL_CALLS {
            return .Too_Many_Tool_Calls
        }

        openai_ensure_tool_slot(decoder, int(slot)) or_return
        entry := &decoder.pending_tools[slot]

        id, _, id_err := decode_optional_string(call, "id")
        if id_err != .None {
            return id_err
        }

        if len(id) > 0 {
            if _, aerr := append(&entry.id, id); aerr != nil {
                return .Resource_Exhausted
            }
        }

        function, function_present, ferr := decode_optional_object(call, "function")
        if ferr != .None {
            return ferr
        }

        if !function_present {
            continue
        }

        name, _, name_err := decode_optional_string(function, "name")
        if name_err != .None {
            return name_err
        }

        if len(name) > 0 {
            if _, aerr := append(&entry.name, name); aerr != nil {
                return .Resource_Exhausted
            }
        }

        arguments, _, args_err := decode_optional_string(function, "arguments")
        if args_err != .None {
            return args_err
        }

        if len(arguments) > 0 {
            assert(len(entry.arguments) <= MAX_TOOL_CALL_BYTES, "retained arguments start bounded")

            if len(arguments) > MAX_TOOL_CALL_BYTES - len(entry.arguments) {
                return .Tool_Call_Too_Large
            }

            if _, aerr := append(&entry.arguments, arguments); aerr != nil {
                return .Resource_Exhausted
            }

            assert(len(entry.arguments) <= MAX_TOOL_CALL_BYTES, "retained arguments remain bounded")
        }
    }

    return .None
}

// Grow the pending-tool table so `slot` is addressable, allocating each new
// entry's fragment buffers in the turn allocator.
@(private)
openai_ensure_tool_slot :: proc(decoder: ^Openai_Chat_Decoder, slot: int) -> Transport_Error {
    assert(slot >= 0 && slot < MAX_TOOL_CALLS, "a tool slot stays within its bound")

    for len(decoder.pending_tools) <= slot {
        id, id_err := make([dynamic]byte, 0, decoder.allocator)
        name, name_err := make([dynamic]byte, 0, decoder.allocator)
        arguments, arguments_err := make([dynamic]byte, 0, decoder.allocator)
        if id_err != nil || name_err != nil || arguments_err != nil {
            return .Resource_Exhausted
        }

        entry := Openai_Pending_Tool {
            id        = id,
            name      = name,
            arguments = arguments,
        }
        if _, aerr := append(&decoder.pending_tools, entry); aerr != nil {
            return .Resource_Exhausted
        }
    }

    return .None
}

// Close any open block, then emit each named tool call as a start/stop pair with
// structurally validated arguments, then the one terminal `Stream_Done`.
@(private)
openai_chat_terminal :: proc(
    decoder: ^Openai_Chat_Decoder,
    events: ^[dynamic]Stream_Event,
    scratch_allocator: runtime.Allocator,
) -> Transport_Error {
    assert(decoder != nil, "the terminal event needs a decoder")
    assert(scratch_allocator.procedure != nil, "the terminal event needs a valid scratch allocator")

    if decoder.block_open {
        openai_close_block(decoder, events) or_return
    }

    tools := 0
    for &entry in decoder.pending_tools {
        if len(entry.name) == 0 {
            continue
        }

        arguments, arguments_err := openai_tool_arguments(entry.arguments[:], scratch_allocator)
        if arguments_err != .None {
            return arguments_err
        }

        id := Stream_Block_Id(decoder.next_id)
        decoder.next_id += 1

        if _, aerr := append(events, Stream_Block_Started{block_id = id, kind = .Tool}); aerr != nil {
            return .Resource_Exhausted
        }

        call := Tool_Call {
            id        = string(entry.id[:]),
            name      = string(entry.name[:]),
            arguments = arguments,
        }
        stopped := Stream_Block_Stopped {
            block_id = id,
            result = Stream_Tool_Block{call = call},
        }
        if _, aerr := append(events, stopped); aerr != nil {
            return .Resource_Exhausted
        }

        tools += 1
    }

    reason := decoder.pending_reason
    if tools > 0 {
        reason = .Tool_Calls
    }

    if _, aerr := append(events, Stream_Done{reason = reason, usage = decoder.pending_usage}); aerr != nil {
        return .Resource_Exhausted
    }

    return .None
}

// Validate a complete argument accumulation as exactly one JSON object. This is
// structural validation only; successful bytes remain unchanged, and an empty
// accumulation becomes `{}`.
@(private)
openai_tool_arguments :: proc(
    bytes: []byte,
    scratch_allocator: runtime.Allocator,
) -> (
    arguments: string,
    err: Transport_Error,
) {
    if len(bytes) == 0 {
        return "{}", .None
    }

    raw := string(bytes)
    value, _, parse_err := decode_json_object(raw, scratch_allocator)
    if parse_err != .None {
        return "", parse_err
    }

    json.destroy_value(value, scratch_allocator)

    return raw, .None
}

// Normalize the OpenAI-compatible finish-reason set. Values without a faithful
// neutral meaning stay explicitly unknown.
@(private)
openai_stop_reason :: proc(reason: string) -> Stop_Reason {
    switch reason {
    case "stop":
        return .End_Turn

    case "length":
        return .Max_Tokens

    case "content_filter":
        return .Content_Filter

    case "tool_calls":
        return .Tool_Calls

    case:
        return .Unknown
    }
}
