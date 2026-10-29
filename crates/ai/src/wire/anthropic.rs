//! Serialize an Anthropic Messages request from the neutral request.

use crate::encoder::{EncodeError, Unsupported};
use crate::request::read_blob;
use crate::request::{AnthropicWire, BlobStore, Block, Media, Modality, ReplayKind, Request, Target, Thinking};

use super::json::{JsonWriter, call_arguments};

/// Write the request up to the open `messages` array, which holds no element yet.
pub(crate) fn write_head(out: &mut Vec<u8>, target: &Target, wire: AnthropicWire, request: &Request<'_>) {
    let mut jw = JsonWriter::new(out);
    jw.begin_object();
    jw.field_str("model", &target.model);
    jw.field_uint(
        "max_tokens",
        u64::from(request.settings.max_output_tokens.unwrap_or(wire.max_tokens)),
    );
    jw.field_bool("stream", true);
    jw.field_float_opt("temperature", request.settings.temperature);
    jw.field_float_opt("top_p", request.settings.top_p);
    write_thinking(&mut jw, request.settings.reasoning.thinking);
    // The effort and the response format share the one object.
    if request.settings.reasoning.effort.is_some() || request.settings.output_schema.is_some() {
        jw.key("output_config");
        jw.begin_object();
        if let Some(effort) = request.settings.reasoning.effort {
            jw.field_str("effort", effort.as_str());
        }
        // Anthropic constrains the response from the schema alone, with no name and no strict flag.
        if let Some(output) = &request.settings.output_schema {
            jw.key("format");
            jw.begin_object();
            jw.field_str("type", "json_schema");
            jw.field_raw("schema", &output.schema);
            jw.end_object();
        }
        jw.end_object();
    }
    if !request.system.is_empty() {
        jw.key("system");
        jw.begin_array();
        jw.begin_object();
        jw.field_str("type", "text");
        jw.field_str("text", request.system);
        write_cache_control(&mut jw, wire.cache);
        jw.end_object();
        jw.end_array();
    }

    if !request.tools.is_empty() {
        jw.key("tools");
        jw.begin_array();
        for tool in request.tools {
            jw.begin_object();
            jw.field_str("name", &tool.name);
            jw.field_str("description", &tool.description);
            if tool.defer_loading {
                jw.field_bool("defer_loading", true);
            }
            jw.field_raw("input_schema", &tool.input_schema);
            jw.end_object();
        }
        jw.end_array();
        // This host spells the control as an object, so only a refusal writes the member.
        if request.settings.tool_choice == crate::ToolChoice::None {
            jw.key("tool_choice");
            jw.begin_object();
            jw.field_str("type", "none");
            jw.end_object();
        }
    }

    jw.key("messages");
    jw.begin_array();
}

/// Write the message of the run of blocks with one role from `start`, and return the end of the run.
/// `marker` is the block that carries the cache marker.
pub(crate) fn write_group(
    jw: &mut JsonWriter<'_>,
    target: &Target,
    request: &Request<'_>,
    start: usize,
    marker: Option<usize>,
) -> Result<usize, EncodeError> {
    let blocks = request.blocks;
    let role = blocks[start].role();
    let end = blocks[start..]
        .iter()
        .position(|block| block.role() != role)
        .map_or(blocks.len(), |len| start + len);
    // A message of reasoning from another origin alone has no content this protocol takes, so it writes nothing.
    if !blocks[start..end].iter().any(|block| super::writes(target, block)) {
        return Ok(end);
    }
    jw.begin_object();
    jw.field_str("role", role.as_str());
    jw.key("content");
    jw.begin_array();
    for (i, block) in blocks.iter().enumerate().take(end).skip(start) {
        write_block(jw, target, request, block, marker == Some(i))?;
    }
    jw.end_array();
    jw.end_object();
    Ok(end)
}

