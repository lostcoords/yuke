//! Serialize an OpenAI Responses request from the neutral request.

use crate::encoder::EncodeError;
use crate::request::{
    Block, Media, Modality, Reasoning, ReasoningSettings, ReplayKind, Request, ResponsesDialect, ResponsesWire,
    SEARCH_TOOL_NAME, Target, ToolChoice, ToolDefinition, ToolResult, read_blob,
};

use super::json::{Elements, JsonWriter, object_text};

/// The instructions of a Codex request with no system prompt. The Codex backend refuses a request without them.
const DEFAULT_INSTRUCTIONS: &str = "You are a helpful assistant.";

/// Write the request up to the open `input` array, which holds no element yet.
pub(crate) fn write_head(out: &mut Vec<u8>, target: &Target, wire: ResponsesWire, request: &Request<'_>) -> bool {
    // The Codex backend refuses the sampling limits an API key accepts.
    let standard = wire.dialect == ResponsesDialect::Standard;
    let mut jw = JsonWriter::new(out);
    jw.begin_object();
    jw.field_str("model", &target.model);
    jw.field_bool("stream", true);
    // The caller owns the input history, so the endpoint never keeps a copy.
    jw.field_bool("store", false);
    // A stable key sends every round of one session to the same cache node.
    if !request.session_id.is_empty() {
        jw.field_str("prompt_cache_key", request.session_id);
    }
    if standard {
        if let Some(limit) = request.max_output_tokens {
            jw.field_uint("max_output_tokens", u64::from(limit));
        }
        jw.field_float_opt("temperature", request.temperature);
        jw.field_float_opt("top_p", request.top_p);
    }

    // Responses reasons by default, so only a named effort is worth a control.
    write_reasoning(&mut jw, request.reasoning);
    // Responses names the format under `text`, not `response_format`.
    if let Some(output) = request.output_schema {
        jw.key("text");
        jw.begin_object();
        jw.key("format");
        jw.begin_object();
        jw.field_str("type", "json_schema");
        jw.field_str("name", output.name);
        jw.field_raw("schema", output.schema);
        jw.field_bool("strict", output.strict);
        jw.end_object();
        jw.end_object();
    }

    // Only the Codex backend refuses a request with no instructions, so the standard one omits it.
    if !request.system.is_empty() {
        jw.field_str("instructions", request.system);
    } else if wire.dialect == ResponsesDialect::Codex {
        jw.field_str("instructions", DEFAULT_INSTRUCTIONS);
    }

    // A deferred tool needs the native search tool, so a request that defers declares the search tool natively.
    let native = defers_tools(request.tools);
    if !request.tools.is_empty() {
        jw.key("tools");
        jw.begin_array();
        for tool in request.tools {
            if native && tool.name == SEARCH_TOOL_NAME {
                jw.begin_object();
                jw.field_str("type", "tool_search");
                jw.field_str("execution", "client");
                jw.field_str("description", &tool.description);
                jw.field_raw("parameters", &tool.input_schema);
                jw.end_object();
            } else {
                write_function_tool(&mut jw, tool, tool.defer_loading);
            }
        }
        jw.end_array();
        jw.field_str(
            "tool_choice",
            match request.tool_choice {
                ToolChoice::Auto => "auto",
                ToolChoice::None => "none",
            },
        );
    }

    jw.key("input");
    jw.begin_array();
    false
}

/// One item holds each block, except that a message holds a run of text and media of one role.
fn group_end(target: &Target, blocks: &[Block], start: usize) -> usize {
    if !in_message(&blocks[start]) {
        return start + 1;
    }
    let role = blocks[start].role();
    let mut end = start + 1;
    while end < blocks.len() {
        let block = &blocks[end];
        // A reasoning block without encrypted content writes nothing, so it leaves the message open.
        if (in_message(block) && block.role() == role) || !writes(target, block) {
            end += 1;
            continue;
        }
        break;
    }
    end
}

fn in_message(block: &Block) -> bool {
    matches!(block, Block::UserText(_) | Block::AssistantText(_) | Block::Media(_))
}

fn writes(target: &Target, block: &Block) -> bool {
    match block {
        Block::Reasoning(reasoning) => replayed(target, reasoning).is_some(),
        Block::UserText(_) | Block::AssistantText(_) | Block::Media(_) | Block::ToolCall(_) | Block::ToolResult(_) => {
            true
        }
    }
}

