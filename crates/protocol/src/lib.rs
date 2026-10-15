//! The yuke protocol: JSON-RPC 2.0 messages between a yuke server and its clients, in the conventions of the Agent
//! Client Protocol. The session types of the messages are the types that `yuke-agent` and its stores save.

#[cfg(test)]
mod bindings;
mod event;
mod id;
mod input;
mod message;
mod session;
mod update;

pub use event::{SessionEvent, StoredEvent};
pub use id::{DraftId, EventNumber, InputId, SessionId};
pub use input::{ConsumedInput, Input, InputError, InputSource, PendingInput};
pub use message::{
    CancelParams, ClientNotification, ClientRequest, EmptyResult, ExtensionEventParams, ForkSessionParams,
    ForkSessionResult, Implementation, InitializeParams, InitializeResult, InputParams, InputResult, JsonRpc,
    LoadSessionParams, LoadSessionResult, NewSessionResult, NoticeLevel, NoticeParams, Notification, PROTOCOL_VERSION,
    RemoveInputParams, Request, RequestId, Response, ResponseError, ResponseOutcome, ServerNotification,
    SetSettingsParams,
};
pub use session::{ModelReference, SessionSettings};
pub use update::{BlockPosition, DraftDiscardReason, LiveUpdate, ModelUpdate, SessionUpdate, SessionUpdateParams};
