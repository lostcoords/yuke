package provider

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import ts "libs:testsupport"

@(private = "file")
test_anthropic_decoder :: proc(t: ^testing.T, allocator := context.temp_allocator) -> Anthropic_Decoder {
    return anthropic_decoder_init(allocator)
}

// Decode one payload through the queue contract and surface the single event
// Anthropic may append, matching the pre-queue return shape these tests inspect.
@(private = "file")
test_anthropic_decode :: proc(
    t: ^testing.T,
    decoder: ^Anthropic_Decoder,
    data: string,
    scratch_allocator := context.allocator,
) -> (
    Maybe(Stream_Event),
    Transport_Error,
) {
    events: [dynamic]Stream_Event
    events.allocator = context.temp_allocator

    err := anthropic_decoder_decode(decoder, data, &events, scratch_allocator)
    testing.expectf(t, len(events) <= 1, "%s: Anthropic decode appends at most one event", data)

    if len(events) == 1 {
        return events[0], err
    }

    return nil, err
}

// Finish through the queue contract; Anthropic must never append on finish.
@(private = "file")
test_anthropic_finish :: proc(t: ^testing.T, decoder: ^Anthropic_Decoder) -> Transport_Error {
    events: [dynamic]Stream_Event
    events.allocator = context.temp_allocator

    err := anthropic_decoder_finish(decoder, &events)
    testing.expect(t, len(events) == 0, "Anthropic finish never appends")

    return err
}

@(private = "file")
test_anthropic_expect_none :: proc(
    t: ^testing.T,
    decoder: ^Anthropic_Decoder,
    data: string,
    scratch_allocator := context.allocator,
) {
    event, err := test_anthropic_decode(t, decoder, data, scratch_allocator)
    testing.expectf(t, err == .None, "%s: want None, got %v", data, err)
    _, present := event.?
    testing.expectf(t, !present, "%s: event must not emit neutral output", data)
}

@(private = "file")
test_anthropic_start_message :: proc(t: ^testing.T, decoder: ^Anthropic_Decoder) {
    test_anthropic_expect_none(
        t,
        decoder,
        `{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":4,"cache_creation_input_tokens":2}}}`,
    )
}

@(private = "file")
test_anthropic_expect_started :: proc(
    t: ^testing.T,
    decoder: ^Anthropic_Decoder,
    data: string,
    block_id: Stream_Block_Id,
    kind: Stream_Block_Kind,
) {
    event, err := test_anthropic_decode(t, decoder, data, context.allocator)
    testing.expectf(t, err == .None, "%s: want None, got %v", data, err)

    stream_event, present := event.?
    if !testing.expect(t, present, "content_block_start must emit") {
        return
    }

    started, ok := stream_event.(Stream_Block_Started)
    if !testing.expect(t, ok, "content_block_start must emit Stream_Block_Started") {
        return
    }

    testing.expect_value(t, started.block_id, block_id)
    testing.expect_value(t, started.kind, kind)
}

@(private = "file")
test_anthropic_expect_stopped :: proc(
    t: ^testing.T,
    decoder: ^Anthropic_Decoder,
    data: string,
    block_id: Stream_Block_Id,
) -> Stream_Block_Stopped {
    event, err := test_anthropic_decode(t, decoder, data, context.allocator)
    testing.expectf(t, err == .None, "%s: want None, got %v", data, err)

    stream_event, present := event.?
    if !testing.expect(t, present, "content_block_stop must emit") {
        return {}
    }

    stopped, ok := stream_event.(Stream_Block_Stopped)
    if !testing.expect(t, ok, "content_block_stop must emit Stream_Block_Stopped") {
        return {}
    }

    testing.expect_value(t, stopped.block_id, block_id)

    return stopped
}

@(private = "file")
test_anthropic_done :: proc(t: ^testing.T, decoder: ^Anthropic_Decoder) -> Stream_Done {
    event, err := test_anthropic_decode(t, decoder, `{"type":"message_stop"}`, context.allocator)
    testing.expect_value(t, err, Transport_Error.None)

    stream_event, present := event.?
    if !testing.expect(t, present, "message_stop must emit a terminal event") {
        return {}
    }

    done, ok := stream_event.(Stream_Done)
    testing.expect(t, ok, "message_stop must emit Stream_Done")

    return done
}

