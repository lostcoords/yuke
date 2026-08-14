package provider

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"
import ts "libs:testsupport"
import "src:wire"

@(private = "file")
test_anthropic_user_message :: proc(parts: []wire.Content_Part) -> wire.Message {
    return wire.User_Message{id = 1, content = parts, input_id = 1, time = {created_at_ms = 1}}
}

@(private = "file")
test_anthropic_assistant_message :: proc(
    parts: []wire.Assistant_Part,
    provenance: Maybe(wire.Turn_Provenance) = nil,
) -> wire.Message {
    return wire.Assistant_Message {
        id = 2,
        run_id = 1,
        config_rev = 1,
        agent = "main",
        content = parts,
        finish = wire.Stop_Reason.Tool_Calls,
        time = {created_at_ms = 2, completed_at_ms = 3},
        provenance = provenance,
    }
}

@(private = "file")
test_anthropic_request :: proc(messages: []wire.Message) -> Request {
    return Request {
        model = "claude-test",
        provenance_model = "claude-test",
        messages = messages,
        max_output_tokens = 4096,
    }
}

@(private = "file")
test_anthropic_build :: proc(t: ^testing.T, request: Request, options: Anthropic_Options = {}) -> string {
    body, err := anthropic_request_body(request, options, context.temp_allocator, context.temp_allocator)
    testing.expect_value(t, err, Transport_Error.None)

    value, _, parse_err := decode_json_object(body, context.temp_allocator)
    testing.expect_value(t, parse_err, Transport_Error.None)
    if parse_err == .None {
        json.destroy_value(value, context.temp_allocator)
    }

    return body
}

@(private = "file")
test_anthropic_expect_invalid :: proc(t: ^testing.T, request: Request, options: Anthropic_Options = {}) {
    body, err := anthropic_request_body(request, options, context.temp_allocator, context.temp_allocator)
    testing.expect_value(t, err, Transport_Error.Invalid_Request)
    testing.expect_value(t, body, "")
}

@(test)
test_anthropic_request_builds_basic_streaming_body :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "hello \"odin\""}}
    messages := [?]wire.Message{test_anthropic_user_message(parts[:])}
    request := test_anthropic_request(messages[:])
    request.system_prompt = "system\nline"
    request.temperature = 0.25

    body := test_anthropic_build(t, request)
    testing.expect_value(
        t,
        body,
        `{"model":"claude-test","max_tokens":4096,"stream":true,"system":"system\nline","temperature":0.25,"messages":[{"role":"user","content":[{"type":"text","text":"hello \"odin\""}]}]}`,
    )
}

@(test)
test_anthropic_request_writes_resolved_thinking_tools_and_effort :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "search"}}
    messages := [?]wire.Message{test_anthropic_user_message(parts[:])}
    tools := [?]Tool_Definition {
        {
            name = "search",
            description = "Find a document",
            input_schema = `{"type":"object","properties":{"q":{"type":"string"}}}`,
        },
    }
    request := test_anthropic_request(messages[:])
    request.tools = tools[:]
    options := Anthropic_Options {
        thinking = Anthropic_Thinking_Adaptive{display = .Summarized},
        effort = Anthropic_Effort.Xhigh,
    }

    body := test_anthropic_build(t, request, options)
    testing.expect_value(
        t,
        body,
        `{"model":"claude-test","max_tokens":4096,"stream":true,"thinking":{"type":"adaptive","display":"summarized"},"output_config":{"effort":"xhigh"},"tools":[{"name":"search","description":"Find a document","input_schema":{"type":"object","properties":{"q":{"type":"string"}}}}],"messages":[{"role":"user","content":[{"type":"text","text":"search"}]}]}`,
    )
}

@(test)
test_anthropic_request_writes_manual_thinking_budget :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "think"}}
    messages := [?]wire.Message{test_anthropic_user_message(parts[:])}
    options := Anthropic_Options {
        thinking = Anthropic_Thinking_Enabled{budget_tokens = 1024, display = .Omitted},
        effort = Anthropic_Effort.Low,
    }

    body := test_anthropic_build(t, test_anthropic_request(messages[:]), options)
    testing.expect_value(
        t,
        body,
        `{"model":"claude-test","max_tokens":4096,"stream":true,"thinking":{"type":"enabled","budget_tokens":1024,"display":"omitted"},"output_config":{"effort":"low"},"messages":[{"role":"user","content":[{"type":"text","text":"think"}]}]}`,
    )
}

