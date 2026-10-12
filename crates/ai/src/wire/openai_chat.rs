//! Serialize OpenAI Chat Completions requests from the neutral request.

use crate::encoder::EncodeError;
use crate::request::{
    Block, ChatDialect, ChatWire, MaxTokensField, Media, Modality, Reasoning, ReasoningReplayMode, ReasoningSettings,
    ReplayKind, Request, Target, ThinkingFormat, ToolChoice, ToolResult, read_blob,
};

use super::json::{JsonWriter, object_text};

/// Write the request up to the open `messages` array. Return whether it wrote the system message into it.
pub(crate) fn write_head(
    out: &mut Vec<u8>,
    target: &Target,
    wire: ChatWire,
    request: &Request<'_>,
) -> Result<bool, EncodeError> {
    if super::defers_tools(request.tools) {
        return Err(EncodeError::Unsupported);
    }
    let mut jw = JsonWriter::new(out);
    jw.begin_object();
    jw.field_str("model", &target.model);
    jw.field_bool("stream", true);
    // Most hosts report the usage of a stream only on request. Mistral reports it unasked and refuses the member.
    if wire.dialect == ChatDialect::Standard {
        jw.key("stream_options");
        jw.begin_object();
        jw.field_bool("include_usage", true);
        jw.end_object();
    }
    // The field enum names the member.
    if let Some(limit) = request.settings.max_output_tokens {
        let member = match wire.max_tokens_field {
            MaxTokensField::MaxTokens => "max_tokens",
            MaxTokensField::MaxCompletionTokens => "max_completion_tokens",
        };
        jw.field_uint(member, u64::from(limit));
    }
    jw.field_float_opt("temperature", request.settings.temperature);
    jw.field_float_opt("top_p", request.settings.top_p);
    // This endpoint writes no cache marker: OpenAI documents explicit breakpoints for Responses alone.
    write_reasoning(&mut jw, wire.thinking_format, request.settings.reasoning);
    // The endpoint nests the schema one level deeper than Responses.
    if let Some(output) = &request.settings.output_schema {
        jw.key("response_format");
        jw.begin_object();
        jw.field_str("type", "json_schema");
        jw.key("json_schema");
        jw.begin_object();
        jw.field_str("name", &output.name);
        jw.field_raw("schema", &output.schema);
        jw.field_bool("strict", output.strict);
        jw.end_object();
        jw.end_object();
    }

    if !request.tools.is_empty() {
        jw.key("tools");
        jw.begin_array();
        for tool in request.tools {
            jw.begin_object();
            jw.field_str("type", "function");
            jw.key("function");
            jw.begin_object();
            jw.field_str("name", &tool.name);
            jw.field_str("description", &tool.description);
            jw.field_raw("parameters", &tool.input_schema);
            // Some compatible hosts refuse a member they do not know, so only strict mode writes it, as pi does.
            if tool.strict {
                jw.field_bool("strict", true);
            }
            jw.end_object();
            jw.end_object();
        }
        jw.end_array();
        // This host reads no member as the automatic control, so only a refusal writes one.
        if request.settings.tool_choice == ToolChoice::None {
            jw.field_str("tool_choice", "none");
        }
    }

    jw.key("messages");
    jw.begin_array();
    if request.settings.system.is_empty() {
        return Ok(false);
    }
    jw.begin_object();
    jw.field_str("role", "system");
    jw.field_str("content", &request.settings.system);
    jw.end_object();
    Ok(true)
}

/// The end of the run of user text and media from `start`.
fn user_end(blocks: &[Block], start: usize) -> usize {
    blocks[start..]
        .iter()
        .position(|block| !matches!(block, Block::UserText(_) | Block::Media(_)))
        .map_or(blocks.len(), |len| start + len)
}

