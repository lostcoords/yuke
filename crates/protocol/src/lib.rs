//! The session types that `yuke-agent` and its stores share: the ids, the settings, the pending inputs, and the saved
//! events of a session. The protocol messages carry the same types.

mod event;
mod id;
mod session;

pub use event::{SessionEvent, StoredEvent};
pub use id::{EventNumber, InputId, SessionId};
pub use session::{ModelReference, PendingInput, SessionSettings};
