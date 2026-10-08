//! Map Anthropic Messages SSE data to neutral stream events.

use serde::Deserialize;

use crate::failure::{self, ProviderKind};
use crate::json::{self, Text, Value};
use crate::request::ReplayKind;
use crate::response::{BlockId, BlockKind, FinishReason};

use super::Reduce;
use super::draft::{DecodeError, Draft};

/// A delta of one block, read with no tree. Other events take the tree path. The typed read rejects a duplicate of a
/// field that it reads, and ignores a duplicate of another field.
#[derive(Deserialize)]
struct BlockDelta<'a> {
    #[serde(rename = "type", borrow)]
    event: Text<'a>,
    /// The tree path reads `index` as an `i64`. A larger number fails the typed read.
    index: i64,
    #[serde(borrow)]
    delta: DeltaFields<'a>,
}

/// These fields hold the members of a block delta that the reducer reads.
#[derive(Deserialize)]
struct DeltaFields<'a> {
    #[serde(rename = "type", borrow)]
    kind: Text<'a>,
    #[serde(borrow)]
    text: Option<Text<'a>>,
    #[serde(borrow)]
    thinking: Option<Text<'a>>,
    #[serde(borrow)]
    signature: Option<Text<'a>>,
    #[serde(borrow)]
    partial_json: Option<Text<'a>>,
}

/// These fields hold one block delta from either path. A field that is absent or not a string is `None`.
struct DeltaView<'v> {
    kind: &'v str,
    text: Option<&'v str>,
    thinking: Option<&'v str>,
    signature: Option<&'v str>,
    partial_json: Option<&'v str>,
}

#[derive(Debug)]
pub(crate) struct Reducer {
    draft: Draft,
    /// The neutral block of each provider block index, or `None` for a block the reducer ignores, whose events it
    /// drops.
    slots: Vec<Option<BlockId>>,
    /// The largest `input_tokens` so far, which counts no cache token.
    uncached_input: u64,
}

impl Reduce for Reducer {
    fn new(draft: Draft) -> Self {
        Reducer {
            draft,
            slots: Vec::new(),
            uncached_input: 0,
        }
    }

    /// Parse one SSE `data` payload and append its neutral events to the draft. Return the provider failure that an
    /// error event names.
    fn decode(&mut self, data: &str) -> Result<Option<ProviderKind>, DecodeError> {
        // A derived struct also reads a JSON array by position, so only an object takes the typed path.
        if data.trim_start().starts_with('{')
            && let Ok(event) = serde_json::from_str::<BlockDelta<'_>>(data)
            && *event.event == *"content_block_delta"
        {
            let index = usize::try_from(event.index).map_err(|_| DecodeError::Protocol)?;
            let fields = &event.delta;
            let delta = DeltaView {
                kind: &fields.kind,
                text: fields.text.as_deref(),
                thinking: fields.thinking.as_deref(),
                signature: fields.signature.as_deref(),
                partial_json: fields.partial_json.as_deref(),
            };
            self.apply_delta(index, Ok(delta))?;
            return Ok(None);
        }
        let root = json::parse(data)?;
        match root.require_str("type")? {
            "error" => return Ok(Some(failure::event_kind(&root))),
            "message_start" => self.on_message_start(&root),
            "content_block_start" => self.on_block_start(&root)?,
            "content_block_delta" => self.on_block_delta(&root)?,
            "content_block_stop" => self.on_block_stop(&root)?,
            "message_delta" => self.on_message_delta(&root),
            "message_stop" => self.on_message_stop()?,
            // Unknown event types are no-ops, `ping` among them.
            _ => {}
        }
        Ok(None)
    }

    fn draft(&self) -> &Draft {
        &self.draft
    }

    fn draft_mut(&mut self) -> &mut Draft {
        &mut self.draft
    }
}

impl Reducer {
    fn on_message_start(&mut self, root: &Value<'_>) {
        if let Some(usage) = root
            .get_object("message")
            .and_then(|message| message.get_object("usage"))
        {
            self.fold_prompt_usage(usage);
        }
    }

