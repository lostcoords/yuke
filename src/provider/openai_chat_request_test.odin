package provider

import "core:strings"
import "core:testing"
import "libs:json"
import ts "libs:testsupport"
import "src:wire"

@(private = "file")
test_openai_user_message :: proc(parts: []wire.Content_Part) -> wire.Message {
    return wire.User_Message{id = 1, content = parts, input_id = 1, time = {created_at_ms = 1}}
}

@(private = "file")
test_openai_assistant_message :: proc(parts: []wire.Assistant_Part) -> wire.Message {
    return wire.Assistant_Message {
        id = 2,
        run_id = 1,
        config_rev = 1,
        agent = "main",
        content = parts,
        finish = wire.Stop_Reason.Tool_Calls,
        time = {created_at_ms = 2, completed_at_ms = 3},
    }
}

@(private = "file")
test_openai_request :: proc(messages: []wire.Message) -> Request {
    return Request{model = "gpt-test", messages = messages, max_output_tokens = 4096}
}

@(private = "file")
test_openai_build :: proc(t: ^testing.T, request: Request, options: Openai_Chat_Options = {}) -> string {
    body, err := openai_chat_request_body(request, options, context.temp_allocator, context.temp_allocator)
    testing.expect_value(t, err, Transport_Error.None)

    value, _, parse_err := decode_json_object(body, context.temp_allocator)
    testing.expect_value(t, parse_err, Transport_Error.None)
    if parse_err == .None do json.destroy_value(value, context.temp_allocator)

    return body
}

@(private = "file")
test_openai_expect_invalid :: proc(t: ^testing.T, request: Request, options: Openai_Chat_Options = {}) {
    body, err := openai_chat_request_body(request, options, context.temp_allocator, context.temp_allocator)
    testing.expect_value(t, err, Transport_Error.Invalid_Request)
    testing.expect_value(t, body, "")
}

@(test)
test_openai_request_builds_basic_streaming_body :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "hello \"odin\""}}
    messages := [?]wire.Message{test_openai_user_message(parts[:])}
    request := test_openai_request(messages[:])
    request.system_prompt = "system\nline"
    request.temperature = 0.5

    body := test_openai_build(t, request)
    testing.expect_value(
        t,
        body,
        `{"model":"gpt-test","stream":true,"stream_options":{"include_usage":true},"store":false,"max_completion_tokens":4096,"temperature":0.5,"messages":[{"role":"system","content":"system\nline"},{"role":"user","content":[{"type":"text","text":"hello \"odin\""}]}]}`,
    )
}

@(test)
test_openai_request_honors_store_and_max_tokens_field :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "hi"}}
    messages := [?]wire.Message{test_openai_user_message(parts[:])}
    options := Openai_Chat_Options {
        max_tokens_field = .Max_Tokens,
        store            = true,
    }

    body := test_openai_build(t, test_openai_request(messages[:]), options)
    testing.expect_value(
        t,
        body,
        `{"model":"gpt-test","stream":true,"stream_options":{"include_usage":true},"max_tokens":4096,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}`,
    )
}

@(test)
test_openai_request_writes_openai_reasoning_effort :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "think"}}
    messages := [?]wire.Message{test_openai_user_message(parts[:])}
    // `None` is the zero value, so a caller that wants a reasoning control names its shape.
    options := Openai_Chat_Options {
        thinking_format = .Openai,
        effort          = Openai_Effort.Medium,
    }

    body := test_openai_build(t, test_openai_request(messages[:]), options)
    testing.expect_value(
        t,
        body,
        `{"model":"gpt-test","stream":true,"stream_options":{"include_usage":true},"store":false,"max_completion_tokens":4096,"reasoning_effort":"medium","messages":[{"role":"user","content":[{"type":"text","text":"think"}]}]}`,
    )
}

