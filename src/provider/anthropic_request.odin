package provider

import "base:runtime"
import stdjson "core:encoding/json"
import "core:io"
import "core:strings"
import "core:unicode/utf8"

import "libs:json"
import "src:wire"

// How Anthropic returns the readable portion of a thinking block.
Anthropic_Thinking_Display :: enum {
    Summarized,
    Omitted,
}

// Anthropic effort values. Model/catalog resolution must choose only a level
// supported by the resolved model.
Anthropic_Effort :: enum {
    Low,
    Medium,
    High,
    Xhigh,
    Max,
}

// Omit the `thinking` member and use the endpoint's default.
Anthropic_Thinking_Default :: struct {}

// Explicitly disable thinking on a model that permits it.
Anthropic_Thinking_Disabled :: struct {}

// Let a current Anthropic model decide when and how much to think.
Anthropic_Thinking_Adaptive :: struct {
    // Whether response thinking text is summarized or omitted; absent uses the
    // model default.
    display: Maybe(Anthropic_Thinking_Display),
}

// Smallest thinking budget the endpoint accepts.
ANTHROPIC_THINKING_BUDGET_MIN :: 1024

// Legacy token-budget thinking for older models and compatible endpoints.
Anthropic_Thinking_Enabled :: struct {
    // Thinking-token budget; at least `ANTHROPIC_THINKING_BUDGET_MIN` and below `max_output_tokens`.
    budget_tokens: u64,

    // Whether response thinking text is summarized or omitted; absent uses the
    // model default.
    display:       Maybe(Anthropic_Thinking_Display),
}

// Resolved Anthropic thinking mode for a request.
Anthropic_Thinking :: union {
    Anthropic_Thinking_Default,
    Anthropic_Thinking_Disabled,
    Anthropic_Thinking_Adaptive,
    Anthropic_Thinking_Enabled,
}

// Anthropic-only controls chosen after catalog/model resolution.
Anthropic_Options :: struct {
    // Thinking request shape; nil has the same omit semantics as `Default`.
    thinking: Anthropic_Thinking,

    // Whole-request effort under `output_config`; absent uses the model default.
    effort:   Maybe(Anthropic_Effort),
}

@(private)
Anthropic_Role :: enum {
    None,
    User,
    Assistant,
}

// Streaming JSON state for the provider `messages` array. Consecutive blocks
// with the same role share one message object.
@(private)
Anthropic_Message_Writer :: struct {
    writer:        io.Writer,
    role:          Anthropic_Role,
    message_count: int,
    block_count:   int,
}

// Build one Anthropic Messages request body. The body is allocated into
// `allocator` and parsed schemas and tool arguments into `scratch_allocator`;
// nothing but the buffer of a failed build is freed, so both are expected to be
// arenas.
anthropic_request_body :: proc(
    request: Request,
    options: Anthropic_Options,
    allocator := context.allocator,
    scratch_allocator: runtime.Allocator,
) -> (
    body: string,
    err: Transport_Error,
) {
    assert(allocator.procedure != nil, "Anthropic request builder needs a valid output allocator")
    assert(scratch_allocator.procedure != nil, "Anthropic request builder needs a valid scratch allocator")

    err = anthropic_request_validate(request, options, scratch_allocator)
    if err != .None {
        return "", err
    }

    builder := strings.builder_make(0, 4096, allocator)
    defer if err != .None {
        strings.builder_destroy(&builder)
    }

    writer := strings.to_writer(&builder)
    json.write_raw(writer, `{"model":`)
    json.write_string(writer, request.model)
    json.write_raw(writer, `,"max_tokens":`)
    json.write_u64(writer, request.max_output_tokens)
    json.write_raw(writer, `,"stream":true`)

    if system, present := request.system_prompt.?; present && len(system) > 0 {
        json.write_raw(writer, `,"system":`)
        json.write_string(writer, system)
    }

    anthropic_write_thinking(writer, options.thinking)

    if effort, present := options.effort.?; present {
        json.write_raw(writer, `,"output_config":{"effort":`)
        json.write_string(writer, anthropic_effort_wire[effort])
        json.write_raw(writer, `}`)
    }

    if temperature, present := request.temperature.?; present {
        json.write_raw(writer, `,"temperature":`)
        json.write_f64(writer, temperature)
    }

    if len(request.tools) > 0 {
        anthropic_write_tools(writer, request.tools)
    }

    json.write_raw(writer, `,"messages":[`)
    messages := Anthropic_Message_Writer {
        writer = writer,
    }
    for message in request.messages {
        anthropic_write_message(&messages, message, request.provenance_model)
    }

    if messages.message_count == 0 {
        return "", .Invalid_Request
    }

    anthropic_message_close(&messages)
    json.write_raw(writer, `]}`)

    body = strings.to_string(builder)
    return body, .None
}

