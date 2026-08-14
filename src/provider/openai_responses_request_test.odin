package provider

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "src:wire"

@(private = "file")
test_responses_user_message :: proc(parts: []wire.Content_Part) -> wire.Message {
    return wire.User_Message{id = 1, content = parts, input_id = 1, time = {created_at_ms = 1}}
}

@(private = "file")
test_responses_assistant_message :: proc(
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
test_responses_request :: proc(messages: []wire.Message) -> Request {
    return Request{model = "gpt-test", provenance_model = "gpt-test", messages = messages, max_output_tokens = 4096}
}

@(private = "file")
test_responses_build :: proc(t: ^testing.T, request: Request, options: Openai_Responses_Options = {}) -> string {
    body, err := openai_responses_request_body(request, options, context.temp_allocator, context.temp_allocator)
    testing.expect_value(t, err, Transport_Error.None)

    value, _, parse_err := decode_json_object(body, context.temp_allocator)
    testing.expect_value(t, parse_err, Transport_Error.None)
    if parse_err == .None {
        json.destroy_value(value, context.temp_allocator)
    }

    return body
}

@(private = "file")
test_responses_expect_invalid :: proc(t: ^testing.T, request: Request, options: Openai_Responses_Options = {}) {
    body, err := openai_responses_request_body(request, options, context.temp_allocator, context.temp_allocator)
    testing.expect_value(t, err, Transport_Error.Invalid_Request)
    testing.expect_value(t, body, "")
}

@(test)
test_responses_request_builds_basic_body_with_default_instructions :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "hi"}}
    messages := [?]wire.Message{test_responses_user_message(parts[:])}

    body := test_responses_build(t, test_responses_request(messages[:]))
    testing.expect_value(
        t,
        body,
        `{"model":"gpt-test","instructions":"You are a helpful assistant.","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}],"store":false,"stream":true,"max_output_tokens":4096}`,
    )
}

@(test)
test_responses_request_codex_dialect_omits_api_only_limits :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "hi"}}
    messages := [?]wire.Message{test_responses_user_message(parts[:])}
    request := test_responses_request(messages[:])

    got := test_responses_build(t, request, {dialect = .Codex})
    testing.expect_value(
        t,
        got,
        `{"model":"gpt-test","instructions":"You are a helpful assistant.","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}],"store":false,"stream":true}`,
    )

    request.temperature = 0.5
    test_responses_expect_invalid(t, request, {dialect = .Codex})
    request.temperature = nil
    test_responses_expect_invalid(t, request, {dialect = .Codex, store = true})
}

@(test)
test_responses_request_folds_system_prompt_and_temperature :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "hi"}}
    messages := [?]wire.Message{test_responses_user_message(parts[:])}
    request := test_responses_request(messages[:])
    request.system_prompt = "be terse"
    request.temperature = 0.5

    body := test_responses_build(t, request)
    testing.expect_value(
        t,
        body,
        `{"model":"gpt-test","instructions":"be terse","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}],"store":false,"stream":true,"max_output_tokens":4096,"temperature":0.5}`,
    )
}

@(test)
test_responses_request_writes_reasoning_verbosity_and_store :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "think"}}
    messages := [?]wire.Message{test_responses_user_message(parts[:])}
    options := Openai_Responses_Options {
        effort    = Openai_Effort.Medium,
        summary   = .Auto,
        verbosity = Openai_Text_Verbosity.Low,
        store     = true,
    }

    body := test_responses_build(t, test_responses_request(messages[:]), options)
    testing.expect_value(
        t,
        body,
        `{"model":"gpt-test","instructions":"You are a helpful assistant.","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"think"}]}],"store":true,"stream":true,"max_output_tokens":4096,"reasoning":{"effort":"medium","summary":"auto"},"include":["reasoning.encrypted_content"],"text":{"verbosity":"low"}}`,
    )
}

@(test)
test_responses_request_omits_reasoning_when_effort_absent :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "x"}}
    messages := [?]wire.Message{test_responses_user_message(parts[:])}

    body := test_responses_build(t, test_responses_request(messages[:]))
    testing.expect(t, !strings.contains(body, `"reasoning":`), body)
    testing.expect(t, !strings.contains(body, `"include":`), body)
    testing.expect(t, !strings.contains(body, `"verbosity":`), body)
}

@(test)
test_responses_request_renders_image_content :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part {
        wire.Content_Text{text = "look"},
        wire.Content_Image{source = wire.Media_Url{url = "https://x/y.png"}},
        wire.Content_Image{source = wire.Media_Base64{mime = "image/png", data = "AAAA"}, detail = "high"},
    }
    messages := [?]wire.Message{test_responses_user_message(parts[:])}

    body := test_responses_build(t, test_responses_request(messages[:]))
    testing.expect(
        t,
        strings.contains(
            body,
            `"content":[{"type":"input_text","text":"look"},{"type":"input_image","image_url":"https://x/y.png"},{"type":"input_image","image_url":"data:image/png;base64,AAAA","detail":"high"}]`,
        ),
        body,
    )
}

@(test)
test_responses_request_rejects_unresolved_blob_image :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    hash: [64]u8
    for &b in hash {
        b = 'a'
    }

    parts := [?]wire.Content_Part {
        wire.Content_Image{source = wire.Media_Blob{hash = hash, mime = "image/png", bytes = 3}},
    }
    messages := [?]wire.Message{test_responses_user_message(parts[:])}
    test_responses_expect_invalid(t, test_responses_request(messages[:]))
}

