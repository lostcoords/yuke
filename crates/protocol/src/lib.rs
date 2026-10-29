//! The yuke protocol: JSON-RPC 2.0 messages between a yuke server and its clients, in the conventions of the Agent
//! Client Protocol. The session types of the messages are the types that `yuke-agent` and its stores save.

mod auth;
#[cfg(test)]
mod bindings;
mod catalog;
mod event;
mod id;
mod input;
mod interaction;
mod mcp;
mod message;
mod session;
mod update;

pub use auth::{
    CancelLoginParams, LoginFinishedParams, LoginOutcome, LoginParams, LoginResult, LogoutParams, SetApiKeyParams,
};
pub use catalog::{
    ListCatalogParams, ListCatalogResult, Modality, ModelInfo, PriceBand, ProviderInfo, ProviderState, ReasoningChoice,
    ReasoningLevel,
};
pub use event::{SessionEvent, StoredEvent};
pub use id::{DraftId, EventNumber, InputId, InstanceId, InteractionId, LoginId, SessionId};
pub use input::{ConsumedInput, Input, InputError, InputKind, InputSource, PendingInput};
pub use interaction::{InteractionRequest, InteractionRespondParams, InteractionResponse};
pub use mcp::{ListMcpServersResult, McpServer, McpServerSource, McpServerState};
pub use message::{
    ClientNotification, ClientRequest, CloseSessionParams, EmptyParams, EmptyResult, ExtensionEventParams,
    ForkSessionParams, GetSessionParams, Implementation, InitializeParams, InitializeResult, InputParams, InputResult,
    Job, JobState, JsonRpc, ListJobsResult, ListSessionsParams, ListSessionsResult, LoadSessionParams, NoticeLevel,
    NoticeParams, Notification, PROTOCOL_VERSION, RemoveInputParams, RemoveInputResult, RemoveSessionParams, Request,
    RequestId, Response, ResponseError, ResponseOutcome, ServerNotification, SessionParams, SessionResult,
    SetSettingsParams, StopJobParams, UpdateCredentialParams,
};
pub use session::{ModelReference, SessionActivity, SessionRow, SessionSettings, SessionSummary};
pub use update::{
    BlockPosition, DraftDiscardReason, LiveUpdate, ModelUpdate, SessionSnapshot, SessionState, SessionUpdate,
    SessionUpdateParams,
};
