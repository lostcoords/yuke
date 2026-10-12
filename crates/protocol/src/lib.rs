//! The yuke protocol: JSON-RPC 2.0 messages between a yuke server and its clients, in the conventions of the Agent
//! Client Protocol. The session types of the messages are the types that `yuke-agent` and its stores save.

#[cfg(test)]
mod bindings;
mod event;
mod id;
mod message;
mod session;
mod update;

pub use event::{SessionEvent, StoredEvent};
pub use id::{EventNumber, InputId, SessionId};
pub use message::{
    CancelParams, ClientNotification, ClientRequest, ForkSessionParams, ForkSessionResult, Implementation,
    InitializeParams, InitializeResult, InputParams, InputResult, JsonRpc, LoadSessionParams, LoadSessionResult,
    NewSessionParams, NewSessionResult, Notification, PROTOCOL_VERSION, Request, RequestId, Response, ResponseError,
    ResponseOutcome, ServerNotification, SetSettingsParams, SetSettingsResult,
};
pub use session::{ModelReference, PendingInput, SessionSettings};
pub use update::{LiveUpdate, SessionUpdate, SessionUpdateParams};
