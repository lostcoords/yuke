//! Session, server process, input, and ephemeral draft identities, and session-local event numbers.

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

/// The id of one server process: a version 7 UUID that the server makes before its first client. A client that
/// reconnects and gets another id talks to a new process, so the turns and jobs of the old process are gone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(transparent)]
pub struct InstanceId(#[cfg_attr(test, ts(type = "string"))] uuid::Uuid);

impl InstanceId {
    /// A new id from the current time and random bits.
    pub fn generate() -> Self {
        InstanceId(uuid::Uuid::now_v7())
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

/// The id of a question. The server gives each question a larger id than the questions before it, in each session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(transparent)]
pub struct InteractionId(pub u64);

/// The ephemeral identity of one live provider attempt. The store never saves it.
/// A reconnect cannot resume this draft. The client replaces prior drafts with saved history.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(transparent)]
pub struct DraftId(#[cfg_attr(test, ts(type = "string"))] uuid::Uuid);

impl DraftId {
    /// Create an identity for a new draft.
    pub fn generate() -> Self {
        Self(uuid::Uuid::now_v7())
    }
}
