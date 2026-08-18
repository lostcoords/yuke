package provider

import "base:runtime"
import "core:io"
import "core:strings"
import "core:unicode/utf8"
import "src:wire"

// Reasoning summary verbosity requested under `reasoning.summary`.
Openai_Reasoning_Summary :: enum {
    Auto,
    Concise,
    Detailed,
}

// Output verbosity requested under `text.verbosity`.
Openai_Text_Verbosity :: enum {
    Low,
    Medium,
    High,
}

// Request-shape variant spoken by an OpenAI Responses endpoint. The
// ChatGPT-account Codex backend deliberately rejects API-only sampling limits.
Openai_Responses_Dialect :: enum {
    Standard,
    Codex,
}

// OpenAI Responses controls chosen after catalog/model resolution.
Openai_Responses_Options :: struct {
    // Endpoint-specific request shape.
    dialect:   Openai_Responses_Dialect,

    // Reasoning effort; absent omits the reasoning control and its include.
    effort:    Maybe(Openai_Effort),

    // Reasoning summary verbosity, written only when `effort` is present.
    summary:   Openai_Reasoning_Summary,

    // Output verbosity; absent omits the `text` control.
    verbosity: Maybe(Openai_Text_Verbosity),

    // Whether the provider may store the conversation; emitted verbatim.
    store:     bool,
}

// Default `instructions`, sent when the request folds in no system prompt: the
// backend rejects a request without one.
@(private)
OPENAI_RESPONSES_DEFAULT_INSTRUCTIONS :: "You are a helpful assistant."

@(rodata)
openai_reasoning_summary_wire := [Openai_Reasoning_Summary]string {
    .Auto     = "auto",
    .Concise  = "concise",
    .Detailed = "detailed",
}

@(rodata)
openai_text_verbosity_wire := [Openai_Text_Verbosity]string {
    .Low    = "low",
    .Medium = "medium",
    .High   = "high",
}

// Streaming JSON state for the `input` array. Every wire message maps to one or
// more input items in order and `count` tracks whether a leading comma is due.
@(private)
Openai_Responses_Input_Writer :: struct {
    writer: io.Writer,
    count:  int,
}

// Build one OpenAI Responses request body. The body is allocated into
// `allocator` and parsed schemas and joined strings into `scratch_allocator`;
// nothing but the buffer of a failed build is freed, so both are expected to be
// arenas.
openai_responses_request_body :: proc(
    request: Request,
    options: Openai_Responses_Options,
    allocator := context.allocator,
    scratch_allocator: runtime.Allocator,
) -> (
    body: string,
    err: Transport_Error,
) {
    assert(allocator.procedure != nil, "OpenAI responses request builder needs a valid output allocator")
    assert(scratch_allocator.procedure != nil, "OpenAI responses request builder needs a valid scratch allocator")

    err = openai_responses_request_validate(request, options, scratch_allocator)
    if err != .None {
        return "", err
    }

    builder := strings.builder_make(0, 4096, allocator)
    defer if err != .None {
        strings.builder_destroy(&builder)
    }

    writer := strings.to_writer(&builder)
    json_write(writer, `{"model":`)
    json_write_string(writer, request.model)

    instructions := OPENAI_RESPONSES_DEFAULT_INSTRUCTIONS
    if system, present := request.system_prompt.?; present && len(system) > 0 {
        instructions = system
    }

    json_write(writer, `,"instructions":`)
    json_write_string(writer, instructions)

    json_write(writer, `,"input":[`)
    input := Openai_Responses_Input_Writer {
        writer = writer,
    }
    for message in request.messages {
        openai_responses_write_message(&input, message, request.provenance_model, scratch_allocator)
    }

    if input.count == 0 {
        return "", .Invalid_Request
    }

    json_write(writer, `]`)

    json_write(writer, options.store ? `,"store":true` : `,"store":false`)
    json_write(writer, `,"stream":true`)

    if options.dialect == .Standard {
        json_write(writer, `,"max_output_tokens":`)
        json_write_u64(writer, request.max_output_tokens)

        if temperature, present := request.temperature.?; present {
            json_write(writer, `,"temperature":`)
            json_write_f64(writer, temperature)
        }

        // Prefix-cache routing hint. The Codex backend does not take it, so it stays
        // inside the Standard-dialect block with the other API-only controls.
        if len(request.cache_key) > 0 {
            json_write(writer, `,"prompt_cache_key":`)
            json_write_string(writer, request.cache_key)
        }
    }

    if effort, present := options.effort.?; present {
        json_write(writer, `,"reasoning":{"effort":`)
        json_write_string(writer, openai_effort_wire[effort])
        json_write(writer, `,"summary":`)
        json_write_string(writer, openai_reasoning_summary_wire[options.summary])
        json_write(writer, `},"include":["reasoning.encrypted_content"]`)
    }

    if verbosity, present := options.verbosity.?; present {
        json_write(writer, `,"text":{"verbosity":`)
        json_write_string(writer, openai_text_verbosity_wire[verbosity])
        json_write(writer, `}`)
    }

    if len(request.tools) > 0 {
        openai_responses_write_tools(writer, request.tools)
        json_write(writer, `,"tool_choice":"auto"`)
    }

    json_write(writer, `}`)

    body = strings.to_string(builder)
    return body, .None
}