@(test)
test_anthropic_text_lifecycle_and_usage_survive_scratch_arena :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    decoder := test_anthropic_decoder(t)
    test_anthropic_start_message(t, &decoder)
    test_anthropic_expect_started(
        t,
        &decoder,
        `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
        0,
        .Text,
    )

    event, err := test_anthropic_decode(
        t,
        &decoder,
        `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}`,
        context.allocator,
    )
    testing.expect_value(t, err, Transport_Error.None)

    stream_event, present := event.?
    if testing.expect(t, present, "non-empty text must emit") {
        text, ok := stream_event.(Stream_Text_Delta)
        testing.expect(t, ok, "text_delta must emit Stream_Text_Delta")
        testing.expect_value(t, text.block_id, Stream_Block_Id(0))
        testing.expect_value(t, text.text, "Hello")
    }

    test_anthropic_expect_none(
        t,
        &decoder,
        `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}`,
    )
    stopped := test_anthropic_expect_stopped(t, &decoder, `{"type":"content_block_stop","index":0}`, 0)
    _, text_ok := stopped.result.(Stream_Text_Block)
    testing.expect(t, text_ok, "text start must close with Stream_Text_Block")

    test_anthropic_expect_none(
        t,
        &decoder,
        `{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}`,
    )

    done := test_anthropic_done(t, &decoder)
    testing.expect_value(t, done.reason, Stop_Reason.End_Turn)
    testing.expect_value(t, done.usage.input, u64(16))
    testing.expect_value(t, done.usage.cache_read, u64(4))
    testing.expect_value(t, done.usage.cache_write, u64(2))
    testing.expect_value(t, done.usage.output, u64(3))
    testing.expect_value(t, done.usage.total, u64(19))
}

@(test)
test_anthropic_reasoning_and_redacted_blocks_preserve_terminal_metadata :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    decoder := test_anthropic_decoder(t)
    test_anthropic_start_message(t, &decoder)
    test_anthropic_expect_started(
        t,
        &decoder,
        `{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}`,
        0,
        .Reasoning,
    )

    event, err := test_anthropic_decode(
        t,
        &decoder,
        `{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"consider"}}`,
        context.allocator,
    )
    testing.expect_value(t, err, Transport_Error.None)

    stream_event, present := event.?
    if testing.expect(t, present, "reasoning must emit") {
        reasoning, ok := stream_event.(Stream_Reasoning_Delta)
        testing.expect(t, ok, "thinking_delta must emit Stream_Reasoning_Delta")
        testing.expect_value(t, reasoning.block_id, Stream_Block_Id(0))
        testing.expect_value(t, reasoning.text, "consider")
    }

    test_anthropic_expect_none(
        t,
        &decoder,
        `{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}`,
    )
    stopped := test_anthropic_expect_stopped(t, &decoder, `{"type":"content_block_stop","index":0}`, 0)
    reasoning, reasoning_ok := stopped.result.(Stream_Reasoning_Block)
    if testing.expect(t, reasoning_ok, "thinking start must close with Stream_Reasoning_Block") {
        testing.expect_value(t, reasoning.signature, "sig")
    }

    test_anthropic_expect_started(
        t,
        &decoder,
        `{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"opaque-data"}}`,
        1,
        .Redacted_Reasoning,
    )
    stopped = test_anthropic_expect_stopped(t, &decoder, `{"type":"content_block_stop","index":1}`, 1)
    redacted, redacted_ok := stopped.result.(Stream_Redacted_Reasoning_Block)
    if testing.expect(t, redacted_ok, "redacted start must close with Stream_Redacted_Reasoning_Block") {
        testing.expect_value(t, redacted.data, "opaque-data")
    }

    test_anthropic_expect_none(
        t,
        &decoder,
        `{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":8}}`,
    )
    _ = test_anthropic_done(t, &decoder)
}