@(test)
test_anthropic_request_preserves_block_order_and_puts_results_first :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    assistant_parts := [?]wire.Assistant_Part {
        wire.Reasoning_Part{id = 0, text = "", signature = "signed"},
        wire.Redacted_Reasoning_Part{id = 1, data = "opaque-data"},
        wire.Text_Part{id = 2, text = "checking"},
        wire.Tool_Part {
            id = 3,
            call_id = "call_ok",
            name = "read",
            arguments = `{"path":"a"}`,
            state = wire.Tool_State_Completed{output = "file", duration_ms = 1},
        },
        wire.Tool_Part {
            id = 4,
            call_id = "call_bad",
            name = "search",
            arguments = `{}`,
            state = wire.Tool_State_Error{error = "boom", duration_ms = 1},
        },
        wire.Tool_Part {
            id = 5,
            call_id = "call_denied",
            name = "write",
            arguments = `{}`,
            state = wire.Tool_State_Denied{reason = "not allowed", denied_by = .Policy},
        },
        wire.Tool_Part {
            id = 6,
            call_id = "call_canceled",
            name = "run",
            arguments = "",
            state = wire.Tool_State_Canceled{},
        },
    }
    user_parts := [?]wire.Content_Part{wire.Content_Text{text = "continue"}}
    messages := [?]wire.Message {
        test_anthropic_assistant_message(
            assistant_parts[:],
            wire.Turn_Provenance{protocol = .Anthropic_Messages, model = "claude-test"},
        ),
        test_anthropic_user_message(user_parts[:]),
    }

    body := test_anthropic_build(t, test_anthropic_request(messages[:]))
    testing.expect_value(
        t,
        body,
        `{"model":"claude-test","max_tokens":4096,"stream":true,"messages":[{"role":"assistant","content":[{"type":"thinking","thinking":"","signature":"signed"},{"type":"redacted_thinking","data":"opaque-data"},{"type":"text","text":"checking"},{"type":"tool_use","id":"call_ok","name":"read","input":{"path":"a"}},{"type":"tool_use","id":"call_bad","name":"search","input":{}},{"type":"tool_use","id":"call_denied","name":"write","input":{}},{"type":"tool_use","id":"call_canceled","name":"run","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_ok","content":"file"},{"type":"tool_result","tool_use_id":"call_bad","content":"boom","is_error":true},{"type":"tool_result","tool_use_id":"call_denied","content":"not allowed"},{"type":"tool_result","tool_use_id":"call_canceled","content":"canceled"},{"type":"text","text":"continue"}]}]}`,
    )
}