@(private)
anthropic_request_validate :: proc(
    request: Request,
    options: Anthropic_Options,
    scratch_allocator: runtime.Allocator,
) -> Transport_Error {
    if len(request.model) == 0 || len(request.model) > 128 || !utf8.valid_string(request.model) {
        return .Invalid_Request
    }

    if len(request.provenance_model) == 0 || !utf8.valid_string(request.provenance_model) {
        return .Invalid_Request
    }

    if request.max_output_tokens == 0 || request.max_output_tokens > MAX_EXACT_JSON_INTEGER {
        return .Invalid_Request
    }

    if system, present := request.system_prompt.?; present && !utf8.valid_string(system) {
        return .Invalid_Request
    }

    thinking_on := false
    if options.thinking != nil {
        switch thinking in options.thinking {
        case Anthropic_Thinking_Default, Anthropic_Thinking_Disabled:

        case Anthropic_Thinking_Adaptive:
            thinking_on = true
            if !anthropic_display_valid(thinking.display) {
                return .Invalid_Request
            }

        case Anthropic_Thinking_Enabled:
            thinking_on = true
            if thinking.budget_tokens < ANTHROPIC_THINKING_BUDGET_MIN ||
               thinking.budget_tokens >= request.max_output_tokens {
                return .Invalid_Request
            }

            if !anthropic_display_valid(thinking.display) {
                return .Invalid_Request
            }
        }
    }

    if effort, present := options.effort.?; present {
        index := int(effort)
        if index < 0 || index >= len(anthropic_effort_wire) {
            return .Invalid_Request
        }
    }

    if temperature, present := request.temperature.?; present {
        bits := transmute(u64)temperature
        finite := (bits >> 52) & 0x7ff != 0x7ff

        if !finite || temperature < 0 || temperature > 1 || thinking_on {
            return .Invalid_Request
        }
    }

    tools_validate(request.tools, scratch_allocator) or_return

    if len(request.messages) == 0 {
        return .Invalid_Request
    }

    for message in request.messages {
        if wire.message_validate(message) != .None || !anthropic_message_supported(message) {
            return .Invalid_Request
        }

        anthropic_tool_arguments_validate(message, scratch_allocator) or_return
    }

    return .None
}

// Structural preflight for assistant tool_use arguments: a non-empty argument
// blob must be exactly one JSON object, parsed into `scratch_allocator`. This
// mirrors the serialization walk one-to-one, so the writer emits arguments raw
// with no re-parse.
@(private)
anthropic_tool_arguments_validate :: proc(
    message: wire.Message,
    scratch_allocator: runtime.Allocator,
) -> Transport_Error {
    assistant, is_assistant := message.(wire.Assistant_Message)
    if !is_assistant {
        return .None
    }

    for part in assistant.content {
        tool, is_tool := part.(wire.Tool_Part)
        if !is_tool || len(tool.arguments) == 0 {
            continue
        }

        value, _, parse_err := decode_json_object(tool.arguments, scratch_allocator)
        if parse_err != .None {
            return parse_err == .Resource_Exhausted ? .Resource_Exhausted : .Invalid_Request
        }

        stdjson.destroy_value(value, scratch_allocator)
    }

    return .None
}