@(test)
test_anthropic_tool_blocks_complete_in_content_order :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    decoder := test_anthropic_decoder(t)
    test_anthropic_start_message(t, &decoder)
    test_anthropic_expect_started(
        t,
        &decoder,
        `{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call_0","name":"ping","input":{}}}`,
        0,
        .Tool,
    )
    test_anthropic_expect_none(
        t,
        &decoder,
        `{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"x\":"}}`,
    )
    test_anthropic_expect_none(
        t,
        &decoder,
        `{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":" 1}"}}`,
    )

    stopped := test_anthropic_expect_stopped(t, &decoder, `{"type":"content_block_stop","index":0}`, 0)
    tool, tool_ok := stopped.result.(Stream_Tool_Block)
    if testing.expect(t, tool_ok, "tool start must close with Stream_Tool_Block") {
        testing.expect_value(t, tool.call.id, "call_0")
        testing.expect_value(t, tool.call.name, "ping")
        testing.expect_value(t, tool.call.arguments, `{"x": 1}`)
    }

    test_anthropic_expect_started(
        t,
        &decoder,
        `{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call_1","name":"empty","input":{}}}`,
        1,
        .Tool,
    )
    stopped = test_anthropic_expect_stopped(t, &decoder, `{"type":"content_block_stop","index":1}`, 1)
    tool, tool_ok = stopped.result.(Stream_Tool_Block)
    if testing.expect(t, tool_ok, "empty tool arguments still complete") {
        testing.expect_value(t, tool.call.arguments, "{}")
    }

    test_anthropic_expect_none(
        t,
        &decoder,
        `{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}`,
    )
    done := test_anthropic_done(t, &decoder)
    testing.expect_value(t, done.reason, Stop_Reason.Tool_Calls)
}

@(test)
test_anthropic_rejects_malformed_tool_arguments_at_block_stop :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    decoder := test_anthropic_decoder(t)
    test_anthropic_start_message(t, &decoder)
    test_anthropic_expect_started(
        t,
        &decoder,
        `{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call","name":"broken","input":{}}}`,
        0,
        .Tool,
    )
    test_anthropic_expect_none(
        t,
        &decoder,
        `{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{bad"}}`,
    )

    _, err := test_anthropic_decode(t, &decoder, `{"type":"content_block_stop","index":0}`, context.allocator)
    testing.expect_value(t, err, Transport_Error.Parse_Error)
}

@(test)
test_anthropic_stop_reason_mapping :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    Case :: struct {
        wire: string,
        want: Stop_Reason,
    }

    cases := [?]Case {
        {"end_turn", .End_Turn},
        {"tool_use", .Tool_Calls},
        {"max_tokens", .Max_Tokens},
        {"model_context_window_exceeded", .Max_Tokens},
        {"stop_sequence", .Stop_Sequence},
        {"refusal", .Content_Filter},
        {"pause_turn", .Unknown},
        {"future_reason", .Unknown},
    }

    for c in cases {
        decoder := test_anthropic_decoder(t)
        test_anthropic_start_message(t, &decoder)
        test_anthropic_expect_none(
            t,
            &decoder,
            strings.concatenate(
                {`{"type":"message_delta","delta":{"stop_reason":"`, c.wire, `"},"usage":{"output_tokens":0}}`},
                context.temp_allocator,
            ),
        )

        done := test_anthropic_done(t, &decoder)
        testing.expectf(t, done.reason == c.want, "%s: want %v, got %v", c.wire, c.want, done.reason)
    }
}

@(test)
test_anthropic_rejects_too_many_tool_calls :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    decoder := test_anthropic_decoder(t)
    test_anthropic_start_message(t, &decoder)

    for index in 0 ..< MAX_TOOL_CALLS {
        index_text := fmt.tprintf("%d", index)
        test_anthropic_expect_started(
            t,
            &decoder,
            strings.concatenate(
                {
                    `{"type":"content_block_start","index":`,
                    index_text,
                    `,"content_block":{"type":"tool_use","id":"call_`,
                    index_text,
                    `","name":"tool","input":{}}}`,
                },
                context.temp_allocator,
            ),
            Stream_Block_Id(index),
            .Tool,
        )
        _ = test_anthropic_expect_stopped(
            t,
            &decoder,
            strings.concatenate({`{"type":"content_block_stop","index":`, index_text, `}`}, context.temp_allocator),
            Stream_Block_Id(index),
        )
    }

    data := strings.concatenate(
        {
            `{"type":"content_block_start","index":`,
            fmt.tprintf("%d", MAX_TOOL_CALLS),
            `,"content_block":{"type":"tool_use","id":"overflow","name":"tool","input":{}}}`,
        },
        context.temp_allocator,
    )
    _, err := test_anthropic_decode(t, &decoder, data, context.allocator)
    testing.expect_value(t, err, Transport_Error.Too_Many_Tool_Calls)

    event, after_err := test_anthropic_decode(t, &decoder, `{"type":"message_stop"}`, context.allocator)
    testing.expect_value(t, after_err, Transport_Error.None)
    _, present := event.?
    testing.expect(t, !present, "a terminal decoder ignores later events")
}