@(private)
openai_responses_request_validate :: proc(
    request: Request,
    options: Openai_Responses_Options,
    scratch_allocator: runtime.Allocator,
) -> Transport_Error {
    if len(request.model) == 0 || len(request.model) > 128 || !utf8.valid_string(request.model) {
        return .Invalid_Request
    }

    if len(request.provenance_model) == 0 || !utf8.valid_string(request.provenance_model) {
        return .Invalid_Request
    }

    dialect_index := int(options.dialect)
    if dialect_index < 0 || dialect_index >= 2 {
        return .Invalid_Request
    }

    if options.dialect == .Codex {
        if options.store {
            return .Invalid_Request
        }

        if _, temperature_present := request.temperature.?; temperature_present {
            return .Invalid_Request
        }
    }

    if request.max_output_tokens == 0 || request.max_output_tokens > MAX_EXACT_JSON_INTEGER {
        return .Invalid_Request
    }

    if system, present := request.system_prompt.?; present && !utf8.valid_string(system) {
        return .Invalid_Request
    }

    if len(request.cache_key) > 0 && !utf8.valid_string(request.cache_key) {
        return .Invalid_Request
    }

    if effort, present := options.effort.?; present {
        index := int(effort)
        if index < 0 || index >= len(openai_effort_wire) {
            return .Invalid_Request
        }
    }

    if temperature, present := request.temperature.?; present {
        bits := transmute(u64)temperature
        finite := (bits >> 52) & 0x7ff != 0x7ff

        if !finite || temperature < 0 || temperature > 2 {
            return .Invalid_Request
        }
    }

    tools_validate(request.tools, scratch_allocator) or_return

    if len(request.messages) == 0 {
        return .Invalid_Request
    }

    for message in request.messages {
        if wire.message_validate(message) != .None || !openai_message_supported(message) {
            return .Invalid_Request
        }
    }

    return .None
}

@(private)
openai_responses_write_tools :: proc(writer: io.Writer, tools: []Tool_Definition) {
    assert(len(tools) > 0, "OpenAI responses tools writer needs a non-empty slice")

    json_write(writer, `,"tools":[`)
    for tool, index in tools {
        if index > 0 {
            json_write(writer, `,`)
        }

        json_write(writer, `{"type":"function","name":`)
        json_write_string(writer, tool.name)
        json_write(writer, `,"description":`)
        json_write_string(writer, tool.description)
        json_write(writer, `,"parameters":`)
        json_write(writer, tool.input_schema)
        json_write(writer, `,"strict":false}`)
    }

    json_write(writer, `]`)
}

