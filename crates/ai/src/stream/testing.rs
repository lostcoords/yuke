//! The three protocol reducers share these assertions, so each suite states only its own protocol differences.

use std::fmt::Write as _;

use crate::failure::{Failure, ProviderKind};
use crate::request::{Origin, ReplayKind};
use crate::response::{BlockKind, BlockResult, Event, ResponseLimits};
use crate::testing::block_on;
use crate::wire::json::escape_into;

use super::turn::{DecodeError, Turn};
use super::{Reduce, Stream};

/// A test harness. It holds a reducer, the trace of its events, and the first provider failure of any payload.
pub(crate) struct Harness<R: Reduce> {
    pub(crate) reducer: R,
    pub(crate) failed: Option<ProviderKind>,
    /// The trace line of every event so far. A delta borrows its payload, so the harness renders the delta before the
    /// next payload.
    lines: Vec<String>,
}

impl<R: Reduce> Harness<R> {
    pub(crate) fn new() -> Self {
        Self::with_limits(ResponseLimits::default())
    }

    pub(crate) fn with_limits(limits: ResponseLimits) -> Self {
        let origin = Origin {
            model: "m".into(),
            base_url: "https://example.test/v1".into(),
        };
        Harness {
            reducer: R::new(Turn::new(origin, limits)),
            failed: None,
            lines: Vec::new(),
        }
    }

    /// Decode each payload. The turn keeps every event, because the harness never clears them. The first failure
    /// stays.
    pub(crate) fn feed(&mut self, payloads: &[&str]) -> Result<(), DecodeError> {
        for payload in payloads {
            // A stream reads nothing after the end of an answer.
            assert!(!self.reducer.turn().done, "a payload after the end of the answer");
            self.reducer.turn_mut().begin_payload(payload);
            let decoded = self.reducer.decode(payload);
            let turn = self.reducer.turn();
            self.lines
                .extend((0..turn.pending()).map(|i| trace_line(&turn.event(i, payload))));
            self.reducer.turn_mut().clear_events();
            self.failed = self.failed.or(decoded?);
        }
        Ok(())
    }

    /// Compare every event so far, one line each, and the provider failure, with `expected`.
    #[track_caller]
    pub(crate) fn expect_trace(&self, expected: &str) {
        let mut lines = self.lines.clone();
        if let Some(kind) = self.failed {
            lines.push(failure_line(Failure::Provider(kind)));
        }
        assert_eq!(lines.join("\n"), expected);
    }
}

/// Read every event of a stream into one trace. An event expires at the next read, so its line renders before that
/// read.
pub(crate) fn read_trace(stream: &mut Stream) -> String {
    let mut lines = Vec::new();
    while let Some(item) = block_on(stream.next()) {
        lines.push(item_line(&item));
    }
    lines.join("\n")
}

fn quoted(text: &str) -> String {
    let mut out = vec![b'"'];
    escape_into(&mut out, text.as_bytes());
    out.push(b'"');
    String::from_utf8(out).unwrap()
}

/// Render one event as one trace line, so a test states the whole sequence in one comparison:
///
/// ```text
/// start 0 text
/// text_delta 0 "Hel"
/// stop 0 text
/// done stop "end_turn" input=120 output=5
/// ```
///
/// A string is a JSON string, and `done` names only the usage counts that are not zero.
pub(crate) fn trace_line(event: &Event<'_>) -> String {
    match event {
        Event::BlockStarted(started) => format!("start {} {}", started.block, kind_name(started.kind)),
        Event::TextDelta(delta) => format!("text_delta {} {}", delta.block, quoted(delta.text)),
        Event::RefusalDelta(delta) => format!("refusal_delta {} {}", delta.block, quoted(delta.text)),
        Event::ReasoningDelta(delta) => format!("reasoning_delta {} {}", delta.block, quoted(delta.text)),
        Event::ReasoningSectionStarted(block) => format!("reasoning_section_started {block}"),
        Event::ToolInputDelta(delta) => format!("args {} {}", delta.block, quoted(delta.text)),
        Event::BlockStopped(stopped) => match stopped.result {
            BlockResult::Text => format!("stop {} text", stopped.block),
            BlockResult::Refusal => format!("stop {} refusal", stopped.block),
            BlockResult::Reasoning(None) => format!("stop {} reasoning", stopped.block),
            BlockResult::Reasoning(Some(replay)) => {
                let tag = match replay.kind {
                    ReplayKind::AnthropicSignature => "anthropic_signature",
                    ReplayKind::AnthropicRedacted => "anthropic_redacted",
                    ReplayKind::ResponsesEncrypted => "responses_encrypted",
                    ReplayKind::OpenrouterDetails => "openrouter_details",
                };
                format!("stop {} reasoning {tag}={}", stopped.block, quoted(replay.data))
            }
            BlockResult::ToolCall(call) => format!(
                "stop {} tool_call id={} name={} arguments={}",
                stopped.block,
                quoted(call.call_id),
                quoted(call.name),
                quoted(call.arguments)
            ),
        },
        Event::Done(done) => {
            let mut line = format!(
                "done {} {}",
                done.finish_reason.as_str(),
                quoted(done.raw_finish_reason)
            );
            let usage = done.usage;
            for (name, count) in [
                ("input", usage.input),
                ("output", usage.output),
                ("reasoning", usage.reasoning),
                ("cache_read", usage.cache_read),
                ("cache_write", usage.cache_write),
            ] {
                if count != 0 {
                    _ = write!(line, " {name}={count}");
                }
            }
            line
        }
    }
}

/// Render one item of a stream: an event, or the failure that ends the attempt.
pub(crate) fn item_line(item: &Result<Event<'_>, Failure>) -> String {
    match item {
        Ok(event) => trace_line(event),
        Err(failure) => failure_line(*failure),
    }
}

/// Render the failure that ends an attempt as one trace line.
pub(crate) fn failure_line(failure: Failure) -> String {
    format!("failed {}", failure_name(failure))
}

/// The trace name of a block kind.
fn kind_name(kind: BlockKind) -> &'static str {
    match kind {
        BlockKind::Text => "text",
        BlockKind::Refusal => "refusal",
        BlockKind::Reasoning => "reasoning",
        BlockKind::ToolCall => "tool_call",
    }
}

/// The trace name of a failure: the provider kind in snake case, or the variant name.
fn failure_name(failure: Failure) -> String {
    match failure {
        Failure::Provider(kind) => {
            let debug = format!("{kind:?}");
            let mut snake = String::new();
            for (i, c) in debug.chars().enumerate() {
                if c.is_ascii_uppercase() && i != 0 {
                    snake.push('_');
                }
                snake.push(c.to_ascii_lowercase());
            }
            snake
        }
        Failure::Transport(fault) => format!("{fault:?}"),
        other => format!("{other:?}"),
    }
}
