//! Map OpenAI Chat Completions SSE data to neutral stream events.

use std::fmt;
use std::marker::PhantomData;

use serde::Deserialize;
use serde::de::{self, Deserializer, IgnoredAny, SeqAccess, Visitor};

use crate::failure::{self, ProviderKind};
use crate::json::{self, Text, Value};
use crate::request::ReplayKind;
use crate::response::{BlockId, BlockKind, FinishReason};
use crate::wire::json::JsonWriter;

use super::draft::{DecodeError, Draft, OpenTools};

/// The kind of one OpenRouter `reasoning_details` entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DetailKind {
    Text,
    Summary,
    Encrypted,
}

impl DetailKind {
    fn parse(name: &str) -> Option<Self> {
        match name {
            "reasoning.text" => Some(Self::Text),
            "reasoning.summary" => Some(Self::Summary),
            "reasoning.encrypted" => Some(Self::Encrypted),
            _ => None,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Text => "reasoning.text",
            Self::Summary => "reasoning.summary",
            Self::Encrypted => "reasoning.encrypted",
        }
    }

    /// The member that holds the body.
    fn field(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Summary => "summary",
            Self::Encrypted => "data",
        }
    }
}

/// One merged OpenRouter `reasoning_details` entry.
#[derive(Debug)]
struct Detail {
    kind: DetailKind,
    /// The text, the summary, or the encrypted data, joined across fragments.
    body: String,
    /// Some fragment named the body member, so the merged entry writes it.
    has_body: bool,
    signature: Option<String>,
    id: Option<String>,
    format: Option<String>,
    index: Option<i64>,
}

/// Keep the first non-empty value a fragment names, as the `||` merge of the SDK does.
fn keep_first(slot: &mut Option<String>, value: Option<&str>) {
    if slot.is_none()
        && let Some(bytes) = value
        && !bytes.is_empty()
    {
        *slot = Some(bytes.to_owned());
    }
}

/// One choice with text, reasoning, a refusal, or one tool call fragment, read with no tree. Other chunks take the tree
/// path. The typed read rejects a duplicate of a field that it reads, and ignores a duplicate of another field.
#[derive(Deserialize)]
struct Chunk<'a> {
    error: Option<IgnoredAny>,
    usage: Option<IgnoredAny>,
    #[serde(default, borrow)]
    choices: One<Choice<'a>>,
}

#[derive(Deserialize)]
struct Choice<'a> {
    #[serde(borrow)]
    delta: Option<Delta<'a>>,
    #[serde(borrow)]
    finish_reason: Option<Text<'a>>,
}

#[derive(Deserialize)]
struct Delta<'a> {
    // A chunk with both names fails the typed read, and the tree path reads `reasoning_content` first.
    #[serde(borrow, alias = "reasoning")]
    reasoning_content: Option<Text<'a>>,
    reasoning_details: Option<IgnoredAny>,
    #[serde(borrow)]
    content: Option<Text<'a>>,
    #[serde(borrow)]
    refusal: Option<Text<'a>>,
    #[serde(borrow)]
    tool_calls: Option<One<ToolCall<'a>>>,
}

#[derive(Deserialize)]
struct ToolCall<'a> {
    /// An `i64`, as the tree path reads it. A larger number fails the typed read.
    index: i64,
    #[serde(borrow)]
    id: Option<Text<'a>>,
    #[serde(borrow)]
    function: Option<Function<'a>>,
}

#[derive(Deserialize)]
struct Function<'a> {
    #[serde(borrow)]
    name: Option<Text<'a>>,
    #[serde(borrow)]
    arguments: Option<Text<'a>>,
}

impl Chunk<'_> {
    /// Return true when the typed fields cover every field that the tree path reads. Return false for a non-null
    /// `error` or `usage`, for `reasoning_details`, or for a tool call with no `function`. The tree path rejects a null
    /// `function`, and ignores a missing one.
    fn typed(&self) -> bool {
        let delta = self.choices.0.as_ref().and_then(|choice| choice.delta.as_ref());
        self.error.is_none()
            && self.usage.is_none()
            && delta.is_none_or(|delta| {
                delta.reasoning_details.is_none()
                    && delta
                        .tool_calls
                        .as_ref()
                        .and_then(|calls| calls.0.as_ref())
                        .is_none_or(|call| call.function.is_some())
            })
    }
}