@(test)
test_anthropic_stream_blocks_round_trip_through_wire_request :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    decoder := anthropic_decoder_init(context.temp_allocator)
    events := [?]string {
        `{"type":"message_start","message":{"usage":{"input_tokens":5}}}`,
        `{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}`,
        `{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan"}}`,
        `{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed"}}`,
        `{"type":"content_block_stop","index":0}`,
        `{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"opaque-data"}}`,
        `{"type":"content_block_stop","index":1}`,
        `{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"call_2","name":"read","input":{}}}`,
        `{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"a\"}"}}`,
        `{"type":"content_block_stop","index":2}`,
        `{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}`,
        `{"type":"message_stop"}`,
    }

    parts: [3]wire.Assistant_Part
    reasoning_text: string
    starts := 0
    stops := 0

    for data in events {
        decoded: [dynamic]Stream_Event
        decoded.allocator = context.temp_allocator

        err := anthropic_decoder_decode(&decoder, data, &decoded, context.allocator)
        testing.expectf(t, err == .None, "%s: got %v", data, err)
        testing.expectf(t, len(decoded) <= 1, "%s: Anthropic decode appends at most one event", data)

        if len(decoded) == 0 {
            continue
        }

        switch value in decoded[0] {
        case Stream_Block_Started:
            testing.expect_value(t, value.block_id, Stream_Block_Id(starts))
            starts += 1

        case Stream_Text_Delta:
            testing.expect(t, false, "golden stream has no text block")

        case Stream_Reasoning_Delta:
            testing.expect_value(t, value.block_id, Stream_Block_Id(0))
            reasoning_text = value.text

        case Stream_Block_Stopped:
            testing.expect_value(t, value.block_id, Stream_Block_Id(stops))

            switch result in value.result {
            case Stream_Text_Block:
                testing.expect(t, false, "golden stream has no text block")

            case Stream_Reasoning_Block:
                parts[stops] = wire.Reasoning_Part {
                    id        = wire.Part_Id(stops),
                    text      = reasoning_text,
                    signature = result.signature,
                }

            case Stream_Redacted_Reasoning_Block:
                parts[stops] = wire.Redacted_Reasoning_Part {
                    id   = wire.Part_Id(stops),
                    data = result.data,
                }

            case Stream_Tool_Block:
                parts[stops] = wire.Tool_Part {
                    id = wire.Part_Id(stops),
                    call_id = result.call.id,
                    name = result.call.name,
                    arguments = result.call.arguments,
                    state = wire.Tool_State_Completed{output = "file", duration_ms = 1},
                }
            }

            stops += 1

        case Stream_Done:
            testing.expect_value(t, value.reason, Stop_Reason.Tool_Calls)
            testing.expect_value(t, value.usage.total, u64(12))
        }
    }

    testing.expect_value(t, starts, 3)
    testing.expect_value(t, stops, 3)

    messages := [?]wire.Message {
        test_anthropic_assistant_message(
            parts[:],
            wire.Turn_Provenance{protocol = .Anthropic_Messages, model = "claude-test"},
        ),
    }
    body := test_anthropic_build(t, test_anthropic_request(messages[:]))
    testing.expect_value(
        t,
        body,
        `{"model":"claude-test","max_tokens":4096,"stream":true,"messages":[{"role":"assistant","content":[{"type":"thinking","thinking":"plan","signature":"signed"},{"type":"redacted_thinking","data":"opaque-data"},{"type":"tool_use","id":"call_2","name":"read","input":{"path":"a"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_2","content":"file"}]}]}`,
    )
}

@(test)
test_anthropic_request_replays_only_matching_provider_reasoning :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    Case :: struct {
        provenance: Maybe(wire.Turn_Provenance),
        signature:  string,
        want:       bool,
    }

    cases := [?]Case {
        {wire.Turn_Provenance{protocol = .Anthropic_Messages, model = "claude-test"}, "signed", true},
        {wire.Turn_Provenance{protocol = .Anthropic_Messages, model = "other-model"}, "signed", false},
        {wire.Turn_Provenance{protocol = .Openai_Chat, model = "claude-test"}, "signed", false},
        {nil, "signed", false},
        {wire.Turn_Provenance{protocol = .Anthropic_Messages, model = "claude-test"}, "", false},
    }

    for c in cases {
        assistant_parts := [?]wire.Assistant_Part {
            wire.Reasoning_Part{id = 0, text = "reasoning", signature = c.signature},
            wire.Redacted_Reasoning_Part{id = 1, data = "opaque-data"},
        }
        user_parts := [?]wire.Content_Part{wire.Content_Text{text = "next"}}
        messages := [?]wire.Message {
            test_anthropic_assistant_message(assistant_parts[:], c.provenance),
            test_anthropic_user_message(user_parts[:]),
        }

        body := test_anthropic_build(t, test_anthropic_request(messages[:]))
        has_thinking := strings.contains(body, `"type":"thinking"`)
        testing.expectf(t, has_thinking == c.want, "want thinking=%v: %s", c.want, body)

        has_redacted := strings.contains(body, `"type":"redacted_thinking"`)
        testing.expectf(t, has_redacted == c.want, "want redacted=%v: %s", c.want, body)
    }
}

@(test)
test_anthropic_request_drops_thinking_when_any_reasoning_is_unsigned :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    assistant_parts := [?]wire.Assistant_Part {
        wire.Reasoning_Part{id = 0, text = "planned", signature = "signed"},
        wire.Redacted_Reasoning_Part{id = 1, data = "opaque-data"},
        wire.Reasoning_Part{id = 2, text = "interrupted", signature = ""},
        wire.Text_Part{id = 3, text = "answer"},
    }
    user_parts := [?]wire.Content_Part{wire.Content_Text{text = "next"}}
    provenance := wire.Turn_Provenance {
        protocol = .Anthropic_Messages,
        model    = "claude-test",
    }
    messages := [?]wire.Message {
        test_anthropic_assistant_message(assistant_parts[:], provenance),
        test_anthropic_user_message(user_parts[:]),
    }

    body := test_anthropic_build(t, test_anthropic_request(messages[:]))

    testing.expect(t, !strings.contains(body, `"type":"thinking"`), body)
    testing.expect(t, !strings.contains(body, `"type":"redacted_thinking"`), body)
    testing.expect(t, strings.contains(body, `"text":"answer"`), body)
}