@(private)
openai_responses_write_message :: proc(
    out: ^Openai_Responses_Input_Writer,
    message: wire.Message,
    provenance_model: string,
    scratch_allocator: runtime.Allocator,
) {
    assert(out != nil, "OpenAI responses message serialization needs output state")
    assert(out.writer.procedure != nil, "OpenAI responses message output needs a writer")

    switch value in message {
    case wire.User_Message:
        openai_responses_write_user_message(out, value, scratch_allocator)

    case wire.Assistant_Message:
        openai_responses_write_assistant_message(out, value, provenance_model)

    case wire.Compaction_Message:
        openai_responses_write_compaction_message(out, value)
    }
}

@(private)
openai_responses_write_user_message :: proc(
    out: ^Openai_Responses_Input_Writer,
    message: wire.User_Message,
    scratch_allocator: runtime.Allocator,
) {
    openai_responses_input_sep(out)
    json_write(out.writer, `{"type":"message","role":"user","content":[`)
    for part, index in message.content {
        if index > 0 {
            json_write(out.writer, `,`)
        }

        openai_responses_write_content_part(out.writer, part, scratch_allocator)
    }

    json_write(out.writer, `]}`)
}

// Render one user content part in its Responses `input_*` shape. A blob is
// unreachable on validated input; the daemon inlines blobs before a request is
// built.
@(private)
openai_responses_write_content_part :: proc(
    writer: io.Writer,
    part: wire.Content_Part,
    scratch_allocator: runtime.Allocator,
) {
    switch v in part {
    case wire.Content_Text:
        json_write(writer, `{"type":"input_text","text":`)
        json_write_string(writer, v.text)
        json_write(writer, `}`)

    case wire.Content_Image:
        json_write(writer, `{"type":"input_image","image_url":`)
        openai_write_media_url(writer, v.source, scratch_allocator)

        if detail, ok := v.detail.?; ok {
            json_write(writer, `,"detail":`)
            json_write_string(writer, detail)
        }

        json_write(writer, `}`)

    case wire.Content_Audio:
        json_write(writer, `{"type":"input_audio","input_audio":{"data":`)
        openai_write_media_base64(writer, v.source)
        json_write(writer, `,"format":`)
        json_write_string(writer, v.format)
        json_write(writer, `}}`)

    case wire.Content_File:
        json_write(writer, `{"type":"input_file","file_data":`)
        openai_write_media_url(writer, v.source, scratch_allocator)

        if filename, ok := v.filename.?; ok {
            json_write(writer, `,"filename":`)
            json_write_string(writer, filename)
        }

        json_write(writer, `}`)
    }
}

// Serialize one assistant message. Text, reasoning, and tool calls become input
// items in content order; tool results follow as `function_call_output` items,
// mirroring the transcript's inline call-and-result pairing.
@(private)
openai_responses_write_assistant_message :: proc(
    out: ^Openai_Responses_Input_Writer,
    message: wire.Assistant_Message,
    provenance_model: string,
) {
    replay_reasoning := false
    if provenance, present := message.provenance.?; present {
        replay_reasoning = provenance.protocol == .Openai_Responses && provenance.model == provenance_model
    }

    for part in message.content {
        switch content in part {
        case wire.Text_Part:
            if len(content.text) > 0 {
                openai_responses_write_output_text(out, content.text)
            }

        case wire.Reasoning_Part:
            // Stateless replay omits the item id and emits only signed reasoning:
            // the backend rejects a prior reasoning item without encrypted state.
            if replay_reasoning && len(content.signature) > 0 {
                openai_responses_write_reasoning(out, content.text, content.signature)
            }

        case wire.Redacted_Reasoning_Part:
            if replay_reasoning {
                openai_responses_write_reasoning(out, "", content.data)
            }

        case wire.Tool_Part:
            openai_responses_write_function_call(out, content)
        }
    }

    for part in message.content {
        if tool, is_tool := part.(wire.Tool_Part); is_tool {
            openai_responses_write_function_call_output(out, tool)
        }
    }
}

