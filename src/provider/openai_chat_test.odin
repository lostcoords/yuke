package provider

import "core:mem"
import "core:strings"
import "core:testing"

@(private = "file")
concat_temp :: proc(a, b: string) -> string {
    res, _ := strings.concatenate({a, b}, context.temp_allocator)
    return res
}

@(private = "file")
concat_repeat :: proc(s: string, n: int) -> string {
    return strings.repeat(s, n, context.temp_allocator)
}

// Drive a fresh decoder over a list of SSE `data` payloads and finish at EOF,
// collecting every neutral event. Returns the first decode error, or the finish
// error when every payload decoded cleanly.
@(private = "file")
test_openai_drive :: proc(t: ^testing.T, payloads: []string) -> (events: [dynamic]Stream_Event, err: Transport_Error) {
    events.allocator = context.temp_allocator
    decoder := openai_chat_decoder_init(context.temp_allocator)

    // Mirror production: JSON trees decode into a scratch arena freed wholesale,
    // never the individually tracked heap. `core:encoding/json` can leave a small
    // internal allocation behind on a mid-parse failure that only an arena reset
    // reclaims.
    scratch_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch_arena, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&scratch_arena)
    scratch := mem.dynamic_arena_allocator(&scratch_arena)

    for data in payloads {
        e := openai_chat_decoder_decode(&decoder, data, &events, scratch)
        if e != .None {
            return events, e
        }
    }

    err = openai_chat_decoder_finish(&decoder, &events, scratch)
    return events, err
}

@(private = "file")
test_openai_last_done :: proc(t: ^testing.T, events: [dynamic]Stream_Event) -> Stream_Done {
    if !testing.expect(t, len(events) > 0, "a terminated stream has at least one event") {
        return {}
    }

    done, ok := events[len(events) - 1].(Stream_Done)
    testing.expect(t, ok, "the final event is Stream_Done")

    return done
}

@(private = "file")
test_openai_expect_started :: proc(
    t: ^testing.T,
    event: Stream_Event,
    block_id: Stream_Block_Id,
    kind: Stream_Block_Kind,
) {
    started, ok := event.(Stream_Block_Started)
    if !testing.expect(t, ok, "event must be Stream_Block_Started") {
        return
    }

    testing.expect_value(t, started.block_id, block_id)
    testing.expect_value(t, started.kind, kind)
}

@(private = "file")
test_openai_expect_stopped :: proc(
    t: ^testing.T,
    event: Stream_Event,
    block_id: Stream_Block_Id,
) -> Stream_Block_Result {
    stopped, ok := event.(Stream_Block_Stopped)
    if !testing.expect(t, ok, "event must be Stream_Block_Stopped") {
        return nil
    }

    testing.expect_value(t, stopped.block_id, block_id)

    return stopped.result
}

@(test)
test_openai_stream_yields_text_then_done :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string{`{"choices":[{"delta":{"content":"Hel"}}]}`, `[DONE]`}
    events, err := test_openai_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    if !testing.expect(t, len(events) == 4, "text then done emits four events") {
        return
    }

    test_openai_expect_started(t, events[0], 0, .Text)

    delta, ok := events[1].(Stream_Text_Delta)
    if testing.expect(t, ok, "second event is a text delta") {
        testing.expect_value(t, delta.block_id, Stream_Block_Id(0))
        testing.expect_value(t, delta.text, "Hel")
    }

    _, text_ok := test_openai_expect_stopped(t, events[2], 0).(Stream_Text_Block)
    testing.expect(t, text_ok, "text block closes with Stream_Text_Block")

    done := test_openai_last_done(t, events)
    testing.expect_value(t, done.reason, Stop_Reason.End_Turn)
}