/// Zero or one element of a JSON array, with no `Vec`. An array of more elements fails the typed read.
struct One<T>(Option<T>);

/// A missing field reads as no element. A derived `Default` adds the bound `T: Default`, and `One` needs no element.
impl<T> Default for One<T> {
    fn default() -> Self {
        One(None)
    }
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for One<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct OneVisitor<T>(PhantomData<T>);

        impl<'de, T: Deserialize<'de>> Visitor<'de> for OneVisitor<T> {
            type Value = One<T>;

            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("an array of at most one element")
            }

            fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<One<T>, A::Error> {
                let first = seq.next_element()?;
                if seq.next_element::<IgnoredAny>()?.is_some() {
                    return Err(de::Error::custom("more than one element"));
                }
                Ok(One(first))
            }
        }

        deserializer.deserialize_seq(OneVisitor(PhantomData))
    }
}

/// This dialect sends no block-stop event, so every block stays open until `[DONE]`.
#[derive(Debug)]
pub(crate) struct Reducer {
    pub(super) draft: Draft,
    /// The one block of each text channel: `content`, `refusal`, and reasoning. Their deltas interleave in no fixed
    /// order. The wire message has one string per channel, so a block never splits.
    channels: [Option<BlockId>; 3],
    /// The neutral block of each wire tool call index.
    tools: Vec<(usize, BlockId)>,
    /// The OpenRouter `reasoning_details` entries, merged as the provider streams them.
    details: Vec<Detail>,
    /// The provider sent the member, even an empty array, so the message must carry it back.
    details_seen: bool,
}

impl Reducer {
    pub(super) fn new(draft: Draft) -> Self {
        Reducer {
            draft,
            channels: [None; 3],
            tools: Vec::new(),
            details: Vec::new(),
            details_seen: false,
        }
    }

    /// Parse one SSE `data` payload and append its neutral events to the draft. Return the provider failure that an
    /// error event names.
    pub(super) fn decode(&mut self, data: &str) -> Result<Option<ProviderKind>, DecodeError> {
        if data == "[DONE]" {
            self.on_done()?;
            return Ok(None);
        }

        // A derived struct also reads a JSON array by position, so only an object takes the typed path.
        if data.trim_start().starts_with('{')
            && let Ok(chunk) = serde_json::from_str::<Chunk<'_>>(data)
            && chunk.typed()
        {
            return self.on_chunk(chunk);
        }
        let root = json::parse(data)?;
        // A gateway can send a failure after the HTTP 200 head. The chunk then holds a top-level `error`.
        if let Some(value) = root.get("error")
            && *value != Value::Null
        {
            return Ok(Some(failure::event_kind(&root)));
        }
        // The request asks for one choice, so the first is the answer. A chunk with none, such as the usage chunk,
        // carries nothing to read, as pi skips it.
        if let Some(Value::Array(choices)) = root.get("choices")
            && let Some(choice) = choices.first()
            && let Some(kind) = self.on_choice(choice)?
        {
            return Ok(Some(kind));
        }
        self.read_usage(&root);
        Ok(None)
    }

    /// Read one choice. Return the failure a finish reason names when the server cut the generation short.
    fn on_choice(&mut self, choice: &Value<'_>) -> Result<Option<ProviderKind>, DecodeError> {
        if let Some(delta @ Value::Object(_)) = choice.get("delta") {
            self.on_delta(delta)?;
        }
        Ok(choice.get_str("finish_reason").and_then(|raw| self.on_finish(raw)))
    }

    /// Record `raw` as the finish reason. Return a server error when `raw` marks a generation that the server cut short.
    fn on_finish(&mut self, raw: &str) -> Option<ProviderKind> {
        if is_interrupted(raw) {
            return Some(ProviderKind::ServerError);
        }
        self.draft.set_finish(finish_reason(raw), raw);
        None
    }