/// Write the messages of the group from `start`, and return its end. A group is a user run, an assistant run, or tool
/// results with the user blocks that take their attachments.
pub(crate) fn write_group(
    jw: &mut JsonWriter<'_>,
    target: &Target,
    wire: ChatWire,
    request: &Request<'_>,
    start: usize,
) -> Result<usize, EncodeError> {
    let blocks = request.blocks;
    match blocks[start] {
        Block::ToolResult(_) => {
            let mut results_end = start;
            let mut images = false;
            while let Some(Block::ToolResult(result)) = blocks.get(results_end) {
                write_tool_result(jw, result);
                images = images || !result.media.is_empty();
                results_end += 1;
            }
            if !images {
                return Ok(results_end);
            }
            // A tool message holds text only, so its images move into a user message. A strict host refuses two user
            // messages in a row, so the images join the user blocks that follow.
            let end = user_end(blocks, results_end);
            write_user_message(jw, request, &blocks[start..results_end], &blocks[results_end..end])?;
            Ok(end)
        }
        Block::UserText(_) | Block::Media(_) => {
            let end = user_end(blocks, start);
            write_user_message(jw, request, &[], &blocks[start..end])?;
            Ok(end)
        }
        Block::AssistantText(_) | Block::Reasoning(_) | Block::ToolCall(_) => {
            let end = blocks[start..]
                .iter()
                .position(|block| block.role() != crate::Role::Assistant)
                .map_or(blocks.len(), |len| start + len);
            let run = &blocks[start..end];
            // A message needs content or tool calls, so a run of reasoning alone writes none, as pi skips it.
            if run
                .iter()
                .any(|block| matches!(block, Block::AssistantText(_) | Block::ToolCall(_)))
            {
                write_assistant_message(jw, target, wire.reasoning_replay, run);
            }
            Ok(end)
        }
    }
}

/// Write one user message. The images of `results` lead it, each under a label that names its call.
/// `blocks` holds user text and media alone, as `group` groups them.
fn write_user_message(
    jw: &mut JsonWriter<'_>,
    request: &Request<'_>,
    results: &[Block],
    blocks: &[Block],
) -> Result<(), EncodeError> {
    debug_assert!(!results.is_empty() || !blocks.is_empty());
    jw.begin_object();
    jw.field_str("role", "user");
    jw.key("content");
    jw.begin_array();
    for result in results {
        if let Block::ToolResult(result) = result {
            for media in &result.media {
                write_attachment_label(jw, &result.call_id);
                write_media(jw, request, media)?;
            }
        }
    }
    for block in blocks {
        match block {
            Block::UserText(text) => {
                jw.begin_object();
                jw.field_str("type", "text");
                jw.field_str("text", text);
                jw.end_object();
            }
            Block::Media(media) => write_media(jw, request, media)?,
            // `group` admits no other block.
            Block::ToolResult(_) | Block::AssistantText(_) | Block::Reasoning(_) | Block::ToolCall(_) => {}
        }
    }
    jw.end_array();
    jw.end_object();
    Ok(())
}

/// `blocks` holds assistant blocks alone, as `group` groups them.
fn write_assistant_message(jw: &mut JsonWriter<'_>, target: &Target, replay: ReasoningReplayMode, blocks: &[Block]) {
    debug_assert_ne!(blocks, []);
    let has_text = blocks.iter().any(|block| matches!(block, Block::AssistantText(_)));
    let has_tool_calls = blocks.iter().any(|block| matches!(block, Block::ToolCall(_)));
    // A host that takes no replay drops the block. It is never a reason to fail the turn.
    let has_details = blocks
        .iter()
        .any(|block| matches!(block, Block::Reasoning(reasoning) if replayed(target, reasoning).is_some()));
    debug_assert!(
        has_text || has_tool_calls,
        "`write_group` writes no message without either"
    );

    jw.begin_object();
    jw.field_str("role", "assistant");
    jw.key("content");
    // The text joins into one string, as OpenAI documents it: DeepSeek refuses an array of parts with a 400, and
    // pi and the AI SDK join it the same way.
    if has_text {
        jw.string_parts(blocks.iter().filter_map(|block| match block {
            Block::AssistantText(text) => Some(text.as_str()),
            _ => None,
        }));
    } else {
        jw.null();
    }

    match replay {
        ReasoningReplayMode::None => {}
        // DeepSeek answers 400 when an assistant message returns without the member, even one that never reasoned,
        // so every message carries it, empty when it has no reasoning, as pi and opencode write it.
        ReasoningReplayMode::Reasoning | ReasoningReplayMode::ReasoningContent => {
            jw.key(if replay == ReasoningReplayMode::Reasoning {
                "reasoning"
            } else {
                "reasoning_content"
            });
            jw.string_parts(blocks.iter().filter_map(|block| match block {
                Block::Reasoning(reasoning) => Some(reasoning.text.as_str()),
                _ => None,
            }));
        }
        // OpenRouter takes its own entries back verbatim. Gemini refuses a tool turn without them.
        ReasoningReplayMode::ReasoningDetails => {
            if has_details {
                write_details(jw, target, blocks);
            }
        }
    }

    if has_tool_calls {
        jw.key("tool_calls");
        jw.begin_array();
        for block in blocks {
            if let Block::ToolCall(call) = block {
                jw.begin_object();
                jw.field_str("id", &call.call_id);
                jw.field_str("type", "function");
                jw.key("function");
                jw.begin_object();
                jw.field_str("name", &call.name);
                // A caller may send no arguments. The endpoint reads a JSON object text.
                jw.field_str("arguments", object_text(&call.arguments));
                jw.end_object();
                jw.end_object();
            }
        }
        jw.end_array();
    }
    jw.end_object();
}

