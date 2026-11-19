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
mod plugin;
mod session;
mod update;

pub use auth::{
    CancelLoginParams, LoginFinishedParams, LoginOutcome, LoginParams, LoginResult, LogoutParams, SetApiKeyParams,
};
pub use catalog::{
    ListCatalogParams, ListCatalogResult, Modality, ModelInfo, PriceBand, ProviderCredential, ProviderInfo,
    ProviderState, ReasoningChoice, ReasoningLevel,
};
pub use event::{CommitEvent, SessionEvent, StoredEvent};
pub use id::{DraftId, EventNumber, InputId, InstanceId, InteractionId, JobId, LoginId, SessionId};
pub use input::{ConsumedInput, Input, InputError, InputKind, InputSource, PendingInput};
pub use interaction::{
    InteractionRequest, InteractionRespondParams, InteractionResponse, Question, QuestionAnswer, QuestionOption,
};
pub use mcp::{ListMcpServersResult, McpServer, McpServerSource, McpServerState};
pub use message::{
    ClientNotification, ClientRequest, EmptyParams, EmptyResult, ExtensionCancelParams, ExtensionEventParams,
    ExtensionRequestParams, ForkSessionParams, GetBlobParams, GetBlobResult, GetSessionParams, Implementation,
    InitializeParams, InitializeResult, InputParams, InputResult, Job, JobKind, JobState, JsonRpc, ListJobsResult,
    ListSessionsParams, ListSessionsResult, LoadSessionParams, NewSessionParams, NoticeLevel, NoticeParams,
    Notification, PROTOCOL_VERSION, PutBlobParams, RemoveInputParams, RemoveInputResult, RemoveSessionParams,
    RenameSessionParams, Request, RequestId, Response, ResponseError, ResponseOutcome, ServerNotification,
    ServerRequest, ServerResult, SessionParams, SessionResult, SetSettingsParams, StopJobParams,
    UpdateCredentialParams,
};
pub use plugin::{
    AddPluginsParams, AddPluginsResult, AddedPlugin, ApplyPluginsParams, CheckPluginsParams, CheckPluginsResult,
    FailedPlugin, FindPluginsParams, FindPluginsResult, FoundPlugin, ListPluginsResult, LockedPlugin, ManagedPlugin,
    PluginChange, PluginLoad, PluginLog, PluginOrigin, PluginSource, PluginState, PluginTarget, RemovePluginParams,
    SyncPluginsResult,
};
pub use session::{InvalidSessionTitle, ModelReference, SessionRow, SessionSettings, SessionSummary, SessionTitle};
pub use update::{
    BlockPosition, BlockStarted, BlockStopped, DraftCommitted, DraftDiscardReason, DraftDiscarded, DraftModelUpdate,
    DraftStarted, InputAccepted, InputRemoved, InteractionClosed, InteractionRequested, JobUpdate, LiveUpdate,
    ModelUpdate, ReasoningDelta, ReasoningSectionStarted, RefusalDelta, ResponseCompleted, RetryScheduled, RoundFailed,
    SessionSnapshot, SessionState, SessionUpdate, SessionUpdateParams, StartedBlock, StateUpdate, TextDelta,
    ToolFinished, ToolInputDelta, ToolOutput, ToolStarted,
};