@(private)
anthropic_message_supported :: proc(message: wire.Message) -> bool {
    switch value in message {
    case wire.User_Message:
        for part in value.content {
            if !anthropic_content_supported(part) {
                return false
            }
        }

    case wire.Assistant_Message:
        for part in value.content {
            switch content in part {
            case wire.Text_Part:
                if !utf8.valid_string(content.text) {
                    return false
                }

            case wire.Reasoning_Part:
                if !utf8.valid_string(content.text) || !utf8.valid_string(content.signature) {
                    return false
                }

            case wire.Redacted_Reasoning_Part:
                if len(content.data) == 0 || !utf8.valid_string(content.data) {
                    return false
                }

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
                    if !utf8.valid_string(state.output) {
                        return false
                    }

                case wire.Tool_State_Error:
                    if !utf8.valid_string(state.error) {
                        return false
                    }

                case wire.Tool_State_Denied:
                    if !utf8.valid_string(state.reason) {
                        return false
                    }

                case wire.Tool_State_Canceled:

                case wire.Tool_State_Pending, wire.Tool_State_Waiting_Permission, wire.Tool_State_Running:
                    return false
                }

            case:
                return false
            }
        }

    case wire.Compaction_Message:
        return utf8.valid_string(value.summary)

    case:
        return false
    }

    return true
}

// Anthropic Messages accepts text and image user content. Audio and document
// parts are out of scope, and an unresolved blob never reaches the builder: the
// daemon inlines blobs to base64 first.
@(private)
anthropic_content_supported :: proc(part: wire.Content_Part) -> bool {
    #partial switch v in part {
    case wire.Content_Text:
        return utf8.valid_string(v.text)

    case wire.Content_Image:
        return anthropic_image_source_supported(v.source)
    }

    return false
}

@(private)
anthropic_image_source_supported :: proc(source: wire.Media_Source) -> bool {
    #partial switch s in source {
    case wire.Media_Url:
        return utf8.valid_string(s.url)

    case wire.Media_Base64:
        return utf8.valid_string(s.mime) && utf8.valid_string(s.data)
    }

    return false
}

@(private)
anthropic_display_valid :: proc(display: Maybe(Anthropic_Thinking_Display)) -> bool {
    if value, present := display.?; present {
        index := int(value)
        return index >= 0 && index < len(anthropic_display_wire)
    }

    return true
}

@(rodata)
anthropic_display_wire := [Anthropic_Thinking_Display]string {
    .Summarized = "summarized",
    .Omitted    = "omitted",
}

@(rodata)
anthropic_effort_wire := [Anthropic_Effort]string {
    .Low    = "low",
    .Medium = "medium",
    .High   = "high",
    .Xhigh  = "xhigh",
    .Max    = "max",
}

@(private)
anthropic_write_thinking :: proc(writer: io.Writer, value: Anthropic_Thinking) {
    if value == nil {
        return
    }

    switch thinking in value {
    case Anthropic_Thinking_Default:
        return

    case Anthropic_Thinking_Disabled:
        json.write_raw(writer, `,"thinking":{"type":"disabled"}`)

    case Anthropic_Thinking_Adaptive:
        json.write_raw(writer, `,"thinking":{"type":"adaptive"`)
        anthropic_write_display(writer, thinking.display)
        json.write_raw(writer, `}`)

    case Anthropic_Thinking_Enabled:
        json.write_raw(writer, `,"thinking":{"type":"enabled","budget_tokens":`)
        json.write_u64(writer, thinking.budget_tokens)
        anthropic_write_display(writer, thinking.display)
        json.write_raw(writer, `}`)
    }
}

@(private)
anthropic_write_display :: proc(writer: io.Writer, display: Maybe(Anthropic_Thinking_Display)) {
    if value, present := display.?; present {
        json.write_raw(writer, `,"display":`)
        json.write_string(writer, anthropic_display_wire[value])
    }
}

@(private)
anthropic_write_tools :: proc(writer: io.Writer, tools: []Tool_Definition) {
    assert(len(tools) > 0, "Anthropic tools writer needs a non-empty slice")

    json.write_raw(writer, `,"tools":[`)
    for tool, index in tools {
        if index > 0 {
            json.write_raw(writer, `,`)
        }

        json.write_raw(writer, `{"name":`)
        json.write_string(writer, tool.name)
        json.write_raw(writer, `,"description":`)
        json.write_string(writer, tool.description)
        json.write_raw(writer, `,"input_schema":`)
        json.write_raw(writer, tool.input_schema)
        json.write_raw(writer, `}`)
    }

    json.write_raw(writer, `]`)
}

