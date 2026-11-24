//! The JSON-RPC 2.0 messages: the requests and notifications of a client and of a server, and the responses. Each type
//! holds one message, a JSON object with `"jsonrpc": "2.0"`. The protocol has no batches.
//!
//! An absent field is left out of the JSON, never `null`: each `Option` field has `skip_serializing_if`, and its type has
//! `ts(optional_fields)`. The `id` of a [`Response`] is the one exception, because JSON-RPC asks for a null.

use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use yuke_ai::Blob;

use crate::{
    AddPluginsResult, CheckPluginsResult, EventNumber, FindPluginsResult, InputId, InstanceId,
    InteractionRespondParams, ListCatalogResult, ListMcpServersResult, ListPluginsResult, LoginResult, McpLoginResult,
    SessionId, SessionRow, SessionSettings, SessionTitle, SessionUpdateParams, SyncPluginsResult,
};

/// The protocol version that this crate speaks.
pub const PROTOCOL_VERSION: u32 = 1;

/// The `jsonrpc` member of each message. It is `"2.0"`, and a read of another text fails.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum JsonRpc {
    /// JSON-RPC 2.0.
    #[serde(rename = "2.0")]
    V2,
}

/// The id of a request: a number or a text, as its sender chose it. The ids of each direction are separate.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(untagged)]
pub enum RequestId {
    /// A number.
    Number(i64),
    /// A text.
    Text(String),
}

/// A request: a [`ClientRequest`] or a [`ServerRequest`]. The receiver answers it with one [`Response`] of the same id.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
pub struct Request<Call> {
    /// The version, `"2.0"`.
    #[cfg_attr(test, ts(type = "\"2.0\""))]
    pub jsonrpc: JsonRpc,
    /// The id that the response repeats.
    pub id: RequestId,
    /// The method and its params.
    #[serde(flatten)]
    pub call: Call,
}