@(test)
test_openai_request_writes_each_thinking_format_shape :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    Case :: struct {
        format:   Openai_Thinking_Format,
        effort:   Maybe(Openai_Effort),
        fragment: string,
        absent:   string,
    }

    cases := [?]Case {
        {.Openai, Openai_Effort.High, `,"reasoning_effort":"high"`, ""},
        {.Openai, Openai_Effort.None, `,"reasoning_effort":"none"`, ""},
        {.Openrouter, Openai_Effort.High, `,"reasoning":{"effort":"high"}`, ""},
        {.Deepseek, Openai_Effort.High, `,"thinking":{"type":"enabled"},"reasoning_effort":"high"`, ""},
        {.Deepseek, Openai_Effort.None, `,"thinking":{"type":"disabled"}`, `reasoning_effort`},
        {.Zai, Openai_Effort.High, `,"thinking":{"type":"enabled","clear_thinking":false}`, ""},
        {.Qwen, Openai_Effort.High, `,"enable_thinking":true`, ""},
        {.Qwen, Openai_Effort.None, `,"enable_thinking":false`, ""},
        {.Together, Openai_Effort.High, `,"reasoning":{"enabled":true}`, ""},
        {.String_Thinking, Openai_Effort.High, `,"thinking":"high"`, ""},
        {.Ant_Ling, Openai_Effort.High, `,"reasoning":{"effort":"high"}`, ""},
        {.Ant_Ling, Openai_Effort.None, "", `reasoning`},
        {.None, Openai_Effort.High, "", `reasoning`},
        {.Openai, nil, "", `reasoning`},
    }

    for c in cases {
        parts := [?]wire.Content_Part{wire.Content_Text{text = "x"}}
        messages := [?]wire.Message{test_openai_user_message(parts[:])}
        options := Openai_Chat_Options {
            thinking_format = c.format,
            effort          = c.effort,
        }

        body := test_openai_build(t, test_openai_request(messages[:]), options)

        if len(c.fragment) > 0 do testing.expectf(t, strings.contains(body, c.fragment), "%v: want %q in %s", c.format, c.fragment, body)

        if len(c.absent) > 0 do testing.expectf(t, !strings.contains(body, c.absent), "%v: want no %q in %s", c.format, c.absent, body)
    }
}

@(test)
test_openai_request_round_trips_tools_and_tool_calls :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    assistant_parts := [?]wire.Assistant_Part {
        wire.Text_Part{id = 0, text = "sure"},
        wire.Tool_Part {
            id = 1,
            call_id = "call_1",
            name = "calc",
            arguments = `{"a":2}`,
            state = wire.Tool_State_Completed{output = "4", duration_ms = 1},
        },
    }
    user_parts := [?]wire.Content_Part{wire.Content_Text{text = "thanks"}}
    tools := [?]Tool_Definition{{name = "calc", description = "Adds", input_schema = `{"type":"object"}`}}
    messages := [?]wire.Message {
        test_openai_assistant_message(assistant_parts[:]),
        test_openai_user_message(user_parts[:]),
    }
    request := test_openai_request(messages[:])
    request.tools = tools[:]

    body := test_openai_build(t, request)
    testing.expect_value(
        t,
        body,
        `{"model":"gpt-test","stream":true,"stream_options":{"include_usage":true},"store":false,"max_completion_tokens":4096,"tools":[{"type":"function","function":{"name":"calc","description":"Adds","parameters":{"type":"object"}}}],"messages":[{"role":"assistant","content":"sure","tool_calls":[{"id":"call_1","type":"function","function":{"name":"calc","arguments":"{\"a\":2}"}}]},{"role":"tool","content":"4","tool_call_id":"call_1"},{"role":"user","content":[{"type":"text","text":"thanks"}]}]}`,
    )
}

@(test)
test_openai_request_replays_reasoning_content_even_when_empty :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    reasoned := [?]wire.Assistant_Part {
        wire.Reasoning_Part{id = 0, text = "because"},
        wire.Text_Part{id = 1, text = "answer"},
    }
    plain := [?]wire.Assistant_Part{wire.Text_Part{id = 0, text = "done"}}
    messages := [?]wire.Message{test_openai_assistant_message(reasoned[:]), test_openai_assistant_message(plain[:])}
    options := Openai_Chat_Options {
        reasoning_replay = .Reasoning_Content,
    }

    body := test_openai_build(t, test_openai_request(messages[:]), options)
    testing.expect(
        t,
        strings.contains(body, `{"role":"assistant","content":"answer","reasoning_content":"because"`),
        body,
    )
    testing.expect(t, strings.contains(body, `{"role":"assistant","content":"done","reasoning_content":""`), body)
}