/// Write the thinking control and its display. The effort rides on `output_config`.
fn write_thinking(jw: &mut JsonWriter<'_>, thinking: Option<Thinking>) {
    let Some(thinking) = thinking else { return };
    jw.key("thinking");
    jw.begin_object();
    match thinking {
        Thinking::Off => jw.field_str("type", "disabled"),
        Thinking::Adaptive(display) => {
            jw.field_str("type", "adaptive");
            if let Some(shown) = display {
                jw.field_str("display", shown.as_str());
            }
        }
        Thinking::Budget(tokens) => {
            jw.field_str("type", "enabled");
            jw.field_uint("budget_tokens", tokens);
        }
    }
    jw.end_object();
}

fn write_cache_control(jw: &mut JsonWriter<'_>, cache: bool) {
    if cache {
        jw.key("cache_control");
        jw.begin_object();
        jw.field_str("type", "ephemeral");
        jw.end_object();
    }
}

fn write_block(
    jw: &mut JsonWriter<'_>,
    target: &Target,
    request: &Request<'_>,
    block: &Block,
    cache: bool,
) -> Result<(), EncodeError> {
    match block {
        Block::UserText(text) | Block::AssistantText(text) => {
            jw.begin_object();
            jw.field_str("type", "text");
            jw.field_str("text", text);
            write_cache_control(jw, cache);
            jw.end_object();
        }
        Block::Media(media) => write_media(jw, request.blobs, media, cache)?,
        Block::Reasoning(reasoning) => match reasoning.replay_to(target) {
            Some((ReplayKind::AnthropicSignature, signature)) => {
                jw.begin_object();
                jw.field_str("type", "thinking");
                jw.field_str("thinking", &reasoning.text);
                jw.field_str("signature", signature);
                jw.end_object();
            }
            Some((_, data)) => {
                jw.begin_object();
                jw.field_str("type", "redacted_thinking");
                jw.field_str("data", data);
                jw.end_object();
            }
            None => {}
        },
        Block::ToolCall(call) => {
            jw.begin_object();
            jw.field_str("type", "tool_use");
            jw.field_str("id", &call.call_id);
            jw.field_str("name", &call.name);
            jw.field_raw("input", call_arguments(&call.arguments));
            write_cache_control(jw, cache);
            jw.end_object();
        }
        Block::ToolResult(result) => {
            jw.begin_object();
            jw.field_str("type", "tool_result");
            jw.field_str("tool_use_id", &result.call_id);
            jw.key("content");
            // A reference needs the deferred tools of a native target. A request without them keeps the result text.
            let loaded = if super::defers_tools(request.tools) {
                result.loaded.as_slice()
            } else {
                &[]
            };
            if result.media.is_empty() && loaded.is_empty() {
                jw.string(&result.content);
            } else {
                // The API refuses an empty text block, so a result of media or references alone writes no text.
                jw.begin_array();
                if !result.content.is_empty() {
                    jw.begin_object();
                    jw.field_str("type", "text");
                    jw.field_str("text", &result.content);
                    jw.end_object();
                }
                for media in &result.media {
                    write_media(jw, request.blobs, media, false)?;
                }
                for tool in loaded {
                    jw.begin_object();
                    jw.field_str("type", "tool_reference");
                    jw.field_str("tool_name", &tool.name);
                    jw.end_object();
                }
                jw.end_array();
            }
            jw.field_bool("is_error", result.is_error);
            write_cache_control(jw, cache);
            jw.end_object();
        }
    }
    Ok(())
}

/// Write one attachment. An image is an `image` block and every other document is a `document` block.
fn write_media(
    jw: &mut JsonWriter<'_>,
    blobs: Option<&dyn BlobStore>,
    media: &Media,
    cache: bool,
) -> Result<(), EncodeError> {
    let kind = media.kind();
    let block_type = match kind {
        Modality::Image => "image",
        // A document is a PDF or plain text, and no other type has a source shape on this API.
        Modality::Pdf | Modality::Text => "document",
        // Anthropic reads no sound and no moving picture.
        modality @ (Modality::Audio | Modality::Video | Modality::Other) => {
            return Err(EncodeError::Unsupported(Unsupported::Media(modality)));
        }
    };
    jw.begin_object();
    jw.field_str("type", block_type);
    jw.key("source");
    let data = read_blob(blobs, &media.blob)?;
    jw.begin_object();
    // Plain text rides in a `text` source, which carries the characters rather than base64. Its media type is
    // `text/plain` whatever kind of text the attachment holds: the API types it as that literal.
    if kind == Modality::Text {
        jw.field_str("type", "text");
        jw.field_str("media_type", "text/plain");
        jw.key("data");
        // Bytes that are no UTF-8 text become U+FFFD, so the model still reads the rest of the file.
        jw.string(&String::from_utf8_lossy(&data));
    } else {
        jw.field_str("type", "base64");
        jw.field_str("media_type", &media.mime);
        jw.key("data");
        jw.base64(None, &data);
    }
    jw.end_object();
    write_cache_control(jw, cache);
    jw.end_object();
    Ok(())
}