/// The encrypted content a reasoning block returns with. Only content this origin produced in this protocol returns,
/// so other reasoning writes nothing.
fn replayed<'a>(target: &Target, reasoning: &'a Reasoning) -> Option<&'a str> {
    match reasoning.replay_to(target)? {
        (ReplayKind::ResponsesEncrypted, encrypted) if !encrypted.is_empty() => Some(encrypted),
        _ => None,
    }
}

/// Write the item of the group from `start`, and return its end. `marker` is the block that carries the explicit
/// cache breakpoint.
pub(crate) fn write_group(
    elements: &mut Elements<'_>,
    target: &Target,
    request: &Request<'_>,
    start: usize,
    marker: Option<usize>,
) -> Result<usize, EncodeError> {
    let end = group_end(target, request.blocks, start);
    write_item(elements, target, request, start, end, marker)?;
    Ok(end)
}

fn write_item(
    elements: &mut Elements<'_>,
    target: &Target,
    request: &Request<'_>,
    start: usize,
    end: usize,
    marker: Option<usize>,
) -> Result<(), EncodeError> {
    let blocks = request.blocks;
    let first = &blocks[start];
    if !writes(target, first) {
        return Ok(());
    }
    let mut jw = elements.next();
    match first {
        Block::UserText(_) | Block::AssistantText(_) | Block::Media(_) => {
            jw.begin_object();
            jw.field_str("type", "message");
            jw.field_str("role", first.role().as_str());
            jw.key("content");
            jw.begin_array();
            for (index, block) in blocks.iter().enumerate().take(end).skip(start) {
                match block {
                    Block::UserText(text) => {
                        jw.begin_object();
                        jw.field_str("type", "input_text");
                        jw.field_str("text", text);
                        if marker == Some(index) {
                            jw.key("prompt_cache_breakpoint");
                            jw.begin_object();
                            jw.field_str("mode", "explicit");
                            jw.end_object();
                        }
                        jw.end_object();
                    }
                    Block::AssistantText(text) => {
                        jw.begin_object();
                        jw.field_str("type", "output_text");
                        jw.field_str("text", text);
                        jw.end_object();
                    }
                    Block::Media(media) => write_media(&mut jw, request, media)?,
                    // `group_end` admits only empty reasoning beside the message content.
                    _ => debug_assert!(!writes(target, block)),
                }
            }
            jw.end_array();
            jw.end_object();
        }
        Block::Reasoning(reasoning) => {
            if let Some(encrypted) = replayed(target, reasoning) {
                write_reasoning_item(&mut jw, &reasoning.text, encrypted);
            }
        }
        Block::ToolCall(call) => {
            jw.begin_object();
            if call.name == SEARCH_TOOL_NAME && defers_tools(request.tools) {
                jw.field_str("type", "tool_search_call");
                jw.field_str("execution", "client");
                jw.field_str("call_id", &call.call_id);
                jw.field_str("status", "completed");
                jw.field_raw("arguments", &call.arguments);
            } else {
                jw.field_str("type", "function_call");
                jw.field_str("call_id", &call.call_id);
                jw.field_str("name", &call.name);
                // A caller may send no arguments. The endpoint reads a JSON object text.
                jw.field_str("arguments", object_text(&call.arguments));
            }
            jw.end_object();
        }
        Block::ToolResult(result) => {
            if answers_search(&blocks[..start], &result.call_id) && defers_tools(request.tools) {
                write_search_output(&mut jw, result);
                return Ok(());
            }
            jw.begin_object();
            jw.field_str("type", "function_call_output");
            jw.field_str("call_id", &result.call_id);
            jw.key("output");
            if result.media.is_empty() {
                jw.tool_text(&result.content, result.is_error);
            } else {
                jw.begin_array();
                if !result.content.is_empty() || result.is_error {
                    jw.begin_object();
                    jw.field_str("type", "input_text");
                    jw.key("text");
                    jw.tool_text(&result.content, result.is_error);
                    jw.end_object();
                }
                for media in &result.media {
                    write_media(&mut jw, request, media)?;
                }
                jw.end_array();
            }
            jw.end_object();
        }
    }
    Ok(())
}

/// The last user text carries the explicit cache breakpoint. A breakpoint on a tool result never writes a cache.
pub(crate) fn cacheable(block: &Block) -> bool {
    matches!(block, Block::UserText(_))
}

/// True when a request defers a tool, so it declares the search tool natively.
pub(crate) fn defers_tools(tools: &[ToolDefinition]) -> bool {
    tools.iter().any(|tool| tool.defer_loading)
}