/// Write the `reasoning_details` entries of the OpenRouter reasoning blocks, in order, as one array.
fn write_details(jw: &mut JsonWriter<'_>, target: &Target, blocks: &[Block]) {
    jw.key("reasoning_details");
    jw.begin_array();
    for block in blocks {
        let Block::Reasoning(reasoning) = block else { continue };
        // One raw write holds the entries of one block. The writer puts one comma between two such writes.
        let entries = replayed(target, reasoning).map_or("", array_items);
        if !entries.is_empty() {
            jw.raw(entries);
        }
    }
    jw.end_array();
}

/// The `reasoning_details` a reasoning block returns with. Only entries this origin produced in this protocol return.
fn replayed<'a>(target: &Target, reasoning: &'a Reasoning) -> Option<&'a str> {
    match reasoning.replay_to(target)? {
        (ReplayKind::OpenrouterDetails, details) => Some(details),
        _ => None,
    }
}

/// The text between the brackets of a JSON array text. The caller supplies a valid array, as for any raw JSON.
fn array_items(array: &str) -> &str {
    const SPACE: &[char] = &[' ', '\t', '\r', '\n'];
    let trimmed = array.trim_matches(SPACE);
    debug_assert!(trimmed.len() >= 2 && trimmed.starts_with('[') && trimmed.ends_with(']'));
    let inner = trimmed
        .strip_prefix('[')
        .and_then(|rest| rest.strip_suffix(']'))
        .unwrap_or(trimmed);
    inner.trim_matches(SPACE)
}

/// The label states which call the attachment belongs to, because it left the tool message of that call.
fn write_attachment_label(jw: &mut JsonWriter<'_>, call_id: &str) {
    jw.begin_object();
    jw.field_str("type", "text");
    jw.key("text");
    jw.string_parts(["Attachment from tool call ", call_id, ":"]);
    jw.end_object();
}

fn write_tool_result(jw: &mut JsonWriter<'_>, result: &ToolResult) {
    jw.begin_object();
    jw.field_str("role", "tool");
    jw.field_str("tool_call_id", &result.call_id);
    jw.key("content");
    jw.tool_text(&result.content, result.is_error);
    jw.end_object();
}

