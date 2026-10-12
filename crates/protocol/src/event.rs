//! The saved events of a session.

use yuke_engine::Commit;

use crate::{EventNumber, InputId, SessionSettings};

/// One saved event of a session, with its event number.
#[derive(Debug, Clone, PartialEq)]
pub struct StoredEvent {
    /// The number of the event in its session.
    pub event_number: EventNumber,
    /// What the event saved.
    pub event: SessionEvent,
}

/// A change of a session that the store saves.
#[derive(Debug, Clone, PartialEq)]
pub enum SessionEvent {
    /// A commit of a turn, and the inputs that it consumed. The blocks of the commit hold the blocks of those inputs.
    Commit {
        /// The commit, with its own blocks.
        commit: Commit<'static>,
        /// The inputs that the commit consumed.
        consumed: Vec<InputId>,
    },
    /// The settings of the session from this event on.
    Settings(SessionSettings),
}