/// Write the effort. Responses has no thinking shape of its own, so only `off` and the effort reach the wire.
fn write_reasoning(jw: &mut JsonWriter<'_>, reasoning: ReasoningSettings) {
    // A model that lists `off` takes `none`. It writes no trace, so it needs no include.
    if reasoning.off() {
        jw.key("reasoning");
        jw.begin_object();
        jw.field_str("effort", "none");
        jw.end_object();
        return;
    }
    let Some(effort) = reasoning.effort else { return };
    // Encrypted traces have no visible text without a plaintext summary.
    jw.key("reasoning");
    jw.begin_object();
    jw.field_str("effort", effort.as_str());
    jw.field_str("summary", "auto");
    jw.end_object();
    jw.key("include");
    jw.begin_array();
    jw.string("reasoning.encrypted_content");
    jw.end_array();
}

/// Write one reasoning item. `replayed` admits only non-empty encrypted content.
fn write_reasoning_item(jw: &mut JsonWriter<'_>, summary: &str, encrypted: &str) {
    jw.begin_object();
    jw.field_str("type", "reasoning");
    jw.key("summary");
    jw.begin_array();
    jw.begin_object();
    jw.field_str("type", "summary_text");
    jw.field_str("text", summary);
    jw.end_object();
    jw.end_array();
    jw.field_str("encrypted_content", encrypted);
    jw.end_object();
}

/// Write one function tool. A tool that a search loads keeps `defer_loading`.
fn write_function_tool(jw: &mut JsonWriter<'_>, tool: &ToolDefinition, defer_loading: bool) {
    jw.begin_object();
    jw.field_str("type", "function");
    jw.field_str("name", &tool.name);
    jw.field_str("description", &tool.description);
    if defer_loading {
        jw.field_bool("defer_loading", true);
    }
    jw.field_raw("parameters", &tool.input_schema);
    jw.field_bool("strict", tool.strict);
    jw.end_object();
}

/// Report whether the call a result answers is the search tool. The call comes before its result.
fn answers_search(before: &[Block], call_id: &str) -> bool {
    before
        .iter()
        .rev()
        .find_map(|block| match block {
            Block::ToolCall(call) if call.call_id == call_id => Some(call.name == SEARCH_TOOL_NAME),
            _ => None,
        })
        .unwrap_or(false)
}

/// Answer a client search with its declarations. The output has no error member, so a failed search loads nothing.
fn write_search_output(jw: &mut JsonWriter<'_>, result: &ToolResult) {
    jw.begin_object();
    jw.field_str("type", "tool_search_output");
    jw.field_str("execution", "client");
    jw.field_str("call_id", &result.call_id);
    jw.field_str("status", "completed");
    jw.key("tools");
    jw.begin_array();
    for tool in &result.loaded {
        write_function_tool(jw, tool, true);
    }
    jw.end_array();
    jw.end_object();
}