@(private)
anthropic_write_message :: proc(out: ^Anthropic_Message_Writer, message: wire.Message, provenance_model: string) {
    assert(out != nil, "Anthropic message serialization needs output state")
    assert(out.writer.procedure != nil, "Anthropic message output needs a writer")
    assert(len(provenance_model) > 0, "Anthropic message serialization needs a public model")

    switch value in message {
    case wire.User_Message:
        for part in value.content {
            switch content in part {
            case wire.Content_Text:
                if len(content.text) > 0 {
                    anthropic_write_text_block(out, .User, content.text)
                }

            case wire.Content_Image:
                anthropic_write_image_block(out, content.source)

            case wire.Content_Audio, wire.Content_File:
                // @todo Anthropic document/PDF support could map Content_File to a `document` block.
                // Preflight rejects both content kinds, so the writer never reaches them.
                unreachable()
            }
        }

    case wire.Assistant_Message:
        // All-or-nothing: the provider rejects a partially dropped sequence.
        replay_thinking := false
        if provenance, present := value.provenance.?; present {
            replay_thinking = provenance.protocol == .Anthropic_Messages && provenance.model == provenance_model
        }

        if replay_thinking {
            for part in value.content {
                reasoning, is_reasoning := part.(wire.Reasoning_Part)
                if is_reasoning && len(reasoning.signature) == 0 {
                    replay_thinking = false
                    break
                }
            }
        }

        for part in value.content {
            switch content in part {
            case wire.Text_Part:
                if len(content.text) > 0 {
                    anthropic_write_text_block(out, .Assistant, content.text)
                }

            case wire.Reasoning_Part:
                if replay_thinking {
                    anthropic_write_thinking_block(out, content.text, content.signature)
                }

            case wire.Redacted_Reasoning_Part:
                if replay_thinking {
                    anthropic_write_redacted_thinking_block(out, content.data)
                }

            case wire.Tool_Part:
                anthropic_write_tool_use_block(out, content)
            }
        }

        for part in value.content {
            if tool, is_tool := part.(wire.Tool_Part); is_tool {
                anthropic_write_tool_result_block(out, tool)
            }
        }

    case wire.Compaction_Message:
        if len(value.summary) > 0 {
            anthropic_write_text_block(out, .User, value.summary)
        }
    }
}

@(private)
anthropic_message_block_begin :: proc(out: ^Anthropic_Message_Writer, role: Anthropic_Role) {
    assert(out != nil, "Anthropic block serialization needs output state")
    assert(role == .User || role == .Assistant, "Anthropic content needs a provider role")
    assert(out.message_count >= 0, "Anthropic message count cannot be negative")
    assert(out.block_count >= 0, "Anthropic block count cannot be negative")

    if out.role != role {
        anthropic_message_close(out)

        if out.message_count > 0 {
            json.write_raw(out.writer, `,`)
        }

        role_wire := "user" if role == .User else "assistant"
        json.write_raw(out.writer, `{"role":`)
        json.write_string(out.writer, role_wire)
        json.write_raw(out.writer, `,"content":[`)
        out.role = role
        out.message_count += 1
        out.block_count = 0
    }

    if out.block_count > 0 {
        json.write_raw(out.writer, `,`)
    }
    out.block_count += 1
}

@(private)
anthropic_message_close :: proc(out: ^Anthropic_Message_Writer) {
    assert(out != nil, "Anthropic message close needs output state")
    assert(out.message_count >= 0, "Anthropic message count cannot be negative")
    assert(out.block_count >= 0, "Anthropic block count cannot be negative")

    if out.role == .None {
        assert(out.block_count == 0, "closed Anthropic message has no blocks")
        return
    }

    assert(out.block_count > 0, "open Anthropic message must contain a block")
    json.write_raw(out.writer, `]}`)
    out.role = .None
    out.block_count = 0
}

@(private)
anthropic_write_text_block :: proc(out: ^Anthropic_Message_Writer, role: Anthropic_Role, text: string) {
    assert(len(text) > 0, "Anthropic text blocks are never empty")

    anthropic_message_block_begin(out, role)
    json.write_raw(out.writer, `{"type":"text","text":`)
    json.write_string(out.writer, text)
    json.write_raw(out.writer, `}`)
}