@(test)
test_openai_stream_switches_between_reasoning_and_text :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string{`{"choices":[{"delta":{"reasoning_content":"why","content":"answer"}}]}`, `[DONE]`}
    events, err := test_openai_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    if !testing.expect(t, len(events) == 7, "reasoning-then-text in one chunk closes the reasoning block") {
        return
    }

    test_openai_expect_started(t, events[0], 0, .Reasoning)

    reasoning, reasoning_ok := events[1].(Stream_Reasoning_Delta)
    if testing.expect(t, reasoning_ok, "second event is a reasoning delta") {
        testing.expect_value(t, reasoning.text, "why")
    }

    _, closed_reasoning := test_openai_expect_stopped(t, events[2], 0).(Stream_Reasoning_Block)
    testing.expect(t, closed_reasoning, "the reasoning block closes before text opens")

    test_openai_expect_started(t, events[3], 1, .Text)

    text, text_ok := events[4].(Stream_Text_Delta)
    if testing.expect(t, text_ok, "fifth event is a text delta") {
        testing.expect_value(t, text.block_id, Stream_Block_Id(1))
        testing.expect_value(t, text.text, "answer")
    }

    _, closed_text := test_openai_expect_stopped(t, events[5], 1).(Stream_Text_Block)
    testing.expect(t, closed_text, "the text block closes at terminal")
}

@(test)
test_openai_stream_accumulates_reasoning_then_text_across_chunks :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string {
        `{"choices":[{"delta":{"reasoning_content":"th"}}]}`,
        `{"choices":[{"delta":{"reasoning_content":"ink"}}]}`,
        `{"choices":[{"delta":{"content":"Hel"}}]}`,
        `{"choices":[{"delta":{"content":"lo"}}]}`,
        `{"choices":[{"delta":{},"finish_reason":"stop"}]}`,
        `{"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}`,
        `[DONE]`,
    }
    events, err := test_openai_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    starts := 0
    reasoning_text: string
    text: string
    for event in events {
        #partial switch v in event {
        case Stream_Block_Started:
            starts += 1

        case Stream_Reasoning_Delta:
            reasoning_text = concat_temp(reasoning_text, v.text)

        case Stream_Text_Delta:
            text = concat_temp(text, v.text)
        }
    }

    testing.expect_value(t, starts, 2)
    testing.expect_value(t, reasoning_text, "think")
    testing.expect_value(t, text, "Hello")

    done := test_openai_last_done(t, events)
    testing.expect_value(t, done.reason, Stop_Reason.End_Turn)
    testing.expect_value(t, done.usage.input, u64(3))
    testing.expect_value(t, done.usage.output, u64(2))
    testing.expect_value(t, done.usage.total, u64(5))
}

@(test)
test_openai_stream_tolerates_null_content_and_reasoning :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string {
        `{"choices":[{"delta":{"content":null,"reasoning_content":"Think"}}]}`,
        `{"choices":[{"delta":{"content":"hola","reasoning_content":null}}]}`,
        `[DONE]`,
    }
    events, err := test_openai_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    reasoning, reasoning_ok := events[1].(Stream_Reasoning_Delta)
    if testing.expect(t, reasoning_ok, "null content still yields the reasoning delta") {
        testing.expect_value(t, reasoning.text, "Think")
    }
}

@(test)
test_openai_stream_reads_cached_and_provider_total_usage :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    cached := [?]string {
        `{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":8}}}`,
        `[DONE]`,
    }
    events, err := test_openai_drive(t, cached[:])
    testing.expect_value(t, err, Transport_Error.None)
    done := test_openai_last_done(t, events)
    testing.expect_value(t, done.usage.input, u64(10))
    testing.expect_value(t, done.usage.cache_read, u64(8))
    testing.expect_value(t, done.usage.total, u64(12))

    total := [?]string{`{"choices":[],"usage":{"total_tokens":200}}`, `[DONE]`}
    total_events, total_err := test_openai_drive(t, total[:])
    testing.expect_value(t, total_err, Transport_Error.None)
    total_done := test_openai_last_done(t, total_events)
    testing.expect_value(t, total_done.usage.total, u64(200))
}

