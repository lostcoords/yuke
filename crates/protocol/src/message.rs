//! The JSON-RPC 2.0 messages: the requests and notifications of a client, the notifications of a server, and the
//! responses. Each type holds one message, a JSON object with `"jsonrpc": "2.0"`. The protocol has no batches.
//!
//! An `Option` field that JSON can omit has `serde(default)` beside `skip_serializing_if`: serde needs only the second,
//! and ts-rs marks the field optional only with both.

use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::{
    EventNumber, InputId, InstanceId, InteractionRespondParams, SessionId, SessionSettings, SessionUpdateParams,
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
    /// Create a session with these settings. Each field is required. The server builds the system prompt of the session
    /// from its folder. Result: [`SessionResult`].
    #[serde(rename = "session/new")]
    NewSession(SessionSettings),
    /// Fork a session at the end of a completed turn. Result: [`SessionResult`].
    #[serde(rename = "session/fork")]
    ForkSession(ForkSessionParams),
    /// Open a session, and send it as `session/update` notifications: the saved events, a `state` update, an
    /// `input_accepted` update for each pending input, a `job` update for each running job, an `interaction_requested`
    /// update for each open question, and an `mcp_server` update for each MCP server. The live updates that come during
    /// the load follow them. The result comes last. A load starts no turn, also when input waits. Result:
    /// [`EmptyResult`].
    #[serde(rename = "session/load")]
    LoadSession(LoadSessionParams),
    /// Stop the running turn and the background jobs of a session, and free the session. The session stays saved, and
    /// a load opens it again. A session with running jobs closes only with `stopJobs: true`. Result: [`EmptyResult`].
    #[serde(rename = "session/close")]
    CloseSession(CloseSessionParams),
    /// Add input to a session. An idle session starts a turn. During a turn, the input joins the turn at its next
    /// round. Result: [`InputResult`].
    #[serde(rename = "session/input")]
    Input(InputParams),
    /// Replace the settings of a session from its next turn on. It fails while a turn runs or input waits, because
    /// the settings of a turn do not change. Result: [`EmptyResult`].
    #[serde(rename = "session/set_settings")]
    SetSettings(SetSettingsParams),
    /// Remove a pending input of a session. An input that a commit consumed is no longer pending, so its removal
    /// fails. Result: [`EmptyResult`].
    #[serde(rename = "session/remove_input")]
    RemoveInput(RemoveInputParams),
    /// List the saved sessions, newest first, in pages. Result: [`ListSessionsResult`].
    #[serde(rename = "session/list")]
    ListSessions(ListSessionsParams),
    /// The row of one saved session. Result: [`SessionRow`](crate::SessionRow).
    #[serde(rename = "session/get")]
    GetSession(GetSessionParams),
    /// Delete a saved session with its events, its pending inputs, and its blobs. Its forks stay. It fails for an open
    /// session: close it first with `session/close`. Result: [`EmptyResult`].
    #[serde(rename = "session/remove")]
    RemoveSession(RemoveSessionParams),
    /// Start a device login of a provider, and give its code at once. A login in progress of the provider ends as
    /// cancelled first. The server polls the provider, saves the login, and sends `auth/login_finished`. Result:
    /// [`LoginResult`](crate::LoginResult).
    #[serde(rename = "auth/login")]
    Login(crate::LoginParams),
    /// Ask a login in progress to stop. Its `auth/login_finished` tells how it ended: a poll that got the approval
    /// still saves the login. Result: [`EmptyResult`].
    #[serde(rename = "auth/cancel_login")]
    CancelLogin(crate::CancelLoginParams),
    /// List the providers and their models. Result: [`ListCatalogResult`](crate::ListCatalogResult).
    #[serde(rename = "catalog/list")]
    ListCatalog(crate::ListCatalogParams),
    /// List the running background jobs of an open session. Result: [`ListJobsResult`].
    #[serde(rename = "job/list")]
    ListJobs(SessionParams),
    /// Stop a running background job, and wait for its end. The `job` update with the end comes before the answer. A
    /// stopped job sends no end input. Result: [`EmptyResult`].
    #[serde(rename = "job/stop")]
    StopJob(StopJobParams),
    /// Use `accessToken` for each model request of a provider with a login flow, from the next attempt on, also in a
    /// running turn. The server keeps it only in memory and never refreshes it. After the first update, the server never
    /// uses the stored login of the provider. An expired token fails each attempt until the next update. Result:
    /// [`EmptyResult`].
    #[serde(rename = "credential/update")]
    UpdateCredential(UpdateCredentialParams),
    /// Answer an open question of a session. The `interaction_closed` update of the question comes before the answer.
    /// Result: [`EmptyResult`].
    #[serde(rename = "interaction/respond")]
    InteractionRespond(InteractionRespondParams),
    /// List the MCP servers of an open session. Result: [`crate::ListMcpServersResult`].
    #[serde(rename = "mcp/list")]
    ListMcpServers(SessionParams),
    /// Load the plugins of `config.json` and the providers of `providers.json` again. Each open session stays open, and
    /// its next turn takes the tools and hooks of the new plugins. Result: [`EmptyResult`].
    /// - It fails while a turn runs. Then nothing changes.
    /// - It fails when the server cannot read or check a file. Then the old plugins and providers stay.
    /// - A plugin that does not load sends a notice, and the other plugins load.
    /// - The next request of an open session can miss the prompt cache when the reload changes the tools of that session.
    #[serde(rename = "profile/reload")]
    ReloadProfile(EmptyParams),
}

