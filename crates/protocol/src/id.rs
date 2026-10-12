//! The ids of a session and of a pending input, and the number of an event in its session.

use serde::{Deserialize, Serialize};

/// The id of a session: a version 7 UUID, so the ids sort by the millisecond of their creation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(transparent)]
pub struct SessionId(#[cfg_attr(test, ts(type = "string"))] uuid::Uuid);

impl SessionId {
    /// A new id from the current time and random bits.
    pub fn generate() -> Self {
        SessionId(uuid::Uuid::now_v7())
    }

    /// The 16 bytes of the id, in the order that sorts by time.
    pub fn as_bytes(&self) -> &[u8; 16] {
        self.0.as_bytes()
    }
}

/// The number of an event in its session. The events of a session have the numbers 1, 2, 3, and so on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(transparent)]
pub struct EventNumber(pub u64);

/// The id of a pending input. A store gives each input of a session a larger id than the inputs before it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(transparent)]
pub struct InputId(pub u64);