@(private)
anthropic_write_image_block :: proc(out: ^Anthropic_Message_Writer, source: wire.Media_Source) {
    anthropic_message_block_begin(out, .User)
    json.write_raw(out.writer, `{"type":"image","source":`)
    anthropic_write_image_source(out.writer, source)
    json.write_raw(out.writer, `}`)
}

// Write an Anthropic image `source` object. The wire `detail` hint has no
// equivalent and is dropped. A blob never reaches a validated request; the
// daemon inlines blobs to base64 first.
@(private)
anthropic_write_image_source :: proc(writer: io.Writer, source: wire.Media_Source) {
    switch s in source {
    case wire.Media_Base64:
        json.write_raw(writer, `{"type":"base64","media_type":`)
        json.write_string(writer, s.mime)
        json.write_raw(writer, `,"data":`)
        json.write_string(writer, s.data)
        json.write_raw(writer, `}`)

    case wire.Media_Url:
        json.write_raw(writer, `{"type":"url","url":`)
        json.write_string(writer, s.url)
        json.write_raw(writer, `}`)

    case wire.Media_Blob:
        assert(false, "a validated Anthropic request never carries an unresolved blob")
    }
}

@(private)
anthropic_write_thinking_block :: proc(out: ^Anthropic_Message_Writer, thinking: string, signature: string) {
    assert(len(signature) > 0, "replayed Anthropic thinking must be signed")

    anthropic_message_block_begin(out, .Assistant)
    json.write_raw(out.writer, `{"type":"thinking","thinking":`)
    json.write_string(out.writer, thinking)
    json.write_raw(out.writer, `,"signature":`)
    json.write_string(out.writer, signature)
    json.write_raw(out.writer, `}`)
}

@(private)
anthropic_write_redacted_thinking_block :: proc(out: ^Anthropic_Message_Writer, data: string) {
    assert(len(data) > 0, "replayed Anthropic redacted thinking retains provider data")

    anthropic_message_block_begin(out, .Assistant)
    json.write_raw(out.writer, `{"type":"redacted_thinking","data":`)
    json.write_string(out.writer, data)
    json.write_raw(out.writer, `}`)
}

@(private)
anthropic_write_tool_use_block :: proc(out: ^Anthropic_Message_Writer, tool: wire.Tool_Part) {
    call_id, has_call_id := tool.call_id.?
    assert(has_call_id && len(call_id) > 0, "validated Anthropic tool use has an id")
    assert(len(tool.name) > 0, "validated Anthropic tool use has a name")

    // Arguments were structurally validated in preflight; write them raw.
    arguments := tool.arguments
    if len(arguments) == 0 {
        arguments = "{}"
    }

    anthropic_message_block_begin(out, .Assistant)
    json.write_raw(out.writer, `{"type":"tool_use","id":`)
    json.write_string(out.writer, call_id)
    json.write_raw(out.writer, `,"name":`)
    json.write_string(out.writer, tool.name)
    json.write_raw(out.writer, `,"input":`)
    json.write_raw(out.writer, arguments)
    json.write_raw(out.writer, `}`)
}

@(private)
anthropic_write_tool_result_block :: proc(out: ^Anthropic_Message_Writer, tool: wire.Tool_Part) {
    call_id, has_call_id := tool.call_id.?
    assert(has_call_id && len(call_id) > 0, "validated Anthropic tool result has an id")

    result, terminal := tool_result(tool.state)
    assert(terminal, "a validated Anthropic tool result is in a terminal state")

    anthropic_message_block_begin(out, .User)
    json.write_raw(out.writer, `{"type":"tool_result","tool_use_id":`)
    json.write_string(out.writer, call_id)
    json.write_raw(out.writer, `,"content":`)
    json.write_string(out.writer, result.content)
    if result.is_error {
        json.write_raw(out.writer, `,"is_error":true`)
    }

    json.write_raw(out.writer, `}`)
}

#assert(len(Anthropic_Thinking_Display) == 2)
#assert(len(Anthropic_Effort) == 5)