@(test)
test_openai_request_renders_image_content :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parts := [?]wire.Content_Part {
        wire.Content_Text{text = "look"},
        wire.Content_Image{source = wire.Media_Url{url = "https://x/y.png"}},
        wire.Content_Image{source = wire.Media_Base64{mime = "image/png", data = "AAAA"}, detail = "high"},
    }
    messages := [?]wire.Message{test_openai_user_message(parts[:])}

    body := test_openai_build(t, test_openai_request(messages[:]))
    testing.expect(
        t,
        strings.contains(
            body,
            `"content":[{"type":"text","text":"look"},{"type":"image_url","image_url":{"url":"https://x/y.png"}},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA","detail":"high"}}]`,
        ),
        body,
    )
}

@(test)
test_openai_request_rejects_unresolved_blob_image :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    hash: [64]u8
    for &b in hash {
        b = 'a'
    }

    parts := [?]wire.Content_Part {
        wire.Content_Image{source = wire.Media_Blob{hash = hash, mime = "image/png", bytes = 3}},
    }
    messages := [?]wire.Message{test_openai_user_message(parts[:])}
    test_openai_expect_invalid(t, test_openai_request(messages[:]))
}

@(test)
test_openai_request_folds_compaction_as_user_message :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    first := [?]wire.Content_Part{wire.Content_Text{text = "one"}}
    second := [?]wire.Content_Part{wire.Content_Text{text = "two"}}
    messages := [?]wire.Message {
        test_openai_user_message(first[:]),
        wire.Compaction_Message{summary = "summary"},
        test_openai_user_message(second[:]),
    }

    body := test_openai_build(t, test_openai_request(messages[:]))
    testing.expect_value(
        t,
        body,
        `{"model":"gpt-test","stream":true,"stream_options":{"include_usage":true},"store":false,"max_completion_tokens":4096,"messages":[{"role":"user","content":[{"type":"text","text":"one"}]},{"role":"user","content":"summary"},{"role":"user","content":[{"type":"text","text":"two"}]}]}`,
    )
}

@(test)
test_openai_request_rejects_invalid_configuration_and_history :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    user_parts := [?]wire.Content_Part{wire.Content_Text{text = "hello"}}
    messages := [?]wire.Message{test_openai_user_message(user_parts[:])}
    valid := test_openai_request(messages[:])

    invalid := valid
    invalid.model = ""
    test_openai_expect_invalid(t, invalid)

    invalid = valid
    invalid.max_output_tokens = 0
    test_openai_expect_invalid(t, invalid)

    invalid = valid
    invalid.temperature = 2.5
    test_openai_expect_invalid(t, invalid)

    invalid = valid
    invalid.tools = []Tool_Definition{{name = "bad", input_schema = `[]`}}
    test_openai_expect_invalid(t, invalid)

    invalid = valid
    invalid.tools = []Tool_Definition{{name = "same", input_schema = `{}`}, {name = "same", input_schema = `{}`}}
    test_openai_expect_invalid(t, invalid)

    missing_id_parts := [?]wire.Assistant_Part {
        wire.Tool_Part{id = 0, name = "read", arguments = `{}`, state = wire.Tool_State_Completed{output = "ok"}},
    }
    missing_id_messages := [?]wire.Message{test_openai_assistant_message(missing_id_parts[:])}
    test_openai_expect_invalid(t, test_openai_request(missing_id_messages[:]))

    pending_parts := [?]wire.Assistant_Part {
        wire.Tool_Part{id = 0, call_id = "call", name = "read", arguments = `{}`, state = wire.Tool_State_Pending{}},
    }
    pending_messages := [?]wire.Message{test_openai_assistant_message(pending_parts[:])}
    test_openai_expect_invalid(t, test_openai_request(pending_messages[:]))

    empty := valid
    empty.messages = nil
    test_openai_expect_invalid(t, empty)
}

@(test)
test_openai_request_surfaces_schema_scratch_exhaustion :: proc(t: ^testing.T) {
    parts := [?]wire.Content_Part{wire.Content_Text{text = "hello"}}
    messages := [?]wire.Message{test_openai_user_message(parts[:])}
    tools := [?]Tool_Definition{{name = "read", input_schema = `{"type":"object"}`}}
    request := test_openai_request(messages[:])
    request.tools = tools[:]

    failing: ts.Failing_Allocator
    ts.failing_allocator_init(&failing, context.allocator, 0)
    body, err := openai_chat_request_body(request, {}, context.allocator, ts.failing_allocator(&failing))
    testing.expect_value(t, err, Transport_Error.Resource_Exhausted)
    testing.expect_value(t, body, "")
}
