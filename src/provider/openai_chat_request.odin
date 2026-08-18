package provider

import "base:runtime"
import "core:io"
import "core:strings"
import "core:unicode/utf8"

import "libs:json"
import "src:wire"

// Reasoning effort level, sent verbatim on the wire. `None` is the literal
// "none" some 2026 models accept; `Minimal` keeps older-model compatibility.
// `Max` arrived with the gpt-5.6 family; Codex models stop at `Xhigh`. Catalog
// resolution only ever picks a level the resolved model advertises.
Openai_Effort :: enum {
    None,
    Minimal,
    Low,
    Medium,
    High,
    Xhigh,
    Max,
}

// Which request-body control carries the reasoning knob. OpenAI-compatible
// gateways disagree on the shape, so model/catalog resolution picks the format
// and this builder writes it. `None` omits the control entirely.
Openai_Thinking_Format :: enum {
    // No reasoning control. The zero value, so a row that names no shape asks for none.
    None,

    // Top-level `reasoning_effort` string (OpenAI, gpt-5.x).
    Openai,

    // Nested `reasoning:{effort}` (OpenRouter).
    Openrouter,

    // `thinking:{type}` toggle plus `reasoning_effort` when on (DeepSeek).
    Deepseek,

    // `thinking:{type,clear_thinking:false}` toggle (z.ai).
    Zai,

    // `enable_thinking` boolean (Qwen).
    Qwen,

    // Nested `reasoning:{enabled}` boolean (Together).
    Together,

    // Top-level `thinking` string level.
    String_Thinking,

    // Nested `reasoning:{effort}` emitted only when reasoning is on (ant-ling).
    Ant_Ling,
}

// Which assistant field replays prior reasoning back to the provider so it stays
// in context across a tool-use round. Providers name the field differently.
Openai_Reasoning_Replay :: enum {
    // Do not replay reasoning.
    None,

    // Replay under `reasoning`.
    Reasoning,

    // Replay under `reasoning_content` (DeepSeek, z.ai).
    Reasoning_Content,

    // Replay under `reasoning_details` (OpenRouter).
    Reasoning_Details,
}

// Which output-token ceiling field a model expects. Newer OpenAI models use
// `max_completion_tokens`; older/compatible endpoints use `max_tokens`.
Openai_Max_Tokens_Field :: enum {
    Max_Completion_Tokens,
    Max_Tokens,
}

// OpenAI Chat Completions controls chosen after catalog/model resolution.
Openai_Chat_Options :: struct {
    // Reasoning effort; absent leaves the reasoning control unset.
    effort:           Maybe(Openai_Effort),

    // Wire shape of the reasoning control.
    thinking_format:  Openai_Thinking_Format,

    // Whether and how to replay prior reasoning on assistant messages.
    reasoning_replay: Openai_Reasoning_Replay,

    // Output-token ceiling field name.
    max_tokens_field: Openai_Max_Tokens_Field,

    // Whether the provider may store the conversation; false emits `store:false`.
    store:            bool,
}

// Effort <-> wire string, indexed so a missing mapping is visible.
@(rodata)
openai_effort_wire := [Openai_Effort]string {
    .None    = "none",
    .Minimal = "minimal",
    .Low     = "low",
    .Medium  = "medium",
    .High    = "high",
    .Xhigh   = "xhigh",
    .Max     = "max",
}

// Assistant field name a reasoning-replay mode writes under.
@(private)
openai_reasoning_replay_field :: proc(mode: Openai_Reasoning_Replay) -> string {
    switch mode {
    case .Reasoning:
        return "reasoning"

    case .Reasoning_Content:
        return "reasoning_content"

    case .Reasoning_Details:
        return "reasoning_details"

    case .None:
        return ""
    }

    return ""
}

// Streaming JSON state for the provider `messages` array. Chat Completions never
// merges consecutive roles, so every wire message maps to one or more objects in
// order and `count` tracks whether a leading comma is due.
@(private)
Openai_Message_Writer :: struct {
    writer: io.Writer,
    count:  int,
}