impl ClientRequest {
    /// The method of each request. A server tells an unknown method from bad params with it.
    pub const METHODS: [&str; 20] = [
        "initialize",
        "session/new",
        "session/fork",
        "session/load",
        "session/close",
        "session/input",
        "session/set_settings",
        "session/remove_input",
        "session/list",
        "session/get",
        "session/remove",
        "auth/login",
        "auth/cancel_login",
        "catalog/list",
        "job/list",
        "job/stop",
        "credential/update",
        "interaction/respond",
        "mcp/list",
        "profile/reload",
    ];
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
    Cancel(SessionParams),
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
    /// The end of a login of `auth/login`.
    #[serde(rename = "auth/login_finished")]
    LoginFinished(crate::LoginFinishedParams),
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
    /// The session runs no background job with this id: the id is unknown, or the job has ended.
    pub const JOB_NOT_FOUND: i32 = -32_004;
    /// The session has no open question with this id: the id is unknown, or the question has ended.
    pub const INTERACTION_NOT_FOUND: i32 = -32_005;
    /// The server has no login in progress with this id: the id is unknown, or the login has ended.
    pub const LOGIN_NOT_FOUND: i32 = -32_006;
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
    /// The id of the server process. Each connection of one `yuke --rpc --listen` gets the same id.
    pub instance_id: InstanceId,
}

/// The result of `session/new` and `session/fork`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SessionResult {
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

/// The params of `session/close`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct CloseSessionParams {
    /// The open session.
    pub session_id: SessionId,
    /// Whether to stop the running background jobs of the session. With `false`, a session with running jobs does not
    /// close.
    pub stop_jobs: bool,
}

/// The params of `session/list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ListSessionsParams {
    /// Only the sessions whose newest settings name this folder. None lists the sessions of every folder.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<PathBuf>,
    /// The most rows of the page, from 1 to 100. None gives 50.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    /// The `nextCursor` of the page before, with the same `cwd`. None starts at the newest session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
}

/// The result of `session/list`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ListSessionsResult {
    /// The sessions of the page, newest first by their newest event. The pages are no snapshot: a session that a new
    /// event moves to the front between two pages comes only in a new list.
    pub sessions: Vec<crate::SessionRow>,
    /// The cursor of the next page. None when no older session exists.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

/// The params of `session/get`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct GetSessionParams {
    /// The id of the saved session. The session can be closed.
    pub session_id: SessionId,
}

/// The params of `session/remove`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct RemoveSessionParams {
    /// The id of the saved session. The session must be closed.
    pub session_id: SessionId,
}

/// The params of a message that names only an open session: `job/list`, `mcp/list`, and `session/cancel`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SessionParams {
    /// The open session.
    pub session_id: SessionId,
}

/// The result of `job/list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ListJobsResult {
    /// The running jobs of the session, oldest first.
    pub jobs: Vec<Job>,
}

/// A background job.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Job {
    /// The id of the job, for example `job-1a2b`.
    pub id: String,
    /// The command of the job.
    pub command: String,
    /// The file that holds the output of the job.
    pub log: PathBuf,
    /// Whether the job runs, and how it ended.
    #[serde(flatten)]
    pub state: JobState,
}

/// Whether a job runs, and how it ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "state", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum JobState {
    /// The process runs.
    Running,
    /// The process ended. Without an exit code and a signal, the wait for the process failed.
    Ended {
        /// The exit code, when the process exited.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        exit_code: Option<i32>,
        /// The signal that ended the process.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        signal: Option<i32>,
        /// A stop ended the job: `job/stop`, a close, or the end of the server.
        stopped: bool,
    },
}

/// The params of `job/stop`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct StopJobParams {
    /// The open session of the job.
    pub session_id: SessionId,
    /// The running job.
    pub job_id: String,
}

/// The params of `credential/update`.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct UpdateCredentialParams {
    /// The provider id, such as `openai-codex`. The provider must have a login flow.
    pub provider: String,
    /// The access token of the model requests.
    pub access_token: String,
    /// The expiry time of `accessToken`, in milliseconds since the Unix epoch.
    pub expires_at: u64,
    /// The account id, for a login flow with accounts. Each model request names it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_id: Option<String>,
}

// `Debug` writes no token.
impl fmt::Debug for UpdateCredentialParams {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("UpdateCredentialParams")
            .field("provider", &self.provider)
            .field("access_token", &"<redacted>")
            .field("expires_at", &self.expires_at)
            .field("account_id", &self.account_id)
            .finish()
    }
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

/// The params of a request with no data: an empty object.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[expect(
    clippy::empty_structs_with_brackets,
    reason = "serde reads a struct with braces from `{}`, and a unit struct from `null`"
)]
pub struct EmptyParams {}

/// The result of a request with no data: an empty object.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[expect(
    clippy::empty_structs_with_brackets,
    reason = "serde writes a struct with braces as `{}`, and a unit struct as `null`"
)]
pub struct EmptyResult {}
