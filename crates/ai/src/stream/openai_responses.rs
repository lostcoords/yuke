//! Map OpenAI Responses SSE data to neutral stream events, and reject bad input as a protocol error.

use std::collections::HashMap;
use std::hash::BuildHasherDefault;

use serde::Deserialize;

use crate::failure::{self, ProviderKind};
use crate::json::{self, Text, Value};
use crate::request::{ReplayKind, SEARCH_TOOL_NAME};
use crate::response::{BlockId, BlockKind, FinishReason};
use crate::wire::json::JsonWriter;
use crate::wyhash::Wyhash;

use super::Reduce;
use super::turn::{BlockState, DecodeError, ToolField, Turn};

/// A delta of text, a refusal, reasoning, or tool arguments, read with no tree. Other events take the tree path. The
/// typed read rejects a duplicate of a field that it reads, and ignores a duplicate of another field.
#[derive(Deserialize)]
struct DeltaEvent<'a> {
    #[serde(rename = "type", borrow)]
    event: Text<'a>,
    /// The tree path reads `output_index` as an `i64`. A larger number fails the typed read.
    output_index: i64,
    #[serde(borrow)]
    delta: Text<'a>,
    /// A value that is not an `i64` fails the typed read. The tree path reads it as absent.
    summary_index: Option<i64>,
}

/// What an output item holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ItemKind {
    Message,
    Reasoning,
    Tool,
    Ignored,
}

/// An output item records the blocks that it owns.
#[derive(Debug, Clone, Copy)]
struct Output {
    kind: ItemKind,
    /// The block of each kind this item opened.
    blocks: [Option<BlockId>; 4],
    /// The `summary_index` of the last summary delta, so a new summary section starts on its own paragraph.
    last_summary_index: Option<i64>,
}

impl Output {
    fn block(&self, kind: BlockKind) -> Option<BlockId> {
        self.blocks[slot(kind)]
    }

    /// The block of this kind that the item owns. The turn checks that it is still open.
    fn require(&self, kind: BlockKind) -> Result<BlockId, DecodeError> {
        self.block(kind).ok_or(DecodeError::Protocol)
    }
}

/// The delta events. Both paths select them with [`delta_kind`].
#[derive(Clone, Copy)]
enum DeltaKind {
    Text(BlockKind),
    Summary,
    Reasoning,
    Arguments,
}

fn delta_kind(event: &str) -> Option<DeltaKind> {
    Some(match event {
        "response.output_text.delta" => DeltaKind::Text(BlockKind::Text),
        "response.refusal.delta" => DeltaKind::Text(BlockKind::Refusal),
        "response.reasoning_summary_text.delta" => DeltaKind::Summary,
        "response.reasoning_text.delta" => DeltaKind::Reasoning,
        "response.function_call_arguments.delta" => DeltaKind::Arguments,
        _ => return None,
    })
}

fn slot(kind: BlockKind) -> usize {
    match kind {
        BlockKind::Text => 0,
        BlockKind::Refusal => 1,
        BlockKind::Reasoning => 2,
        BlockKind::ToolCall => 3,
    }
}

#[derive(Debug)]
pub(crate) struct Reducer {
    turn: Turn,
    /// The output items, in the order they first arrived. A repeated `output_index` replaces its item.
    outputs: Vec<Output>,
    /// The position in `outputs` of each `output_index`.
    positions: HashMap<usize, usize, BuildHasherDefault<Wyhash>>,
}

impl Reduce for Reducer {
    fn new(turn: Turn) -> Self {
        Reducer {
            turn,
            outputs: Vec::new(),
            positions: HashMap::default(),
        }
    }

