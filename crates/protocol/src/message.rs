//! The JSON-RPC 2.0 messages: the requests and notifications of a client, the notifications of a server, and the
//! responses. Each type holds one message, a JSON object with `"jsonrpc": "2.0"`. The protocol has no batches.
//!
//! An `Option` field that JSON can omit has `serde(default)` beside `skip_serializing_if`: serde needs only the second,
//! and ts-rs marks the field optional only with both.

use serde::{Deserialize, Serialize};

use crate::{
    EventNumber, InputId, InteractionClosedParams, InteractionRequestedParams, InteractionRespondParams, PendingInput,
    SessionId, SessionSettings, SessionUpdateParams,
};

/// The protocol version that this crate speaks. A breaking change of the messages takes the next number.
pub const PROTOCOL_VERSION: u32 = 1;

/// The `jsonrpc` member of each message. It is `"2.0"`, and a read of another text fails.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum JsonRpc {
    /// JSON-RPC 2.0.
    #[serde(rename = "2.0")]
    V2,
}

/// The id of a request: a number or a text, as the client chose it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(untagged)]
pub enum RequestId {
    /// A number.
    Number(i64),
    /// A text.
    Text(String),
}

/// A request of a client. The server answers it with one [`Response`] of the same id.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
pub struct Request {
    /// The version, `"2.0"`.
    #[cfg_attr(test, ts(type = "\"2.0\""))]
    pub jsonrpc: JsonRpc,
    /// The id that the response repeats.
    pub id: RequestId,
    /// The method and its params.
    #[serde(flatten)]
    pub call: ClientRequest,
}

/// The method and the params of a client request.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "method", content = "params")]
pub enum ClientRequest {
    /// Agree on the protocol version. The first request of a connection.
    #[serde(rename = "initialize")]
    Initialize(InitializeParams),
    /// Create a session with these settings. Each field is required. Result: [`NewSessionResult`].
    #[serde(rename = "session/new")]
    NewSession(SessionSettings),
    /// Fork a session at the end of a completed turn. Result: [`ForkSessionResult`].
    #[serde(rename = "session/fork")]
    ForkSession(ForkSessionParams),
    /// Read a session. The server sends its saved events as `session/update` notifications before the result.
    /// Result: [`LoadSessionResult`].
    #[serde(rename = "session/load")]
    LoadSession(LoadSessionParams),
    /// Add input to a session. Result: [`InputResult`].
    #[serde(rename = "session/input")]
    Input(InputParams),
    /// Replace the settings of a session. Result: [`EmptyResult`].
    #[serde(rename = "session/set_settings")]
    SetSettings(SetSettingsParams),
    /// Remove a pending input of a session. An input that a commit consumed is no longer pending, so its removal
    /// fails. Result: [`EmptyResult`].
    #[serde(rename = "session/remove_input")]
    RemoveInput(RemoveInputParams),
    /// Answer a question of a plugin. Result: [`EmptyResult`].
    #[serde(rename = "interaction/respond")]
    InteractionRespond(InteractionRespondParams),
}

/// A notification: a message that a server or a client sends with no id. It gets no response.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
pub struct Notification<Message> {
    /// The version, `"2.0"`.
    #[cfg_attr(test, ts(type = "\"2.0\""))]
    pub jsonrpc: JsonRpc,
    /// The method and its params.
    #[serde(flatten)]
    pub message: Message,
}

/// The method and the params of a client notification.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "method", content = "params")]
pub enum ClientNotification {
    /// Ask the server to stop the running turn of a session. The end of the turn arrives as a saved commit.
    #[serde(rename = "session/cancel")]
    Cancel(CancelParams),
}

/// The method and the params of a server notification.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "method", content = "params")]
pub enum ServerNotification {
    /// A saved event or a live update of a session.
    #[serde(rename = "session/update")]
    SessionUpdate(SessionUpdateParams),
    /// A message for the user. It is not part of session history.
    #[serde(rename = "notice")]
    Notice(NoticeParams),
    /// An event of a plugin. It is not part of session history. A client ignores an extension that it does not know.
    #[serde(rename = "extension/event")]
    ExtensionEvent(ExtensionEventParams),
    /// A plugin asks the user a question. The client answers with `interaction/respond`.
    #[serde(rename = "interaction/requested")]
    InteractionRequested(InteractionRequestedParams),
    /// A question ended without an answer of this client. The client removes it.
    #[serde(rename = "interaction/closed")]
    InteractionClosed(InteractionClosedParams),
}

/// The params of `notice`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct NoticeParams {
    /// The session of the notice. The field is absent for a notice of the whole process.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<SessionId>,
    /// The severity of the notice. A client uses it to show the notice.
    pub level: NoticeLevel,
    /// The plugin or the part of yuke that sent the notice.
    pub source: String,
    /// The text for the user.
    pub message: String,
}

/// The severity of a notice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum NoticeLevel {
    /// A diagnostic detail.
    Debug,
    /// Routine information.
    Info,
    /// A problem that needs attention.
    Warn,
    /// A serious problem.
    Error,
}