    /// Read a chunk that [`Chunk::typed`] accepts, in the order of [`Reducer::on_delta`].
    fn on_chunk(&mut self, chunk: Chunk<'_>) -> Result<Option<ProviderKind>, DecodeError> {
        let Some(choice) = chunk.choices.0 else {
            return Ok(None);
        };
        if let Some(delta) = choice.delta {
            if let Some(Text(text)) = delta.reasoning_content {
                self.append_delta(BlockKind::Reasoning, &text)?;
            }
            if let Some(Text(text)) = delta.content {
                self.append_delta(BlockKind::Text, &text)?;
            }
            if let Some(Text(text)) = delta.refusal {
                self.append_delta(BlockKind::Refusal, &text)?;
            }
            if let Some(One(Some(call))) = delta.tool_calls
                && let Some(function) = call.function
            {
                let index = usize::try_from(call.index).map_err(|_| DecodeError::Protocol)?;
                let (id, name) = (call.id.as_deref(), function.name.as_deref());
                self.on_tool_fragment(index, id, name, function.arguments.as_deref())?;
            }
        }
        Ok(choice.finish_reason.and_then(|Text(raw)| self.on_finish(&raw)))
    }

    fn on_delta(&mut self, delta: &Value<'_>) -> Result<(), DecodeError> {
        // A chunk that crosses the end of thinking carries both fields, and its reasoning comes first.
        if let Some(text) = delta
            .get_str("reasoning_content")
            .or_else(|| delta.get_str("reasoning"))
        {
            self.append_delta(BlockKind::Reasoning, text)?;
        }
        if let Some(Value::Array(entries)) = delta.get("reasoning_details") {
            // The state can come with no reasoning text, and an empty array still returns, so it opens the block.
            self.channel(BlockKind::Reasoning)?;
            self.details_seen = true;
            for entry in entries {
                self.on_detail(entry)?;
            }
        }
        if let Some(text) = delta.get_str("content") {
            self.append_delta(BlockKind::Text, text)?;
        }
        // A refusal is the text of a model that declined, so it streams in its own block.
        if let Some(text) = delta.get_str("refusal") {
            self.append_delta(BlockKind::Refusal, text)?;
        }
        if let Some(Value::Array(calls)) = delta.get("tool_calls") {
            for call in calls {
                self.on_tool_call(call)?;
            }
        }
        Ok(())
    }

    /// Merge one `reasoning_details` fragment as the OpenRouter SDK does: by type, not `index`, which is often 0.
    /// Text and summary fragments join, an encrypted entry stays whole, and an unknown type drops.
    fn on_detail(&mut self, entry: &Value<'_>) -> Result<(), DecodeError> {
        let Some(kind) = entry.get_str("type").and_then(DetailKind::parse) else {
            return Ok(());
        };
        let reuse = self
            .details
            .last()
            .is_some_and(|last| last.kind == kind && kind != DetailKind::Encrypted);
        if !reuse {
            if self.details.len() >= self.draft.limits.max_blocks as usize {
                return Err(DecodeError::TooLarge);
            }
            self.details.push(Detail {
                kind,
                body: String::new(),
                has_body: false,
                signature: None,
                id: None,
                format: None,
                index: entry.get_int("index"),
            });
        }
        let Some(detail) = self.details.last_mut() else {
            return Ok(());
        };
        if let Some(body) = entry.get_str(kind.field()) {
            detail.body.push_str(body);
            detail.has_body = true;
        }
        keep_first(&mut detail.signature, entry.get_str("signature"));
        keep_first(&mut detail.id, entry.get_str("id"));
        keep_first(&mut detail.format, entry.get_str("format"));
        Ok(())
    }

    /// Write the merged entries as one JSON array into the reasoning block, its `openrouter_details` state.
    fn store_details(&mut self) -> Result<(), DecodeError> {
        if !self.details_seen {
            return Ok(());
        }
        let id = self.channels[channel_index(BlockKind::Reasoning)].ok_or(DecodeError::Protocol)?;
        let max = self.draft.limits.max_event_bytes;
        let block = self.draft.open(id)?;
        block.replay = Some(ReplayKind::OpenrouterDetails);
        let mut bytes = std::mem::take(&mut block.bytes).into_bytes();
        write_details(&mut bytes, &self.details);
        block.bytes = String::from_utf8(bytes).map_err(|_| DecodeError::Protocol)?;
        // The array returns whole in one message, so it is bounded like one event.
        if block.bytes.len() > max {
            return Err(DecodeError::TooLarge);
        }
        Ok(())
    }