    /// Keep the larger of each cumulative prompt count, so a repeat counts once and counts from different events add
    /// up. The neutral input adds the cache counts, which Anthropic keeps apart from `input_tokens`.
    fn fold_prompt_usage(&mut self, usage: &Value<'_>) {
        let total = &mut self.draft.usage;
        self.uncached_input = self.uncached_input.max(usage.count("input_tokens"));
        total.cache_read = total.cache_read.max(usage.count("cache_read_input_tokens"));
        total.cache_write = total.cache_write.max(usage.count("cache_creation_input_tokens"));
        total.input = self
            .uncached_input
            .saturating_add(total.cache_read)
            .saturating_add(total.cache_write);
    }

    fn on_block_start(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let index = root.get_index("index")?;
        if index != self.slots.len() {
            return Err(DecodeError::Protocol); // Block indexes must arrive in dense order.
        }
        // An ignored block opens no neutral block, so the slots need their own bound.
        if self.slots.len() >= self.draft.limits.max_blocks as usize {
            return Err(DecodeError::TooLarge);
        }

        let block = root.get("content_block").ok_or(DecodeError::Protocol)?;
        let block_type = block.require_str("type")?;
        let Some(kind) = block_kind(block_type) else {
            // An ignored block emits nothing, so the neutral ids stay dense from 0.
            self.slots.push(None);
            return Ok(());
        };
        let id = match kind {
            BlockKind::ToolCall => self
                .draft
                .start_tool(block.require_str("id")?, block.require_str("name")?)?,
            _ => self.draft.start(kind)?,
        };
        self.slots.push(Some(id));
        match kind {
            BlockKind::Text => {
                if let Some(text) = block.get_str("text")
                    && !text.is_empty()
                {
                    self.draft.delta(id, text)?;
                }
            }
            // MiniMax (and some Anthropic-compatible hosts) put the whole trace on start, with no deltas.
            BlockKind::Reasoning => {
                if block_type == "redacted_thinking" {
                    let open = self.draft.open(id)?;
                    open.replay = Some(ReplayKind::AnthropicRedacted);
                    open.bytes.push_str(block.get_str("data").unwrap_or_default());
                } else {
                    // A compatible host may never sign the block, so even an empty signature replays to this protocol.
                    self.draft.open(id)?.replay = Some(ReplayKind::AnthropicSignature);
                    if let Some(text) = block.get_str("thinking")
                        && !text.is_empty()
                    {
                        self.draft.delta(id, text)?;
                    }
                    self.draft
                        .open(id)?
                        .bytes
                        .push_str(block.get_str("signature").unwrap_or_default());
                }
            }
            // Anthropic names a refusal by its stop reason, so `block_kind` maps no block to one.
            BlockKind::ToolCall | BlockKind::Refusal => {}
        }
        Ok(())
    }

    fn on_block_delta(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let index = root.get_index("index")?;
        let delta = root.get("delta").ok_or(DecodeError::Protocol).and_then(|delta| {
            Ok(DeltaView {
                kind: delta.require_str("type")?,
                text: delta.get_str("text"),
                thinking: delta.get_str("thinking"),
                signature: delta.get_str("signature"),
                partial_json: delta.get_str("partial_json"),
            })
        });
        self.apply_delta(index, delta)
    }

    /// Apply one block delta. The reducer looks up the block before it reads the delta. An ignored block takes no
    /// event, even from a malformed delta.
    fn apply_delta(&mut self, index: usize, delta: Result<DeltaView<'_>, DecodeError>) -> Result<(), DecodeError> {
        let Some(id) = self.slots.get(index).copied().ok_or(DecodeError::Protocol)? else {
            return Ok(());
        };
        let block = self.draft.open(id)?;
        let (block_kind, replay) = (block.kind, block.replay);

        let delta = delta?;
        let expected = match delta.kind {
            "text_delta" => BlockKind::Text,
            "thinking_delta" | "signature_delta" => BlockKind::Reasoning,
            "input_json_delta" => BlockKind::ToolCall,
            _ => return Ok(()), // Unknown delta types are no-ops.
        };
        if block_kind != expected {
            return Err(DecodeError::Protocol);
        }
        // A redacted block arrives whole on its start, so it takes no delta.
        if replay == Some(ReplayKind::AnthropicRedacted) {
            return Err(DecodeError::Protocol);
        }
        match delta.kind {
            "text_delta" => self.draft.delta(id, required(delta.text)?),
            "thinking_delta" => self.draft.delta(id, required(delta.thinking)?),
            "signature_delta" => {
                let signature = required(delta.signature)?;
                self.draft.open(id)?.bytes.push_str(signature);
                Ok(())
            }
            _ => self.draft.tool_delta(id, required(delta.partial_json)?),
        }
    }