@(test)
test_anthropic_request_merges_consecutive_user_content :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    first := [?]wire.Content_Part{wire.Content_Text{text = "one"}}
    second := [?]wire.Content_Part{wire.Content_Text{text = "two"}}
    messages := [?]wire.Message {
        test_anthropic_user_message(first[:]),
        wire.Compaction_Message{summary = "summary"},
        test_anthropic_user_message(second[:]),
    }

    body := test_anthropic_build(t, test_anthropic_request(messages[:]))
    testing.expect_value(
        t,
        body,
        `{"model":"claude-test","max_tokens":4096,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"one"},{"type":"text","text":"summary"},{"type":"text","text":"two"}]}]}`,
    )
}

@(test)
test_anthropic_request_writes_base64_image_block :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part {
        wire.Content_Image{source = wire.Media_Base64{mime = "image/png", data = "AAAA"}, detail = "high"},
    }
    messages := [?]wire.Message{test_anthropic_user_message(parts[:])}

    body := test_anthropic_build(t, test_anthropic_request(messages[:]))
    testing.expect_value(
        t,
        body,
        `{"model":"claude-test","max_tokens":4096,"stream":true,"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}]}`,
    )
}

@(test)
test_anthropic_request_writes_url_image_block :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part{wire.Content_Image{source = wire.Media_Url{url = "https://example.com/image.png"}}}
    messages := [?]wire.Message{test_anthropic_user_message(parts[:])}

    body := test_anthropic_build(t, test_anthropic_request(messages[:]))
    testing.expect_value(
        t,
        body,
        `{"model":"claude-test","max_tokens":4096,"stream":true,"messages":[{"role":"user","content":[{"type":"image","source":{"type":"url","url":"https://example.com/image.png"}}]}]}`,
    )
}

@(test)
test_anthropic_request_preserves_mixed_text_and_image_order :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part {
        wire.Content_Text{text = "look"},
        wire.Content_Image{source = wire.Media_Base64{mime = "image/jpeg", data = "BBBB"}},
        wire.Content_Text{text = "done"},
    }
    messages := [?]wire.Message{test_anthropic_user_message(parts[:])}

    body := test_anthropic_build(t, test_anthropic_request(messages[:]))
    testing.expect_value(
        t,
        body,
        `{"model":"claude-test","max_tokens":4096,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"look"},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"BBBB"}},{"type":"text","text":"done"}]}]}`,
    )
}