/// Write one attachment. This endpoint names a different part for each kind.
fn write_media(jw: &mut JsonWriter<'_>, request: &Request<'_>, media: &Media) -> Result<(), EncodeError> {
    match media.kind() {
        // This part reads a URL alone, so the bytes travel as a data URL.
        Modality::Image => {
            let data = read_blob(request.blobs, &media.blob)?;
            jw.begin_object();
            jw.field_str("type", "image_url");
            jw.key("image_url");
            jw.begin_object();
            jw.key("url");
            jw.base64(Some(&media.mime), &data);
            jw.end_object();
            jw.end_object();
        }
        // The part carries raw base64 with no envelope.
        Modality::Audio => {
            let data = read_blob(request.blobs, &media.blob)?;
            let format = audio_format(&media.mime)?;
            jw.begin_object();
            jw.field_str("type", "input_audio");
            jw.key("input_audio");
            jw.begin_object();
            jw.key("data");
            jw.base64(None, &data);
            jw.field_str("format", format);
            jw.end_object();
            jw.end_object();
        }
        // Every document travels as a file part, which names its media type in the data URL.
        Modality::Pdf | Modality::Text | Modality::Other => {
            if media.filename.is_empty() {
                return Err(EncodeError::Unsupported); // The endpoint names the file.
            }
            let data = read_blob(request.blobs, &media.blob)?;
            jw.begin_object();
            jw.field_str("type", "file");
            jw.key("file");
            jw.begin_object();
            jw.key("file_data");
            jw.base64(Some(&media.mime), &data);
            jw.field_str("filename", &media.filename);
            jw.end_object();
            jw.end_object();
        }
        Modality::Video => return Err(EncodeError::Unsupported),
    }
    Ok(())
}

/// Name the audio container this endpoint accepts, which is only wav and mp3.
fn audio_format(mime: &str) -> Result<&'static str, EncodeError> {
    match mime {
        "audio/wav" | "audio/x-wav" => Ok("wav"),
        "audio/mpeg" | "audio/mp3" => Ok("mp3"),
        _ => Err(EncodeError::Unsupported),
    }
}

/// Write `off` or the effort in the dialect of the host. The Anthropic thinking shapes have no chat form.
fn write_reasoning(jw: &mut JsonWriter<'_>, format: ThinkingFormat, reasoning: ReasoningSettings) {
    let on = !reasoning.off();
    let level = if !on {
        "none"
    } else if let Some(effort) = reasoning.effort {
        effort.as_str()
    } else {
        return;
    };
    let switch_shape = if on { "enabled" } else { "disabled" };
    // A toggle host takes the effort beside its switch. The caller names one only from the reasoning levels of the
    // model, so a model that takes the switch alone never sends it.
    let effort = on.then_some(level);
    let write_effort = |jw: &mut JsonWriter<'_>| {
        if let Some(effort) = effort {
            jw.field_str("reasoning_effort", effort);
        }
    };

    match format {
        ThinkingFormat::None => {}
        ThinkingFormat::Openai => jw.field_str("reasoning_effort", level),
        ThinkingFormat::Openrouter => write_effort_object(jw, level),
        ThinkingFormat::AntLing => {
            if on {
                write_effort_object(jw, level);
            }
        }
        ThinkingFormat::Deepseek => {
            jw.key("thinking");
            jw.begin_object();
            jw.field_str("type", switch_shape);
            jw.end_object();
            write_effort(jw);
        }
        // Preserved thinking keeps the reasoning of earlier turns, which an agent loop sends again. It means nothing
        // when off.
        ThinkingFormat::Zai => {
            jw.key("thinking");
            jw.begin_object();
            jw.field_str("type", switch_shape);
            if on {
                jw.field_bool("clear_thinking", false);
            }
            jw.end_object();
            write_effort(jw);
        }
        ThinkingFormat::Qwen => {
            jw.field_bool("enable_thinking", on);
            write_effort(jw);
        }
        ThinkingFormat::Together => {
            jw.key("reasoning");
            jw.begin_object();
            jw.field_bool("enabled", on);
            jw.end_object();
            write_effort(jw);
        }
    }
}

