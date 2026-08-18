package provider

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import "libs:json"

// Tool state retained only while its content block is open. Strings and
// argument bytes live in the turn allocator.
@(private)
Anthropic_Open_Tool :: struct {
    // Provider-issued tool-use id.
    id:        string,

    // Complete tool name from the block start.
    name:      string,

    // Concatenated, decoded `partial_json` fragments.
    arguments: [dynamic]byte,
}

// One currently open Anthropic content block. Anthropic block lifecycles are
// sequential: a block must stop before the next index starts.
@(private)
Anthropic_Open_Block :: struct {
    // Provider content-array index, also used as the neutral turn-local id.
    index:         u64,

    // Neutral shape established by the block start.
    kind:          Stream_Block_Kind,

    // Visible-thinking signature retained until block stop.
    signature:     string,

    // Opaque safety-redacted thinking retained until block stop.
    redacted_data: string,

    // Tool descriptor and partial arguments; meaningful only for `.Tool`.
    tool:          Anthropic_Open_Tool,
}

// Stateful decoder for Anthropic Messages SSE payloads. `allocator` must be the
// owning turn's arena: every retained string is allocated there and nothing is
// ever freed individually, not even on a partial-failure path. JSON trees use a
// separate per-event allocator that must not alias it.
Anthropic_Decoder :: struct {
    // Turn-lifetime owner for retained stream data.
    allocator:      runtime.Allocator,

    // Last normalized reason reported by `message_delta`.
    pending_reason: Stop_Reason,

    // Usage folded across `message_start` and `message_delta`.
    pending_usage:  Usage,

    // The only content block currently accepting deltas.
    open_block:     Anthropic_Open_Block,

    // Next dense Anthropic content-array index.
    next_index:     u64,

    // Number of tool blocks opened in this turn.
    tool_count:     int,

    // Provider ids already accepted in this turn, for strict result correlation.
    tool_ids:       [dynamic]string,

    // A valid `message_start` established the stream.
    started:        bool,

    // The one terminal `message_delta` has been folded.
    metadata_done:  bool,

    // A content block is currently open.
    block_open:     bool,

    // Terminal event or error has already been observed.
    done:           bool,
}

// Initialize an empty decoder. Every later decode allocates its retained output
// into `allocator` and frees none of it.
anthropic_decoder_init :: proc(allocator := context.allocator) -> Anthropic_Decoder {
    assert(allocator.procedure != nil, "Anthropic decoder needs a valid turn allocator")

    decoder := Anthropic_Decoder {
        allocator      = allocator,
        pending_reason = .Unknown,
    }
    decoder.tool_ids.allocator = allocator

    return decoder
}

