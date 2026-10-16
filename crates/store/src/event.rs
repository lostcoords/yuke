//! The rows of the events table as [`StoredEvent`]s.

use std::borrow::Cow;

use yuke_agent::StoreError;
use yuke_engine::{Answer, Commit, Outcome, Replaced, TurnEnd};
use yuke_protocol::{EventNumber, SessionEvent, StoredEvent};
use yuke_sql::rusqlite;

use crate::context::required;
use crate::queries::events;
use crate::store::failed;

/// The four `end_kind` names of a turn end. The writer and the reader of a commit row use these constants, and the
/// queries and the schema use the same names in SQL.
pub(crate) const COMPLETED: &str = "completed";
pub(crate) const STOPPED: &str = "stopped";
pub(crate) const CANCELLED: &str = "cancelled";
pub(crate) const FAILED: &str = "failed";

/// Decode an event row as a [`StoredEvent`].
pub(crate) fn stored_event(mut row: events::EventsAfter) -> Result<StoredEvent, StoreError> {
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
fn commit(row: events::EventsAfter) -> rusqlite::Result<Commit<'static>> {
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
                input: row.input_tokens,
                output: row.output_tokens,
                reasoning: row.reasoning_tokens,
                cache_read: row.cache_read_tokens,
                cache_write: row.cache_write_tokens,
            },
            finish_reason: finish_reason(&required(row.finish_reason, "finish_reason")?, "finish_reason")?,
        }),
        None => None,
    };
    Ok(Commit {
        replaced,
        blocks: Cow::Owned(required(row.blocks, "blocks")?.0),
        answer,
        end: turn_end(row.end_kind.as_deref(), row.end_finish_reason, row.end_message)?,
    })
}

/// Decode the end columns of a commit row. `None` when the commit ends no turn.
pub(crate) fn turn_end(
    end_kind: Option<&str>,
    end_finish_reason: Option<String>,
    end_message: Option<String>,
) -> rusqlite::Result<Option<TurnEnd>> {
    Ok(match end_kind {
        None => None,
        Some(COMPLETED) => Some(TurnEnd::Outcome(Outcome::Completed {
            finish_reason: finish_reason(&required(end_finish_reason, "end_finish_reason")?, "end_finish_reason")?,
        })),
        Some(STOPPED) => Some(TurnEnd::Outcome(Outcome::Stopped)),
        Some(CANCELLED) => Some(TurnEnd::Outcome(Outcome::Cancelled)),
        Some(FAILED) => Some(TurnEnd::Failed(required(end_message, "end_message")?)),
        Some(_) => return Err(invalid("end_kind")),
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