/// Write one attachment. Responses names the image URL as a plain string, not an object.
fn write_media(jw: &mut JsonWriter<'_>, request: &Request<'_>, media: &Media) -> Result<(), EncodeError> {
    match media.kind() {
        // The schema requires `detail`, and `auto` is the documented default.
        Modality::Image => {
            let data = read_blob(request.blobs, &media.blob)?;
            jw.begin_object();
            jw.field_str("type", "input_image");
            jw.key("image_url");
            jw.base64(Some(&media.mime), &data);
            jw.field_str("detail", "auto");
            jw.end_object();
        }
        // Every document travels as an input file, which names its media type in the data URL.
        Modality::Pdf | Modality::Text | Modality::Other => {
            if media.filename.is_empty() {
                return Err(EncodeError::Unsupported); // The endpoint names the file.
            }
            let data = read_blob(request.blobs, &media.blob)?;
            jw.begin_object();
            jw.field_str("type", "input_file");
            jw.field_str("filename", &media.filename);
            jw.key("file_data");
            jw.base64(Some(&media.mime), &data);
            jw.end_object();
        }
        // This API takes text, image and file alone. Sound needs the Chat Completions endpoint.
        Modality::Audio | Modality::Video => return Err(EncodeError::Unsupported),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Wire;
    use crate::request::{Effort, OutputSchema, Thinking};
    use crate::wire::testing::{blob, call, expect_error, expect_json, replay, result};

    fn responses() -> Wire {
        Wire::OpenaiResponses(ResponsesWire::default())
    }

    fn codex() -> Wire {
        Wire::OpenaiResponses(ResponsesWire {
            dialect: ResponsesDialect::Codex,
            cache: false,
        })
    }

    fn cached() -> Wire {
        Wire::OpenaiResponses(ResponsesWire {
            dialect: ResponsesDialect::Standard,
            cache: true,
        })
    }

    fn media(data: &'static str, mime: &'static str, filename: &'static str) -> Media {
        Media::new(blob(data), mime).with_filename(filename)
    }

    fn reasoning<'a>(text: &'a str, kind: ReplayKind, data: &'a str) -> Block {
        Block::Reasoning(Reasoning {
            text: text.to_string(),
            replay: Some(replay("gpt-5", kind, data)),
        })
    }

    #[test]
    fn user_turn_with_system_prompt() {
        let blocks = [Block::user_text("hello")];
        expect_json(
            r#"{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":1024,"instructions":"be brief","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}"#,
            "gpt-5",
            responses(),
            Request::new(&blocks).system("be brief").max_output_tokens(1024),
        );
    }

    #[test]
    fn effort() {
        let blocks = [Block::user_text("hello")];
        expect_json(
            r#"{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"reasoning":{"effort":"high","summary":"auto"},"include":["reasoning.encrypted_content"],"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}"#,
            "gpt-5",
            responses(),
            Request::new(&blocks).max_output_tokens(8).effort(Effort::High),
        );
    }

    // gpt-5.1 and later list `off`, and this endpoint spells it `none`.
    #[test]
    fn thinking_off_sends_no_reasoning() {
        let blocks = [Block::user_text("hello")];
        expect_json(
            r#"{"model":"gpt-5.2","stream":true,"store":false,"max_output_tokens":8,"reasoning":{"effort":"none"},"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}"#,
            "gpt-5.2",
            responses(),
            Request::new(&blocks).max_output_tokens(8).thinking(Thinking::Off),
        );
    }

    #[test]
    fn assistant_items_precede_tool_result() {
        let blocks = [
            reasoning("check", ReplayKind::ResponsesEncrypted, "sig_1"),
            Block::assistant_text("checking"),
            call("call_1", "run", r#"{"c":1}"#),
            Block::ToolResult(result("call_1", "ok", false)),
        ];
        expect_json(
            r#"{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":64,"input":[{"type":"reasoning","summary":[{"type":"summary_text","text":"check"}],"encrypted_content":"sig_1"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"checking"}]},{"type":"function_call","call_id":"call_1","name":"run","arguments":"{\"c\":1}"},{"type":"function_call_output","call_id":"call_1","output":"ok"}]}"#,
            "gpt-5",
            responses(),
            Request::new(&blocks).max_output_tokens(64),
        );
    }

    #[test]
    fn error_result_prefixes_text() {
        let blocks = [
            call("call_1", "run", "{}"),
            Block::ToolResult(result("call_1", "no \"x\"", true)),
        ];
        expect_json(
            r#"{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":64,"input":[{"type":"function_call","call_id":"call_1","name":"run","arguments":"{}"},{"type":"function_call_output","call_id":"call_1","output":"Error: no \"x\""}]}"#,
            "gpt-5",
            responses(),
            Request::new(&blocks).max_output_tokens(64),
        );
    }

    #[test]
    fn tool_result_with_image() {
        for (text, is_error, output) in [("PNG image", false, "PNG image"), ("", true, "Error: ")] {
            let blocks = [
                call("call_1", "read", "{}"),
                Block::ToolResult(result("call_1", text, is_error).with_media(vec![media("ab", "image/png", "")])),
            ];
            let expected = format!(
                r#"{{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"input":[{{"type":"function_call","call_id":"call_1","name":"read","arguments":"{{}}"}},{{"type":"function_call_output","call_id":"call_1","output":[{{"type":"input_text","text":"{output}"}},{{"type":"input_image","image_url":"data:image/png;base64,YWI=","detail":"auto"}}]}}]}}"#
            );
            expect_json(
                &expected,
                "gpt-5",
                responses(),
                Request::new(&blocks).max_output_tokens(8),
            );
        }
    }

    #[test]
    fn deferred_tools_use_client_search() {
        let tools = [
            ToolDefinition::new(SEARCH_TOOL_NAME, "Find.", r#"{"type":"object"}"#),
            ToolDefinition::new("mcp_read", "Read.", "{}").deferred(),
        ];
        let blocks = [
            Block::user_text("go"),
            call("call_1", SEARCH_TOOL_NAME, r#"{"query":"read"}"#),
            Block::ToolResult(result("call_1", "found", false).with_loaded(tools[1..].to_vec())),
        ];
        expect_json(
            r#"{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"tools":[{"type":"tool_search","execution":"client","description":"Find.","parameters":{"type":"object"}},{"type":"function","name":"mcp_read","description":"Read.","defer_loading":true,"parameters":{},"strict":false}],"tool_choice":"auto","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]},{"type":"tool_search_call","execution":"client","call_id":"call_1","status":"completed","arguments":{"query":"read"}},{"type":"tool_search_output","execution":"client","call_id":"call_1","status":"completed","tools":[{"type":"function","name":"mcp_read","description":"Read.","defer_loading":true,"parameters":{},"strict":false}]}]}"#,
            "gpt-5",
            responses(),
            Request::new(&blocks).tools(&tools).max_output_tokens(8),
        );
        // Without a deferred tool, as on a bridge target, the search is an ordinary call and its result keeps its text.
        expect_json(
            r#"{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"tools":[{"type":"function","name":"tool_search","description":"Find.","parameters":{"type":"object"},"strict":false}],"tool_choice":"auto","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]},{"type":"function_call","call_id":"call_1","name":"tool_search","arguments":"{\"query\":\"read\"}"},{"type":"function_call_output","call_id":"call_1","output":"found"}]}"#,
            "gpt-5",
            responses(),
            Request::new(&blocks).tools(&tools[..1]).max_output_tokens(8),
        );
    }

    #[test]
    fn tool_schema_and_strict_mode() {
        let tools = [
            ToolDefinition::new("run", "run a command", r#"{"type":"object"}"#),
            ToolDefinition::new("strict_run", "run strictly", r#"{"type":"object"}"#).strict(),
        ];
        let blocks = [Block::user_text("go")];
        expect_json(
            r#"{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"tools":[{"type":"function","name":"run","description":"run a command","parameters":{"type":"object"},"strict":false},{"type":"function","name":"strict_run","description":"run strictly","parameters":{"type":"object"},"strict":true}],"tool_choice":"auto","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}]}"#,
            "gpt-5",
            responses(),
            Request::new(&blocks).tools(&tools).max_output_tokens(8),
        );
    }

    #[test]
    fn schema_uses_text_format() {
        let blocks = [Block::user_text("go")];
        let request = Request::new(&blocks).max_output_tokens(8);
        let mut schema = OutputSchema {
            name: "person",
            ..OutputSchema::new(r#"{"type":"object"}"#)
        };
        for (strict, expected) in [
            (
                true,
                r#"{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"text":{"format":{"type":"json_schema","name":"person","schema":{"type":"object"},"strict":true}},"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}]}"#,
            ),
            (
                false,
                r#"{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"text":{"format":{"type":"json_schema","name":"person","schema":{"type":"object"},"strict":false}},"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}]}"#,
            ),
        ] {
            schema.strict = strict;
            expect_json(expected, "gpt-5", responses(), request.output_schema(schema));
        }
    }

    #[test]
    fn rejects_audio() {
        // The Responses input union is text, image and file alone. Audio needs Chat Completions.
        let blocks = [Block::Media(media("ab", "audio/wav", ""))];
        expect_error(
            EncodeError::Unsupported,
            "gpt-5",
            responses(),
            Request::new(&blocks).max_output_tokens(8),
        );
    }

    #[test]
    fn attachment_input_parts() {
        let blocks = [
            Block::Media(media("ab", "image/png", "")),
            Block::Media(media("ab", "application/pdf", "a.pdf")),
        ];
        expect_json(
            r#"{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"input":[{"type":"message","role":"user","content":[{"type":"input_image","image_url":"data:image/png;base64,YWI=","detail":"auto"},{"type":"input_file","filename":"a.pdf","file_data":"data:application/pdf;base64,YWI="}]}]}"#,
            "gpt-5",
            responses(),
            Request::new(&blocks).max_output_tokens(8),
        );
    }

    #[test]
    fn breakpoint_marks_last_user_text() {
        let blocks = [
            Block::user_text("one"),
            Block::assistant_text("two"),
            Block::user_text("three"),
        ];
        expect_json(
            r#"{"model":"gpt-5.6","stream":true,"store":false,"max_output_tokens":8,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"one"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"two"}]},{"type":"message","role":"user","content":[{"type":"input_text","text":"three","prompt_cache_breakpoint":{"mode":"explicit"}}]}]}"#,
            "gpt-5.6",
            cached(),
            Request::new(&blocks).max_output_tokens(8),
        );
    }

    #[test]
    fn cache_key_in_every_dialect() {
        let blocks = [Block::ToolResult(result("c1", "ok", false))];
        // The codex route marks no breakpoint, so the key is the only cache control it carries.
        expect_json(
            r#"{"model":"gpt-5.6","stream":true,"store":false,"prompt_cache_key":"0123456789abcdef","max_output_tokens":8,"input":[{"type":"function_call_output","call_id":"c1","output":"ok"}]}"#,
            "gpt-5.6",
            responses(),
            Request::new(&blocks)
                .max_output_tokens(8)
                .session_id("0123456789abcdef"),
        );
        expect_json(
            r#"{"model":"gpt-5.6","stream":true,"store":false,"prompt_cache_key":"0123456789abcdef","instructions":"You are a helpful assistant.","input":[{"type":"function_call_output","call_id":"c1","output":"ok"}]}"#,
            "gpt-5.6",
            codex(),
            Request::new(&blocks)
                .max_output_tokens(8)
                .session_id("0123456789abcdef"),
        );
    }

    #[test]
    fn breakpoint_needs_user_text() {
        // The endpoint refuses a breakpoint on instructions, so a tool-result-only turn marks nothing.
        let only_result = [Block::ToolResult(result("c1", "ok", false))];
        expect_json(
            r#"{"model":"gpt-5.6","stream":true,"store":false,"max_output_tokens":8,"input":[{"type":"function_call_output","call_id":"c1","output":"ok"}]}"#,
            "gpt-5.6",
            cached(),
            Request::new(&only_result).max_output_tokens(8),
        );
        // A tool call and its result after the user text leave the marker on that text.
        let after = [
            Block::user_text("q"),
            call("c1", "ls", "{}"),
            Block::ToolResult(result("c1", "ok", false)),
        ];
        expect_json(
            r#"{"model":"gpt-5.6","stream":true,"store":false,"max_output_tokens":8,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"q","prompt_cache_breakpoint":{"mode":"explicit"}}]},{"type":"function_call","call_id":"c1","name":"ls","arguments":"{}"},{"type":"function_call_output","call_id":"c1","output":"ok"}]}"#,
            "gpt-5.6",
            cached(),
            Request::new(&after).max_output_tokens(8),
        );
    }

    #[test]
    fn codex_dialect() {
        let blocks = [Block::user_text("hello")];
        let request = Request::new(&blocks).max_output_tokens(8).temperature(0.7).top_p(0.9);
        expect_json(
            r#"{"model":"gpt-5","stream":true,"store":false,"max_output_tokens":8,"temperature":0.7,"top_p":0.9,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}"#,
            "gpt-5",
            responses(),
            request,
        );
        // The ChatGPT backend refuses every sampling limit, exactly as it refuses the token ceiling.
        expect_json(
            r#"{"model":"gpt-5","stream":true,"store":false,"instructions":"You are a helpful assistant.","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}]}"#,
            "gpt-5",
            codex(),
            request,
        );
    }

    #[test]
    fn empty_arguments_send_empty_object() {
        let blocks = [call("c", "ls", ""), Block::ToolResult(result("c", "ok", false))];
        expect_json(
            r#"{"model":"m","stream":true,"store":false,"max_output_tokens":8,"input":[{"type":"function_call","call_id":"c","name":"ls","arguments":"{}"},{"type":"function_call_output","call_id":"c","output":"ok"}]}"#,
            "m",
            responses(),
            Request::new(&blocks).max_output_tokens(8),
        );
    }

    #[test]
    fn foreign_reasoning_is_dropped() {
        let blocks = [
            Block::Reasoning(Reasoning {
                text: "unsigned".to_string(),
                replay: None,
            }),
            reasoning("t", ReplayKind::AnthropicSignature, "sig"),
            reasoning("", ReplayKind::AnthropicRedacted, "opaque"),
            reasoning("t", ReplayKind::OpenrouterDetails, "[]"),
            Block::assistant_text("done"),
        ];
        expect_json(
            r#"{"model":"gpt-5","stream":true,"store":false,"input":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}"#,
            "gpt-5",
            responses(),
            Request::new(&blocks),
        );
    }
}
