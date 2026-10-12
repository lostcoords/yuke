//! The rows of the events table as [`StoredEvent`]s.

use std::borrow::Cow;

use yuke_agent::StoreError;
use yuke_engine::{Answer, Commit, Outcome, Replaced, TurnEnd};
use yuke_protocol::{EventNumber, SessionEvent, StoredEvent};
use yuke_sql::rusqlite;

use crate::context::required;
use crate::queries::events;
use crate::store::failed;

/// Decode an event row as a [`StoredEvent`].
pub(crate) fn stored_event(mut row: events::Event) -> Result<StoredEvent, StoreError> {
    let event_number = EventNumber(row.seq);
    let kind = std::mem::take(&mut row.kind);
    let event = match kind.as_str() {
        "settings" => SessionEvent::Settings(required(row.settings, "settings").map_err(failed)?.0),
        "commit" => SessionEvent::Commit {
            consumed: required(row.consumed.take(), "consumed").map_err(failed)?.0,
            commit: commit(row).map_err(failed)?,
        },
        kind => return Err(failed(format!("the event kind {kind} is unknown"))),
    };
    Ok(StoredEvent { event_number, event })
}

/// Decode a commit row as an owned [`Commit`].
fn commit(row: events::Event) -> rusqlite::Result<Commit<'static>> {
    let replaced = match (row.head, row.keep) {
        (Some(head), Some(keep)) => Some(Replaced {
            head: Cow::Owned(head.0),
            keep,
        }),
        _ => None,
    };
    let answer = match row.model {
        Some(model) => Some(Answer {
            origin: yuke_ai::Origin {
                model,
                base_url: required(row.base_url, "base_url")?,
            },
            usage: yuke_ai::Usage {
                input: required(row.input_tokens, "input_tokens")?,
                output: required(row.output_tokens, "output_tokens")?,
                reasoning: required(row.reasoning_tokens, "reasoning_tokens")?,
                cache_read: required(row.cache_read_tokens, "cache_read_tokens")?,
                cache_write: required(row.cache_write_tokens, "cache_write_tokens")?,
            },
            finish_reason: finish_reason(&required(row.finish_reason, "finish_reason")?, "finish_reason")?,
        }),
        None => None,
    };
    let end = match row.end_kind.as_deref() {
        None => None,
        Some("completed") => Some(TurnEnd::Outcome(Outcome::Completed {
            finish_reason: finish_reason(
                &required(row.end_finish_reason, "end_finish_reason")?,
                "end_finish_reason",
            )?,
        })),
        Some("stopped") => Some(TurnEnd::Outcome(Outcome::Stopped)),
        Some("cancelled") => Some(TurnEnd::Outcome(Outcome::Cancelled)),
        Some("failed") => Some(TurnEnd::Failed(required(row.end_message, "end_message")?)),
        Some(_) => return Err(invalid("end_kind")),
    };
    Ok(Commit {
        replaced,
        blocks: Cow::Owned(required(row.blocks, "blocks")?.0),
        answer,
        end,
    })
}

/// Decode `name` from `column` as a finish reason.
fn finish_reason(name: &str, column: &str) -> rusqlite::Result<yuke_ai::FinishReason> {
    yuke_ai::FinishReason::from_name(name).ok_or_else(|| invalid(column))
}

/// The error for an unknown value in `column`.
fn invalid(column: &str) -> rusqlite::Error {
    rusqlite::Error::InvalidColumnType(0, column.to_owned(), rusqlite::types::Type::Text)
}