@(private)
openai_responses_write_output_text :: proc(out: ^Openai_Responses_Input_Writer, text: string) {
    assert(len(text) > 0, "an assistant output_text item is never empty")

    openai_responses_input_sep(out)
    json_write(out.writer, `{"type":"message","role":"assistant","content":[{"type":"output_text","text":`)
    json_write_string(out.writer, text)
    json_write(out.writer, `}]}`)
}

// Write a reasoning replay item. An empty summary text emits an empty summary
// array; `encrypted_content` carries the opaque replay blob (a visible block's
// signature or a redacted block's data).
@(private)
openai_responses_write_reasoning :: proc(
    out: ^Openai_Responses_Input_Writer,
    text: string,
    encrypted_content: string,
) {
    assert(len(encrypted_content) > 0, "a replayed reasoning item carries encrypted content")

    openai_responses_input_sep(out)
    json_write(out.writer, `{"type":"reasoning","summary":[`)

    if len(text) > 0 {
        json_write(out.writer, `{"type":"summary_text","text":`)
        json_write_string(out.writer, text)
        json_write(out.writer, `}`)
    }

    json_write(out.writer, `],"encrypted_content":`)
    json_write_string(out.writer, encrypted_content)
    json_write(out.writer, `}`)
}

@(private)
openai_responses_write_function_call :: proc(out: ^Openai_Responses_Input_Writer, tool: wire.Tool_Part) {
    call_id, has_call_id := tool.call_id.?
    assert(has_call_id && len(call_id) > 0, "validated OpenAI responses tool call has an id")
    assert(len(tool.name) > 0, "validated OpenAI responses tool call has a name")

    arguments := tool.arguments
    if len(arguments) == 0 {
        arguments = "{}"
    }

    openai_responses_input_sep(out)
    json_write(out.writer, `{"type":"function_call","call_id":`)
    json_write_string(out.writer, call_id)
    json_write(out.writer, `,"name":`)
    json_write_string(out.writer, tool.name)
    json_write(out.writer, `,"arguments":`)
    json_write_string(out.writer, arguments)
    json_write(out.writer, `}`)
}

@(private)
openai_responses_write_function_call_output :: proc(out: ^Openai_Responses_Input_Writer, tool: wire.Tool_Part) {
    call_id, has_call_id := tool.call_id.?
    assert(has_call_id && len(call_id) > 0, "validated OpenAI responses tool result has an id")

    result, terminal := tool_result(tool.state)
    assert(terminal, "a validated OpenAI responses tool result is in a terminal state")

    openai_responses_input_sep(out)
    json_write(out.writer, `{"type":"function_call_output","call_id":`)
    json_write_string(out.writer, call_id)
    json_write(out.writer, `,"output":`)
    json_write_string(out.writer, result.content)
    json_write(out.writer, `}`)
}

// A compaction divider replays as a user input item carrying its summary, the
// same fold the other builders use. An empty summary emits nothing.
@(private)
openai_responses_write_compaction_message :: proc(
    out: ^Openai_Responses_Input_Writer,
    message: wire.Compaction_Message,
) {
    if len(message.summary) == 0 {
        return
    }

    openai_responses_input_sep(out)
    json_write(out.writer, `{"type":"message","role":"user","content":[{"type":"input_text","text":`)
    json_write_string(out.writer, message.summary)
    json_write(out.writer, `}]}`)
}

// Write the leading comma between input items and count the one being opened.
@(private)
openai_responses_input_sep :: proc(out: ^Openai_Responses_Input_Writer) {
    assert(out != nil, "OpenAI responses input separator needs output state")
    assert(out.count >= 0, "OpenAI responses input count cannot be negative")

    if out.count > 0 {
        json_write(out.writer, `,`)
    }
    out.count += 1
}

#assert(len(Openai_Reasoning_Summary) == 3)
#assert(len(Openai_Text_Verbosity) == 3)