/// The last block that can carry the cache marker carries it. A thinking block cannot.
pub(crate) fn cacheable(block: &Block) -> bool {
    !matches!(block, Block::Reasoning(_))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ToolResult;
    use crate::request::{
        Blob, BlobStore, Effort, Origin, OutputSchema, Reasoning, ReasoningReplay, Settings, ThinkingDisplay,
        ToolDefinition,
    };
    use crate::wire::testing::{blob, call, expect_error, expect_json, replay};

    fn anthropic(max_tokens: u32) -> crate::Wire {
        crate::Wire::AnthropicMessages(AnthropicWire {
            max_tokens,
            cache: false,
        })
    }

    fn cached(max_tokens: u32) -> crate::Wire {
        crate::Wire::AnthropicMessages(AnthropicWire {
            max_tokens,
            cache: true,
        })
    }

    fn image(data: &'static str, mime: &'static str) -> Media {
        Media::new(blob(data), mime)
    }

    #[test]
    fn request_limit_overrides_wire_limit() {
        let blocks = [Block::user_text("hi")];
        expect_json(
            r#"{"model":"claude","max_tokens":64,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#,
            "claude",
            anthropic(64),
            Request::new(&blocks),
        );
        expect_json(
            r#"{"model":"claude","max_tokens":9,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#,
            "claude",
            anthropic(64),
            Request::new(&blocks).settings(&Settings::new().max_output_tokens(9)),
        );
    }

    #[test]
    fn user_turn_with_system_prompt() {
        let blocks = [Block::user_text("hello")];
        expect_json(
            r#"{"model":"claude","max_tokens":1024,"stream":true,"system":[{"type":"text","text":"be brief"}],"messages":[{"role":"user","content":[{"type":"text","text":"hello"}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks)
                .system("be brief")
                .settings(&Settings::new().max_output_tokens(1024)),
        );
    }

    #[test]
    fn assistant_blocks_join_one_message() {
        let blocks = [
            Block::user_text("read"),
            Block::assistant_text("searching"),
            Block::assistant_text("done"),
        ];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"read"}]},{"role":"assistant","content":[{"type":"text","text":"searching"},{"type":"text","text":"done"}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks).settings(&Settings::new().max_output_tokens(8)),
        );
    }

    #[test]
    fn thinking_budget_writes_enabled() {
        let blocks = [Block::user_text("hi")];
        expect_json(
            r#"{"model":"claude","max_tokens":8192,"stream":true,"thinking":{"type":"enabled","budget_tokens":4096},"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks).settings(&Settings::new().max_output_tokens(8192).thinking(Thinking::Budget(4096))),
        );
    }

    #[test]
    fn thinking_off_writes_disabled() {
        let blocks = [Block::user_text("hi")];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"thinking":{"type":"disabled"},"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks).settings(&Settings::new().max_output_tokens(8).thinking(Thinking::Off)),
        );
    }

    #[test]
    fn adaptive_thinking_display_and_effort() {
        let blocks = [Block::user_text("hi")];
        for (model, settings, expected) in [
            (
                "MiniMax-M3",
                Settings::new().max_output_tokens(8).thinking(Thinking::Adaptive(None)),
                r#"{"model":"MiniMax-M3","max_tokens":8,"stream":true,"thinking":{"type":"adaptive"},"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#,
            ),
            (
                "claude",
                Settings::new()
                    .max_output_tokens(8)
                    .thinking(Thinking::Adaptive(Some(ThinkingDisplay::Summarized)))
                    .effort(Effort::Low),
                r#"{"model":"claude","max_tokens":8,"stream":true,"thinking":{"type":"adaptive","display":"summarized"},"output_config":{"effort":"low"},"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#,
            ),
        ] {
            expect_json(expected, model, anthropic(8), Request::new(&blocks).settings(&settings));
        }
    }

    #[test]
    fn tool_call_and_result_group_by_role() {
        let blocks = [
            Block::assistant_text("checking"),
            call("toolu_1", "run", r#"{"c":1}"#),
            Block::ToolResult(ToolResult::error("toolu_1", "no")),
        ];
        expect_json(
            r#"{"model":"claude","max_tokens":64,"stream":true,"messages":[{"role":"assistant","content":[{"type":"text","text":"checking"},{"type":"tool_use","id":"toolu_1","name":"run","input":{"c":1}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"no","is_error":true}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks).settings(&Settings::new().max_output_tokens(64)),
        );
    }

    #[test]
    fn tool_result_with_image() {
        let images = [image("ab", "image/png")];
        let blocks = [
            call("toolu_1", "read", "{}"),
            Block::ToolResult(ToolResult::success("toolu_1", "PNG image").with_media(images.to_vec())),
            Block::ToolResult(ToolResult::success("toolu_2", "").with_media(images.to_vec())),
        ];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"read","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"PNG image"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"YWI="}}],"is_error":false},{"type":"tool_result","tool_use_id":"toolu_2","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"YWI="}}],"is_error":false,"cache_control":{"type":"ephemeral"}}]}]}"#,
            "claude",
            cached(8),
            Request::new(&blocks).settings(&Settings::new().max_output_tokens(8)),
        );
    }

    #[test]
    fn tool_result_loads_deferred_tools() {
        let tools = [
            ToolDefinition {
                name: "tool_search".to_owned(),
                description: "Find.".to_owned(),
                input_schema: r#"{"type":"object"}"#.to_owned(),
                defer_loading: false,
            },
            ToolDefinition {
                name: "mcp_read".to_owned(),
                description: "Read.".to_owned(),
                input_schema: r#"{"type":"object"}"#.to_owned(),
                defer_loading: false,
            }
            .deferred(),
            ToolDefinition {
                name: "mcp_write".to_owned(),
                description: "Write.".to_owned(),
                input_schema: r#"{"type":"object"}"#.to_owned(),
                defer_loading: false,
            }
            .deferred(),
        ];
        let blocks = [
            call("toolu_1", "tool_search", "{}"),
            Block::ToolResult(ToolResult::success("toolu_1", "found").with_loaded(tools[1..].to_vec())),
        ];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"tools":[{"name":"tool_search","description":"Find.","input_schema":{"type":"object"}},{"name":"mcp_read","description":"Read.","defer_loading":true,"input_schema":{"type":"object"}},{"name":"mcp_write","description":"Write.","defer_loading":true,"input_schema":{"type":"object"}}],"messages":[{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"tool_search","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"found"},{"type":"tool_reference","tool_name":"mcp_read"},{"type":"tool_reference","tool_name":"mcp_write"}],"is_error":false}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks)
                .tools(&tools)
                .settings(&Settings::new().max_output_tokens(8)),
        );
        // Without a deferred tool, as on a bridge target, a reference would name an undeclared tool, so none is written.
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"tools":[{"name":"tool_search","description":"Find.","input_schema":{"type":"object"}}],"messages":[{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"tool_search","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"found","is_error":false}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks)
                .tools(&tools[..1])
                .settings(&Settings::new().max_output_tokens(8)),
        );
    }

    #[test]
    fn cache_marks_system_and_last_block() {
        let blocks = [Block::user_text("one"), Block::user_text("two")];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"system":[{"type":"text","text":"sys","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"one"},{"type":"text","text":"two","cache_control":{"type":"ephemeral"}}]}]}"#,
            "claude",
            cached(8),
            Request::new(&blocks)
                .system("sys")
                .settings(&Settings::new().max_output_tokens(8)),
        );
    }

    // A side request adds a prompt after the context of its round, and the marker stays where the round puts it.
    #[test]
    fn a_cached_bound_keeps_the_marker_on_the_last_block_before_it() {
        let blocks = [Block::user_text("one"), Block::user_text("two")];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"one","cache_control":{"type":"ephemeral"}},{"type":"text","text":"two"}]}]}"#,
            "claude",
            cached(8),
            Request::new(&blocks).cached(1),
        );
    }

    #[test]
    fn cache_skips_trailing_thinking() {
        let blocks = [
            Block::assistant_text("answer"),
            Block::Reasoning(Reasoning {
                text: "ponder".to_string(),
                replay: Some(replay("claude", ReplayKind::AnthropicSignature, "sig")),
            }),
        ];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"assistant","content":[{"type":"text","text":"answer","cache_control":{"type":"ephemeral"}},{"type":"thinking","thinking":"ponder","signature":"sig"}]}]}"#,
            "claude",
            cached(8),
            Request::new(&blocks).settings(&Settings::new().max_output_tokens(8)),
        );
    }

    #[test]
    fn image_and_document_blocks() {
        let blocks = [
            Block::Media(image("ab", "image/png")),
            Block::Media(image("ab", "application/pdf")),
        ];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"YWI="}},{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":"YWI="}}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks).settings(&Settings::new().max_output_tokens(8)),
        );
    }

    #[test]
    fn rejects_audio_and_video() {
        for (mime, modality) in [("audio/mpeg", Modality::Audio), ("video/mp4", Modality::Video)] {
            let blocks = [Block::Media(image("ab", mime))];
            expect_error(
                EncodeError::Unsupported(Unsupported::Media(modality)),
                "claude",
                anthropic(8),
                Request::new(&blocks).settings(&Settings::new().max_output_tokens(8)),
            );
        }
    }

    #[test]
    fn schema_uses_output_config() {
        let blocks = [Block::user_text("hi")];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"output_config":{"format":{"type":"json_schema","schema":{"type":"object"}}},"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks).settings(
                &Settings::new()
                    .max_output_tokens(8)
                    .output_schema(OutputSchema::new(r#"{"type":"object"}"#).clone()),
            ),
        );
    }

    #[test]
    fn effort_and_schema_share_output_config() {
        let blocks = [Block::user_text("hi")];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"output_config":{"effort":"high","format":{"type":"json_schema","schema":{"type":"object"}}},"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks).settings(
                &Settings::new()
                    .max_output_tokens(8)
                    .effort(Effort::High)
                    .output_schema(OutputSchema::new(r#"{"type":"object"}"#).clone()),
            ),
        );
    }

    // A text file with a stray byte still reaches the model, so the request stays valid JSON.
    #[test]
    fn invalid_utf8_text_document_is_replaced() {
        struct Latin1;

        impl BlobStore for Latin1 {
            fn read(
                &self,
                _: &crate::Digest,
            ) -> Result<Option<std::borrow::Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>> {
                Ok(Some(std::borrow::Cow::Borrowed(b"caf\xe9")))
            }
        }

        let file = Blob {
            digest: [0; 32],
            len: 4,
        };
        let blocks = [Block::Media(Media::new(file, "text/plain"))];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"user","content":[{"type":"document","source":{"type":"text","media_type":"text/plain","data":"caf�"}}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks)
                .blobs(&Latin1)
                .settings(&Settings::new().max_output_tokens(8)),
        );
    }

    #[test]
    fn text_document_uses_text_source() {
        // A markdown file is text too, and its source still names `text/plain`.
        let text_doc = [Block::Media(image("note", "text/markdown"))];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"user","content":[{"type":"document","source":{"type":"text","media_type":"text/plain","data":"note"}}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&text_doc).settings(&Settings::new().max_output_tokens(8)),
        );
        // A document is a PDF or plain text. Anything else has no source shape and must not be mislabelled.
        let spreadsheet = [Block::Media(image("ab", "application/zip"))];
        expect_error(
            EncodeError::Unsupported(Unsupported::Media(Modality::Other)),
            "claude",
            anthropic(8),
            Request::new(&spreadsheet).settings(&Settings::new().max_output_tokens(8)),
        );
    }

    #[test]
    fn sampling_members() {
        let blocks = [Block::user_text("hi")];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"temperature":0.7,"top_p":0.9,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks).settings(&Settings::new().max_output_tokens(8).temperature(0.7).top_p(0.9)),
        );
        // A missing value leaves the endpoint default, so the member never reaches the wire.
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"temperature":0,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks).settings(&Settings::new().max_output_tokens(8).temperature(0.0)),
        );
    }

    #[test]
    fn foreign_reasoning_is_dropped() {
        let blocks = [
            Block::user_text("q"),
            Block::Reasoning(Reasoning {
                text: "elsewhere".to_string(),
                replay: Some(replay("claude", ReplayKind::ResponsesEncrypted, "enc")),
            }),
            Block::Reasoning(Reasoning {
                text: "plain".to_string(),
                replay: None,
            }),
            // A signature of another model, or of the same model at another host, does not replay.
            Block::Reasoning(Reasoning {
                text: "ponder".to_string(),
                replay: Some(replay("other-model", ReplayKind::AnthropicSignature, "sig")),
            }),
            Block::Reasoning(Reasoning {
                text: "ponder".to_string(),
                replay: Some(ReasoningReplay {
                    origin: Origin {
                        model: "claude".to_string(),
                        base_url: "https://compatible.test/v1".to_string(),
                    },
                    kind: ReplayKind::AnthropicSignature,
                    data: "sig".to_string(),
                }),
            }),
            Block::user_text("again"),
            Block::Reasoning(Reasoning {
                text: String::new(),
                replay: Some(replay("claude", ReplayKind::AnthropicRedacted, "opaque")),
            }),
            Block::Reasoning(Reasoning {
                text: "other".to_string(),
                replay: Some(replay("claude", ReplayKind::OpenrouterDetails, "[]")),
            }),
            Block::assistant_text("a"),
        ];
        expect_json(
            r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"q"}]},{"role":"user","content":[{"type":"text","text":"again"}]},{"role":"assistant","content":[{"type":"redacted_thinking","data":"opaque"},{"type":"text","text":"a"}]}]}"#,
            "claude",
            anthropic(8),
            Request::new(&blocks),
        );
    }

    #[test]
    fn every_cacheable_block_carries_the_marker() {
        let cases = [
            (
                Block::user_text("a"),
                r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"a","cache_control":{"type":"ephemeral"}}]}]}"#,
            ),
            (
                Block::assistant_text("a"),
                r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"assistant","content":[{"type":"text","text":"a","cache_control":{"type":"ephemeral"}}]}]}"#,
            ),
            (
                Block::Media(image("ab", "image/png")),
                r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"YWI="},"cache_control":{"type":"ephemeral"}}]}]}"#,
            ),
            (
                call("c", "n", "{}"),
                r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"assistant","content":[{"type":"tool_use","id":"c","name":"n","input":{},"cache_control":{"type":"ephemeral"}}]}]}"#,
            ),
            (
                Block::ToolResult(ToolResult::success("c", "")),
                r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"c","content":"","is_error":false,"cache_control":{"type":"ephemeral"}}]}]}"#,
            ),
            (
                Block::Reasoning(Reasoning {
                    text: "t".to_string(),
                    replay: Some(replay("claude", ReplayKind::AnthropicSignature, "s")),
                }),
                r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[{"role":"assistant","content":[{"type":"thinking","thinking":"t","signature":"s"}]}]}"#,
            ),
            (
                Block::Reasoning(Reasoning {
                    text: "t".to_string(),
                    replay: None,
                }),
                r#"{"model":"claude","max_tokens":8,"stream":true,"messages":[]}"#,
            ),
        ];
        for (block, expected) in cases {
            expect_json(
                expected,
                "claude",
                cached(8),
                Request::new(std::slice::from_ref(&block)),
            );
        }
    }
}