    /// Parse one SSE `data` payload and append its neutral events to the turn. Return the provider failure that an
    /// error event names.
    fn decode(&mut self, data: &str) -> Result<Option<ProviderKind>, DecodeError> {
        // A derived struct also reads a JSON array by position, so only an object takes the typed path.
        if data.trim_start().starts_with('{')
            && let Ok(event) = serde_json::from_str::<DeltaEvent<'_>>(data)
            && let Some(kind) = delta_kind(&event.event)
        {
            let index = usize::try_from(event.output_index).map_err(|_| DecodeError::Protocol)?;
            self.apply_delta(index, kind, event.summary_index, Ok(&event.delta))?;
            return Ok(None);
        }
        let root = json::parse(data)?;
        let event_type = root.require_str("type")?;
        if let Some(kind) = delta_kind(event_type) {
            let delta = root.require_str("delta").map_err(DecodeError::from);
            let index = root.get_index("output_index")?;
            self.apply_delta(index, kind, root.get_int("summary_index"), delta)?;
            return Ok(None);
        }
        match event_type {
            "response.output_item.added" => self.on_output_item_added(&root)?,
            "response.content_part.added" => self.on_content_part_added(&root)?,
            "response.output_text.done" => self.on_text_done(&root, BlockKind::Text)?,
            "response.refusal.done" => self.on_text_done(&root, BlockKind::Refusal)?,
            "response.content_part.done" => self.on_content_part_done(&root)?,
            "response.function_call_arguments.done" => self.on_tool_arguments_done(&root)?,
            "response.output_item.done" => self.on_output_item_done(&root)?,
            "response.completed" => self.on_completed(&root)?,
            "response.incomplete" => self.on_incomplete(&root)?,
            "response.failed" | "error" => return Ok(Some(failure::event_kind(&root))),
            // `response.created`, `response.in_progress`, and unknown event types do nothing.
            _ => {}
        }
        Ok(None)
    }

    fn turn(&self) -> &Turn {
        &self.turn
    }

    fn turn_mut(&mut self) -> &mut Turn {
        &mut self.turn
    }
}

impl Reducer {
    fn on_output_item_added(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let index = root.get_index("output_index")?;
        let item = root.get("item").ok_or(DecodeError::Protocol)?;
        let item_type = item.require_str("type")?;

        // An ignored item opens no block, so the items need their own bound.
        if self.outputs.len() >= self.turn.limits.max_blocks as usize {
            return Err(DecodeError::TooLarge);
        }
        let fresh = Output {
            kind: ItemKind::Ignored,
            blocks: [None; 4],
            last_summary_index: None,
        };
        let position = if let Some(&position) = self.positions.get(&index) {
            self.outputs[position] = fresh;
            position
        } else {
            self.outputs.push(fresh);
            self.positions.insert(index, self.outputs.len() - 1);
            self.outputs.len() - 1
        };

        match item_type {
            "message" => {
                self.outputs[position].kind = ItemKind::Message;
                return Ok(());
            }
            "reasoning" => {
                // Its block opens lazily: on a delta, a content part, or encrypted content at done.
                self.outputs[position].kind = ItemKind::Reasoning;
                return Ok(());
            }
            _ => {}
        }
        // A client search call is a call of the search tool. The model answers to its declared name.
        let search = item_type == "tool_search_call" && item.get_str("execution") == Some("client");
        if !search && item_type != "function_call" {
            return Ok(());
        }

        let name = if search {
            SEARCH_TOOL_NAME
        } else {
            item.require_str("name")?
        };
        // The search item may name its call only when it is done.
        let call_id = match item.get_str("call_id") {
            Some(call_id) => call_id,
            None if search => "",
            None => return Err(DecodeError::Protocol),
        };
        let id = self.turn.start_tool(call_id, name)?;
        let output = &mut self.outputs[position];
        output.kind = ItemKind::Tool;
        output.blocks[slot(BlockKind::ToolCall)] = Some(id);
        Ok(())
    }

    fn on_content_part_added(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let position = self.output_for(root)?;
        let Some(kind) = part_kind(part_type(root)?) else {
            return Ok(());
        };
        if self.outputs[position].block(kind).is_some() {
            return Err(DecodeError::Protocol);
        }
        let id = self.turn.start(kind)?;
        self.outputs[position].blocks[slot(kind)] = Some(id);
        Ok(())
    }

    /// Add a text or refusal delta to the block of that kind the item opened.
    /// Apply one delta event. A summary delta reads `summary`, and another kind ignores it.
    fn apply_delta(
        &mut self,
        index: usize,
        kind: DeltaKind,
        summary: Option<i64>,
        delta: Result<&str, DecodeError>,
    ) -> Result<(), DecodeError> {
        match kind {
            DeltaKind::Text(block) => self.text_delta(index, block, delta),
            DeltaKind::Summary => self.reasoning_delta(index, summary, delta),
            DeltaKind::Reasoning => self.reasoning_delta(index, None, delta),
            DeltaKind::Arguments => self.arguments_delta(index, delta),
        }
    }

