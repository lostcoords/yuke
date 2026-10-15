//! The saved events of a session.

use serde::{Deserialize, Serialize};
use yuke_engine::Commit;

use crate::{ConsumedInput, EventNumber, SessionSettings};

/// One saved event of a session, with its event number. Its JSON holds the number as `seq` beside the fields of the
/// event.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
pub struct StoredEvent {
    /// The number of the event in its session.
    #[serde(rename = "seq")]
    pub event_number: EventNumber,
    /// What the event saved.
    #[serde(flatten)]
    pub event: SessionEvent,
}

/// A change of a session that the store saves. A `session/update` carries it with its event number.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "sessionUpdate", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum SessionEvent {
    /// A commit of a turn, and the inputs that it consumed. The blocks of the commit start with the model blocks of
    /// those inputs.
    Commit {
        /// The commit, with its own blocks.
        commit: Commit<'static>,
        /// The inputs that the commit consumed, in input order.
        consumed: Vec<ConsumedInput>,
    },
    /// The settings of the session from this event on.
    Settings(SessionSettings),
}