@(test)
test_anthropic_request_rejects_invalid_configuration_and_history :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    user_parts := [?]wire.Content_Part{wire.Content_Text{text = "hello"}}
    messages := [?]wire.Message{test_anthropic_user_message(user_parts[:])}
    valid := test_anthropic_request(messages[:])

    invalid := valid
    invalid.model = ""
    test_anthropic_expect_invalid(t, invalid)

    invalid = valid
    invalid.max_output_tokens = 0
    test_anthropic_expect_invalid(t, invalid)

    invalid = valid
    invalid.temperature = 0.2
    test_anthropic_expect_invalid(t, invalid, {thinking = Anthropic_Thinking_Adaptive{}})

    test_anthropic_expect_invalid(t, valid, {thinking = Anthropic_Thinking_Enabled{budget_tokens = 1023}})
    test_anthropic_expect_invalid(
        t,
        valid,
        {thinking = Anthropic_Thinking_Enabled{budget_tokens = valid.max_output_tokens}},
    )

    invalid = valid
    invalid.tools = []Tool_Definition{{name = "bad", input_schema = `[]`}}
    test_anthropic_expect_invalid(t, invalid)

    invalid = valid
    invalid.tools = []Tool_Definition{{name = "same", input_schema = `{}`}, {name = "same", input_schema = `{}`}}
    test_anthropic_expect_invalid(t, invalid)

    blob_parts := [?]wire.Content_Part {
        wire.Content_Image{source = wire.Media_Blob{hash = 'a', mime = "image/png", bytes = 3}},
    }
    blob_messages := [?]wire.Message{test_anthropic_user_message(blob_parts[:])}
    test_anthropic_expect_invalid(t, test_anthropic_request(blob_messages[:]))

    audio_parts := [?]wire.Content_Part {
        wire.Content_Audio{source = wire.Media_Base64{mime = "audio/mpeg", data = "AAAA"}, format = "mp3"},
    }
    audio_messages := [?]wire.Message{test_anthropic_user_message(audio_parts[:])}
    test_anthropic_expect_invalid(t, test_anthropic_request(audio_messages[:]))

    file_parts := [?]wire.Content_Part {
        wire.Content_File{source = wire.Media_Base64{mime = "application/pdf", data = "AAAA"}},
    }
    file_messages := [?]wire.Message{test_anthropic_user_message(file_parts[:])}
    test_anthropic_expect_invalid(t, test_anthropic_request(file_messages[:]))

    missing_id_parts := [?]wire.Assistant_Part {
        wire.Tool_Part{id = 0, name = "read", arguments = `{}`, state = wire.Tool_State_Completed{output = "ok"}},
    }
    missing_id_messages := [?]wire.Message{test_anthropic_assistant_message(missing_id_parts[:])}
    test_anthropic_expect_invalid(t, test_anthropic_request(missing_id_messages[:]))

    pending_parts := [?]wire.Assistant_Part {
        wire.Tool_Part{id = 0, call_id = "call", name = "read", arguments = `{}`, state = wire.Tool_State_Pending{}},
    }
    pending_messages := [?]wire.Message{test_anthropic_assistant_message(pending_parts[:])}
    test_anthropic_expect_invalid(t, test_anthropic_request(pending_messages[:]))

    malformed_arguments_parts := [?]wire.Assistant_Part {
        wire.Tool_Part {
            id = 0,
            call_id = "call",
            name = "read",
            arguments = `{bad`,
            state = wire.Tool_State_Completed{output = "ok"},
        },
    }
    malformed_arguments_messages := [?]wire.Message{test_anthropic_assistant_message(malformed_arguments_parts[:])}
    test_anthropic_expect_invalid(t, test_anthropic_request(malformed_arguments_messages[:]))

    empty := valid
    empty.messages = nil
    test_anthropic_expect_invalid(t, empty)
}

@(test)
test_anthropic_request_surfaces_schema_scratch_exhaustion :: proc(t: ^testing.T) {
    parts := [?]wire.Content_Part{wire.Content_Text{text = "hello"}}
    messages := [?]wire.Message{test_anthropic_user_message(parts[:])}
    tools := [?]Tool_Definition{{name = "read", input_schema = `{"type":"object"}`}}
    request := test_anthropic_request(messages[:])
    request.tools = tools[:]

    failing: ts.Failing_Allocator
    ts.failing_allocator_init(&failing, context.allocator, 0)
    body, err := anthropic_request_body(request, {}, context.allocator, ts.failing_allocator(&failing))
    testing.expect_value(t, err, Transport_Error.Resource_Exhausted)
    testing.expect_value(t, body, "")
}

@(test)
test_anthropic_request_surfaces_every_output_allocation_failure :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    long := strings.repeat("x", 16 * 1024, context.temp_allocator)
    parts := [?]wire.Content_Part{wire.Content_Text{text = long}}
    messages := [?]wire.Message{test_anthropic_user_message(parts[:])}
    request := test_anthropic_request(messages[:])

    reached_success := false
    for fail_at in 0 ..< 16 {
        arena: mem.Dynamic_Arena
        mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
        arena_allocator := mem.dynamic_arena_allocator(&arena)

        failing: ts.Failing_Allocator
        ts.failing_allocator_init(&failing, arena_allocator, fail_at)
        body, err := anthropic_request_body(request, {}, ts.failing_allocator(&failing), context.temp_allocator)
        if err == .None {
            reached_success = true
            testing.expect(t, len(body) > len(long), "successful body must contain the envelope")
            mem.dynamic_arena_destroy(&arena)
            break
        }

        testing.expect_value(t, err, Transport_Error.Resource_Exhausted)
        testing.expect_value(t, body, "")
        mem.dynamic_arena_destroy(&arena)
    }

    testing.expect(t, reached_success, "fault sweep must eventually pass every request-body allocation")
}