@(test)
test_anthropic_enforces_tool_argument_limit_per_call :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    decoder := test_anthropic_decoder(t)
    test_anthropic_start_message(t, &decoder)
    test_anthropic_expect_started(
        t,
        &decoder,
        `{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call","name":"tool","input":{}}}`,
        0,
        .Tool,
    )

    fragment := strings.repeat("a", MAX_TOOL_CALL_BYTES + 1, context.temp_allocator)
    data := strings.concatenate(
        {
            `{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"`,
            fragment,
            `"}}`,
        },
        context.temp_allocator,
    )
    _, err := test_anthropic_decode(t, &decoder, data, context.allocator)
    testing.expect_value(t, err, Transport_Error.Tool_Call_Too_Large)
}

@(test)
test_anthropic_rejects_invalid_block_lifecycles :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    Case :: struct {
        prepare: []string,
        data:    string,
    }

    cases := [?]Case {
        {nil, `{"type":7}`},
        {nil, `{"type":"message_start","message":[]}`},
        {nil, `{"type":"message_start","message":{}}`},
        {{`{"type":"message_start","message":{"usage":{}}}`}, `{"type":"message_start","message":{"usage":{}}}`},
        {
            {`{"type":"message_start","message":{"usage":{}}}`},
            `{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}`,
        },
        {
            {`{"type":"message_start","message":{"usage":{}}}`},
            `{"type":"content_block_start","index":0,"content_block":{"type":"future"}}`,
        },
        {
            {`{"type":"message_start","message":{"usage":{}}}`},
            `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"initial"}}`,
        },
        {
            {`{"type":"message_start","message":{"usage":{}}}`},
            `{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call","name":"tool"}}`,
        },
        {
            {`{"type":"message_start","message":{"usage":{}}}`},
            `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"orphan"}}`,
        },
        {
            {
                `{"type":"message_start","message":{"usage":{}}}`,
                `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
            },
            `{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"wrong index"}}`,
        },
        {
            {
                `{"type":"message_start","message":{"usage":{}}}`,
                `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
            },
            `{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"wrong kind"}}`,
        },
        {
            {
                `{"type":"message_start","message":{"usage":{}}}`,
                `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
            },
            `{"type":"content_block_delta","index":0,"delta":{"type":"future_delta"}}`,
        },
        {{`{"type":"message_start","message":{"usage":{}}}`}, `{"type":"content_block_stop","index":0}`},
        {
            {
                `{"type":"message_start","message":{"usage":{}}}`,
                `{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}`,
            },
            `{"type":"content_block_stop","index":0}`,
        },
        {{`{"type":"message_start","message":{"usage":{}}}`}, `{"type":"message_delta","usage":{"output_tokens":0}}`},
        {{`{"type":"message_start","message":{"usage":{}}}`}, `{"type":"message_stop"}`},
    }

    for c in cases {
        decoder := test_anthropic_decoder(t)
        for data in c.prepare {
            event, err := test_anthropic_decode(t, &decoder, data, context.allocator)
            testing.expectf(t, err == .None, "%s: prepare got %v", data, err)
            _ = event
        }

        _, err := test_anthropic_decode(t, &decoder, c.data, context.allocator)
        testing.expectf(t, err == .Parse_Error, "%s: want Parse_Error, got %v", c.data, err)

        event, after_err := test_anthropic_decode(t, &decoder, `{"type":"message_stop"}`, context.allocator)
        testing.expect_value(t, after_err, Transport_Error.None)
        _, present := event.?
        testing.expect(t, !present, "parse failure latches the decoder terminal")
    }
}

@(test)
test_anthropic_ignores_only_non_material_lifecycle_events :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    decoder := test_anthropic_decoder(t)
    test_anthropic_expect_none(t, &decoder, "  \n\t")
    test_anthropic_expect_none(t, &decoder, `{"unknown":true}`)
    test_anthropic_expect_none(t, &decoder, `{"type":"ping","index":-1,"future":[]}`)

    test_anthropic_start_message(t, &decoder)
    test_anthropic_expect_none(
        t,
        &decoder,
        `{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}`,
    )
    _ = test_anthropic_done(t, &decoder)
}

@(test)
test_anthropic_error_and_eof_are_terminal :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    errored := test_anthropic_decoder(t)
    _, err := test_anthropic_decode(
        t,
        &errored,
        `{"type":"error","error":{"type":"overloaded_error"}}`,
        context.allocator,
    )
    testing.expect_value(t, err, Transport_Error.Server_Error)
    testing.expect_value(t, test_anthropic_finish(t, &errored), Transport_Error.None)

    event, after_err := test_anthropic_decode(t, &errored, `{not json`, context.allocator)
    testing.expect_value(t, after_err, Transport_Error.None)
    _, present := event.?
    testing.expect(t, !present, "events after a provider error are ignored")

    truncated := test_anthropic_decoder(t)
    test_anthropic_start_message(t, &truncated)
    test_anthropic_expect_started(
        t,
        &truncated,
        `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
        0,
        .Text,
    )
    testing.expect_value(t, test_anthropic_finish(t, &truncated), Transport_Error.Stream_Truncated)
    testing.expect_value(t, test_anthropic_finish(t, &truncated), Transport_Error.None)

    completed := test_anthropic_decoder(t)
    test_anthropic_start_message(t, &completed)
    test_anthropic_expect_none(
        t,
        &completed,
        `{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}`,
    )
    _ = test_anthropic_done(t, &completed)
    event, after_err = test_anthropic_decode(t, &completed, `{"type":"message_stop"}`, context.allocator)
    testing.expect_value(t, after_err, Transport_Error.None)
    _, present = event.?
    testing.expect(t, !present, "message_stop emits at most once")
    testing.expect_value(t, test_anthropic_finish(t, &completed), Transport_Error.None)
}

@(test)
test_anthropic_surfaces_turn_allocation_failures :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    start := `{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call","name":"tool","input":{}}}`
    reached_success := false
    for fail_at in 0 ..< 8 {
        arena: mem.Dynamic_Arena
        mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
        defer mem.dynamic_arena_destroy(&arena)

        failing: ts.Failing_Allocator
        ts.failing_allocator_init(&failing, mem.dynamic_arena_allocator(&arena), fail_at)

        decoder := test_anthropic_decoder(t, ts.failing_allocator(&failing))
        test_anthropic_start_message(t, &decoder)

        _, err := test_anthropic_decode(t, &decoder, start, context.temp_allocator)
        if err == .None {
            reached_success = true
            break
        }

        testing.expect_value(t, err, Transport_Error.Resource_Exhausted)
    }
    testing.expect(t, reached_success, "fault sweep must eventually pass every tool-start allocation")

    // Production tears a failed decode down with the turn arena, never field by
    // field; these decoders do the same.
    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&arena)

    failing: ts.Failing_Allocator
    ts.failing_allocator_init(&failing, mem.dynamic_arena_allocator(&arena), 0)
    text_decoder := test_anthropic_decoder(t, ts.failing_allocator(&failing))
    test_anthropic_start_message(t, &text_decoder)
    test_anthropic_expect_started(
        t,
        &text_decoder,
        `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
        0,
        .Text,
    )
    _, text_err := test_anthropic_decode(
        t,
        &text_decoder,
        `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}`,
        context.temp_allocator,
    )
    testing.expect_value(t, text_err, Transport_Error.Resource_Exhausted)

    ts.failing_allocator_init(&failing, mem.dynamic_arena_allocator(&arena), 100)
    argument_decoder := test_anthropic_decoder(t, ts.failing_allocator(&failing))
    test_anthropic_start_message(t, &argument_decoder)
    test_anthropic_expect_started(t, &argument_decoder, start, 0, .Tool)
    failing.fail_at = failing.count
    _, argument_err := test_anthropic_decode(
        t,
        &argument_decoder,
        `{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}`,
        context.temp_allocator,
    )
    testing.expect_value(t, argument_err, Transport_Error.Resource_Exhausted)
}

@(test)
test_anthropic_surfaces_scratch_arena_exhaustion :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    decoder := test_anthropic_decoder(t)
    failing: ts.Failing_Allocator
    ts.failing_allocator_init(&failing, context.allocator, 0)

    _, err := test_anthropic_decode(t, &decoder, `{"type":"message_start"}`, ts.failing_allocator(&failing))
    testing.expect_value(t, err, Transport_Error.Resource_Exhausted)
    testing.expect_value(t, test_anthropic_finish(t, &decoder), Transport_Error.None)

    ts.failing_allocator_init(&failing, context.allocator, 0)
    raw := `{"x":1}`
    _, arguments_err := tool_arguments(transmute([]byte)raw, ts.failing_allocator(&failing))
    testing.expect_value(t, arguments_err, Transport_Error.Resource_Exhausted)
}

#assert(len(Stop_Reason) == 6)
#assert(len(Stream_Block_Kind) == 4)