/// Define [`ClientRequest`], [`ClientRequest::METHODS`], [`ServerResult`], and the TypeScript map of the results from
/// one table, so they name the same methods. Each entry names a result type with a bare name, for its doc link.
macro_rules! client_requests {
    ($($(#[doc = $doc:literal])* $method:literal => $variant:ident($params:ty) -> $result:ident,)*) => {
        /// The method and the params of a client request.
        #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
        #[cfg_attr(test, derive(ts_rs::TS))]
        #[serde(tag = "method", content = "params")]
        pub enum ClientRequest {
            $(
                $(#[doc = $doc])*
                #[doc = ""]
                #[doc = concat!("Result: [`", stringify!($result), "`].")]
                #[serde(rename = $method)]
                $variant($params),
            )*
        }

        impl ClientRequest {
            /// The method of each request. A server tells an unknown method from bad params with it.
            pub const METHODS: &[&str] = &[$($method),*];
        }

        /// The result of a client request, one variant for each method. Its JSON is the JSON of the result type.
        #[derive(Debug, Serialize)]
        #[serde(untagged)]
        pub enum ServerResult {
            $($(#[doc = $doc])* $variant($result),)*
        }

        /// The result type of each client request, by its method. A client reads the type of a response from it.
        // Only the bindings test uses this type: it writes the TypeScript map.
        #[cfg(test)]
        #[derive(ts_rs::TS)]
        #[expect(dead_code, non_snake_case, reason = "only ts-rs reads this type, and its fields are the variants")]
        pub(crate) struct ClientRequestResults {
            $($(#[doc = $doc])* #[ts(rename = $method)] $variant: $result,)*
        }
    };
}

client_requests!(
    /// Agree on the protocol version. The first request of a connection.
    "initialize" => Initialize(InitializeParams) -> InitializeResult,
    /// Create a session with these settings. Each field of the settings is required. The server builds the system
    /// prompt of the session from its folder.
    "session/new" => NewSession(NewSessionParams) -> SessionResult,
    /// Fork a session at the end of a completed turn.
    "session/fork" => ForkSession(ForkSessionParams) -> SessionResult,
    /// Open a session, and send it as `session/update` notifications: the saved events, a `state` update, an
    /// `inputAccepted` update for each pending input, a `job` update for each running job, an `mcpServer` update for
    /// each MCP server, and an `interactionRequested` update for each open question. The live updates that come during
    /// the load and that these updates do not hold follow them. The result comes last. A load starts no turn, also when
    /// input waits.
    "session/load" => LoadSession(LoadSessionParams) -> EmptyResult,
    /// Stop the running turn and the background jobs of a session, and free the session. The session stays saved, and
    /// a load opens it again.
    "session/close" => CloseSession(SessionParams) -> EmptyResult,
    /// Add input to a session. An idle session starts a turn. During a turn, the input joins the turn at its next
    /// round.
    "session/input" => Input(InputParams) -> InputResult,
    /// Replace the settings of a session from its next turn on. It fails while a turn runs or input waits, because
    /// the settings of a turn do not change.
    "session/setSettings" => SetSettings(SetSettingsParams) -> EmptyResult,
    /// Rename a saved session.
    "session/rename" => RenameSession(RenameSessionParams) -> EmptyResult,
    /// Remove a pending input of a session. A turn saves its input before the model reads it, so the model never reads
    /// a removed input.
    "session/removeInput" => RemoveInput(RemoveInputParams) -> RemoveInputResult,
    /// List the saved sessions, newest first, in pages.
    "session/list" => ListSessions(ListSessionsParams) -> ListSessionsResult,
    /// The row of one saved session.
    "session/get" => GetSession(GetSessionParams) -> SessionRow,
    /// Delete a saved session and its descendants, with their events, pending inputs, and blobs. Its forks stay. It fails
    /// while one of these sessions is open: close them first with `session/close`.
    "session/remove" => RemoveSession(RemoveSessionParams) -> EmptyResult,
    /// Start a device login of a provider, and give its code at once. A login in progress of the provider ends as
    /// cancelled first. The server polls the provider, saves the login, and sends `auth/loginFinished`.
    "auth/login" => Login(crate::LoginParams) -> LoginResult,
    /// Ask a login in progress to stop. Its `auth/loginFinished` tells how it ended: a poll that got the approval
    /// still saves the login.
    "auth/cancelLogin" => CancelLogin(crate::CancelLoginParams) -> EmptyResult,
    /// Remove what yuke stored for a provider: its login or its API key in `auth.json`, and the token of
    /// `credential/update`. A login in progress of the provider ends first. yuke revokes no token at the provider.
    "auth/logout" => Logout(crate::LogoutParams) -> EmptyResult,
    /// Store an API key in `auth.json` for a provider with an API key variable. The new key replaces the stored key and
    /// wins over the variable. Each session takes the key at its next turn.
    "auth/setApiKey" => SetApiKey(crate::SetApiKeyParams) -> EmptyResult,
    /// List the providers and their models.
    "catalog/list" => ListCatalog(crate::ListCatalogParams) -> ListCatalogResult,
    /// List the running background jobs of an open session.
    "job/list" => ListJobs(SessionParams) -> ListJobsResult,
    /// Stop a running background job, and wait for its end. The `job` update with the end comes before the answer. A
    /// stopped job sends no report.
    "job/stop" => StopJob(StopJobParams) -> EmptyResult,
    /// Use `accessToken` for each model request of a provider with a login flow, from the next attempt on, also in a
    /// running turn. The server keeps it only in memory and never refreshes it. After the first update, the server never
    /// uses the stored login of the provider. An expired token fails each attempt until the next update.
    "credential/update" => UpdateCredential(UpdateCredentialParams) -> EmptyResult,
    /// Answer an open question of a session. The `interactionClosed` update of the question comes before the answer.
    "interaction/respond" => InteractionRespond(InteractionRespondParams) -> EmptyResult,
    /// List the MCP servers of an open session.
    "mcp/list" => ListMcpServers(SessionParams) -> ListMcpServersResult,
    /// Start the login of an MCP server of a session. The MCP server must be in the state `needsLogin`. The result
    /// holds the page where the user approves the login. A login in progress of the same MCP server ends as cancelled
    /// first. The browser then goes to a listener of yuke on 127.0.0.1. yuke stores the tokens and sends
    /// `mcp/loginFinished`. After a success, yuke connects the MCP server again, and the `mcpServer` updates show
    /// `connecting` and then `connected`. The close of the session ends its logins.
    "mcp/login" => McpLogin(crate::McpLoginParams) -> McpLoginResult,
    /// Finish a login of `mcp/login` with the address that the browser ended on, for a browser that cannot reach the
    /// listener. An address that is not the redirect of the login is an error, and the login goes on to wait.
    "mcp/completeLogin" => McpCompleteLogin(crate::McpCompleteLoginParams) -> EmptyResult,
    /// Ask a login of `mcp/login` to stop. Its `mcp/loginFinished` tells how it ended. A cancel ends only the wait for
    /// the redirect. After the redirect came, the login finishes: yuke stores the tokens, and the outcome is
    /// `succeeded`.
    "mcp/cancelLogin" => McpCancelLogin(crate::CancelLoginParams) -> EmptyResult,
    /// Remove the stored login of a remote MCP server of a session. A login in progress of the MCP server ends first.
    /// An MCP server that had a login stops, and it gets the state `needsLogin`. yuke revokes no token.
    "mcp/logout" => McpLogout(crate::McpLogoutParams) -> EmptyResult,
    /// List the plugins of `config.json` with their state on disk and whether they run. It uses no network.
    "plugin/list" => ListPlugins(EmptyParams) -> ListPluginsResult,
    /// Install the commit of `plugins.lock` of each Git plugin, and lock each new one at the commit of its ref. The lock
    /// keeps only the plugins of `config.json`. Git asks for no password: the credential helper and the ssh agent of
    /// the user serve. No plugin code runs.
    "plugin/sync" => SyncPlugins(EmptyParams) -> SyncPluginsResult,
    /// Resolve the ref of each Git plugin of the target again, and install each new commit. `plugins.lock` stays as it
    /// is until `plugin/apply`.
    "plugin/check" => CheckPlugins(crate::CheckPluginsParams) -> CheckPluginsResult,
    /// Write the new commits of changes of `plugin/check` into `plugins.lock`. It fails for a plugin that is not in the
    /// lock. The running plugins keep their commits until `profile/reload`.
    "plugin/apply" => ApplyPlugins(crate::ApplyPluginsParams) -> EmptyResult,
    /// List the plugins of a Git repository at the commit of a ref: each folder with a `plugin.json`. It fetches the
    /// commit, and changes no file of the profile.
    "plugin/find" => FindPlugins(crate::FindPluginsParams) -> FindPluginsResult,
    /// Add plugins of a Git repository to `config.json` by their names, install them, and lock them at the commit of the
    /// ref. The comments and the layout of `config.json` stay. It fails when `config.json` has one of them already.
    "plugin/add" => AddPlugins(crate::AddPluginsParams) -> AddPluginsResult,
    /// Remove a plugin of `config.json` by the name of its `plugin.json`, and its entry of `plugins.lock`. Its install
    /// stays on disk.
    "plugin/remove" => RemovePlugin(crate::RemovePluginParams) -> EmptyResult,
    /// Load the plugins of `config.json` and the providers of `providers.json` again. Each open session stays open, and
    /// its next turn takes the tools and hooks of the new plugins.
    /// - It fails while a turn runs. Then nothing changes.
    /// - It fails when the server cannot read or check a file. Then the old plugins and providers stay.
    /// - A plugin that does not load sends a notice, and the other plugins load.
    /// - The next request of an open session can miss the prompt cache when the reload changes the tools of that session.
    "profile/reload" => ReloadProfile(EmptyParams) -> EmptyResult,
    /// Save bytes in the store of a saved session, as for the image of an input. The same bytes give the same blob.
    /// The blob stays until `session/remove`.
    "blob/put" => PutBlob(PutBlobParams) -> Blob,
    /// The bytes of a blob of a saved session, which can be closed.
    "blob/get" => GetBlob(GetBlobParams) -> GetBlobResult,
);

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
    /// Ask the server to move each tool call of a session that waits for a job, such as a running command, to the background.
    /// The turn goes on.
    #[serde(rename = "session/background")]
    Background(SessionParams),
}

/// The method and the params of a server request. A client answers each one. It answers the error -32601
/// ([`ResponseError::METHOD_NOT_FOUND`]) for a method or an extension that it does not know.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "method", content = "params")]
pub enum ServerRequest {
    /// A request of a plugin. The plugin chooses `request` and `data`, and the client chooses the result or the error. An
    /// `extension/cancel` can end it.
    #[serde(rename = "extension/request")]
    ExtensionRequest(ExtensionRequestParams),
}

/// The method and the params of a server notification.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "method", content = "params")]
pub enum ServerNotification {
    /// A saved event or a live update of a session.
    #[serde(rename = "session/update")]
    SessionUpdate(Box<SessionUpdateParams>),
    /// A message for the user. It is not part of session history.
    #[serde(rename = "notice")]
    Notice(NoticeParams),
    /// An event of a plugin. It is not part of session history. A client ignores an extension that it does not know.
    #[serde(rename = "extension/event")]
    ExtensionEvent(ExtensionEventParams),
    /// The plugin of an `extension/request` stopped waiting for the answer. The client can stop its work. The answer is
    /// optional, and the server ignores it.
    #[serde(rename = "extension/cancel")]
    ExtensionCancel(ExtensionCancelParams),
    /// The end of a login of `auth/login`.
    #[serde(rename = "auth/loginFinished")]
    LoginFinished(crate::LoginFinishedParams),
    /// The end of a login of `mcp/login`.
    #[serde(rename = "mcp/loginFinished")]
    McpLoginFinished(crate::McpLoginFinishedParams),
}

/// The params of `notice`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
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
    pub text: String,
}

/// The severity of a notice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
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
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct ExtensionEventParams {
    /// The session of the event. The field is absent for an event of the whole process.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<SessionId>,
    /// The name that the host gives the plugin.
    pub extension: String,
    /// The name of the event. The plugin chooses it.
    pub event: String,
    /// The data of the event. The plugin chooses its shape, and it puts a version in it when the shape changes.
    #[cfg_attr(test, ts(type = "unknown"))]
    pub data: serde_json::Value,
}

/// The params of `extension/request`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ExtensionRequestParams {
    /// The session of the plugin.
    pub session_id: SessionId,
    /// The name that the host gives the plugin.
    pub extension: String,
    /// The name of the request. The plugin chooses it.
    pub request: String,
    /// The data of the request. The plugin chooses its shape.
    #[cfg_attr(test, ts(type = "unknown"))]
    pub data: serde_json::Value,
}

/// The params of `extension/cancel`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ExtensionCancelParams {
    /// The id of the `extension/request`.
    pub request_id: RequestId,
}

/// The answer to a request: its result or its error.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
pub struct Response {
    /// The version, `"2.0"`.
    #[cfg_attr(test, ts(type = "\"2.0\""))]
    pub jsonrpc: JsonRpc,
    /// The id of the request. It is null when the receiver cannot read the id, as after a parse error.
    pub id: Option<RequestId>,
    /// The result or the error.
    #[serde(flatten)]
    pub outcome: ResponseOutcome,
}

/// The `result` or the `error` member of a response. A result is the JSON of the result type of its method.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub enum ResponseOutcome {
    /// The request succeeded.
    Result(#[cfg_attr(test, ts(type = "unknown"))] serde_json::Value),
    /// The request failed.
    Error(ResponseError),
}

/// The error of a failed request.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
pub struct ResponseError {
    /// The kind of the error. A server error is one of the constants of this type.
    pub code: i32,
    /// A short text for a person.
    pub message: String,
    /// More facts about the error, when the sender has them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[cfg_attr(test, ts(type = "unknown"))]
    pub data: Option<serde_json::Value>,
}

/// Define the error codes as constants of [`ResponseError`], and list them for the TypeScript constants.
macro_rules! error_codes {
    ($($(#[doc = $doc:literal])* $name:ident = $code:expr,)*) => {
        impl ResponseError {
            $($(#[doc = $doc])* pub const $name: i32 = $code;)*
        }

        /// The name, the value, and the doc of each error code.
        #[cfg(test)]
        pub(crate) const ERROR_CODES: &[(&str, i32, &str)] = &[$((stringify!($name), $code, concat!($($doc),*)),)*];
    };
}

error_codes!(
    /// The server cannot read the message as JSON.
    PARSE_ERROR = -32_700,
    /// The JSON is no valid message object: no object, or a request without a valid `jsonrpc`, `id`, or `method`.
    INVALID_REQUEST = -32_600,
    /// The server has no such method.
    METHOD_NOT_FOUND = -32_601,
    /// The params do not fit the method.
    INVALID_PARAMS = -32_602,
    /// The server failed.
    INTERNAL_ERROR = -32_603,
    /// The server has no session with this id.
    SESSION_NOT_FOUND = -32_002,
    /// Another writer holds the session.
    SESSION_OWNED = -32_003,
    /// The session runs no background job with this id: the id is unknown, or the job has ended.
    JOB_NOT_FOUND = -32_004,
    /// The session has no open question with this id: the id is unknown, or the question has ended.
    INTERACTION_NOT_FOUND = -32_005,
    /// The server has no login in progress with this id: the id is unknown, or the login has ended.
    LOGIN_NOT_FOUND = -32_006,
    /// The session has no blob with this digest.
    BLOB_NOT_FOUND = -32_007,
    /// The session is open, so the server cannot remove it. Close it first.
    SESSION_OPEN = -32_008,
    /// A turn runs or input waits, so the request cannot run now. Send it again after the turn ends.
    TURN_ACTIVE = -32_009,
    /// Another call opens or closes the session, or a reload runs. Send the request again after it ends.
    TRY_AGAIN = -32_010,
    /// The server shuts down, so it opens no session.
    STOPPING = -32_011,
    /// The connection sent no `initialize` yet.
    NOT_INITIALIZED = -32_012,
);

/// The name, an optional title, and the version of a client or a server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
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
    /// The protocol version of the server. The server speaks one version, so it answers that one for any client.
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
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct ForkSessionParams {
    /// The source session.
    pub session_id: SessionId,
    /// The event number of the end of a completed turn. Without it, the fork takes the newest completed turn, or the
    /// settings before the first commit when no turn completed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub through: Option<EventNumber>,
}

/// The params of `session/new`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct NewSessionParams {
    /// The settings of the session.
    #[serde(flatten)]
    pub settings: SessionSettings,
    /// The parent session. A session with a parent stays out of the default list.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<SessionId>,
}

/// The params of `session/load`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct LoadSessionParams {
    /// The session.
    pub session_id: SessionId,
    /// The last event that the client has. Without it, the load sends every event.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<EventNumber>,
}

/// The params of `session/list`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct ListSessionsParams {
    /// Only the sessions whose newest settings name this folder. Without it, the list has the sessions of every folder.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<PathBuf>,
    /// Only the children of this session. Without it, the list has the sessions without a parent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<SessionId>,
    /// The most rows of the page, from 1 to 100. The default is 50.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    /// The `nextCursor` of the page before, with the same `folder` and `parent`. Without it, the page starts at the newest
    /// session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
}

/// The result of `session/list`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct ListSessionsResult {
    /// The sessions of the page, newest first by their newest event. The pages are no snapshot: a session that a new
    /// event moves to the front between two pages comes only in a new list.
    pub sessions: Vec<SessionRow>,
    /// The cursor of the next page. It is absent when no older session exists.
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

/// The params of a message that names only an open session: `session/close`, `job/list`, `mcp/list`,
/// `session/cancel`, and `session/background`.
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
    /// The id of the job.
    pub id: crate::JobId,
    /// A short text for display.
    pub label: String,
    /// Whether the job runs, and how it ended.
    pub state: JobState,
    /// What runs.
    #[serde(flatten)]
    pub kind: JobKind,
}

/// Whether a job runs, and how it ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub enum JobState {
    /// The job runs.
    Running,
    /// The job ended by itself.
    Ended,
    /// A stop ended the job: `job/stop`, a close, or the end of the server.
    Stopped,
}

/// What a job runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum JobKind {
    /// A shell command.
    Process {
        /// The exact command.
        command: String,
        /// The file that holds the output.
        log: PathBuf,
        /// The exit code, when the process exited. An ended process without one did not exit by itself.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        exit_code: Option<i32>,
    },
    /// The work of a plugin.
    Plugin {
        /// The name of the plugin.
        plugin: String,
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
    pub job_id: crate::JobId,
}

/// The params of `credential/update`.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
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
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct InputParams {
    /// The session.
    pub session_id: SessionId,
    /// The blocks that the user sees. The server saves the input with the user as its source.
    pub content: Vec<yuke_ai::Block>,
    /// The blocks that the model reads in place of the content.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_content: Option<Vec<yuke_ai::Block>>,
}

/// The result of `session/input`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct InputResult {
    /// The id of the pending input.
    pub input_id: InputId,
}

/// The params of `session/setSettings`.
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

/// The params of `session/rename`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct RenameSessionParams {
    /// The saved session.
    pub session_id: SessionId,
    /// The new title, with normalized whitespace and 1 to 200 Unicode scalar values.
    pub title: SessionTitle,
}