    fn append_delta(&mut self, kind: BlockKind, text: &str) -> Result<(), DecodeError> {
        if text.is_empty() {
            return Ok(());
        }
        let id = self.channel(kind)?;
        self.draft.delta(id, text)
    }

    /// The block of a text channel, started on first use.
    fn channel(&mut self, kind: BlockKind) -> Result<BlockId, DecodeError> {
        debug_assert_ne!(kind, BlockKind::ToolCall);
        let index = channel_index(kind);
        if let Some(id) = self.channels[index] {
            return Ok(id);
        }
        let id = self.draft.start(kind)?;
        self.channels[index] = Some(id);
        Ok(id)
    }

    fn on_tool_call(&mut self, call: &Value<'_>) -> Result<(), DecodeError> {
        let index = call.get_index("index")?;
        // Only `index` is required on a chunk, so an entry with no function carries nothing to add.
        let Some(function) = call.get("function") else {
            return Ok(());
        };
        if !matches!(function, Value::Object(_)) {
            return Err(DecodeError::Protocol);
        }
        let arguments = match function.get("arguments") {
            Some(Value::String(fragment)) => Some(&**fragment),
            None | Some(Value::Null) => None,
            Some(_) => return Err(DecodeError::Protocol),
        };
        let (id, name) = (call.optional_str("id")?, function.optional_str("name")?);
        self.on_tool_fragment(index, id, name, arguments)
    }

    /// Apply one tool call fragment: its id, its name, and a piece of its arguments.
    fn on_tool_fragment(
        &mut self,
        index: usize,
        id: Option<&str>,
        name: Option<&str>,
        arguments: Option<&str>,
    ) -> Result<(), DecodeError> {
        let block = self.tool_block(index)?;
        self.draft
            .identify(block, id.unwrap_or_default(), name.unwrap_or_default())?;
        match arguments {
            Some(fragment) => self.draft.tool_delta(block, fragment),
            None => Ok(()),
        }
    }

    fn tool_block(&mut self, index: usize) -> Result<BlockId, DecodeError> {
        if let Some(&(_, id)) = self.tools.iter().find(|(tool, _)| *tool == index) {
            return Ok(id);
        }
        let id = self.draft.start(BlockKind::ToolCall)?;
        self.tools.push((index, id));
        Ok(id)
    }

    fn read_usage(&mut self, root: &Value<'_>) {
        let Some(usage) = root.get_object("usage") else { return };
        let total = &mut self.draft.usage;
        total.input = usage.count("prompt_tokens");
        total.output = usage.count("completion_tokens");
        let prompt = usage.get_object("prompt_tokens_details");
        // Read the cache hits in pi's order: the details (OpenAI, OpenRouter), `prompt_cache_hit_tokens` (DeepSeek),
        // then a top-level `cached_tokens` (Kimi).
        total.cache_read = [
            (prompt, "cached_tokens"),
            (Some(usage), "prompt_cache_hit_tokens"),
            (Some(usage), "cached_tokens"),
        ]
        .into_iter()
        .find_map(|(object, key)| object?.count(key));
        if let Some(details) = prompt {
            total.cache_write = details.count("cache_write_tokens");
        }
        if let Some(details) = usage.get_object("completion_tokens_details") {
            total.reasoning = details.count("reasoning_tokens");
        }
    }

    fn on_done(&mut self) -> Result<(), DecodeError> {
        // A signature can arrive after the text, so the entries are final only here.
        self.store_details()?;
        // This dialect stops no block before `[DONE]`, so every call is complete here.
        self.draft.close_and_finish(OpenTools::Keep)
    }
}