@(test)
test_openai_stream_assembles_tool_call_split_across_chunks :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string {
        `{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_42","function":{"name":"calc","arguments":""}}]}}]}`,
        `{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"a\":"}}]}}]}`,
        `{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"2}"}}]}}]}`,
        `{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
        `[DONE]`,
    }
    events, err := test_openai_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    if !testing.expect(t, len(events) == 3, "one tool call emits start, stop, done") {
        return
    }

    test_openai_expect_started(t, events[0], 0, .Tool)

    tool, tool_ok := test_openai_expect_stopped(t, events[1], 0).(Stream_Tool_Block)
    if testing.expect(t, tool_ok, "the tool block closes with Stream_Tool_Block") {
        testing.expect_value(t, tool.call.id, "call_42")
        testing.expect_value(t, tool.call.name, "calc")
        testing.expect_value(t, tool.call.arguments, `{"a":2}`)
    }

    done := test_openai_last_done(t, events)
    testing.expect_value(t, done.reason, Stop_Reason.Tool_Calls)
}

@(test)
test_openai_stream_assembles_parallel_tool_calls_by_index :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string {
        `{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"first","arguments":"{}"}},{"index":1,"id":"b","function":{"name":"second","arguments":"{}"}}]}}]}`,
        `{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
        `[DONE]`,
    }
    events, err := test_openai_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    first, first_ok := test_openai_expect_stopped(t, events[1], 0).(Stream_Tool_Block)
    if testing.expect(t, first_ok, "first tool block closes") {
        testing.expect_value(t, first.call.name, "first")
    }

    test_openai_expect_started(t, events[2], 1, .Tool)

    second, second_ok := test_openai_expect_stopped(t, events[3], 1).(Stream_Tool_Block)
    if testing.expect(t, second_ok, "second tool block closes") {
        testing.expect_value(t, second.call.name, "second")
        testing.expect_value(t, second.call.arguments, "{}")
    }
}

@(test)
test_openai_stream_rejects_missing_or_duplicate_tool_ids :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    cases := [?][]string {
        {
            `{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"first","arguments":"{}"}}]}}]}`,
            `[DONE]`,
        },
        {
            `{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"same","function":{"name":"first","arguments":"{}"}},{"index":1,"id":"same","function":{"name":"second","arguments":"{}"}}]}}]}`,
            `[DONE]`,
        },
    }

    for payloads in cases {
        _, err := test_openai_drive(t, payloads)
        testing.expect_value(t, err, Transport_Error.Parse_Error)
    }
}

@(test)
test_openai_stream_finishes_without_done_sentinel :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string {
        `{"choices":[{"delta":{"content":"Hi!"}}]}`,
        `{"choices":[{"delta":{},"finish_reason":"stop"}]}`,
        `{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3}}`,
    }
    events, err := test_openai_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)

    done := test_openai_last_done(t, events)
    testing.expect_value(t, done.reason, Stop_Reason.End_Turn)
    testing.expect_value(t, done.usage.input, u64(5))
    testing.expect_value(t, done.usage.output, u64(3))
}

@(test)
test_openai_stream_treats_eof_before_terminus_as_truncation :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string{`{"choices":[{"delta":{"content":"partial"}}]}`}
    _, err := test_openai_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.Stream_Truncated)
}

@(test)
test_openai_stream_ignores_events_after_done :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string{`[DONE]`, `{"choices":[{"delta":{"content":"late"}}]}`}
    events, err := test_openai_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.None)
    testing.expect_value(t, len(events), 1)
    _, ok := events[0].(Stream_Done)
    testing.expect(t, ok, "only the terminal event survives after [DONE]")
}

@(test)
test_openai_stream_maps_malformed_json_to_parse_error :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string{`{"choices":[}`}
    _, err := test_openai_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.Parse_Error)
}

@(test)
test_openai_stream_rejects_tool_call_index_beyond_limit :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    payloads := [?]string{`{"choices":[{"delta":{"tool_calls":[{"index":64,"function":{"name":"bad"}}]}}]}`}
    _, err := test_openai_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.Too_Many_Tool_Calls)
}

@(test)
test_openai_stream_rejects_oversized_tool_arguments :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    fragment := concat_repeat("a", MAX_TOOL_CALL_BYTES + 1)
    payload := concat_temp(
        concat_temp(`{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"t","arguments":"`, fragment),
        `"}}]}}]}`,
    )
    payloads := [?]string{payload}
    _, err := test_openai_drive(t, payloads[:])
    testing.expect_value(t, err, Transport_Error.Tool_Call_Too_Large)
}