/// Write `"reasoning":{"effort":level}`.
fn write_effort_object(jw: &mut JsonWriter<'_>, level: &str) {
    jw.key("reasoning");
    jw.begin_object();
    jw.field_str("effort", level);
    jw.end_object();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request::{Effort, OutputSchema, Settings, Thinking, ToolDefinition, Wire};
    use crate::wire::testing::{blob, call, expect_error, expect_json, replay, result};

    fn chat() -> Wire {
        Wire::OpenaiChat(ChatWire::default())
    }

    fn chat_with(wire: ChatWire) -> Wire {
        Wire::OpenaiChat(wire)
    }

    fn replaying(mode: ReasoningReplayMode) -> Wire {
        chat_with(ChatWire {
            reasoning_replay: mode,
            ..ChatWire::default()
        })
    }

    fn media(data: &'static str, mime: &'static str, filename: &'static str) -> Media {
        Media {
            filename: filename.to_owned(),
            ..Media::new(blob(data), mime)
        }
    }

    fn reasoning(text: &str) -> Block {
        Block::Reasoning(Reasoning {
            text: text.to_string(),
            replay: None,
        })
    }

    /// The settings of most tests: a small output limit.
    static SETTINGS: std::sync::LazyLock<Settings> = std::sync::LazyLock::new(|| Settings::new().max_output_tokens(8));

    fn request(blocks: &[Block]) -> Request<'_> {
        Request::new(blocks).settings(&SETTINGS)
    }

    // DeepSeek answers "invalid type: sequence, expected a string" for an assistant message whose content is an
    // array (marimo-team/marimo#7036), and OpenAI documents the content as a string.
    #[test]
    fn assistant_text_joins_into_one_string() {
        let blocks = [
            Block::user_text("go"),
            Block::assistant_text("say \"hi\""),
            Block::assistant_text(" and bye"),
        ];
        expect_json(
            r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"messages":[{"role":"user","content":[{"type":"text","text":"go"}]},{"role":"assistant","content":"say \"hi\" and bye"}]}"#,
            "m",
            chat(),
            request(&blocks),
        );
    }

    // Mistral answers `stream_options` with 422 "Extra inputs are not permitted" (yetone/avante.nvim#2347), and
    // reports the usage of a stream without it.
    #[test]
    fn mistral_omits_stream_options() {
        let blocks = [Block::user_text("go")];
        expect_json(
            r#"{"model":"m","stream":true,"max_tokens":8,"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}"#,
            "m",
            chat_with(ChatWire {
                dialect: ChatDialect::Mistral,
                ..ChatWire::default()
            }),
            request(&blocks),
        );
    }

    #[test]
    fn no_replay_host_drops_reasoning() {
        let blocks = [reasoning("ponder"), Block::assistant_text("answer")];
        for mode in [ReasoningReplayMode::None, ReasoningReplayMode::ReasoningDetails] {
            expect_json(
                r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"messages":[{"role":"assistant","content":"answer"}]}"#,
                "m",
                replaying(mode),
                request(&blocks),
            );
        }
    }

    #[test]
    fn replayed_reasoning_joins_across_blocks() {
        let blocks = [
            reasoning("say \"hi\"\n"),
            reasoning("then stop"),
            Block::assistant_text("answer"),
        ];
        for (mode, expected) in [
            (
                ReasoningReplayMode::ReasoningContent,
                r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"messages":[{"role":"assistant","content":"answer","reasoning_content":"say \"hi\"\nthen stop"}]}"#,
            ),
            (
                ReasoningReplayMode::Reasoning,
                r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"messages":[{"role":"assistant","content":"answer","reasoning":"say \"hi\"\nthen stop"}]}"#,
            ),
        ] {
            expect_json(expected, "m", replaying(mode), request(&blocks));
        }
    }

    // A message needs content or tool calls ("either content or tool_calls, but not none"), so pi skips one with
    // neither, such as a failed attempt that only reasoned. The system message still separates from what follows.
    #[test]
    fn reasoning_only_run_writes_no_message() {
        let only = [reasoning("only")];
        let after = [Block::user_text("go"), reasoning("only")];
        let cases: [(&str, &[Block], &str); 3] = [
            ("", &only, "[]"),
            ("s", &only, r#"[{"role":"system","content":"s"}]"#),
            (
                "s",
                &after,
                r#"[{"role":"system","content":"s"},{"role":"user","content":[{"type":"text","text":"go"}]}]"#,
            ),
        ];
        for (system, blocks, messages) in cases {
            let expected = format!(
                r#"{{"model":"m","stream":true,"stream_options":{{"include_usage":true}},"max_tokens":8,"messages":{messages}}}"#
            );
            expect_json(
                &expected,
                "m",
                replaying(ReasoningReplayMode::ReasoningContent),
                Request::new(blocks).settings(&Settings::new().max_output_tokens(8).system(system)),
            );
        }
    }

    // DeepSeek: "the `reasoning_content` must be fully passed back ... even for turns where the model did not perform
    // a tool call", or it answers 400.
    #[test]
    fn replay_host_gets_empty_reasoning_on_plain_assistant_message() {
        let blocks = [Block::user_text("go"), Block::assistant_text("a")];
        expect_json(
            r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"messages":[{"role":"user","content":[{"type":"text","text":"go"}]},{"role":"assistant","content":"a","reasoning_content":""}]}"#,
            "m",
            replaying(ReasoningReplayMode::ReasoningContent),
            request(&blocks),
        );
    }

    // Only OpenAI renamed the member. Every compatible host kept `max_tokens`.
    #[test]
    fn max_tokens_field_follows_host() {
        let blocks = [Block::user_text("go")];
        expect_json(
            r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"max_completion_tokens":8,"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}"#,
            "m",
            chat_with(ChatWire {
                max_tokens_field: MaxTokensField::MaxCompletionTokens,
                ..ChatWire::default()
            }),
            request(&blocks),
        );
    }

    #[test]
    fn thinking_format_per_host() {
        // The members between the output limit and the messages: the whole control, so a stray member fails too.
        let cases = [
            (ThinkingFormat::None, "", ""),
            (
                ThinkingFormat::Openai,
                r#""reasoning_effort":"high","#,
                r#""reasoning_effort":"none","#,
            ),
            (
                ThinkingFormat::Openrouter,
                r#""reasoning":{"effort":"high"},"#,
                r#""reasoning":{"effort":"none"},"#,
            ),
            // This host has no off switch, so `off` leaves its default.
            (ThinkingFormat::AntLing, r#""reasoning":{"effort":"high"},"#, ""),
            // A toggle host takes a named effort beside its switch. Z.ai preserves thinking when on.
            (
                ThinkingFormat::Deepseek,
                r#""thinking":{"type":"enabled"},"reasoning_effort":"high","#,
                r#""thinking":{"type":"disabled"},"#,
            ),
            (
                ThinkingFormat::Zai,
                r#""thinking":{"type":"enabled","clear_thinking":false},"reasoning_effort":"high","#,
                r#""thinking":{"type":"disabled"},"#,
            ),
            (
                ThinkingFormat::Qwen,
                r#""enable_thinking":true,"reasoning_effort":"high","#,
                r#""enable_thinking":false,"#,
            ),
            (
                ThinkingFormat::Together,
                r#""reasoning":{"enabled":true},"reasoning_effort":"high","#,
                r#""reasoning":{"enabled":false},"#,
            ),
        ];
        let head = r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"#;
        let tail = r#""messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}"#;
        let blocks = [Block::user_text("go")];
        for (format, high, off) in cases {
            for (reasoning, control) in [
                (
                    ReasoningSettings {
                        thinking: None,
                        effort: Some(Effort::High),
                    },
                    high,
                ),
                (
                    ReasoningSettings {
                        thinking: Some(Thinking::Off),
                        effort: None,
                    },
                    off,
                ),
            ] {
                expect_json(
                    &format!("{head}{control}{tail}"),
                    "m",
                    chat_with(ChatWire {
                        thinking_format: format,
                        ..ChatWire::default()
                    }),
                    Request::new(&blocks).settings(&Settings::new().max_output_tokens(8).reasoning(reasoning)),
                );
            }
        }
    }

    #[test]
    fn user_turn_with_system_prompt() {
        let blocks = [Block::user_text("hello")];
        expect_json(
            r#"{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"max_tokens":1024,"messages":[{"role":"system","content":"be brief"},{"role":"user","content":[{"type":"text","text":"hello"}]}]}"#,
            "gpt",
            chat(),
            Request::new(&blocks).settings(&Settings::new().system("be brief").max_output_tokens(1024)),
        );
    }

    #[test]
    fn tool_call_and_standalone_result() {
        let blocks = [
            Block::assistant_text("checking"),
            call("call_1", "run", r#"{"c":1}"#),
            Block::ToolResult(result("call_1", "ok", false)),
        ];
        expect_json(
            r#"{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"max_tokens":64,"messages":[{"role":"assistant","content":"checking","tool_calls":[{"id":"call_1","type":"function","function":{"name":"run","arguments":"{\"c\":1}"}}]},{"role":"tool","tool_call_id":"call_1","content":"ok"}]}"#,
            "gpt",
            chat(),
            Request::new(&blocks).settings(&Settings::new().max_output_tokens(64)),
        );
    }

    #[test]
    fn error_result_prefixes_text() {
        let blocks = [
            call("call_1", "run", "{}"),
            Block::ToolResult(result("call_1", "no \"x\"", true)),
        ];
        expect_json(
            r#"{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"max_tokens":64,"messages":[{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"run","arguments":"{}"}}]},{"role":"tool","tool_call_id":"call_1","content":"Error: no \"x\""}]}"#,
            "gpt",
            chat(),
            Request::new(&blocks).settings(&Settings::new().max_output_tokens(64)),
        );
    }

    #[test]
    fn tool_images_follow_tool_messages() {
        let image = [media("ab", "image/png", "")];
        // A middle image tests both the media scan and the order of all three results.
        let run = [
            call("call_1", "read", "{}"),
            call("call_2", "read", "{}"),
            call("call_3", "read", "{}"),
            Block::ToolResult(result("call_1", "text", false)),
            Block::ToolResult(result("call_2", "PNG image", false).with_media(image.to_vec())),
            Block::ToolResult(result("call_3", "text", false)),
            Block::assistant_text("three files"),
        ];
        expect_json(
            r#"{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"messages":[{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"read","arguments":"{}"}},{"id":"call_2","type":"function","function":{"name":"read","arguments":"{}"}},{"id":"call_3","type":"function","function":{"name":"read","arguments":"{}"}}]},{"role":"tool","tool_call_id":"call_1","content":"text"},{"role":"tool","tool_call_id":"call_2","content":"PNG image"},{"role":"tool","tool_call_id":"call_3","content":"text"},{"role":"user","content":[{"type":"text","text":"Attachment from tool call call_2:"},{"type":"image_url","image_url":{"url":"data:image/png;base64,YWI="}}]},{"role":"assistant","content":"three files"}]}"#,
            "gpt",
            chat(),
            request(&run),
        );

        // A canceled turn ends on the result, so the next user text takes the image instead of a second user message.
        let merged = [
            call("call_1", "read", "{}"),
            Block::ToolResult(result("call_1", "PNG image", false).with_media(image.to_vec())),
            Block::user_text("what is it"),
        ];
        expect_json(
            r#"{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"messages":[{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"read","arguments":"{}"}}]},{"role":"tool","tool_call_id":"call_1","content":"PNG image"},{"role":"user","content":[{"type":"text","text":"Attachment from tool call call_1:"},{"type":"image_url","image_url":{"url":"data:image/png;base64,YWI="}},{"type":"text","text":"what is it"}]}]}"#,
            "gpt",
            chat(),
            request(&merged),
        );
    }

    #[test]
    fn tool_schema_and_strict_mode() {
        let tools = [
            ToolDefinition::new("run", "run a command", r#"{"type":"object"}"#),
            ToolDefinition {
                strict: true,
                ..ToolDefinition::new("read", "read a file", "{}")
            },
        ];
        let blocks = [Block::user_text("go")];
        expect_json(
            r#"{"model":"gpt","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"tools":[{"type":"function","function":{"name":"run","description":"run a command","parameters":{"type":"object"}}},{"type":"function","function":{"name":"read","description":"read a file","parameters":{},"strict":true}}],"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}"#,
            "gpt",
            chat(),
            request(&blocks).tools(&tools),
        );
    }

    #[test]
    fn schema_uses_response_format() {
        let blocks = [Block::user_text("go")];
        let mut schema = OutputSchema {
            name: "person".to_owned(),
            ..OutputSchema::new(r#"{"type":"object"}"#)
        };
        for (strict, expected) in [
            (
                true,
                r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"response_format":{"type":"json_schema","json_schema":{"name":"person","schema":{"type":"object"},"strict":true}},"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}"#,
            ),
            (
                false,
                r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"response_format":{"type":"json_schema","json_schema":{"name":"person","schema":{"type":"object"},"strict":false}},"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}"#,
            ),
        ] {
            schema.strict = strict;
            expect_json(
                expected,
                "m",
                chat(),
                Request::new(&blocks).settings(&Settings::new().max_output_tokens(8).output_schema(schema.clone())),
            );
        }
    }

    #[test]
    fn attachment_content_parts() {
        let blocks = [
            Block::Media(media("ab", "image/png", "")),
            Block::Media(media("ab", "application/pdf", "a.pdf")),
            Block::Media(media("ab", "audio/mpeg", "")),
        ];
        expect_json(
            r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,YWI="}},{"type":"file","file":{"file_data":"data:application/pdf;base64,YWI=","filename":"a.pdf"}},{"type":"input_audio","input_audio":{"data":"YWI=","format":"mp3"}}]}]}"#,
            "m",
            chat(),
            request(&blocks),
        );
    }

    #[test]
    fn rejects_unsupported_media() {
        // A document must name itself, and the endpoint takes no video and only wav or mp3 sound.
        for media in [
            media("ab", "application/pdf", ""),
            media("ab", "video/mp4", ""),
            media("ab", "audio/flac", ""),
        ] {
            let blocks = [Block::Media(media)];
            expect_error(EncodeError::Unsupported, "m", chat(), request(&blocks));
        }
    }

    #[test]
    fn sampling_members() {
        let blocks = [Block::user_text("go")];
        expect_json(
            r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"temperature":1.5,"top_p":0.1,"messages":[{"role":"user","content":[{"type":"text","text":"go"}]}]}"#,
            "m",
            chat(),
            Request::new(&blocks).settings(&Settings::new().max_output_tokens(8).temperature(1.5).top_p(0.1)),
        );
    }

    #[test]
    fn rejects_deferred_tools() {
        let blocks = [Block::user_text("read")];
        let tools = [ToolDefinition::new("mcp_read", "read", "{}").deferred()];
        expect_error(
            EncodeError::Unsupported,
            "chat",
            chat(),
            Request::new(&blocks)
                .tools(&tools)
                .settings(&Settings::new().max_output_tokens(100)),
        );
    }

    #[test]
    fn empty_arguments_send_empty_object() {
        let blocks = [call("c", "ls", ""), Block::ToolResult(result("c", "ok", false))];
        expect_json(
            r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"max_tokens":8,"messages":[{"role":"assistant","content":null,"tool_calls":[{"id":"c","type":"function","function":{"name":"ls","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c","content":"ok"}]}"#,
            "m",
            chat(),
            request(&blocks),
        );
    }

    #[test]
    fn openrouter_replays_reasoning_details() {
        let blocks = [
            Block::Reasoning(Reasoning {
                text: "a".to_string(),
                replay: Some(replay(
                    "m",
                    ReplayKind::OpenrouterDetails,
                    r#"[{"type":"reasoning.text","text":"a"},{"type":"reasoning.text","text":"a2"}]"#,
                )),
            }),
            // An empty array adds no entry and no comma.
            Block::Reasoning(Reasoning {
                text: String::new(),
                replay: Some(replay("m", ReplayKind::OpenrouterDetails, "[]")),
            }),
            Block::Reasoning(Reasoning {
                text: "b".to_string(),
                replay: Some(replay(
                    "m",
                    ReplayKind::OpenrouterDetails,
                    r#" [ {"type":"reasoning.encrypted","data":"x"} ] "#,
                )),
            }),
            Block::Reasoning(Reasoning {
                text: "c".to_string(),
                replay: Some(replay("m", ReplayKind::AnthropicSignature, "sig")),
            }),
            Block::assistant_text("answer"),
        ];
        expect_json(
            r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"assistant","content":"answer","reasoning_details":[{"type":"reasoning.text","text":"a"},{"type":"reasoning.text","text":"a2"},{"type":"reasoning.encrypted","data":"x"}]}]}"#,
            "m",
            replaying(ReasoningReplayMode::ReasoningDetails),
            Request::new(&blocks),
        );
        // A text replay sends every reasoning text, whatever produced it.
        expect_json(
            r#"{"model":"m","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"assistant","content":"answer","reasoning_content":"abc"}]}"#,
            "m",
            replaying(ReasoningReplayMode::ReasoningContent),
            Request::new(&blocks),
        );
    }
}
