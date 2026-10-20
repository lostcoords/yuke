//! The yuke protocol: JSON-RPC 2.0 messages between a yuke server and its clients, in the conventions of the Agent
//! Client Protocol. The session types of the messages are the types that `yuke-agent` and its stores save.

#[cfg(test)]
mod bindings;
mod event;
mod id;
mod input;
mod interaction;
mod message;
mod session;
mod update;

pub use event::{SessionEvent, StoredEvent};
pub use id::{DraftId, EventNumber, InputId, InstanceId, InteractionId, SessionId};
pub use input::{ConsumedInput, Input, InputError, InputKind, InputSource, PendingInput};
pub use interaction::{InteractionRequest, InteractionRespondParams, InteractionResponse};
pub use message::{
    CancelParams, ClientNotification, ClientRequest, CloseSessionParams, EmptyResult, ForkSessionParams,
    Implementation, InitializeParams, InitializeResult, InputParams, InputResult, Job, JobState, JsonRpc,
    ListJobsParams, ListJobsResult, LoadSessionParams, NoticeLevel, NoticeParams, Notification, PROTOCOL_VERSION,
    RemoveInputParams, Request, RequestId, Response, ResponseError, ResponseOutcome, ServerNotification, SessionResult,
    SetSettingsParams, StopJobParams, UpdateCredentialParams,
};
pub use session::{ModelReference, SessionSettings};
pub use update::{
    BlockPosition, DraftDiscardReason, LiveUpdate, ModelUpdate, SessionState, SessionUpdate, SessionUpdateParams,
};