    // These functions take `delta` as a `Result`, and read it after they check the item. The reasoning delta opens
    // its block first, so a delta that is not a string fails after the block starts.

    fn text_delta(
        &mut self,
        index: usize,
        kind: BlockKind,
        delta: Result<&str, DecodeError>,
    ) -> Result<(), DecodeError> {
        let id = self.outputs[self.position(index)?].require(kind)?;
        self.turn.delta(id, delta?)
    }

    fn reasoning_delta(
        &mut self,
        index: usize,
        summary: Option<i64>,
        delta: Result<&str, DecodeError>,
    ) -> Result<(), DecodeError> {
        let position = self.position(index)?;
        let id = self.reasoning_block(position)?;
        let delta = delta?;
        // Each summary section opens with a bold title, so sections joined without a break read as one run of titles.
        if let Some(index) = summary {
            let last = self.outputs[position].last_summary_index;
            if last.is_some_and(|last| last != index) {
                self.turn.delta(id, "\n\n")?;
            }
            if last != Some(index) {
                self.turn.section(id)?;
            }
            self.outputs[position].last_summary_index = Some(index);
        }
        self.turn.delta(id, delta)
    }

    fn arguments_delta(&mut self, index: usize, delta: Result<&str, DecodeError>) -> Result<(), DecodeError> {
        let id = self.outputs[self.position(index)?].require(BlockKind::ToolCall)?;
        self.turn.tool_delta(id, delta?)
    }

    fn on_text_done(&mut self, root: &Value<'_>, kind: BlockKind) -> Result<(), DecodeError> {
        // An item with no block of this kind sent no delta of it, so the event closes nothing.
        match self.outputs[self.output_for(root)?].block(kind) {
            Some(id) => self.turn.stop_if_open(id),
            None => Ok(()),
        }
    }

    fn on_content_part_done(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let position = self.output_for(root)?;
        let Some(kind) = part_kind(part_type(root)?) else {
            return Ok(());
        };
        match self.outputs[position].block(kind) {
            Some(id) => self.turn.stop_if_open(id),
            None => Ok(()),
        }
    }

    fn on_tool_arguments_done(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let id = self.outputs[self.output_for(root)?].require(BlockKind::ToolCall)?;
        self.turn.final_args(id, root.require_str("arguments")?)
    }

    fn on_output_item_done(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let position = self.output_for(root)?;
        let item = root.get("item").ok_or(DecodeError::Protocol)?;

        let output = self.outputs[position];
        match output.kind {
            ItemKind::Message | ItemKind::Ignored => Ok(()),
            ItemKind::Reasoning => {
                // Encrypted reasoning can arrive without summary deltas, so open a block to carry it.
                let encrypted = item.get_str("encrypted_content").unwrap_or_default();
                if output.block(BlockKind::Reasoning).is_none() && encrypted.is_empty() {
                    return Ok(());
                }
                let id = self.reasoning_block(position)?;
                if !encrypted.is_empty() {
                    let block = self.turn.open(id)?;
                    block.replay = Some(ReplayKind::ResponsesEncrypted);
                    block.bytes.push_str(encrypted);
                }
                self.turn.stop_if_open(id)
            }
            ItemKind::Tool => {
                let id = output.require(BlockKind::ToolCall)?;
                self.on_tool_done(id, item, item.require_str("type")?)
            }
        }
    }

    fn on_tool_done(&mut self, id: BlockId, item: &Value<'_>, item_type: &str) -> Result<(), DecodeError> {
        let block = self.turn.open(id)?;
        let search = block.name == SEARCH_TOOL_NAME && item_type == "tool_search_call";
        if !search && item_type != "function_call" {
            return Err(DecodeError::Protocol);
        }
        // A status other than `completed` marks a call the model never finished. Drop it.
        if let Some(status) = item.get_str("status")
            && status != "completed"
        {
            return self.turn.drop_block(id);
        }
        if search {
            self.read_search_call(id, item)?;
        } else if let Some(arguments) = item.optional_str("arguments")? {
            self.turn.final_args(id, arguments)?;
        }
        self.turn.stop(id)
    }