// Build one OpenAI Chat Completions request body. The body is allocated into
// `allocator` and parsed schemas and joined strings into `scratch_allocator`;
// nothing but the buffer of a failed build is freed, so both are expected to be
// arenas.
openai_chat_request_body :: proc(
    request: Request,
    options: Openai_Chat_Options,
    allocator := context.allocator,
    scratch_allocator: runtime.Allocator,
) -> (
    body: string,
    err: Transport_Error,
) {
    assert(allocator.procedure != nil, "OpenAI chat request builder needs a valid output allocator")
    assert(scratch_allocator.procedure != nil, "OpenAI chat request builder needs a valid scratch allocator")

    err = openai_chat_request_validate(request, options, scratch_allocator)
    if err != .None do return "", err

    builder := strings.builder_make(0, 4096, allocator)
    defer if err != .None do strings.builder_destroy(&builder)

    writer := strings.to_writer(&builder)
    json.write_raw(writer, `{"model":`)
    json.write_string(writer, request.model)
    json.write_raw(writer, `,"stream":true,"stream_options":{"include_usage":true}`)

    if !options.store do json.write_raw(writer, `,"store":false`)

    max_field := options.max_tokens_field == .Max_Tokens ? `,"max_tokens":` : `,"max_completion_tokens":`
    json.write_raw(writer, max_field)
    json.write_u64(writer, request.max_output_tokens)

    if temperature, present := request.temperature.?; present {
        json.write_raw(writer, `,"temperature":`)
        json.write_f64(writer, temperature)
    }

    openai_write_reasoning(writer, options.thinking_format, options.effort)

    if len(request.tools) > 0 do openai_write_tools(writer, request.tools)

    json.write_raw(writer, `,"messages":[`)
    messages := Openai_Message_Writer {
        writer = writer,
    }

    if system, present := request.system_prompt.?; present && len(system) > 0 do openai_write_system(&messages, system)

    for message in request.messages {
        openai_write_message(&messages, message, options, scratch_allocator)
    }

    if messages.count == 0 do return "", .Invalid_Request

    json.write_raw(writer, `]}`)

    body = strings.to_string(builder)
    return body, .None
}

@(private)
openai_chat_request_validate :: proc(
    request: Request,
    options: Openai_Chat_Options,
    scratch_allocator: runtime.Allocator,
) -> Transport_Error {
    if len(request.model) == 0 || len(request.model) > 128 || !utf8.valid_string(request.model) do return .Invalid_Request

    if request.max_output_tokens == 0 || request.max_output_tokens > MAX_EXACT_JSON_INTEGER do return .Invalid_Request

    if system, present := request.system_prompt.?; present && !utf8.valid_string(system) do return .Invalid_Request

    if effort, present := options.effort.?; present {
        index := int(effort)
        if index < 0 || index >= len(openai_effort_wire) do return .Invalid_Request
    }

    if temperature, present := request.temperature.?; present {
        bits := transmute(u64)temperature
        finite := (bits >> 52) & 0x7ff != 0x7ff

        if !finite || temperature < 0 || temperature > 2 do return .Invalid_Request
    }

    tools_validate(request.tools, scratch_allocator) or_return

    if len(request.messages) == 0 do return .Invalid_Request

    for message in request.messages {
        if wire.message_validate(message) != .None || !openai_message_supported(message) do return .Invalid_Request
    }

    return .None
}

@(private)
openai_message_supported :: proc(message: wire.Message) -> bool {
    switch value in message {
    case wire.User_Message:
        for part in value.content {
            if !openai_content_supported(part) do return false
        }

    case wire.Assistant_Message:
        for part in value.content {
            switch content in part {
            case wire.Text_Part:
                if !utf8.valid_string(content.text) do return false

            case wire.Reasoning_Part:
                if !utf8.valid_string(content.text) || !utf8.valid_string(content.signature) do return false

            case wire.Redacted_Reasoning_Part:
                if !utf8.valid_string(content.data) do return false

            case wire.Tool_Part:
                call_id, has_call_id := content.call_id.?
                if !has_call_id ||
                   len(call_id) == 0 ||
                   !utf8.valid_string(call_id) ||
                   len(content.name) == 0 ||
                   !utf8.valid_string(content.name) ||
                   !utf8.valid_string(content.arguments) ||
                   content.state == nil {
                    return false
                }

                switch state in content.state {
                case wire.Tool_State_Completed:
                    if !utf8.valid_string(state.output) do return false

                case wire.Tool_State_Error:
                    if !utf8.valid_string(state.error) do return false

                case wire.Tool_State_Denied:
                    if !utf8.valid_string(state.reason) do return false

                case wire.Tool_State_Canceled:

                case wire.Tool_State_Pending, wire.Tool_State_Waiting_Permission, wire.Tool_State_Running:
                    return false
                }
            }
        }

    case wire.Compaction_Message:
        return utf8.valid_string(value.summary)

    case:
        return false
    }

    return true
}

