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

use super::draft::{BlockState, DecodeError, Draft, OpenTools};

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

    /// The block of this kind that the item owns. The draft checks that it is still open.
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
    pub(super) draft: Draft,
    /// The output items by their `output_index`. A repeated `output_index` replaces its item.
    outputs: HashMap<usize, Output, BuildHasherDefault<Wyhash>>,
}

impl Reducer {
    pub(super) fn new(draft: Draft) -> Self {
        Reducer {
            draft,
            outputs: HashMap::default(),
        }
    }

    /// Parse one SSE `data` payload and append its neutral events to the draft. Return the provider failure that an
    /// error event names.
    pub(super) fn decode(&mut self, data: &str) -> Result<Option<ProviderKind>, DecodeError> {
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
            "response.output_text.done" => self.stop_part(&root, Some(BlockKind::Text))?,
            "response.refusal.done" => self.stop_part(&root, Some(BlockKind::Refusal))?,
            "response.content_part.done" => self.stop_part(&root, part_kind(part_type(&root)?))?,
            "response.output_item.done" => self.on_output_item_done(&root)?,
            "response.completed" => self.on_completed(&root)?,
            "response.incomplete" => self.on_incomplete(&root)?,
            "response.failed" | "error" => return Ok(Some(failure::event_kind(&root))),
            // `response.created`, `response.in_progress`, and unknown event types do nothing.
            _ => {}
        }
        Ok(None)
    }

    fn on_output_item_added(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let index = root.get_index("output_index")?;
        let item = root.get("item").ok_or(DecodeError::Protocol)?;
        let item_type = item.require_str("type")?;

        let fresh = Output {
            kind: ItemKind::Ignored,
            blocks: [None; 4],
            last_summary_index: None,
        };
        // An ignored item opens no block, so the items need their own bound. A repeated index replaces the earlier
        // item.
        if !self.outputs.contains_key(&index) && self.outputs.len() >= self.draft.limits.max_blocks as usize {
            return Err(DecodeError::TooLarge);
        }
        self.outputs.insert(index, fresh);

        match item_type {
            "message" => {
                self.output_mut(index)?.kind = ItemKind::Message;
                return Ok(());
            }
            "reasoning" => {
                // Its block opens lazily: on a delta, a content part, or encrypted content at done.
                self.output_mut(index)?.kind = ItemKind::Reasoning;
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
        let id = self.draft.start_tool(call_id, name)?;
        let output = self.output_mut(index)?;
        output.kind = ItemKind::Tool;
        output.blocks[slot(BlockKind::ToolCall)] = Some(id);
        Ok(())
    }

    fn on_content_part_added(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let output_index = Self::output_for(root)?;
        let Some(kind) = part_kind(part_type(root)?) else {
            return Ok(());
        };
        // The parts of one kind come one after another, so a new part takes the slot of its kind. A delta selects its
        // block by kind, so an overlapping part of one kind is a protocol error.
        if let Some(previous) = self.output(output_index)?.block(kind)
            && self.draft.open(previous).is_ok()
        {
            return Err(DecodeError::Protocol);
        }
        let id = self.draft.start(kind)?;
        self.output_mut(output_index)?.blocks[slot(kind)] = Some(id);
        Ok(())
    }

    /// Apply one delta event. Only a summary delta reads `summary`. Each arm checks the item before it reads `delta`.
    /// The reasoning arm starts its block when the item has none.
    fn apply_delta(
        &mut self,
        index: usize,
        kind: DeltaKind,
        summary: Option<i64>,
        delta: Result<&str, DecodeError>,
    ) -> Result<(), DecodeError> {
        match kind {
            DeltaKind::Text(block) => {
                let id = self.output(index)?.require(block)?;
                self.draft.delta(id, delta?)
            }
            DeltaKind::Summary => self.reasoning_delta(index, summary, delta),
            DeltaKind::Reasoning => self.reasoning_delta(index, None, delta),
            DeltaKind::Arguments => {
                let id = self.output(index)?.require(BlockKind::ToolCall)?;
                self.draft.tool_delta(id, delta?)
            }
        }
    }

    fn reasoning_delta(
        &mut self,
        output_index: usize,
        summary: Option<i64>,
        delta: Result<&str, DecodeError>,
    ) -> Result<(), DecodeError> {
        let id = self.reasoning_block(output_index)?;
        let delta = delta?;
        // Each summary section opens with a bold title, so sections joined without a break read as one run of titles.
        if let Some(index) = summary {
            let last = self.output(output_index)?.last_summary_index;
            if last.is_some_and(|last| last != index) {
                self.draft.delta(id, "\n\n")?;
            }
            if last != Some(index) {
                self.draft.section(id)?;
            }
            self.output_mut(output_index)?.last_summary_index = Some(index);
        }
        self.draft.delta(id, delta)
    }

    /// Stop the block of kind `kind` that the item at `output_index` holds. `None` is an unknown part type and stops
    /// nothing.
    fn stop_part(&mut self, root: &Value<'_>, kind: Option<BlockKind>) -> Result<(), DecodeError> {
        let output_index = Self::output_for(root)?;
        let Some(kind) = kind else {
            return Ok(());
        };
        // An item with no block of this kind sent no delta of it, so the event closes nothing.
        match self.output(output_index)?.block(kind) {
            Some(id) => self.draft.stop_if_open(id),
            None => Ok(()),
        }
    }

    fn on_output_item_done(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let output_index = Self::output_for(root)?;
        let item = root.get("item").ok_or(DecodeError::Protocol)?;

        let output = *self.output(output_index)?;
        match output.kind {
            ItemKind::Message | ItemKind::Ignored => Ok(()),
            ItemKind::Reasoning => {
                // Encrypted reasoning can arrive without summary deltas, so open a block to carry it.
                let encrypted = item.get_str("encrypted_content").unwrap_or_default();
                if output.block(BlockKind::Reasoning).is_none() && encrypted.is_empty() {
                    return Ok(());
                }
                let id = self.reasoning_block(output_index)?;
                if !encrypted.is_empty() {
                    let block = self.draft.open(id)?;
                    block.replay = Some(ReplayKind::ResponsesEncrypted);
                    block.bytes.push_str(encrypted);
                }
                self.draft.stop_if_open(id)
            }
            ItemKind::Tool => {
                let id = output.require(BlockKind::ToolCall)?;
                self.on_tool_done(id, item, item.require_str("type")?)
            }
        }
    }

    fn on_tool_done(&mut self, id: BlockId, item: &Value<'_>, item_type: &str) -> Result<(), DecodeError> {
        let block = self.draft.open(id)?;
        let search = block.name == SEARCH_TOOL_NAME && item_type == "tool_search_call";
        if !search && item_type != "function_call" {
            return Err(DecodeError::Protocol);
        }
        // A status other than `completed` marks a call the model never finished. Drop it.
        if let Some(status) = item.get_str("status")
            && status != "completed"
        {
            return self.draft.drop_block(id);
        }
        if search {
            self.read_search_call(id, item)?;
        } else {
            self.draft.final_args(id, item.require_str("arguments")?)?;
        }
        self.draft.stop(id)
    }

    /// A client search call names its call id and its arguments only when it is done.
    /// The arguments arrive as one object, so the block writes its JSON text in place.
    fn read_search_call(&mut self, id: BlockId, item: &Value<'_>) -> Result<(), DecodeError> {
        // The done item repeats or first names the call id, and the call must have one by now.
        self.draft
            .identify(id, item.get_str("call_id").unwrap_or_default(), "")?;
        if self.draft.open(id)?.call_id.is_empty() {
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
        self.draft.final_args(id, &text)
    }

    fn on_completed(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let response = root.get_object("response").ok_or(DecodeError::Protocol)?;
        self.read_usage(response);
        // This API reports `completed` even for a response that holds a function call.
        // A refusal block turns either reason into `refusal` when the draft finishes.
        let reason = if self.has_tool_call() {
            FinishReason::ToolCalls
        } else {
            FinishReason::Stop
        };
        self.draft.set_finish(reason, "completed");
        self.draft.close_and_finish(OpenTools::Drop)
    }

    fn on_incomplete(&mut self, root: &Value<'_>) -> Result<(), DecodeError> {
        let response = root.get_object("response").ok_or(DecodeError::Protocol)?;
        self.read_usage(response);

        let reason = match response.get_object("incomplete_details") {
            Some(details) => details.optional_str("reason")?.unwrap_or("incomplete"),
            None => "incomplete",
        };
        self.draft.set_finish(incomplete_reason(reason), reason);
        self.draft.close_and_finish(OpenTools::Drop)
    }

    fn read_usage(&mut self, response: &Value<'_>) {
        let Some(usage) = response.get_object("usage") else {
            return;
        };
        let total = &mut self.draft.usage;
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

    /// The `output_index` of the event `root`.
    fn output_for(root: &Value<'_>) -> Result<usize, DecodeError> {
        Ok(root.get_index("output_index")?)
    }

    /// The item at `output_index`. An unknown index is a protocol error.
    fn output(&self, output_index: usize) -> Result<&Output, DecodeError> {
        self.outputs.get(&output_index).ok_or(DecodeError::Protocol)
    }

    /// The item at `output_index`, for a change. An unknown index is a protocol error.
    fn output_mut(&mut self, output_index: usize) -> Result<&mut Output, DecodeError> {
        self.outputs.get_mut(&output_index).ok_or(DecodeError::Protocol)
    }

    fn reasoning_block(&mut self, output_index: usize) -> Result<BlockId, DecodeError> {
        if let Some(id) = self.output(output_index)?.block(BlockKind::Reasoning) {
            return Ok(id);
        }
        let id = self.draft.start(BlockKind::Reasoning)?;
        self.output_mut(output_index)?.blocks[slot(BlockKind::Reasoning)] = Some(id);
        Ok(id)
    }

    /// True when this response finished a function call. It decides the stop reason at `completed`.
    fn has_tool_call(&self) -> bool {
        // A dropped or unfinished tool block reaches no consumer, so it must not decide the stop reason.
        self.draft
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
/// `max_messages` caps the context, not the output, so it stays `Unknown` with its raw value.
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
    use crate::request::Protocol;
    use crate::response::ResponseLimits;
    use crate::route::Credential;
    use crate::stream::testing::Harness;

    const PROTOCOL: Protocol = Protocol::OpenaiResponses;

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
            let mut h = Harness::new(PROTOCOL);
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
            let mut h = Harness::new(PROTOCOL).limits(ResponseLimits {
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
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_a","name":"read"}}"#,
            r#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"path\":\""}"#,
            r#"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_b","name":"read"}}"#,
            r#"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"path\":\"b\"}"}"#,
            r#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"a\"}"}"#,
            r#"{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","arguments":"{\"path\":\"b\"}"}}"#,
            r#"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","arguments":"{\"path\":\"a\"}"}}"#,
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

    #[test]
    fn latest_final_arguments_win() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"run"}}"#,
            r#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"a\":1}"}"#,
            r#"{"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\"a\":2}"}"#,
            r#"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","arguments":"{\"a\":3}"}}"#,
        ]).unwrap();
        h.expect_trace(
            "start 0 tool_call\n\
             args 0 \"{\\\"a\\\":1}\"\n\
             stop 0 tool_call id=\"call_1\" name=\"run\" arguments=\"{\\\"a\\\":3}\"",
        );
    }

    #[test]
    fn final_function_item_requires_arguments() {
        for arguments in ["", r#","arguments":null"#] {
            let mut h = Harness::new(PROTOCOL);
            h.feed(&[
                r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"run"}}"#,
                r#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{}"}"#,
                r#"{"type":"response.function_call_arguments.done","output_index":0,"arguments":"{}"}"#,
            ]).unwrap();
            let done = format!(
                r#"{{"type":"response.output_item.done","output_index":0,"item":{{"type":"function_call"{arguments}}}}}"#
            );
            assert_eq!(h.feed(&[&done]), Err(DecodeError::Protocol));
        }
    }

    #[test]
    fn summary_section_starts_paragraph() {
        let mut h = Harness::new(PROTOCOL);
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
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.audio.delta","output_index":0,"delta":"x"}"#,
        ])
        .unwrap();
        h.expect_trace("start 0 text");
    }

    #[test]
    fn summary_index_that_is_not_an_integer_reads_as_absent() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning"}}"#,
            r#"{"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":"a","delta":"x"}"#,
        ])
        .unwrap();
        h.expect_trace("start 0 reasoning\nreasoning_delta 0 \"x\"");
    }

    #[test]
    fn non_string_reasoning_delta_fails_without_output() {
        use crate::stream::Stream;
        use crate::testing::{CannedTransport, block_on, frame, target};
        use crate::{Block, Encoder, Failure, Options, Protocol, Request};
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
                .encode(
                    &target(Protocol::OpenaiResponses),
                    &Credential::None,
                    Request::new(&blocks),
                )
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
        let mut h = Harness::new(PROTOCOL);
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
        let mut h = Harness::new(PROTOCOL);
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
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.output_text.done","output_index":0,"text":""}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
        ])
        .unwrap();
        h.expect_trace("done stop \"completed\"");
    }

    // Items are keyed by `output_index`, so an item added again replaces the first one. The block that the first item
    // opened stays open until the draft closes it.
    #[test]
    fn readded_item_replaces_first() {
        let mut h = Harness::new(PROTOCOL);
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

    // A host can end a text part with only `output_text.done`, and a refusal part with only `refusal.done`.
    #[test]
    fn a_text_or_refusal_done_ends_its_part_without_a_part_done() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"a"}"#,
            r#"{"type":"response.output_text.done","output_index":0,"content_index":0}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":1,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":2,"part":{"type":"refusal"}}"#,
            r#"{"type":"response.refusal.delta","output_index":0,"content_index":2,"delta":"no"}"#,
            r#"{"type":"response.refusal.done","output_index":0,"content_index":2}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":3,"part":{"type":"refusal"}}"#,
        ])
        .unwrap();
        h.expect_trace(
            "start 0 text\n\
             text_delta 0 \"a\"\n\
             stop 0 text\n\
             start 1 text\n\
             start 2 refusal\n\
             refusal_delta 2 \"no\"\n\
             stop 2 refusal\n\
             start 3 refusal",
        );
    }

    // A message can hold several parts of one kind, each after the end of the one before.
    #[test]
    fn later_part_of_one_kind_opens_its_own_block() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"a"}"#,
            r#"{"type":"response.content_part.done","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":1,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.output_text.delta","output_index":0,"content_index":1,"delta":"b"}"#,
            r#"{"type":"response.output_text.done","output_index":0,"content_index":1}"#,
            r#"{"type":"response.content_part.done","output_index":0,"content_index":1,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
        ])
        .unwrap();
        h.expect_trace(
            "start 0 text\n\
             text_delta 0 \"a\"\n\
             stop 0 text\n\
             start 1 text\n\
             text_delta 1 \"b\"\n\
             stop 1 text\n\
             done stop \"completed\"",
        );

        // A part that starts while another of its kind is open has no block of its own.
        let overlapping = Harness::new(PROTOCOL).feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":1,"part":{"type":"output_text"}}"#,
        ]);
        assert_eq!(overlapping, Err(DecodeError::Protocol));
    }

    // The replaced item names no text block, so a text delta for it rejects the frame.
    #[test]
    fn replaced_item_forgets_its_blocks() {
        let result = Harness::new(PROTOCOL).feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.output_text.delta","output_index":0,"delta":"b"}"#,
        ]);
        assert_eq!(result, Err(DecodeError::Protocol));
    }

    #[test]
    fn ignored_item_counts_toward_limit() {
        let mut h = Harness::new(PROTOCOL).limits(ResponseLimits {
            max_blocks: 1,
            ..ResponseLimits::default()
        });
        let fed = h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"web_search_call"}}"#,
            r#"{"type":"response.output_item.added","output_index":1,"item":{"id":"msg_1","type":"message"}}"#,
        ]);
        assert_eq!(fed, Err(DecodeError::TooLarge));
    }

    // A replacement reuses the slot of the earlier item, so the item limit allows it.
    #[test]
    fn replacement_at_item_limit_succeeds() {
        let mut h = Harness::new(PROTOCOL).limits(ResponseLimits {
            max_blocks: 1,
            ..ResponseLimits::default()
        });
        h.feed(&[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"web_search_call"}}"#,
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.output_text.delta","output_index":0,"delta":"a"}"#,
            r#"{"type":"response.output_text.done","output_index":0}"#,
            r#"{"type":"response.completed","response":{"status":"completed","usage":{}}}"#,
        ])
        .unwrap();
        h.expect_trace("start 0 text\ntext_delta 0 \"a\"\nstop 0 text\ndone stop \"completed\"");
    }

    // The provider marks a call it never finished, so the call must not reach the consumer.
    #[test]
    fn unfinished_tool_item_is_dropped() {
        let mut h = Harness::new(PROTOCOL);
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
            let mut h = Harness::new(PROTOCOL);
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
            let mut h = Harness::new(PROTOCOL);
            h.feed(events).unwrap();
            h.expect_trace(expected);
        }
    }

    // The caller acts on a cut-off answer, so a token limit outranks the refusal, as in the OpenAI SDK.
    #[test]
    fn incomplete_outranks_refusal() {
        let mut h = Harness::new(PROTOCOL);
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
        let mut h = Harness::new(PROTOCOL);
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
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"type":"response.failed","response":{"status":"failed","error":{"code":"rate_limit_exceeded","message":"try again"}}}"#,
        ])
        .unwrap();
        h.expect_trace("failed rate_limited");
        let mut flat = Harness::new(PROTOCOL);
        flat.feed(&[r#"{"type":"error","code":"context_length_exceeded","message":"too long","param":null,"sequence_number":1}"#])
            .unwrap();
        flat.expect_trace("failed context_overflow");
        let mut bare = Harness::new(PROTOCOL);
        bare.feed(&[r#"{"type":"response.failed"}"#]).unwrap();
        bare.expect_trace("failed provider_failed");
    }
}