@(test)
test_responses_request_replays_reasoning_text_and_function_items_in_order :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Assistant_Part {
        wire.Reasoning_Part{id = 0, text = "because", signature = "sig1"},
        wire.Text_Part{id = 1, text = "answer"},
        wire.Tool_Part {
            id = 2,
            call_id = "call_1",
            name = "calc",
            arguments = `{"a":2}`,
            state = wire.Tool_State_Completed{output = "4", duration_ms = 1},
        },
    }
    provenance := wire.Turn_Provenance {
        protocol = .Openai_Responses,
        model    = "gpt-test",
    }
    messages := [?]wire.Message{test_responses_assistant_message(parts[:], provenance)}

    body := test_responses_build(t, test_responses_request(messages[:]))
    testing.expect_value(
        t,
        body,
        `{"model":"gpt-test","instructions":"You are a helpful assistant.","input":[{"type":"reasoning","summary":[{"type":"summary_text","text":"because"}],"encrypted_content":"sig1"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]},{"type":"function_call","call_id":"call_1","name":"calc","arguments":"{\"a\":2}"},{"type":"function_call_output","call_id":"call_1","output":"4"}],"store":false,"stream":true,"max_output_tokens":4096}`,
    )
}

@(test)
test_responses_request_skips_unsigned_reasoning_and_replays_redacted :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Assistant_Part {
        wire.Reasoning_Part{id = 0, text = "hidden", signature = ""},
        wire.Redacted_Reasoning_Part{id = 1, data = "blob1"},
        wire.Text_Part{id = 2, text = "visible"},
    }
    provenance := wire.Turn_Provenance {
        protocol = .Openai_Responses,
        model    = "gpt-test",
    }
    messages := [?]wire.Message{test_responses_assistant_message(parts[:], provenance)}

    body := test_responses_build(t, test_responses_request(messages[:]))
    testing.expect_value(
        t,
        body,
        `{"model":"gpt-test","instructions":"You are a helpful assistant.","input":[{"type":"reasoning","summary":[],"encrypted_content":"blob1"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"visible"}]}],"store":false,"stream":true,"max_output_tokens":4096}`,
    )
}

@(test)
test_responses_request_replays_only_matching_reasoning :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Assistant_Part {
        wire.Reasoning_Part{id = 0, text = "private", signature = "opaque"},
        wire.Text_Part{id = 1, text = "visible"},
    }
    cases := [?]wire.Turn_Provenance {
        {protocol = .Openai_Chat, model = "gpt-test"},
        {protocol = .Openai_Responses, model = "other-model"},
    }

    for provenance in cases {
        messages := [?]wire.Message{test_responses_assistant_message(parts[:], provenance)}
        body := test_responses_build(t, test_responses_request(messages[:]))

        testing.expect(t, !strings.contains(body, `"encrypted_content"`), body)
        testing.expect(t, strings.contains(body, `"text":"visible"`), body)
    }
}

@(test)
test_responses_request_serializes_tools_flat :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "2+2?"}}
    messages := [?]wire.Message{test_responses_user_message(parts[:])}
    tools := [?]Tool_Definition{{name = "calc", description = "Adds", input_schema = `{"type":"object"}`}}
    request := test_responses_request(messages[:])
    request.tools = tools[:]

    body := test_responses_build(t, request)
    testing.expect(
        t,
        strings.contains(
            body,
            `,"tools":[{"type":"function","name":"calc","description":"Adds","parameters":{"type":"object"},"strict":false}],"tool_choice":"auto"}`,
        ),
        body,
    )
}

@(test)
test_responses_request_folds_compaction_as_user_item :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    first := [?]wire.Content_Part{wire.Content_Text{text = "one"}}
    messages := [?]wire.Message{test_responses_user_message(first[:]), wire.Compaction_Message{summary = "summary"}}

    body := test_responses_build(t, test_responses_request(messages[:]))
    testing.expect(
        t,
        strings.contains(
            body,
            `{"type":"message","role":"user","content":[{"type":"input_text","text":"one"}]},{"type":"message","role":"user","content":[{"type":"input_text","text":"summary"}]}`,
        ),
        body,
    )
}

@(test)
test_responses_request_rejects_invalid_configuration_and_history :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    user_parts := [?]wire.Content_Part{wire.Content_Text{text = "hello"}}
    messages := [?]wire.Message{test_responses_user_message(user_parts[:])}
    valid := test_responses_request(messages[:])

    invalid := valid
    invalid.model = ""
    test_responses_expect_invalid(t, invalid)

    invalid = valid
    invalid.max_output_tokens = 0
    test_responses_expect_invalid(t, invalid)

    invalid = valid
    invalid.temperature = 2.5
    test_responses_expect_invalid(t, invalid)

    invalid = valid
    invalid.tools = []Tool_Definition{{name = "bad", input_schema = `[]`}}
    test_responses_expect_invalid(t, invalid)

    invalid = valid
    invalid.tools = []Tool_Definition{{name = "same", input_schema = `{}`}, {name = "same", input_schema = `{}`}}
    test_responses_expect_invalid(t, invalid)

    pending_parts := [?]wire.Assistant_Part {
        wire.Tool_Part{id = 0, call_id = "call", name = "read", arguments = `{}`, state = wire.Tool_State_Pending{}},
    }
    pending_messages := [?]wire.Message{test_responses_assistant_message(pending_parts[:])}
    test_responses_expect_invalid(t, test_responses_request(pending_messages[:]))

    empty := valid
    empty.messages = nil
    test_responses_expect_invalid(t, empty)
}