// Decode one SSE `data` payload, appending its 0 or 1 neutral events to
// `events`. Empty payloads, unknown lifecycle events, and events after a
// terminal outcome append nothing. An appended event is retained in the
// decoder's allocator; `scratch_allocator` holds only the per-call JSON tree
// and must be a bulk-reclaimable scratch scope the turn resets each event.
anthropic_decoder_decode :: proc(
    decoder: ^Anthropic_Decoder,
    data: string,
    events: ^[dynamic]Stream_Event,
    scratch_allocator := context.allocator,
) -> Transport_Error {
    assert(decoder != nil, "Anthropic decode needs a decoder")
    assert(events != nil, "Anthropic decode needs an event queue")
    assert(decoder.allocator.procedure != nil, "Anthropic decoder must be initialized")
    assert(scratch_allocator.procedure != nil, "Anthropic decode needs a valid scratch allocator")
    assert(
        scratch_allocator.procedure != decoder.allocator.procedure || scratch_allocator.data != decoder.allocator.data,
        "Anthropic event scratch must not alias the turn allocator",
    )
    assert(decoder.tool_count >= 0 && decoder.tool_count <= MAX_TOOL_CALLS, "tool count stays within its bound")
    assert(!decoder.block_open || decoder.started, "an open block belongs to a started message")
    assert(!decoder.metadata_done || !decoder.block_open, "terminal metadata follows every content block")

    if decoder.done || len(strings.trim_space(data)) == 0 {
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

    event: Maybe(Stream_Event)
    err: Transport_Error

    switch event_type {
    case "message_start":
        event, err = anthropic_decode_message_start(decoder, object)

    case "content_block_start":
        event, err = anthropic_decode_content_block_start(decoder, object)

    case "content_block_delta":
        event, err = anthropic_decode_content_block_delta(decoder, object)

    case "content_block_stop":
        event, err = anthropic_decode_content_block_stop(decoder, object, scratch_allocator)

    case "message_delta":
        event, err = anthropic_decode_message_delta(decoder, object)

    case "message_stop":
        event, err = anthropic_terminal_event(decoder)
        decoder.done = true

    case "error":
        decoder.done = true
        return .Server_Error

    case:
        return .None
    }

    if err != .None {
        decoder.done = true
        return err
    }

    assert(decoder.tool_count >= 0 && decoder.tool_count <= MAX_TOOL_CALLS, "successful decode preserves bounds")

    if stream_event, ok := event.?; ok {
        append(events, stream_event)
    }

    return .None
}

// Finish at transport EOF. Anthropic requires an explicit `message_stop`; a
// clean HTTP close before it is still a truncated stream. Anthropic never
// appends on finish; `events` is present only for the uniform decoder contract.
anthropic_decoder_finish :: proc(
    decoder: ^Anthropic_Decoder,
    events: ^[dynamic]Stream_Event,
    scratch_allocator := context.allocator,
) -> Transport_Error {
    assert(decoder != nil, "Anthropic finish needs a decoder")
    assert(events != nil, "Anthropic finish needs an event queue")
    assert(decoder.allocator.procedure != nil, "Anthropic decoder must be initialized")

    if decoder.done {
        return .None
    }

    decoder.done = true
    return .Stream_Truncated
}

// Prompt-side counts with the cache subsets folded into `input`. Read from both stream events,
// since compat servers fill only the cumulative `message_delta`.
@(private)
anthropic_prompt_usage :: proc(usage: json.Object) -> (input: u64, cache_read: u64, cache_write: u64) {
    cache_read = decode_usage_u64(usage, "cache_read_input_tokens")
    cache_write = decode_usage_u64(usage, "cache_creation_input_tokens")
    input = decode_usage_u64(usage, "input_tokens")
    input = intrinsics.saturating_add(input, cache_read)
    input = intrinsics.saturating_add(input, cache_write)

    return
}

// Establish the one message lifecycle and read prompt-side usage. Event is always nil.
@(private)
anthropic_decode_message_start :: proc(
    decoder: ^Anthropic_Decoder,
    object: json.Object,
) -> (
    Maybe(Stream_Event),
    Transport_Error,
) {
    assert(decoder != nil, "message_start needs a decoder")
    assert(!decoder.done, "message_start cannot run after completion")

    if decoder.started || decoder.metadata_done || decoder.block_open {
        return nil, .Parse_Error
    }

    message, present, err := decode_optional_object(object, "message")
    if err != .None {
        return nil, err
    }

    if !present {
        return nil, .Parse_Error
    }

    usage, usage_present, uerr := decode_optional_object(message, "usage")
    if uerr != .None {
        return nil, uerr
    }

    if !usage_present {
        return nil, .Parse_Error
    }

    input, cache_read, cache_write := anthropic_prompt_usage(usage)

    decoder.pending_usage.input = input
    decoder.pending_usage.cache_read = cache_read
    decoder.pending_usage.cache_write = cache_write
    decoder.started = true

    return nil, .None
}

// Open the next dense content-array position and establish its neutral shape.
// Initial visible content must be empty: one provider payload maps to at most
// one neutral event, so a block start cannot also carry a delta.
@(private)
anthropic_decode_content_block_start :: proc(
    decoder: ^Anthropic_Decoder,
    object: json.Object,
) -> (
    Maybe(Stream_Event),
    Transport_Error,
) {
    assert(decoder != nil, "content_block_start needs a decoder")
    assert(!decoder.done, "content_block_start cannot run after completion")

    if !decoder.started || decoder.metadata_done || decoder.block_open {
        return nil, .Parse_Error
    }

    index, index_present, ierr := decode_optional_u64(object, "index")
    if ierr != .None {
        return nil, ierr
    }

    if !index_present || index != decoder.next_index {
        return nil, .Parse_Error
    }

    block, present, berr := decode_optional_object(object, "content_block")
    if berr != .None {
        return nil, berr
    }

    if !present {
        return nil, .Parse_Error
    }

    block_type, type_present, terr := decode_optional_string(block, "type")
    if terr != .None {
        return nil, terr
    }

    if !type_present {
        return nil, .Parse_Error
    }

    open_block := Anthropic_Open_Block {
        index = index,
    }

    switch block_type {
    case "text":
        text, text_present, text_err := decode_optional_string(block, "text")
        if text_err != .None {
            return nil, text_err
        }

        if !text_present || len(text) != 0 {
            return nil, .Parse_Error
        }

        open_block.kind = .Text

    case "thinking":
        thinking, thinking_present, thinking_err := decode_optional_string(block, "thinking")
        if thinking_err != .None {
            return nil, thinking_err
        }

        if !thinking_present || len(thinking) != 0 {
            return nil, .Parse_Error
        }

        signature, signature_present, signature_err := decode_optional_string(block, "signature")
        if signature_err != .None {
            return nil, signature_err
        }

        if signature_present && len(signature) > 0 {
            owned := strings.clone(signature, decoder.allocator)

            open_block.signature = owned
        }

        open_block.kind = .Reasoning

    case "redacted_thinking":
        data, data_present, data_err := decode_optional_string(block, "data")
        if data_err != .None {
            return nil, data_err
        }

        if !data_present || len(data) == 0 {
            return nil, .Parse_Error
        }

        owned := strings.clone(data, decoder.allocator)

        open_block.kind = .Redacted_Reasoning
        open_block.redacted_data = owned

    case "tool_use":
        if decoder.tool_count == MAX_TOOL_CALLS {
            return nil, .Too_Many_Tool_Calls
        }

        id, id_present, id_err := decode_optional_string(block, "id")
        if id_err != .None {
            return nil, id_err
        }

        name, name_present, name_err := decode_optional_string(block, "name")
        if name_err != .None {
            return nil, name_err
        }

        input, input_present, input_err := decode_optional_object(block, "input")
        if input_err != .None {
            return nil, input_err
        }

        if !id_present || len(id) == 0 || !name_present || len(name) == 0 || !input_present || len(input) != 0 {
            return nil, .Parse_Error
        }

        for prior in decoder.tool_ids {
            if id == prior {
                return nil, .Parse_Error
            }
        }

        owned_id := strings.clone(id, decoder.allocator)

        owned_name := strings.clone(name, decoder.allocator)

        arguments := make([dynamic]byte, 0, decoder.allocator)

        open_block.kind = .Tool
        open_block.tool = {
            id        = owned_id,
            name      = owned_name,
            arguments = arguments,
        }
        append(&decoder.tool_ids, owned_id)
        decoder.tool_count += 1

    case:
        return nil, .Parse_Error
    }

    decoder.open_block = open_block
    decoder.block_open = true

    stream_event: Stream_Event = Stream_Block_Started {
        block_id = Stream_Block_Id(index),
        kind     = open_block.kind,
    }

    return stream_event, .None
}

// Surface visible deltas or retain terminal metadata for the currently open
// block.
@(private)
anthropic_decode_content_block_delta :: proc(
    decoder: ^Anthropic_Decoder,
    object: json.Object,
) -> (
    Maybe(Stream_Event),
    Transport_Error,
) {
    assert(decoder != nil, "content_block_delta needs a decoder")
    assert(!decoder.done, "content_block_delta cannot run after completion")

    if !decoder.started || decoder.metadata_done || !decoder.block_open {
        return nil, .Parse_Error
    }

    index, index_present, ierr := decode_optional_u64(object, "index")
    if ierr != .None {
        return nil, ierr
    }

    if !index_present || index != decoder.open_block.index {
        return nil, .Parse_Error
    }

    delta, present, derr := decode_optional_object(object, "delta")
    if derr != .None {
        return nil, derr
    }

    if !present {
        return nil, .Parse_Error
    }

    delta_type, type_present, terr := decode_optional_string(delta, "type")
    if terr != .None {
        return nil, terr
    }

    if !type_present {
        return nil, .Parse_Error
    }

    switch delta_type {
    case "text_delta":
        if decoder.open_block.kind != .Text {
            return nil, .Parse_Error
        }

        text, text_present, text_err := decode_optional_string(delta, "text")
        if text_err != .None {
            return nil, text_err
        }

        if !text_present {
            return nil, .Parse_Error
        }

        if len(text) == 0 {
            return nil, .None
        }

        owned := strings.clone(text, decoder.allocator)

        stream_event: Stream_Event = Stream_Text_Delta {
            block_id = Stream_Block_Id(index),
            text     = owned,
        }
        return stream_event, .None

    case "thinking_delta":
        if decoder.open_block.kind != .Reasoning {
            return nil, .Parse_Error
        }

        thinking, thinking_present, thinking_err := decode_optional_string(delta, "thinking")
        if thinking_err != .None {
            return nil, thinking_err
        }

        if !thinking_present {
            return nil, .Parse_Error
        }

        if len(thinking) == 0 {
            return nil, .None
        }

        owned := strings.clone(thinking, decoder.allocator)

        stream_event: Stream_Event = Stream_Reasoning_Delta {
            block_id = Stream_Block_Id(index),
            text     = owned,
        }
        return stream_event, .None

    case "signature_delta":
        if decoder.open_block.kind != .Reasoning || len(decoder.open_block.signature) > 0 {
            return nil, .Parse_Error
        }

        signature, signature_present, signature_err := decode_optional_string(delta, "signature")
        if signature_err != .None {
            return nil, signature_err
        }

        if !signature_present || len(signature) == 0 {
            return nil, .Parse_Error
        }

        owned := strings.clone(signature, decoder.allocator)

        decoder.open_block.signature = owned

        return nil, .None

    case "input_json_delta":
        if decoder.open_block.kind != .Tool {
            return nil, .Parse_Error
        }

        fragment, fragment_present, fragment_err := decode_optional_string(delta, "partial_json")
        if fragment_err != .None {
            return nil, fragment_err
        }

        if !fragment_present {
            return nil, .Parse_Error
        }

        assert(len(decoder.open_block.tool.arguments) <= MAX_TOOL_CALL_BYTES, "retained arguments start bounded")

        if len(fragment) > MAX_TOOL_CALL_BYTES - len(decoder.open_block.tool.arguments) {
            return nil, .Tool_Call_Too_Large
        }

        append(&decoder.open_block.tool.arguments, fragment)

        assert(len(decoder.open_block.tool.arguments) <= MAX_TOOL_CALL_BYTES, "retained arguments remain bounded")

        return nil, .None

    case:
        return nil, .Parse_Error
    }
}

// Close the currently open block and emit its complete replayable value.
@(private)
anthropic_decode_content_block_stop :: proc(
    decoder: ^Anthropic_Decoder,
    object: json.Object,
    scratch_allocator: runtime.Allocator,
) -> (
    Maybe(Stream_Event),
    Transport_Error,
) {
    assert(decoder != nil, "content_block_stop needs a decoder")
    assert(!decoder.done, "content_block_stop cannot run after completion")

    if !decoder.started || decoder.metadata_done || !decoder.block_open {
        return nil, .Parse_Error
    }

    index, index_present, index_err := decode_optional_u64(object, "index")
    if index_err != .None {
        return nil, index_err
    }

    if !index_present || index != decoder.open_block.index {
        return nil, .Parse_Error
    }

    result: Stream_Block_Result

    switch decoder.open_block.kind {
    case .Text:
        result = Stream_Text_Block{}

    case .Reasoning:
        if len(decoder.open_block.signature) == 0 {
            return nil, .Parse_Error
        }

        result = Stream_Reasoning_Block {
            signature = decoder.open_block.signature,
        }

    case .Redacted_Reasoning:
        assert(len(decoder.open_block.redacted_data) > 0, "an open redacted block retains provider data")

        result = Stream_Redacted_Reasoning_Block {
            data = decoder.open_block.redacted_data,
        }

    case .Tool:
        assert(decoder.tool_count > 0, "an open tool block contributes to the tool count")
        assert(len(decoder.open_block.tool.id) > 0, "an open tool block retains its id")
        assert(len(decoder.open_block.tool.name) > 0, "an open tool block retains its name")

        arguments, arguments_err := tool_arguments(decoder.open_block.tool.arguments[:], scratch_allocator)
        if arguments_err != .None {
            return nil, arguments_err
        }

        result = Stream_Tool_Block {
            call = {id = decoder.open_block.tool.id, name = decoder.open_block.tool.name, arguments = arguments},
        }
    }

    stream_event: Stream_Event = Stream_Block_Stopped {
        block_id = Stream_Block_Id(index),
        result   = result,
    }

    decoder.open_block = {}
    decoder.block_open = false
    decoder.next_index += 1

    assert(decoder.next_index <= MAX_EXACT_JSON_INTEGER + 1, "the next dense block index stays exactly representable")

    return stream_event, .None
}

// Fold the one terminal metadata event after every content block has closed. Event is always nil.
@(private)
anthropic_decode_message_delta :: proc(
    decoder: ^Anthropic_Decoder,
    object: json.Object,
) -> (
    Maybe(Stream_Event),
    Transport_Error,
) {
    assert(decoder != nil, "message_delta needs a decoder")
    assert(!decoder.done, "message_delta cannot run after completion")

    if !decoder.started || decoder.metadata_done || decoder.block_open {
        return nil, .Parse_Error
    }

    delta, delta_present, derr := decode_optional_object(object, "delta")
    if derr != .None {
        return nil, derr
    }

    if !delta_present {
        return nil, .Parse_Error
    }

    reason, reason_present, rerr := decode_optional_string(delta, "stop_reason")
    if rerr != .None {
        return nil, rerr
    }

    if !reason_present {
        return nil, .Parse_Error
    }

    usage, usage_present, uerr := decode_optional_object(object, "usage")
    if uerr != .None {
        return nil, uerr
    }

    if !usage_present {
        return nil, .Parse_Error
    }

    decoder.pending_reason = anthropic_stop_reason(reason)
    decoder.pending_usage.output = decode_usage_u64(usage, "output_tokens")

    // Thinking tokens are a subset of output, reported only on the final message_delta.
    if details, present, terr := decode_optional_object(usage, "output_tokens_details"); terr == .None && present {
        decoder.pending_usage.reasoning = decode_usage_u64(details, "thinking_tokens")
    }

    // Max-fold: compat servers report prompt usage only here, real Anthropic repeats what it
    // already gave. Max recovers the real count without double-counting.
    input, cache_read, cache_write := anthropic_prompt_usage(usage)
    decoder.pending_usage.input = max(decoder.pending_usage.input, input)
    decoder.pending_usage.cache_read = max(decoder.pending_usage.cache_read, cache_read)
    decoder.pending_usage.cache_write = max(decoder.pending_usage.cache_write, cache_write)

    decoder.metadata_done = true

    return nil, .None
}

// Normalize Anthropic's current stop-reason set. Values without a faithful
// neutral meaning, including `pause_turn`, stay explicitly unknown.
@(private)
anthropic_stop_reason :: proc(reason: string) -> Stop_Reason {
    switch reason {
    case "end_turn":
        return .End_Turn

    case "tool_use":
        return .Tool_Calls

    case "max_tokens", "model_context_window_exceeded":
        return .Max_Tokens

    case "stop_sequence":
        return .Stop_Sequence

    case "refusal":
        return .Content_Filter

    case:
        return .Unknown
    }
}

// Build the one terminal event after the provider has closed every content
// block and delivered terminal metadata.
@(private)
anthropic_terminal_event :: proc(decoder: ^Anthropic_Decoder) -> (Maybe(Stream_Event), Transport_Error) {
    assert(decoder != nil, "terminal event needs a decoder")
    assert(!decoder.done, "terminal event is emitted at most once")

    if !decoder.started || !decoder.metadata_done || decoder.block_open {
        return nil, .Parse_Error
    }

    usage := decoder.pending_usage
    usage.total = intrinsics.saturating_add(usage.input, usage.output)

    reason := decoder.pending_reason
    if decoder.tool_count > 0 {
        reason = .Tool_Calls
    }

    stream_event: Stream_Event = Stream_Done {
        reason = reason,
        usage  = usage,
    }
    return stream_event, .None
}