    /// A client search call names its call id and its arguments only when it is done.
    /// The arguments arrive as one object, so the block writes its JSON text in place.
    fn read_search_call(&mut self, id: BlockId, item: &Value<'_>) -> Result<(), DecodeError> {
        // The done item repeats or first names the call id, and the call must have one by now.
        self.turn
            .identify(id, ToolField::CallId, item.get_str("call_id").unwrap_or_default())?;
        if self.turn.open(id)?.call_id.is_empty() {
            return Err(DecodeError::Protocol);
        }
        let object = item.get("arguments").ok_or(DecodeError::Protocol)?;
        if !matches!(object, Value::Object(_)) {
            return Err(DecodeError::Protocol);
        }
        let mut text = Vec::new();
        JsonWriter::new(&mut text).value(object);
        // The text comes from parsed strings and ASCII syntax, so it is valid UTF-8.
        let text = String::from_utf8(text).map_err(|_| DecodeError::Protocol)?;
        self.turn.final_args(id, &text)
    }

    fn on_completed(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let response = root.get_object("response").ok_or(DecodeError::Protocol)?;
        self.read_usage(response);
        // This API reports `completed` even for a response that holds a function call.
        // A refusal block turns either reason into `refusal` when the turn finishes.
        let reason = if self.has_tool_call() {
            FinishReason::ToolCalls
        } else {
            FinishReason::Stop
        };
        self.turn.set_finish(reason, "completed");
        self.turn.close_and_finish(true)
    }

    fn on_incomplete(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let response = root.get_object("response").ok_or(DecodeError::Protocol)?;
        self.read_usage(response);

        let reason = match response.get_object("incomplete_details") {
            Some(details) => details.optional_str("reason")?.unwrap_or("incomplete"),
            None => "incomplete",
        };
        self.turn.set_finish(incomplete_reason(reason), reason);
        self.turn.close_and_finish(true)
    }

    fn read_usage(&mut self, response: &Value<'_>) {
        let Some(usage) = response.get_object("usage") else {
            return;
        };
        let total = &mut self.turn.usage;
        total.input = usage.count("input_tokens");
        total.output = usage.count("output_tokens");
        if let Some(details) = usage.get_object("input_tokens_details") {
            total.cache_read = details.count("cached_tokens");
            total.cache_write = details.count("cache_write_tokens");
        }
        if let Some(details) = usage.get_object("output_tokens_details") {
            total.reasoning = details.count("reasoning_tokens");
        }
    }

    /// Find the item an event names by its `output_index`, as the OpenAI SDK and pi do.
    fn output_for(&self, root: &Value<'_>) -> Result<usize, DecodeError> {
        self.position(root.get_index("output_index")?)
    }

    /// Return the position in `outputs` of the item at `output_index`.
    fn position(&self, index: usize) -> Result<usize, DecodeError> {
        self.positions.get(&index).copied().ok_or(DecodeError::Protocol)
    }

    fn reasoning_block(&mut self, position: usize) -> Result<BlockId, DecodeError> {
        if let Some(id) = self.outputs[position].block(BlockKind::Reasoning) {
            return Ok(id);
        }
        let id = self.turn.start(BlockKind::Reasoning)?;
        self.outputs[position].blocks[slot(BlockKind::Reasoning)] = Some(id);
        Ok(id)
    }

    /// True when this response finished a function call. It decides the stop reason at `completed`.
    fn has_tool_call(&self) -> bool {
        // A dropped or unfinished tool block reaches no consumer, so it must not decide the stop reason.
        self.turn
            .blocks
            .iter()
            .any(|block| block.kind == BlockKind::ToolCall && block.state == BlockState::Stopped)
    }
}

fn part_type<'v>(root: &'v Value<'_>) -> Result<&'v str, DecodeError> {
    Ok(root.get("part").ok_or(DecodeError::Protocol)?.require_str("type")?)
}

/// The block that one content part belongs to. The part type decides the block, and an unknown type does nothing.
fn part_kind(part_type: &str) -> Option<BlockKind> {
    match part_type {
        "output_text" => Some(BlockKind::Text),
        "refusal" => Some(BlockKind::Refusal),
        "reasoning_text" | "summary_text" => Some(BlockKind::Reasoning),
        _ => None,
    }
}