/// The params of `session/removeInput`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct RemoveInputParams {
    /// The session.
    pub session_id: SessionId,
    /// The pending input to remove.
    pub input_id: InputId,
}

/// The result of `session/removeInput`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct RemoveInputResult {
    /// `false` when the input is not pending: a commit consumed it, or a removal came first.
    pub removed: bool,
}

/// The params of `blob/put`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct PutBlobParams {
    /// The saved session that keeps the bytes. Only this session reads the blob.
    pub session_id: SessionId,
    /// The bytes. JSON holds them as standard base64.
    #[serde(with = "media_bytes")]
    #[cfg_attr(test, ts(type = "string"))]
    pub data: Vec<u8>,
}

/// The params of `blob/get`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct GetBlobParams {
    /// The saved session of the blob.
    pub session_id: SessionId,
    /// The blob of a media block. The server reads it by its digest.
    pub blob: Blob,
}

/// The result of `blob/get`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct GetBlobResult {
    /// The bytes. JSON holds them as standard base64.
    #[serde(with = "media_bytes")]
    #[cfg_attr(test, ts(type = "string"))]
    pub data: Vec<u8>,
}

/// Write the bytes of a blob to JSON as standard padded base64, and read them back.
mod media_bytes {
    use base64::Engine;
    use base64::engine::general_purpose::{STANDARD, STANDARD_PAD_INDIFFERENT};
    use serde::de::Error;
    use serde::{Deserialize, Deserializer, Serializer};

    pub(super) fn serialize<S: Serializer>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&STANDARD.encode(bytes))
    }

    pub(super) fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        // An owned text, because a JSON text with an escape, or a buffered message, has no borrowed form.
        let text = String::deserialize(deserializer)?;
        STANDARD_PAD_INDIFFERENT
            .decode(text)
            .map_err(|_| D::Error::custom("the data is not standard base64"))
    }
}

/// The params of a request with no data: an empty object.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(type = "Record<string, never>"))]
#[expect(
    clippy::empty_structs_with_brackets,
    reason = "serde reads a struct with braces from `{}`, and a unit struct from `null`"
)]
pub struct EmptyParams {}

/// The result of a request with no data: an empty object.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(type = "Record<string, never>"))]
#[expect(
    clippy::empty_structs_with_brackets,
    reason = "serde writes a struct with braces as `{}`, and a unit struct as `null`"
)]
pub struct EmptyResult {}
