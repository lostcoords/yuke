//! The ids of a session and of a pending input, and the number of an event in its session.

use std::fmt;
use std::str::FromStr;

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

    /// The id of the 16 bytes that [`SessionId::as_bytes`] returns.
    pub fn from_bytes(bytes: [u8; 16]) -> Self {
        SessionId(uuid::Uuid::from_bytes(bytes))
    }
}

/// The text of the id, as its JSON gives it, for example `0192aaaa-0000-7000-8000-00000000c0ff`.
impl fmt::Display for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.hyphenated().fmt(f)
    }
}

/// Read the id from the text of a UUID in any form, for example the text that [`SessionId`] displays.
impl FromStr for SessionId {
    type Err = uuid::Error;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        uuid::Uuid::parse_str(text).map(SessionId)
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