/// The SDK names `max_output_tokens`, `max_messages`, `content_filter`, and `steered`, which only a WebSocket sends.
/// `max_messages` caps the conversation, not the output, so it stays `Unknown` with its raw value.
fn incomplete_reason(reason: &str) -> FinishReason {
    match reason {
        "max_output_tokens" => FinishReason::Length,
        "content_filter" => FinishReason::ContentFilter,
        _ => FinishReason::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::response::ResponseLimits;
    use crate::stream::testing::Harness;

    #[test]
    fn text_turn() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.created"}"#,
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.output_text.delta","output_index":0,"delta":"Hel"}"#,
            r#"{"type":"response.output_text.delta","output_index":0,"delta":"lo"}"#,
            r#"{"type":"response.output_text.done","output_index":0}"#,
            r#"{"type":"response.content_part.done","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":100,"output_tokens":5,"input_tokens_details":{"cached_tokens":20}}}}"#,
        ])
        .unwrap();
        h.expect_trace(
            "start 0 text\n\
             text_delta 0 \"Hel\"\n\
             text_delta 0 \"lo\"\n\
             stop 0 text\n\
             done stop \"completed\" input=100 output=5 cache_read=20",
        );
    }

    #[test]
    fn search_call_id_comes_from_first_naming_item() {
        let added_only = r#"{"type":"response.output_item.done","output_index":0,"item":{"type":"tool_search_call","execution":"client","status":"completed","arguments":{}}}"#;
        let other_id = r#"{"type":"response.output_item.done","output_index":0,"item":{"type":"tool_search_call","execution":"client","call_id":"call_8","status":"completed","arguments":{}}}"#;
        let named_late = r#"{"type":"response.output_item.done","output_index":0,"item":{"type":"tool_search_call","execution":"client","call_id":"call_9","status":"completed","arguments":{}}}"#;
        let with_id = r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"tool_search_call","execution":"client","call_id":"call_9","status":"in_progress"}}"#;
        let without_id = r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"tool_search_call","execution":"client","status":"in_progress"}}"#;
        for (added, done, ok) in [
            (with_id, added_only, true),
            (without_id, named_late, true),
            (with_id, other_id, true),
            (without_id, added_only, false),
        ] {
            let mut h = Harness::<Reducer>::new();
            let fed = h.feed(&[added, done]);
            if !ok {
                assert_eq!(fed, Err(DecodeError::Protocol));
                continue;
            }
            fed.unwrap();
            h.expect_trace("start 0 tool_call\nstop 0 tool_call id=\"call_9\" name=\"tool_search\" arguments=\"{}\"");
        }
    }

    // The provider sends these arguments as one object, so the bound applies to the JSON text the block keeps.
    #[test]
    fn search_call_past_argument_bound_fails() {
        let arguments = r#"{"query":"read","limit":2}"#;
        for (max, fits) in [(arguments.len(), true), (arguments.len() - 1, false)] {
            let mut h = Harness::<Reducer>::with_limits(ResponseLimits {
                max_tool_arg_bytes: max,
                ..ResponseLimits::default()
            });
            let fed = h.feed(&[
                r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"tool_search_call","execution":"client","call_id":"call_9","status":"in_progress"}}"#,
                r#"{"type":"response.output_item.done","output_index":0,"item":{"type":"tool_search_call","execution":"client","call_id":"call_9","status":"completed","arguments":{"query":"read","limit":2}}}"#,
            ]);
            if fits {
                fed.unwrap();
                h.feed(&[r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#])
                    .unwrap();
                h.expect_trace(
                    "start 0 tool_call\n\
                     stop 0 tool_call id=\"call_9\" name=\"tool_search\" arguments=\"{\\\"query\\\":\\\"read\\\",\\\"limit\\\":2}\"\n\
                     done tool_calls \"completed\"",
                );
            } else {
                assert_eq!(fed, Err(DecodeError::TooLarge));
            }
        }
    }

    // Nothing orders the item completions, so a later item may close first.
    #[test]
    fn interleaved_tool_items_keep_their_calls() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_a","name":"read"}}"#,
            r#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"path\":\""}"#,
            r#"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_b","name":"read"}}"#,
            r#"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"path\":\"b\"}"}"#,
            r#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"a\"}"}"#,
            r#"{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call"}}"#,
            r#"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call"}}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
        ]).unwrap();
        h.expect_trace(
            "start 0 tool_call\n\
             args 0 \"{\\\"path\\\":\\\"\"\n\
             start 1 tool_call\n\
             args 1 \"{\\\"path\\\":\\\"b\\\"}\"\n\
             args 0 \"a\\\"}\"\n\
             stop 1 tool_call id=\"call_b\" name=\"read\" arguments=\"{\\\"path\\\":\\\"b\\\"}\"\n\
             stop 0 tool_call id=\"call_a\" name=\"read\" arguments=\"{\\\"path\\\":\\\"a\\\"}\"\n\
             done tool_calls \"completed\"",
        );
    }

    // As the OpenAI SDK and pi do, each final statement of the arguments replaces what came before.
    #[test]
    fn latest_final_arguments_win() {
        for (done, arguments) in [
            (
                r#"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call"}}"#,
                r#"{"a":2}"#,
            ),
            (
                r#"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","arguments":"{\"a\":3}"}}"#,
                r#"{"a":3}"#,
            ),
        ] {
            let mut h = Harness::<Reducer>::new();
            h.feed(&[
                r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"run"}}"#,
                r#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"a\":1}"}"#,
                r#"{"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\"a\":2}"}"#,
                done,
            ]).unwrap();
            h.expect_trace(&format!("start 0 tool_call\nargs 0 \"{{\\\"a\\\":1}}\"\nstop 0 tool_call id=\"call_1\" name=\"run\" arguments={arguments:?}"));
        }
    }

    #[test]
    fn reasoning_item_captures_encrypted_content() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning"}}"#,
            r#"{"type":"response.reasoning_summary_text.delta","output_index":0,"delta":"pondering"}"#,
            r#"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"gAAAAsig"}}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{"output_tokens":7}}}"#,
        ])
        .unwrap();
        h.expect_trace(
            "start 0 reasoning\n\
             reasoning_delta 0 \"pondering\"\n\
             stop 0 reasoning responses_encrypted=\"gAAAAsig\"\n\
             done stop \"completed\" output=7",
        );
    }

    #[test]
    fn summary_section_starts_paragraph() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning"}}"#,
            r#"{"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":0,"delta":"**One**"}"#,
            r#"{"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":0,"delta":" body"}"#,
            r#"{"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":1,"delta":"**Two**"}"#,
        ])
        .unwrap();
        // The separator comes before the section event, so each section opens on its title.
        h.expect_trace(
            "start 0 reasoning\n\
             reasoning_section_started 0\n\
             reasoning_delta 0 \"**One**\"\n\
             reasoning_delta 0 \" body\"\n\
             reasoning_delta 0 \"\\n\\n\"\n\
             reasoning_section_started 0\n\
             reasoning_delta 0 \"**Two**\"",
        );
    }

    // The typed path reads the five delta events. For each one, it must match the tree path.
    #[test]
    fn delta_shaped_unknown_event_does_nothing() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.audio.delta","output_index":0,"delta":"x"}"#,
        ])
        .unwrap();
        h.expect_trace("start 0 text");
    }

    #[test]
    fn output_index_outside_i64_fails() {
        for index in ["9223372036854775808", "-1", "0"] {
            let mut h = Harness::<Reducer>::new();
            h.feed(&[
                r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
                r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            ]).unwrap();
            let delta = format!(r#"{{"type":"response.output_text.delta","output_index":{index},"delta":"x"}}"#);
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

    #[test]
    fn summary_index_that_is_not_an_integer_reads_as_absent() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning"}}"#,
            r#"{"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":"a","delta":"x"}"#,
        ])
        .unwrap();
        h.expect_trace("start 0 reasoning\nreasoning_delta 0 \"x\"");
    }

    #[test]
    fn non_string_reasoning_delta_fails_without_output() {
        use crate::testing::{CannedTransport, block_on, frame, target};
        use crate::{Block, Encoder, Failure, Options, Protocol, Request, Stream};
        for (delta, valid) in [("5", false), (r#""x""#, true)] {
            let events = [
                r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning"}}"#.to_owned(),
                format!(r#"{{"type":"response.reasoning_text.delta","output_index":0,"delta":{delta}}}"#),
                r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#.to_owned(),
            ];
            let canned = CannedTransport::new(events.iter().map(|event| frame(event)).collect::<String>());
            let mut encoder = Encoder::new();
            let blocks = [Block::user_text("hello")];
            let encoded = encoder
                .encode(&target(Protocol::OpenaiResponses), Request::new(&blocks))
                .unwrap();
            let mut stream = block_on(Stream::open(&canned, &encoded, Options::default()));
            if valid {
                assert_eq!(
                    super::super::testing::read_trace(&mut stream),
                    "start 0 reasoning\nreasoning_delta 0 \"x\"\nstop 0 reasoning\ndone stop \"completed\""
                );
            } else {
                assert!(matches!(block_on(stream.next()), Some(Err(Failure::Protocol))));
                assert!(block_on(stream.next()).is_none());
            }
        }
    }

    #[test]
    fn encrypted_reasoning_without_summary_emits_block() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning"}}"#,
            r#"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","encrypted_content":"gAAAAsig"}}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{"output_tokens":7}}}"#,
        ])
        .unwrap();
        h.expect_trace(
            "start 0 reasoning\n\
             stop 0 reasoning responses_encrypted=\"gAAAAsig\"\n\
             done stop \"completed\" output=7",
        );
    }

    #[test]
    fn empty_reasoning_item_emits_no_block() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning"}}"#,
            r#"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning"}}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{"output_tokens":7}}}"#,
        ])
        .unwrap();
        h.expect_trace("done stop \"completed\" output=7");
    }

    // pi and the OpenAI SDK key text by its item and close it at the item's end, so a done event of a part that sent no
    // delta closes nothing.
    #[test]
    fn text_done_without_text_block_is_ignored() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.output_text.done","output_index":0,"text":""}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
        ])
        .unwrap();
        h.expect_trace("done stop \"completed\"");
    }

    // Items are keyed by `output_index`, so an item added again replaces the first one. The block that the first item
    // opened stays open until the turn closes it.
    #[test]
    fn readded_item_replaces_first() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.output_text.delta","output_index":0,"delta":"a"}"#,
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"c","name":"read"}}"#,
            r#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{}"}"#,
            r#"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","status":"completed","arguments":"{}"}}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
        ])
        .unwrap();
        h.expect_trace(
            "start 0 text\n\
             text_delta 0 \"a\"\n\
             start 1 tool_call\n\
             args 1 \"{}\"\n\
             stop 1 tool_call id=\"c\" name=\"read\" arguments=\"{}\"\n\
             stop 0 text\n\
             done tool_calls \"completed\"",
        );
    }

    // The replaced item names no text block, so a text delta for it rejects the frame.
    #[test]
    fn replaced_item_forgets_its_blocks() {
        let result = Harness::<Reducer>::new().feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.output_text.delta","output_index":0,"delta":"b"}"#,
        ]);
        assert_eq!(result, Err(DecodeError::Protocol));
    }

    #[test]
    fn ignored_item_counts_toward_limit() {
        let mut h = Harness::<Reducer>::with_limits(ResponseLimits {
            max_blocks: 1,
            ..ResponseLimits::default()
        });
        let fed = h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"web_search_call"}}"#,
            r#"{"type":"response.output_item.added","output_index":1,"item":{"id":"msg_1","type":"message"}}"#,
        ]);
        assert_eq!(fed, Err(DecodeError::TooLarge));
    }

    // The provider marks a call it never finished, so the call must not reach the consumer.
    #[test]
    fn unfinished_tool_item_is_dropped() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"run"}}"#,
            r#"{"type":"response.output_item.done","output_index":0,"item":{"id":"fc_1","type":"function_call","status":"incomplete","arguments":"{}"}}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
        ])
        .unwrap();
        h.expect_trace("start 0 tool_call\ndone stop \"completed\"");
    }

    // These are the frames the provider sent when `max_output_tokens` cut a call off in its arguments.
    #[test]
    fn call_cut_by_output_cap_is_length() {
        let cases: [(&[&str], &str); 2] = [
            (
                &[
                    r#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"},"usage":{"output_tokens":9}}}"#,
                ],
                "done length \"max_output_tokens\" output=9",
            ),
            (
                &[
                    r#"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","status":"in_progress","call_id":"call_1","name":"exec"}}"#,
                    r#"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{}}}"#,
                ],
                "start 0 tool_call\ndone length \"max_output_tokens\"",
            ),
        ];
        for (events, expected) in cases {
            let mut h = Harness::<Reducer>::new();
            h.feed(events).unwrap();
            h.expect_trace(expected);
        }
    }

    // An open call must not reach the consumer or change the finish reason.
    #[test]
    fn only_closed_tool_calls_are_kept() {
        let cases: [(&[&str], &str); 2] = [
            (
                &[
                    r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"run"}}"#,
                    r#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"cmd\":\"cargo "}"#,
                    r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
                ],
                "start 0 tool_call\nargs 0 \"{\\\"cmd\\\":\\\"cargo \"\ndone stop \"completed\"",
            ),
            (
                &[
                    r#"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_a","name":"read"}}"#,
                    r#"{"type":"response.output_item.added","output_index":1,"item":{"id":"fc_2","type":"function_call","call_id":"call_b","name":"read"}}"#,
                    r#"{"type":"response.output_item.done","output_index":0,"item":{"id":"fc_1","type":"function_call","status":"completed","arguments":"{}"}}"#,
                    r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
                ],
                "start 0 tool_call\nstart 1 tool_call\nstop 0 tool_call id=\"call_a\" name=\"read\" arguments=\"{}\"\ndone tool_calls \"completed\"",
            ),
        ];
        for (events, expected) in cases {
            let mut h = Harness::<Reducer>::new();
            h.feed(events).unwrap();
            h.expect_trace(expected);
        }
    }

    // A refusal arrives in its own content part, so it would otherwise commit an empty message.
    #[test]
    fn refusal_streams_in_own_block() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"item_id":"msg_1","part":{"type":"refusal"}}"#,
            r#"{"type":"response.refusal.delta","output_index":0,"content_index":0,"item_id":"msg_1","delta":"I cannot help"}"#,
            r#"{"type":"response.refusal.done","output_index":0,"content_index":0,"item_id":"msg_1","refusal":"I cannot help"}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
        ])
        .unwrap();
        // The turn reports the refusal, so a caller never reads it as a plain answer.
        h.expect_trace(
            "start 0 refusal\n\
             refusal_delta 0 \"I cannot help\"\n\
             stop 0 refusal\n\
             done refusal \"completed\"",
        );
    }

    // The caller acts on a cut-off answer, so a token limit outranks the refusal, as in the OpenAI SDK.
    #[test]
    fn incomplete_outranks_refusal() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"item_id":"msg_1","part":{"type":"refusal"}}"#,
            r#"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{}}}"#,
        ])
        .unwrap();
        h.expect_trace(
            "start 0 refusal\n\
             stop 0 refusal\n\
             done length \"max_output_tokens\"",
        );
    }

    // A refusal outranks a call, because the model declined the request it was given.
    #[test]
    fn refusal_outranks_tool_call() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"run"}}"#,
            r#"{"type":"response.output_item.done","output_index":0,"item":{"id":"fc_1","type":"function_call","status":"completed","arguments":"{}"}}"#,
            r#"{"type":"response.output_item.added","output_index":1,"item":{"id":"msg_1","type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":1,"content_index":0,"item_id":"msg_1","part":{"type":"refusal"}}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
        ])
        .unwrap();
        h.expect_trace(
            "start 0 tool_call\n\
             stop 0 tool_call id=\"call_1\" name=\"run\" arguments=\"{}\"\n\
             start 1 refusal\n\
             stop 1 refusal\n\
             done refusal \"completed\"",
        );
    }

    #[test]
    fn failed_response_and_error_event_classify_by_code() {
        let mut h = Harness::<Reducer>::new();
        h.feed(&[
            r#"{"type":"response.failed","response":{"status":"failed","error":{"code":"rate_limit_exceeded","message":"try again"}}}"#,
        ])
        .unwrap();
        h.expect_trace("failed rate_limited");
        let mut flat = Harness::<Reducer>::new();
        flat.feed(&[r#"{"type":"error","code":"context_length_exceeded","message":"too long","param":null,"sequence_number":1}"#])
            .unwrap();
        flat.expect_trace("failed context_overflow");
        let mut bare = Harness::<Reducer>::new();
        bare.feed(&[r#"{"type":"response.failed"}"#]).unwrap();
        bare.expect_trace("failed provider_failed");
    }
}