/// The slot of a text channel in `channels`. A tool call has a block per `index`, so it has no channel.
fn channel_index(kind: BlockKind) -> usize {
    match kind {
        BlockKind::Text => 0,
        BlockKind::Refusal => 1,
        BlockKind::Reasoning => 2,
        BlockKind::ToolCall => unreachable!("a tool call has a block per index, not a channel"),
    }
}

/// Write the merged entries as one JSON array, each member in the order the OpenRouter SDK names it.
fn write_details(out: &mut Vec<u8>, details: &[Detail]) {
    let mut jw = JsonWriter::new(out);
    jw.begin_array();
    for detail in details {
        jw.begin_object();
        jw.field_str("type", detail.kind.name());
        if detail.has_body {
            jw.field_str(detail.kind.field(), &detail.body);
        }
        for (name, value) in [
            ("signature", &detail.signature),
            ("id", &detail.id),
            ("format", &detail.format),
        ] {
            if let Some(value) = value {
                jw.field_str(name, value);
            }
        }
        if let Some(index) = detail.index {
            jw.key("index");
            jw.int(index);
        }
        jw.end_object();
    }
    jw.end_array();
}

fn finish_reason(raw: &str) -> FinishReason {
    match raw {
        "stop" => FinishReason::Stop,
        // Mistral names a generation that reached the context limit of the model `model_length`.
        "length" | "model_length" => FinishReason::Length,
        "tool_calls" | "function_call" => FinishReason::ToolCalls,
        "content_filter" => FinishReason::ContentFilter,
        _ => FinishReason::Unknown,
    }
}

