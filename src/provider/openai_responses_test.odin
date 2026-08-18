package provider

import "core:mem"
import "core:testing"

// Drive a fresh decoder over a list of SSE `data` payloads and finish at EOF,
// collecting every neutral event. Returns the first decode error, or the finish
// error when every payload decoded cleanly.
@(private = "file")
test_responses_drive :: proc(
    t: ^testing.T,
    payloads: []string,
) -> (
    events: [dynamic]Stream_Event,
    err: Transport_Error,
) {
    events.allocator = context.temp_allocator
    decoder := openai_responses_decoder_init(context.temp_allocator)

    scratch_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch_arena, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&scratch_arena)
    scratch := mem.dynamic_arena_allocator(&scratch_arena)

    for data in payloads {
        e := openai_responses_decoder_decode(&decoder, data, &events, scratch)
        if e != .None do return events, e
    }

    err = openai_responses_decoder_finish(&decoder, &events)
    return events, err
}

@(private = "file")
test_responses_last_done :: proc(t: ^testing.T, events: [dynamic]Stream_Event) -> Stream_Done {
    if !testing.expect(t, len(events) > 0, "a terminated stream has at least one event") do return {}

    done, ok := events[len(events) - 1].(Stream_Done)
    testing.expect(t, ok, "the final event is Stream_Done")

    return done
}

@(private = "file")
test_responses_expect_started :: proc(
    t: ^testing.T,
    event: Stream_Event,
    block_id: Stream_Block_Id,
    kind: Stream_Block_Kind,
) {
    started, ok := event.(Stream_Block_Started)
    if !testing.expect(t, ok, "event must be Stream_Block_Started") do return

    testing.expect_value(t, started.block_id, block_id)
    testing.expect_value(t, started.kind, kind)
}

@(private = "file")
test_responses_expect_stopped :: proc(
    t: ^testing.T,
    event: Stream_Event,
    block_id: Stream_Block_Id,
) -> Stream_Block_Result {
    stopped, ok := event.(Stream_Block_Stopped)
    if !testing.expect(t, ok, "event must be Stream_Block_Stopped") do return nil

    testing.expect_value(t, stopped.block_id, block_id)

    return stopped.result
}

@(test)
test_responses_stream_yields_text_and_done_with_usage :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string {
        `{"type":"response.output_text.delta","delta":"Hel"}`,
        `{"type":"response.output_text.delta","delta":"lo"}`,
        `{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5}}}`,
    }
    events, err := test_responses_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    if !testing.expect(t, len(events) == 5, "two text deltas then done emits five events") do return

    test_responses_expect_started(t, events[0], 0, .Text)

    first, first_ok := events[1].(Stream_Text_Delta)
    if testing.expect(t, first_ok, "second event is a text delta") do testing.expect_value(t, first.text, "Hel")

    second, second_ok := events[2].(Stream_Text_Delta)
    if testing.expect(t, second_ok, "third event is a text delta") do testing.expect_value(t, second.text, "lo")

    _, text_ok := test_responses_expect_stopped(t, events[3], 0).(Stream_Text_Block)
    testing.expect(t, text_ok, "text block closes with Stream_Text_Block")

    done := test_responses_last_done(t, events)
    testing.expect_value(t, done.reason, Stop_Reason.End_Turn)
    testing.expect_value(t, done.usage.input, u64(3))
    testing.expect_value(t, done.usage.output, u64(2))
    testing.expect_value(t, done.usage.total, u64(5))
}

@(test)
test_responses_stream_captures_reasoning_signature_on_item_done :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string {
        `{"type":"response.output_item.added","item":{"type":"reasoning","id":"rs_1"}}`,
        `{"type":"response.reasoning_summary_text.delta","delta":"Th"}`,
        `{"type":"response.reasoning_text.delta","delta":"ink"}`,
        `{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","encrypted_content":"sig1"}}`,
        `{"type":"response.completed","response":{"status":"completed"}}`,
    }
    events, err := test_responses_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    if !testing.expect(t, len(events) == 5, "reasoning deltas then a signed close emits five events") do return

    test_responses_expect_started(t, events[0], 0, .Reasoning)

    first, first_ok := events[1].(Stream_Reasoning_Delta)
    if testing.expect(t, first_ok, "second event is a reasoning delta") do testing.expect_value(t, first.text, "Th")

    second, second_ok := events[2].(Stream_Reasoning_Delta)
    if testing.expect(t, second_ok, "third event is a reasoning delta") do testing.expect_value(t, second.text, "ink")

    reasoning, reasoning_ok := test_responses_expect_stopped(t, events[3], 0).(Stream_Reasoning_Block)
    if testing.expect(t, reasoning_ok, "the reasoning block closes with its signature") do testing.expect_value(t, reasoning.signature, "sig1")

    done := test_responses_last_done(t, events)
    testing.expect_value(t, done.reason, Stop_Reason.End_Turn)
}

@(test)
test_responses_stream_synthesizes_encrypted_only_reasoning_block :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string {
        `{"type":"response.output_item.added","item":{"type":"reasoning","id":"rs_1"}}`,
        `{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","encrypted_content":"sigX"}}`,
        `{"type":"response.completed","response":{"status":"completed"}}`,
    }
    events, err := test_responses_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    if !testing.expect(t, len(events) == 3, "an encrypted-only reasoning item still emits a signed block") do return

    test_responses_expect_started(t, events[0], 0, .Reasoning)

    reasoning, reasoning_ok := test_responses_expect_stopped(t, events[1], 0).(Stream_Reasoning_Block)
    if testing.expect(t, reasoning_ok, "the synthesized block carries the signature") do testing.expect_value(t, reasoning.signature, "sigX")
}