// A content part is supported when its strings are valid UTF-8 and its media is
// resolved. An unresolved blob is invalid: the daemon inlines blobs before a
// request is built.
@(private)
openai_content_supported :: proc(part: wire.Content_Part) -> bool {
    switch v in part {
    case wire.Content_Text:
        return utf8.valid_string(v.text)

    case wire.Content_Image:
        if detail, ok := v.detail.?; ok && !utf8.valid_string(detail) do return false

        return openai_media_supported(v.source)

    case wire.Content_Audio:
        if !openai_media_supported(v.source) || !utf8.valid_string(v.format) do return false

        // input_audio carries raw base64; a URL source must embed a `base64,` marker.
        if url, is_url := v.source.(wire.Media_Url); is_url do return strings.index(url.url, "base64,") >= 0

        return true

    case wire.Content_File:
        if filename, ok := v.filename.?; ok && !utf8.valid_string(filename) do return false

        return openai_media_supported(v.source)
    }

    return false
}

@(private)
openai_media_supported :: proc(source: wire.Media_Source) -> bool {
    switch s in source {
    case wire.Media_Url:
        return utf8.valid_string(s.url)

    case wire.Media_Base64:
        return utf8.valid_string(s.mime) && utf8.valid_string(s.data)

    case wire.Media_Blob:
        return false
    }

    return false
}

// Write the reasoning control for `format` given the selected effort. Absent
// effort omits the control, matching a model with the knob left unset.
@(private)
openai_write_reasoning :: proc(writer: io.Writer, format: Openai_Thinking_Format, effort_opt: Maybe(Openai_Effort)) {
    if format == .None do return

    level, present := effort_opt.?
    if !present do return

    on := level != .None
    level_wire := openai_effort_wire[level]

    switch format {
    case .Openai:
        json.write_raw(writer, `,"reasoning_effort":`)
        json.write_string(writer, level_wire)

    case .Openrouter:
        json.write_raw(writer, `,"reasoning":{"effort":`)
        json.write_string(writer, level_wire)
        json.write_raw(writer, `}`)

    case .Deepseek:
        json.write_raw(writer, `,"thinking":{"type":`)
        json.write_string(writer, on ? "enabled" : "disabled")
        json.write_raw(writer, `}`)

        if on {
            json.write_raw(writer, `,"reasoning_effort":`)
            json.write_string(writer, level_wire)
        }

        return

    case .Zai:
        json.write_raw(writer, `,"thinking":{"type":`)
        json.write_string(writer, on ? "enabled" : "disabled")
        json.write_raw(writer, `,"clear_thinking":false}`)

    case .Qwen:
        json.write_raw(writer, `,"enable_thinking":`)
        json.write_raw(writer, on ? "true" : "false")

    case .Together:
        json.write_raw(writer, `,"reasoning":{"enabled":`)
        json.write_raw(writer, on ? "true" : "false")
        json.write_raw(writer, `}`)

    case .String_Thinking:
        json.write_raw(writer, `,"thinking":`)
        json.write_string(writer, level_wire)

    case .Ant_Ling:
        if on {
            json.write_raw(writer, `,"reasoning":{"effort":`)
            json.write_string(writer, level_wire)
            json.write_raw(writer, `}`)
        }

        return

    case .None:
        return
    }
}

@(private)
openai_write_tools :: proc(writer: io.Writer, tools: []Tool_Definition) {
    assert(len(tools) > 0, "OpenAI tools writer needs a non-empty slice")

    json.write_raw(writer, `,"tools":[`)
    for tool, index in tools {
        if index > 0 do json.write_raw(writer, `,`)

        json.write_raw(writer, `{"type":"function","function":{"name":`)
        json.write_string(writer, tool.name)
        json.write_raw(writer, `,"description":`)
        json.write_string(writer, tool.description)
        json.write_raw(writer, `,"parameters":`)
        json.write_raw(writer, tool.input_schema)
        json.write_raw(writer, `}}`)
    }

    json.write_raw(writer, `]`)
}

// Write the leading system message, present only when a non-empty system prompt
// was folded in. The wire model carries no mid-history system messages.
@(private)
openai_write_system :: proc(out: ^Openai_Message_Writer, system: string) {
    assert(len(system) > 0, "OpenAI system message is never empty")

    openai_message_sep(out)
    json.write_raw(out.writer, `{"role":"system","content":`)
    json.write_string(out.writer, system)
    json.write_raw(out.writer, `}`)
}