/// The finish reasons of a generation the server cut short, which is no answer: DeepSeek's
/// `insufficient_system_resource` and `aborted`, and Mistral's `error`. pi reports them as errors too.
fn is_interrupted(raw: &str) -> bool {
    matches!(raw, "insufficient_system_resource" | "aborted" | "error")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request::Protocol;
    use crate::response::ResponseLimits;
    use crate::stream::testing::Harness;

    const PROTOCOL: Protocol = Protocol::OpenaiChat;

    // DeepSeek documents `insufficient_system_resource` and `aborted` as interrupted generations, and Mistral `error`.
    #[test]
    fn interrupted_finish_fails_and_model_length_is_length() {
        for reason in ["insufficient_system_resource", "aborted", "error"] {
            let mut h = Harness::new(PROTOCOL);
            let chunk =
                format!(r#"{{"choices":[{{"index":0,"delta":{{"content":"cut"}},"finish_reason":"{reason}"}}]}}"#);
            h.feed(&[&chunk]).unwrap();
            h.expect_trace("start 0 text\ntext_delta 0 \"cut\"\nfailed server_error");
        }
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"choices":[{"index":0,"delta":{"content":"long"},"finish_reason":"model_length"}]}"#,
            "[DONE]",
        ])
        .unwrap();
        h.expect_trace("start 0 text\ntext_delta 0 \"long\"\nstop 0 text\ndone length \"model_length\"");
    }

    // pi skips a chunk without `choices` (openai-completions.ts), and a usage-only chunk is one.
    #[test]
    fn chunk_without_choices_carries_usage() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":"stop"}]}"#,
            r#"{"usage":{"prompt_tokens":3,"completion_tokens":1}}"#,
            r#"{"id":"x"}"#,
            "[DONE]",
        ])
        .unwrap();
        h.expect_trace("start 0 text\ntext_delta 0 \"hi\"\nstop 0 text\ndone stop \"stop\" input=3 output=1");
    }

    // pi reads the cache counts from these places (openai-completions.ts parseChunkUsage).
    #[test]
    fn cache_counts_of_each_host() {
        for (usage, want) in [
            (
                r#""prompt_tokens_details":{"cached_tokens":20,"cache_write_tokens":7}"#,
                "done stop \"stop\" input=100 cache_read=20 cache_write=7",
            ),
            (
                r#""prompt_cache_hit_tokens":30,"prompt_cache_miss_tokens":70"#,
                "done stop \"stop\" input=100 cache_read=30",
            ),
            (r#""cached_tokens":40"#, "done stop \"stop\" input=100 cache_read=40"),
        ] {
            let mut h = Harness::new(PROTOCOL);
            let chunk = format!(
                r#"{{"choices":[{{"index":0,"delta":{{}},"finish_reason":"stop"}}],"usage":{{"prompt_tokens":100,{usage}}}}}"#
            );
            h.feed(&[&chunk, "[DONE]"]).unwrap();
            h.expect_trace(want);
        }
    }

    #[test]
    fn unknown_finish_reason_keeps_raw_value() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":"pause_turn"}]}"#,
            "[DONE]",
        ])
        .unwrap();
        h.expect_trace("start 0 text\ntext_delta 0 \"hello\"\nstop 0 text\ndone unknown \"pause_turn\"");
    }

    #[test]
    fn parallel_tool_calls_keep_their_blocks() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"one","arguments":"{\"a\":"}}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"two","arguments":"{\"b\":"}}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"2}"}}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "[DONE]",
        ])
        .unwrap();
        h.expect_trace(
            "start 0 tool_call\n\
             args 0 \"{\\\"a\\\":\"\n\
             start 1 tool_call\n\
             args 1 \"{\\\"b\\\":\"\n\
             args 0 \"1}\"\n\
             args 1 \"2}\"\n\
             stop 0 tool_call id=\"a\" name=\"one\" arguments=\"{\\\"a\\\":1}\"\n\
             stop 1 tool_call id=\"b\" name=\"two\" arguments=\"{\\\"b\\\":2}\"\n\
             done tool_calls \"tool_calls\"",
        );
    }

    // Grok streams reasoning after content starts, and a chunk can carry both fields.
    #[test]
    fn interleaved_channels_keep_one_block_each() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"choices":[{"index":0,"delta":{"reasoning":"how it","role":"assistant"}}]}"#,
            r#"{"choices":[{"index":0,"delta":{"content":"The"}}]}"#,
            r#"{"choices":[{"index":0,"delta":{"reasoning_content":" works."}}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"read","arguments":"{}"}}]}}]}"#,
            r#"{"choices":[{"index":0,"delta":{"content":" plugin","reasoning_content":" Done."}}]}"#,
            r#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "[DONE]",
        ])
        .unwrap();
        h.expect_trace(
            "start 0 reasoning\n\
             reasoning_delta 0 \"how it\"\n\
             start 1 text\n\
             text_delta 1 \"The\"\n\
             reasoning_delta 0 \" works.\"\n\
             start 2 tool_call\n\
             args 2 \"{}\"\n\
             reasoning_delta 0 \" Done.\"\n\
             text_delta 1 \" plugin\"\n\
             stop 0 reasoning\n\
             stop 1 text\n\
             stop 2 tool_call id=\"a\" name=\"read\" arguments=\"{}\"\n\
             done tool_calls \"tool_calls\"",
        );
    }

    // Mistral repeats the id of a call as the string "null" in its later chunks (zed-industries/zed#54058).
    #[test]
    fn first_call_id_and_name_win() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"real_id","function":{"name":"read"}}]}}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"null","function":{"name":"other"}}]},"finish_reason":"tool_calls"}]}"#,
            "[DONE]",
        ])
        .unwrap();
        h.expect_trace(
            "start 0 tool_call\n\
             stop 0 tool_call id=\"real_id\" name=\"read\" arguments=\"{}\"\n\
             done tool_calls \"tool_calls\"",
        );
    }

    // The caller acts on a cut-off answer, so a token limit or a filter outranks the refusal, as in the OpenAI SDK.
    #[test]
    fn length_and_filter_outrank_refusal() {
        for (reason, trace) in [
            (
                "length",
                "start 0 refusal\nrefusal_delta 0 \"I cannot\"\nstop 0 refusal\ndone length \"length\"",
            ),
            (
                "content_filter",
                "start 0 refusal\nrefusal_delta 0 \"I cannot\"\nstop 0 refusal\ndone content_filter \"content_filter\"",
            ),
        ] {
            let mut h = Harness::new(PROTOCOL);
            let finish = format!(r#"{{"choices":[{{"index":0,"delta":{{}},"finish_reason":"{reason}"}}]}}"#);
            h.feed(&[
                r#"{"choices":[{"index":0,"delta":{"refusal":"I cannot"},"finish_reason":null}]}"#,
                &finish,
                "[DONE]",
            ])
            .unwrap();
            h.expect_trace(trace);
        }
    }

    #[test]
    fn gateway_error_chunk_fails_stream() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}"#,
            r#"{"error":{"code":502,"message":"upstream failed"},"choices":[{"delta":{"content":"must not appear"},"finish_reason":"stop"}]}"#,
        ])
        .unwrap();
        h.expect_trace("start 0 text\ntext_delta 0 \"Hel\"\nfailed server_error");
        // A null `error` is no error.
        let mut ok = Harness::new(PROTOCOL);
        ok.feed(&[r#"{"error":null,"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}"#])
            .unwrap();
        ok.expect_trace("start 0 text\ntext_delta 0 \"hi\"");
    }

    #[test]
    fn duplicate_field_the_decoder_reads_fails() {
        let twice = r#"{"choices":[{"index":0,"delta":{"content":"a","content":"b"}}]}"#;
        assert_eq!(Harness::new(PROTOCOL).feed(&[twice]), Err(DecodeError::Protocol));
    }

    #[test]
    fn tool_index_past_i64_fails() {
        let big = r#"{"choices":[{"delta":{"tool_calls":[{"index":9223372036854775808,"function":{"name":"run"}}]}}]}"#;
        assert_eq!(Harness::new(PROTOCOL).feed(&[big]), Err(DecodeError::Protocol));
        let negative = r#"{"choices":[{"delta":{"tool_calls":[{"index":-1,"function":{"name":"run"}}]}}]}"#;
        assert_eq!(Harness::new(PROTOCOL).feed(&[negative]), Err(DecodeError::Protocol));
    }

    #[test]
    fn array_payload_reads_as_nothing() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[r#"[null,null,[{"delta":{"content":"hi"}}]]"#]).unwrap();
        h.expect_trace("");
    }

    #[test]
    fn null_function_fails_and_missing_function_adds_nothing() {
        let null = r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":null}]}}]}"#;
        assert_eq!(Harness::new(PROTOCOL).feed(&[null]), Err(DecodeError::Protocol));
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a"}]}}]}"#])
            .unwrap();
        h.expect_trace("");
    }

    #[test]
    fn calls_in_one_chunk_all_count() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"one","arguments":"{}"}},{"index":1,"id":"b","function":{"name":"two","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
            "[DONE]",
        ])
        .unwrap();
        h.expect_trace(
            "start 0 tool_call\n\
             args 0 \"{}\"\n\
             start 1 tool_call\n\
             args 1 \"{}\"\n\
             stop 0 tool_call id=\"a\" name=\"one\" arguments=\"{}\"\n\
             stop 1 tool_call id=\"b\" name=\"two\" arguments=\"{}\"\n\
             done tool_calls \"tool_calls\"",
        );
    }

    #[test]
    fn tool_index_past_block_limit_fails() {
        let mut h = Harness::new(PROTOCOL).limits(ResponseLimits {
            max_blocks: 1,
            ..ResponseLimits::default()
        });
        let result = h.feed(&[
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"x","arguments":""}}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"y","arguments":""}}]},"finish_reason":null}]}"#,
        ]);
        assert_eq!(result, Err(DecodeError::TooLarge));
    }

    #[test]
    fn reasoning_details_merge_like_openrouter_sdk() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
        r#"{"choices":[{"index":0,"delta":{"reasoning":"Think","reasoning_details":[{"type":"reasoning.text","text":"Think","format":"anthropic-claude-v1","index":0}]},"finish_reason":null}]}"#,
        r#"{"choices":[{"index":0,"delta":{"reasoning":"ing","reasoning_details":[{"type":"reasoning.text","text":"ing","index":0}]},"finish_reason":null}]}"#,
        r#"{"choices":[{"index":0,"delta":{"content":"Hi","reasoning_details":[{"type":"reasoning.text","signature":"sig","index":0},{"type":"reasoning.encrypted","data":"enc","id":"rs_1"},{"type":"reasoning.future"}]},"finish_reason":"stop"}]}"#,
        "[DONE]",
        ])
        .unwrap();
        h.expect_trace(
            "start 0 reasoning\n\
             reasoning_delta 0 \"Think\"\n\
             reasoning_delta 0 \"ing\"\n\
             start 1 text\n\
             text_delta 1 \"Hi\"\n\
             stop 0 reasoning openrouter_details=\"[{\\\"type\\\":\\\"reasoning.text\\\",\\\"text\\\":\\\"Thinking\\\",\\\"signature\\\":\\\"sig\\\",\\\"format\\\":\\\"anthropic-claude-v1\\\",\\\"index\\\":0},{\\\"type\\\":\\\"reasoning.encrypted\\\",\\\"data\\\":\\\"enc\\\",\\\"id\\\":\\\"rs_1\\\"}]\"\n\
             stop 1 text\n\
             done stop \"stop\"",
        );
    }

    #[test]
    fn encrypted_details_open_reasoning_block() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"choices":[{"index":0,"delta":{"content":"Hi","reasoning_details":[{"type":"reasoning.encrypted","data":"enc"}]},"finish_reason":"stop"}]}"#,
            "[DONE]",
        ])
        .unwrap();
        h.expect_trace(
            "start 0 reasoning\n\
             start 1 text\n\
             text_delta 1 \"Hi\"\n\
             stop 0 reasoning openrouter_details=\"[{\\\"type\\\":\\\"reasoning.encrypted\\\",\\\"data\\\":\\\"enc\\\"}]\"\n\
             stop 1 text\n\
             done stop \"stop\"",
        );
    }

    #[test]
    fn empty_and_signature_only_details() {
        let mut h = Harness::new(PROTOCOL);
        h.feed(&[
            r#"{"choices":[{"index":0,"delta":{"reasoning_details":[]},"finish_reason":"stop"}]}"#,
            "[DONE]",
        ])
        .unwrap();
        h.expect_trace(
            "start 0 reasoning\n\
             stop 0 reasoning openrouter_details=\"[]\"\n\
             done stop \"stop\"",
        );

        let mut signed = Harness::new(PROTOCOL);
        signed
            .feed(&[
                r#"{"choices":[{"index":0,"delta":{"reasoning_details":[{"type":"reasoning.text","signature":"","index":0},{"type":"reasoning.text","signature":"s"}]},"finish_reason":"stop"}]}"#,
                "[DONE]",
            ])
            .unwrap();
        signed.expect_trace(
            "start 0 reasoning\n\
             stop 0 reasoning openrouter_details=\"[{\\\"type\\\":\\\"reasoning.text\\\",\\\"signature\\\":\\\"s\\\",\\\"index\\\":0}]\"\n\
             done stop \"stop\"",
        );
    }

    #[test]
    fn reasoning_details_past_bound_fail() {
        let data = "\"".repeat(30);
        let chunks = [serde_json::Value::Null, serde_json::json!("stop")].map(|finish| {
            serde_json::json!({"choices":[{"index":0,"delta":{"reasoning_details":[
                {"type":"reasoning.encrypted","data":data}
            ]},"finish_reason":finish}]})
            .to_string()
        });
        let entry = format!(
            r#"{{"type":"reasoning.encrypted","data":{}}}"#,
            serde_json::to_string(&data).unwrap()
        );
        let expected = format!("[{entry},{entry}]");
        assert_eq!(expected.len(), 203);
        for bound in [200, 203] {
            let mut h = Harness::new(PROTOCOL).limits(ResponseLimits {
                max_event_bytes: bound,
                ..ResponseLimits::default()
            });
            for chunk in &chunks {
                assert!("data: ".len() + chunk.len() <= bound);
                h.feed(&[chunk]).unwrap();
            }
            let result = h.feed(&["[DONE]"]);
            if bound == 200 {
                assert_eq!(result, Err(DecodeError::TooLarge));
            } else {
                assert_eq!(result, Ok(()));
                h.expect_trace(&format!(
                    "start 0 reasoning\nstop 0 reasoning openrouter_details={expected:?}\ndone stop \"stop\""
                ));
            }
        }
    }
}