@(test)
test_responses_stream_assembles_tool_call_from_argument_deltas :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string {
        `{"type":"response.output_item.added","item":{"type":"function_call","call_id":"call_9","name":"ping","arguments":""}}`,
        `{"type":"response.function_call_arguments.delta","delta":"{\"x\":"}`,
        `{"type":"response.function_call_arguments.delta","delta":"1}"}`,
        `{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_9","name":"ping"}}`,
        `{"type":"response.completed","response":{"status":"completed"}}`,
    }
    events, err := test_responses_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    if !testing.expect(t, len(events) == 3, "one tool call emits start, stop, done") do return

    test_responses_expect_started(t, events[0], 0, .Tool)

    tool, tool_ok := test_responses_expect_stopped(t, events[1], 0).(Stream_Tool_Block)
    if testing.expect(t, tool_ok, "the tool block closes with Stream_Tool_Block") {
        testing.expect_value(t, tool.call.id, "call_9")
        testing.expect_value(t, tool.call.name, "ping")
        testing.expect_value(t, tool.call.arguments, `{"x":1}`)
    }

    done := test_responses_last_done(t, events)
    testing.expect_value(t, done.reason, Stop_Reason.Tool_Calls)
}

@(test)
test_responses_stream_prefers_done_item_arguments :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string {
        `{"type":"response.output_item.added","item":{"type":"function_call","call_id":"call_1","name":"calc","arguments":""}}`,
        `{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"calc","arguments":"{\"a\":2}"}}`,
        `{"type":"response.completed","response":{"status":"completed"}}`,
    }
    events, err := test_responses_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    tool, tool_ok := test_responses_expect_stopped(t, events[1], 0).(Stream_Tool_Block)
    if testing.expect(t, tool_ok, "the tool block closes with Stream_Tool_Block") do testing.expect_value(t, tool.call.arguments, `{"a":2}`)

    done := test_responses_last_done(t, events)
    testing.expect_value(t, done.reason, Stop_Reason.Tool_Calls)
}

@(test)
test_responses_stream_rejects_missing_or_duplicate_tool_ids :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    missing := [?]string {
        `{"type":"response.output_item.done","item":{"type":"function_call","name":"ping","arguments":"{}"}}`,
    }
    _, missing_err := test_responses_drive(t, missing[:])
    testing.expect_value(t, missing_err, Transport_Error.Parse_Error)

    duplicate := [?]string {
        `{"type":"response.output_item.done","item":{"type":"function_call","call_id":"same","name":"first","arguments":"{}"}}`,
        `{"type":"response.output_item.done","item":{"type":"function_call","call_id":"same","name":"second","arguments":"{}"}}`,
    }
    _, duplicate_err := test_responses_drive(t, duplicate[:])
    testing.expect_value(t, duplicate_err, Transport_Error.Parse_Error)
}

@(test)
test_responses_stream_maps_incomplete_to_max_tokens :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string {
        `{"type":"response.output_text.delta","delta":"partial"}`,
        `{"type":"response.incomplete","response":{"status":"incomplete"}}`,
    }
    events, err := test_responses_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    done := test_responses_last_done(t, events)
    testing.expect_value(t, done.reason, Stop_Reason.Max_Tokens)
}

@(test)
test_responses_stream_folds_cached_and_reasoning_usage :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string {
        `{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":10,"output_tokens":5,"input_tokens_details":{"cached_tokens":8},"output_tokens_details":{"reasoning_tokens":3}}}}`,
    }
    events, err := test_responses_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    done := test_responses_last_done(t, events)
    testing.expect_value(t, done.usage.input, u64(10))
    testing.expect_value(t, done.usage.output, u64(5))
    testing.expect_value(t, done.usage.cache_read, u64(8))
    testing.expect_value(t, done.usage.reasoning, u64(3))
    testing.expect_value(t, done.usage.total, u64(15))
}

@(test)
test_responses_stream_maps_failure_discriminators :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    Case :: struct {
        payload: string,
        want:    Transport_Error,
    }

    cases := [?]Case {
        {`{"type":"response.failed","response":{"error":{"code":"insufficient_quota"}}}`, .Quota_Exhausted},
        {`{"type":"response.failed","response":{"error":{"type":"usage_limit_reached"}}}`, .Quota_Exhausted},
        {`{"type":"response.failed","response":{"error":{"code":"rate_limit_exceeded"}}}`, .Rate_Limited},
        {`{"type":"response.failed","response":{}}`, .Server_Error},
        {`{"type":"error","code":"rate_limit_exceeded"}`, .Rate_Limited},
    }

    for c in cases {
        payloads := [?]string{c.payload}
        _, err := test_responses_drive(t, payloads[:])
        testing.expect_value(t, err, c.want)
    }
}

@(test)
test_responses_stream_treats_eof_before_terminus_as_truncation :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string{`{"type":"response.output_text.delta","delta":"partial"}`}
    _, err := test_responses_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.Stream_Truncated)
}

@(test)
test_responses_stream_ignores_events_after_terminal :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string {
        `{"type":"response.completed","response":{"status":"completed"}}`,
        `{"type":"response.output_text.delta","delta":"late"}`,
    }
    events, err := test_responses_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)
    testing.expect_value(t, len(events), 1)
    _, ok := events[0].(Stream_Done)
    testing.expect(t, ok, "only the terminal event survives after completion")
}

@(test)
test_responses_stream_maps_malformed_json_to_parse_error :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string{`{"type":"response.completed"`}
    _, err := test_responses_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.Parse_Error)
}