    fn on_block_stop(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        match self.slot_of(root)? {
            Some(id) => self.draft.stop(id),
            None => Ok(()),
        }
    }

    fn on_message_delta(&mut self, root: &Value<'_>) {
        if let Some(raw) = root.get("delta").and_then(|delta| delta.get_str("stop_reason")) {
            self.draft.set_finish(finish_reason(raw), raw);
        }
        // The final message_delta reports thinking tokens as a subset of output_tokens.
        if let Some(usage) = root.get_object("usage") {
            // A compatible host may leave the count out of a later event, which keeps the one it sent.
            if usage.get("output_tokens").is_some() {
                self.draft.usage.output = usage.count("output_tokens");
            }
            if let Some(details) = usage.get_object("output_tokens_details") {
                self.draft.usage.reasoning = details.count("thinking_tokens");
            }
            self.fold_prompt_usage(usage);
        }
    }

    fn on_message_stop(&mut self) -> Result<(), DecodeError> {
        if self.draft.any_open() {
            return Err(DecodeError::Protocol); // An emitted block closes before the done event.
        }
        self.draft.finish();
        Ok(())
    }

    /// The neutral block the event names, or `None` for an ignored one. An index no block started rejects the frame.
    fn slot_of(&self, root: &Value<'_>) -> Result<Option<BlockId>, DecodeError> {
        let index = root.get_index("index")?;
        self.slots.get(index).copied().ok_or(DecodeError::Protocol)
    }
}

/// Return a field that the delta type needs. An absent field, or a field that is not a string, rejects the frame.
fn required(field: Option<&str>) -> Result<&str, DecodeError> {
    field.ok_or(DecodeError::Protocol)
}

fn block_kind(block_type: &str) -> Option<BlockKind> {
    match block_type {
        "text" => Some(BlockKind::Text),
        "thinking" | "redacted_thinking" => Some(BlockKind::Reasoning),
        "tool_use" => Some(BlockKind::ToolCall),
        _ => None,
    }
}