/// The params of `extension/event`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ExtensionEventParams {
    /// The session of the event. The field is absent for an event of the whole process.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<SessionId>,
    /// The name that the host gives the plugin. The events of yuke itself use names that start with `host:`.
    pub extension: String,
    /// The name of the event. The plugin chooses it.
    pub event: String,
    /// The data of the event. The plugin chooses its shape, and it puts a version in it when the shape changes.
    #[cfg_attr(test, ts(type = "unknown"))]
    pub data: serde_json::Value,
}

/// The answer to a request: its result or its error.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
pub struct Response {
    /// The version, `"2.0"`.
    #[cfg_attr(test, ts(type = "\"2.0\""))]
    pub jsonrpc: JsonRpc,
    /// The id of the request. It is null when the server cannot read the id, as after a parse error.
    pub id: Option<RequestId>,
    /// The result or the error.
    #[serde(flatten)]
    pub outcome: ResponseOutcome,
}

/// The `result` or the `error` member of a response. A result is the JSON of the result type of its method.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum ResponseOutcome {
    /// The request succeeded.
    Result(#[cfg_attr(test, ts(type = "unknown"))] serde_json::Value),
    /// The request failed.
    Error(ResponseError),
}

/// The error of a failed request.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
pub struct ResponseError {
    /// The kind of the error: one of the constants of this type.
    pub code: i32,
    /// A short text for a person.
    pub message: String,
    /// More facts about the error, when the server has them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[cfg_attr(test, ts(type = "unknown"))]
    pub data: Option<serde_json::Value>,
}

impl ResponseError {
    /// The server cannot read the message as JSON.
    pub const PARSE_ERROR: i32 = -32_700;
    /// The JSON is no valid request object.
    pub const INVALID_REQUEST: i32 = -32_600;
    /// The server has no such method.
    pub const METHOD_NOT_FOUND: i32 = -32_601;
    /// The params do not fit the method.
    pub const INVALID_PARAMS: i32 = -32_602;
    /// The fork point is no end of a completed turn: a kind of [`ResponseError::INVALID_PARAMS`].
    pub const NOT_A_COMPLETED_TURN: i32 = Self::INVALID_PARAMS;
    /// The server failed.
    pub const INTERNAL_ERROR: i32 = -32_603;
    /// The server has no session with this id.
    pub const SESSION_NOT_FOUND: i32 = -32_002;
    /// Another writer holds the session.
    pub const SESSION_OWNED: i32 = -32_003;
}

/// The name, an optional title, and the version of a client or a server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Implementation {
    /// The name for a program.
    pub name: String,
    /// The name for a person.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// The version.
    pub version: String,
}

/// The params of `initialize`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct InitializeParams {
    /// The newest protocol version of the client.
    pub protocol_version: u32,
    /// The client.
    pub client_info: Implementation,
}

/// The result of `initialize`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct InitializeResult {
    /// The protocol version that the server selects: the version of the client when the server speaks it, or else
    /// the newest version of the server.
    pub protocol_version: u32,
    /// The server.
    pub agent_info: Implementation,
}

/// The result of `session/new`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct NewSessionResult {
    /// The id of the new session.
    pub session_id: SessionId,
}

/// The params of `session/fork`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ForkSessionParams {
    /// The source session.
    pub session_id: SessionId,
    /// The event number of the end of a completed turn. None takes the newest completed turn, or the settings before
    /// the first commit when no turn completed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub through: Option<EventNumber>,
}

/// The result of `session/fork`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ForkSessionResult {
    /// The id of the new session.
    pub session_id: SessionId,
}

/// The params of `session/load`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct LoadSessionParams {
    /// The session.
    pub session_id: SessionId,
    /// The last event that the client has. None sends every event.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<EventNumber>,
}

/// The result of `session/load`. The saved events arrive before it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct LoadSessionResult {
    /// The inputs that no commit consumed, in id order.
    pub pending: Vec<PendingInput>,
}

/// The params of `session/input`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct InputParams {
    /// The session.
    pub session_id: SessionId,
    /// The blocks of the input. The server saves the input with the user as its source.
    pub content: Vec<yuke_ai::Block>,
}

/// The result of `session/input`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct InputResult {
    /// The id of the pending input.
    pub input_id: InputId,
}

/// The params of `session/set_settings`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SetSettingsParams {
    /// The session.
    pub session_id: SessionId,
    /// The new model, request settings, and working folder.
    #[serde(flatten)]
    pub settings: SessionSettings,
}

/// The params of `session/remove_input`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct RemoveInputParams {
    /// The session.
    pub session_id: SessionId,
    /// The pending input to remove.
    pub input_id: InputId,
}

/// The result of a request with no data: an empty object.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[expect(
    clippy::empty_structs_with_brackets,
    reason = "serde writes a struct with braces as `{}`, and a unit struct as `null`"
)]
pub struct EmptyResult {}

/// The params of `session/cancel`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct CancelParams {
    /// The session.
    pub session_id: SessionId,
}