@(private)
openai_write_message :: proc(
    out: ^Openai_Message_Writer,
    message: wire.Message,
    options: Openai_Chat_Options,
    scratch_allocator: runtime.Allocator,
) {
    assert(out != nil, "OpenAI message serialization needs output state")
    assert(out.writer.procedure != nil, "OpenAI message output needs a writer")

    switch value in message {
    case wire.User_Message:
        openai_write_user_message(out, value, scratch_allocator)

    case wire.Assistant_Message:
        openai_write_assistant_message(out, value, options, scratch_allocator)

    case wire.Compaction_Message:
        openai_write_compaction_message(out, value)
    }
}

@(private)
openai_write_user_message :: proc(
    out: ^Openai_Message_Writer,
    message: wire.User_Message,
    scratch_allocator: runtime.Allocator,
) {
    openai_message_sep(out)
    json.write_raw(out.writer, `{"role":"user","content":[`)
    for part, index in message.content {
        if index > 0 do json.write_raw(out.writer, `,`)

        openai_write_content_part(out.writer, part, scratch_allocator)
    }

    json.write_raw(out.writer, `]}`)
}

@(private)
openai_write_content_part :: proc(writer: io.Writer, part: wire.Content_Part, scratch_allocator: runtime.Allocator) {
    switch v in part {
    case wire.Content_Text:
        json.write_raw(writer, `{"type":"text","text":`)
        json.write_string(writer, v.text)
        json.write_raw(writer, `}`)

    case wire.Content_Image:
        json.write_raw(writer, `{"type":"image_url","image_url":{"url":`)
        openai_write_media_url(writer, v.source, scratch_allocator)

        if detail, ok := v.detail.?; ok {
            json.write_raw(writer, `,"detail":`)
            json.write_string(writer, detail)
        }

        json.write_raw(writer, `}}`)

    case wire.Content_Audio:
        json.write_raw(writer, `{"type":"input_audio","input_audio":{"data":`)
        openai_write_media_base64(writer, v.source)
        json.write_raw(writer, `,"format":`)
        json.write_string(writer, v.format)
        json.write_raw(writer, `}}`)

    case wire.Content_File:
        json.write_raw(writer, `{"type":"file","file":{"file_data":`)
        openai_write_media_url(writer, v.source, scratch_allocator)

        if filename, ok := v.filename.?; ok {
            json.write_raw(writer, `,"filename":`)
            json.write_string(writer, filename)
        }

        json.write_raw(writer, `}}`)
    }
}

// Write a media source as a JSON string URL: a passthrough URL or a `data:` URI
// built from inline base64. A blob is unreachable on validated input.
@(private)
openai_write_media_url :: proc(writer: io.Writer, source: wire.Media_Source, scratch_allocator: runtime.Allocator) {
    switch s in source {
    case wire.Media_Url:
        json.write_string(writer, s.url)

    case wire.Media_Base64:
        uri := strings.concatenate({"data:", s.mime, ";base64,", s.data}, scratch_allocator)

        json.write_string(writer, uri)

    case wire.Media_Blob:
        assert(false, "a validated OpenAI request never carries an unresolved blob")
    }
}

// Write the raw base64 bytes an `input_audio` part carries: inline base64
// directly, or the payload after a `data:` URL's `base64,` marker.
@(private)
openai_write_media_base64 :: proc(writer: io.Writer, source: wire.Media_Source) {
    switch s in source {
    case wire.Media_Base64:
        json.write_string(writer, s.data)

    case wire.Media_Url:
        marker := "base64,"
        index := strings.index(s.url, marker)
        assert(index >= 0, "a validated OpenAI audio URL embeds a base64 marker")

        json.write_string(writer, s.url[index + len(marker):])

    case wire.Media_Blob:
        assert(false, "a validated OpenAI request never carries an unresolved blob")
    }
}