/// The reducer keeps only the raw value for a new reason.
fn finish_reason(raw: &str) -> FinishReason {
    match raw {
        "end_turn" | "stop_sequence" => FinishReason::Stop,
        "max_tokens" | "model_context_window_exceeded" => FinishReason::Length,
        "tool_use" => FinishReason::ToolCalls,
        "refusal" => FinishReason::Refusal,
        "pause_turn" => FinishReason::Pause,
        _ => FinishReason::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::response::ResponseLimits;
    use crate::stream::testing::Harness;

    #[test]
    fn pause_turn_keeps_raw_reason() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"message_delta","delta":{"stop_reason":"pause_turn"}}"#,
            r#"{"type":"message_stop"}"#,
        ])
        .unwrap();
        h.expect_trace("done pause \"pause_turn\"");
    }

    // Each prompt count is cumulative. A repeated count counts once, and counts from separate events add up, as pi
    // does (anthropic-messages.ts).
    #[test]
    fn prompt_usage_folds_across_events() {
        let cases: [(&[&str], &str); 3] = [
            (
                &[
                    r#"{"type":"message_start","message":{"usage":{"input_tokens":7,"cache_read_input_tokens":20,"cache_creation_input_tokens":13}}}"#,
                    r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":7,"cache_read_input_tokens":20,"cache_creation_input_tokens":13,"output_tokens":5}}"#,
                    r#"{"type":"message_stop"}"#,
                ],
                "done stop \"end_turn\" input=40 output=5 cache_read=20 cache_write=13",
            ),
            (
                &[
                    r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":7,"cache_read_input_tokens":20,"output_tokens":5}}"#,
                    r#"{"type":"message_stop"}"#,
                ],
                "done stop \"end_turn\" input=27 output=5 cache_read=20",
            ),
            (
                &[
                    r#"{"type":"message_start","message":{"usage":{"input_tokens":100}}}"#,
                    r#"{"type":"message_delta","delta":{},"usage":{"cache_read_input_tokens":20,"output_tokens":5}}"#,
                    r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{}}"#,
                    r#"{"type":"message_stop"}"#,
                ],
                "done stop \"end_turn\" input=120 output=5 cache_read=20",
            ),
        ];
        for (events, trace) in cases {
            let mut h = Harness::<Reducer>::new();
            h.feed(events).unwrap();
            h.expect_trace(trace);
        }
    }

    // Usage is no part of the answer, so a malformed or null count reads as zero. Anthropic declares every count
    // nullable, so a null count must not fail the response.
    #[test]
    fn invalid_or_null_usage_count_reads_as_zero() {
        let cases: [(&[&str], &str); 2] = [
            (
                &[
                    r#"{"type":"message_start","message":{"usage":{"input_tokens":"nope","cache_read_input_tokens":-3}}}"#,
                    r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
                    r#"{"type":"message_stop"}"#,
                ],
                "done stop \"end_turn\" output=5",
            ),
            (
                &[
                    r#"{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":null,"cache_creation_input_tokens":null}}}"#,
                    r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3,"cache_creation_input_tokens":null}}"#,
                    r#"{"type":"message_stop"}"#,
                ],
                "done stop \"end_turn\" input=10 output=3",
            ),
        ];
        for (events, trace) in cases {
            let mut h = Harness::<Reducer>::new();
            h.feed(events).unwrap();
            h.expect_trace(trace);
        }
    }

    #[test]
    fn tool_reply() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"run"}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"cmd\":\"cargo "}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"test\"}"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            r#"{"type":"message_stop"}"#,
        ])
        .unwrap();
        h.expect_trace(
            "start 0 tool_call\n\
             args 0 \"{\\\"cmd\\\":\\\"cargo \"\n\
             args 0 \"test\\\"}\"\n\
             stop 0 tool_call id=\"toolu_1\" name=\"run\" arguments=\"{\\\"cmd\\\":\\\"cargo test\\\"}\"\n\
             done tool_calls \"tool_use\"",
        );
    }

    #[test]
    fn complete_thinking_on_start_emits_delta() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"plan the poem","signature":"sig"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
        ])
        .unwrap();
        h.expect_trace(
            "start 0 reasoning\n\
             reasoning_delta 0 \"plan the poem\"\n\
             stop 0 reasoning anthropic_signature=\"sig\"",
        );
    }

    #[test]
    fn thinking_collects_signature() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pondering"}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
        ])
        .unwrap();
        h.expect_trace(
            "start 0 reasoning\n\
             reasoning_delta 0 \"pondering\"\n\
             stop 0 reasoning anthropic_signature=\"sig123\"",
        );
    }

    #[test]
    fn redacted_thinking_keeps_data() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"opaque"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
        ])
        .unwrap();
        h.expect_trace("start 0 reasoning\nstop 0 reasoning anthropic_redacted=\"opaque\"");
    }

    #[test]
    fn thinking_tokens_count_as_reasoning_usage() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":40,"output_tokens_details":{"thinking_tokens":25}}}"#,
            r#"{"type":"message_stop"}"#,
        ])
        .unwrap();
        h.expect_trace("done stop \"end_turn\" output=40 reasoning=25");
    }

    // Claude 4 returns this when a safety classifier stops the response. It is not a content filter.
    #[test]
    fn refusal_stop_reason() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#,
            r#"{"type":"message_stop"}"#,
        ])
        .unwrap();
        h.expect_trace("done refusal \"refusal\"");
    }

    #[test]
    fn mismatched_delta_type_fails() {
        for (start, delta) in [
            (
                r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"why"}}"#,
            ),
            (
                r#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"run"}}"#,
                r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}"#,
            ),
        ] {
            let result = Harness::<Reducer>::new().feed(&[start, delta]);
            assert_eq!(result, Err(DecodeError::Protocol));
        }
    }

    #[test]
    fn message_start_without_message_is_accepted() {
        for payload in [
            r#"{"type":"message_start"}"#,
            r#"{"type":"message_start","message":null}"#,
        ] {
            let mut h = Harness::<Reducer>::new();
            h.feed(&[
                payload,
                r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
                r#"{"type":"message_stop"}"#,
            ])
            .unwrap();
            h.expect_trace("done stop \"end_turn\"");
        }
    }

    #[test]
    fn ignored_block_keeps_ids_dense() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv_1","name":"web"}}"#,
            r#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            r#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"hi"}}"#,
            r#"{"type":"content_block_stop","index":1}"#,
            r#"{"type":"message_stop"}"#,
        ])
        .unwrap();
        // The ignored block emits nothing, so the text block is neutral id 0, not the provider index 1.
        h.expect_trace("start 0 text\ntext_delta 0 \"hi\"\nstop 0 text\ndone unknown \"\"");
    }

    #[test]
    fn message_stop_with_open_block_fails() {
        let result = Harness::<Reducer>::new().feed(&[
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            r#"{"type":"message_stop"}"#,
        ]);
        assert_eq!(result, Err(DecodeError::Protocol));
    }

    // An ignored block reaches no consumer, so no event of it can break the answer.
    #[test]
    fn ignored_block_events_are_dropped() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"web_search_tool_result"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"late"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            r#"{"type":"message_stop"}"#,
        ])
        .unwrap();
        h.expect_trace("done stop \"end_turn\"");
    }

    // The typed path reads only `content_block_delta`. For that event, it must match the tree path.
    #[test]
    fn delta_shaped_unknown_event_does_nothing() {
        let mut h = Harness::<Reducer>::new();
        let unknown = [r#"{"type":"some_future_event","data":{}}"#, r#"{"type":"ping"}"#];
        h.feed(&unknown).unwrap();
        h.feed(&[r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#])
            .unwrap();
        h.feed(&unknown).unwrap();
        h.feed(&[r#"{"type":"future_delta","index":0,"delta":{"type":"text_delta","text":"x"}}"#])
            .unwrap();
        h.expect_trace("start 0 text");
    }

    #[test]
    fn delta_index_outside_i64_fails() {
        for index in ["9223372036854775808", "-1", "0"] {
            let mut h = Harness::<Reducer>::new();
            h.feed(&[r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#])
                .unwrap();
            let delta = format!(
                r#"{{"type":"content_block_delta","index":{index},"delta":{{"type":"text_delta","text":"x"}}}}"#
            );
            let result = h.feed(&[&delta]);
            if index == "0" {
                assert_eq!(result, Ok(()));
                h.expect_trace("start 0 text\ntext_delta 0 \"x\"");
            } else {
                assert_eq!(result, Err(DecodeError::Protocol), "{index}");
                h.expect_trace("start 0 text");
            }
        }
    }

    // The block lookup comes first, so a delta of an ignored block does nothing, even a malformed one.
    #[test]
    fn malformed_delta_of_ignored_block_does_nothing() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"web_search_tool_result"}}"#,
            r#"{"type":"content_block_delta","index":0}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"text":"x"}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta"}}"#,
        ])
        .unwrap();
        h.expect_trace("");
    }

    #[test]
    fn ignored_block_counts_toward_limit() {
        let mut h = Harness::<Reducer>::with_limits(ResponseLimits {
            max_blocks: 1,
            ..ResponseLimits::default()
        });
        let result = h.feed(&[
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"s","name":"web_search"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        ]);
        assert_eq!(result, Err(DecodeError::TooLarge));
    }

    #[test]
    fn redacted_thinking_rejects_deltas() {
        let result = Harness::<Reducer>::new().feed(&[
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"opaque"}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"leak"}}"#,
        ]);
        assert_eq!(result, Err(DecodeError::Protocol));
    }
}