@(private)
openai_write_assistant_message :: proc(
    out: ^Openai_Message_Writer,
    message: wire.Assistant_Message,
    options: Openai_Chat_Options,
    scratch_allocator: runtime.Allocator,
) {
    openai_message_sep(out)
    json.write_raw(out.writer, `{"role":"assistant","content":`)

    content := openai_join_assistant_text(message.content, false, scratch_allocator)

    json.write_string(out.writer, content)

    if options.reasoning_replay != .None {
        // @todo: OpenRouter's `reasoning_details` encrypted-on-toolcall array form
        // is not modeled; every replay mode emits the concatenated reasoning text.
        field := openai_reasoning_replay_field(options.reasoning_replay)
        reasoning := openai_join_assistant_text(message.content, true, scratch_allocator)

        json.write_raw(out.writer, `,`)
        json.write_string(out.writer, field)
        json.write_raw(out.writer, `:`)
        json.write_string(out.writer, reasoning)
    }

    first := true
    for part in message.content {
        tool, is_tool := part.(wire.Tool_Part)
        if !is_tool do continue

        if first {
            json.write_raw(out.writer, `,"tool_calls":[`)
            first = false
        } else {
            json.write_raw(out.writer, `,`)
        }

        openai_write_tool_call(out.writer, tool)
    }

    if !first do json.write_raw(out.writer, `]`)

    json.write_raw(out.writer, `}`)

    for part in message.content {
        if tool, is_tool := part.(wire.Tool_Part); is_tool do openai_write_tool_message(out, tool)
    }
}

// Write one `tool_calls` element. `arguments` is relayed verbatim as a JSON
// string, an empty accumulation becoming `{}`.
@(private)
openai_write_tool_call :: proc(writer: io.Writer, tool: wire.Tool_Part) {
    call_id, has_call_id := tool.call_id.?
    assert(has_call_id && len(call_id) > 0, "validated OpenAI tool call has an id")
    assert(len(tool.name) > 0, "validated OpenAI tool call has a name")

    arguments := tool.arguments
    if len(arguments) == 0 do arguments = "{}"

    json.write_raw(writer, `{"id":`)
    json.write_string(writer, call_id)
    json.write_raw(writer, `,"type":"function","function":{"name":`)
    json.write_string(writer, tool.name)
    json.write_raw(writer, `,"arguments":`)
    json.write_string(writer, arguments)
    json.write_raw(writer, `}}`)
}

@(private)
openai_write_tool_message :: proc(out: ^Openai_Message_Writer, tool: wire.Tool_Part) {
    call_id, has_call_id := tool.call_id.?
    assert(has_call_id && len(call_id) > 0, "validated OpenAI tool result has an id")

    result, terminal := tool_result(tool.state)
    assert(terminal, "a validated OpenAI tool result is in a terminal state")

    openai_message_sep(out)
    json.write_raw(out.writer, `{"role":"tool","content":`)
    json.write_string(out.writer, result.content)
    json.write_raw(out.writer, `,"tool_call_id":`)
    json.write_string(out.writer, call_id)
    json.write_raw(out.writer, `}`)
}

// A compaction divider replays as a `user` message carrying its summary, the
// same fold the Anthropic builder uses. An empty summary emits nothing.
@(private)
openai_write_compaction_message :: proc(out: ^Openai_Message_Writer, message: wire.Compaction_Message) {
    if len(message.summary) == 0 do return

    openai_message_sep(out)
    json.write_raw(out.writer, `{"role":"user","content":`)
    json.write_string(out.writer, message.summary)
    json.write_raw(out.writer, `}`)
}

// Concatenate an assistant message's text or reasoning parts in content order.
// The joined result lives in `scratch_allocator`; it is written before that
// arena is reset.
@(private)
openai_join_assistant_text :: proc(
    content: []wire.Assistant_Part,
    reasoning: bool,
    scratch_allocator: runtime.Allocator,
) -> string {
    pieces: [dynamic]string
    pieces.allocator = scratch_allocator

    for part in content {
        piece: string
        take := false

        #partial switch v in part {
        case wire.Text_Part:
            if !reasoning {
                piece = v.text
                take = true
            }

        case wire.Reasoning_Part:
            if reasoning {
                piece = v.text
                take = true
            }
        }

        if take do append(&pieces, piece)
    }

    return strings.concatenate(pieces[:], scratch_allocator)
}

// Write the leading comma between messages and count the one being opened.
@(private)
openai_message_sep :: proc(out: ^Openai_Message_Writer) {
    assert(out != nil, "OpenAI message separator needs output state")
    assert(out.count >= 0, "OpenAI message count cannot be negative")

    if out.count > 0 do json.write_raw(out.writer, `,`)
    out.count += 1
}

#assert(len(Openai_Effort) == 7)
#assert(len(Openai_Thinking_Format) == 9)
#assert(len(Openai_Reasoning_Replay) == 4)
#assert(len(Openai_Max_Tokens_Field) == 2)
