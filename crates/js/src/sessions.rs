//! The sessions, the model catalog, and the plugin manager of the consumer, for `ctx.get("sessions")`,
//! `ctx.get("catalog")`, and `ctx.get("plugins")` of the plugins. The methods mirror the requests of the protocol.

use std::any::Any;
use std::error::Error;
use std::sync::Arc;

use async_trait::async_trait;
use serde::Serialize;
use yuke_protocol::{
    ApplyPluginsParams, ApplyPluginsResult, CheckPluginsParams, CheckPluginsResult, EventNumber, Input, InputId,
    InteractionId, InteractionResponse, Job, ListCatalogResult, ListPluginsResult, ListSessionsParams,
    ListSessionsResult, McpServer, NoticeParams, SessionId, SessionRow, SessionSettings, SessionSnapshot, SessionState,
    SessionUpdate, StoredEvent, SyncPluginsParams, SyncPluginsResult,
};

/// The failure of a request. The plugin gets its text.
pub type SessionsError = Box<dyn Error + Send + Sync>;

/// What a view of a session receives: first its snapshot, then each later update that the snapshot does not hold, and at
/// the close of the session its end.
#[derive(Debug, Clone, PartialEq)]
pub enum ViewEvent {
    /// The session when the view starts.
    Snapshot(SessionSnapshot),
    /// A later update.
    Update(SessionUpdate),
    /// The session closed. No event follows, also when the session opens again.
    Closed,
}

/// Takes the events of one view. The consumer calls it under the output lock of the session. A call must not block, call
/// back into the session, or drop its view.
pub type ViewSink = Arc<dyn Fn(ViewEvent)>;

/// A fact of the consumer for `ctx.on` of the plugins. It reports what happened, and no answer changes it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "event", content = "data")]
pub enum Fact {
    /// An update of the open session `session_id`. The update is the same as the update that a view gets.
    #[serde(rename = "session.update", rename_all = "camelCase")]
    Update {
        /// The session of the update.
        session_id: SessionId,
        /// The update.
        update: Box<SessionUpdate>,
    },
    /// The session `session_id` is open, with its state and its open questions now.
    #[serde(rename = "session.opened", rename_all = "camelCase")]
    Opened {
        /// The session that is open.
        session_id: SessionId,
        /// Whether a turn runs now.
        state: SessionState,
        /// The open questions now, oldest first.
        questions: Vec<InteractionId>,
    },
    /// The session `session_id` closed. A later open of it starts with a new [`Fact::Opened`].
    #[serde(rename = "session.closed", rename_all = "camelCase")]
    Closed {
        /// The session that closed.
        session_id: SessionId,
    },
    /// A notice of the consumer or of a plugin.
    #[serde(rename = "notice")]
    Notice(NoticeParams),
}

/// Takes the facts of one watch. The consumer calls it under the output lock of a session. A call must not block, call
/// back into the consumer, or drop its watch.
pub type FactSink = Arc<dyn Fn(Fact)>;

/// The sessions and the catalog that the plugins use. The consumer gives one value to each runtime. Each async call runs
/// as a local task of the host runtime. A sync call runs on the engine task, so it must not block.
#[async_trait(?Send)]
pub trait Sessions {
    /// Create a session with `settings`, and open it.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn create(&self, settings: SessionSettings, parent: Option<SessionId>) -> Result<SessionId, SessionsError>;

    /// Fork session `id` through event `through`, and open the fork.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn fork(&self, id: SessionId, through: Option<EventNumber>) -> Result<SessionId, SessionsError>;

    /// A page of the saved sessions, newest first.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn list(&self, params: ListSessionsParams) -> Result<ListSessionsResult, SessionsError>;

    /// The row of the saved session `id`.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn get(&self, id: SessionId) -> Result<SessionRow, SessionsError>;

    /// Delete the saved session `id` and its descendants, which are not open.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn remove(&self, id: SessionId) -> Result<(), SessionsError>;

    /// Open session `id` when it is not open, hold it, and watch it: `sink` receives its snapshot with its last `tail`
    /// saved events, then its later updates. The drop of the result ends the hold and the view.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn open(&self, id: SessionId, tail: usize, sink: ViewSink) -> Result<Box<dyn Any>, SessionsError>;

    /// Watch the facts: `sink` first gets [`Fact::Opened`] for each open session, then each later fact. The watch holds
    /// no session. The drop of the result ends the watch.
    fn watch_facts(&self, sink: FactSink) -> Box<dyn Any>;

    /// At most `limit` saved events of session `id` with a number below `before`, or its last `limit` events.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn events_before(
        &self,
        id: SessionId,
        before: Option<EventNumber>,
        limit: usize,
    ) -> Result<Vec<StoredEvent>, SessionsError>;

    /// Save `input` for the open session `id`. A turn starts when the session is idle.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn input(&self, id: SessionId, input: Input) -> Result<InputId, SessionsError>;

    /// Cancel the running turn of session `id`.
    fn cancel(&self, id: SessionId);

    /// Move each job that a call of session `id` waits for out of its call.
    fn background(&self, id: SessionId);

    /// Whether [`Sessions::background`] moves a job of session `id` now.
    fn has_movable(&self, id: SessionId) -> bool;

    /// Wait until the open session `id` runs no turn and has handled each input that it accepted before the call, or until
    /// its close. A failed turn counts as handled, and its input waits for the next wake.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn idle(&self, id: SessionId) -> Result<(), SessionsError>;

    /// Save `settings` for the open session `id`.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn set_settings(&self, id: SessionId, settings: SessionSettings) -> Result<(), SessionsError>;

    /// Save `bytes` in the store of the open session `id`, and return the blob that names them.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn put_blob(&self, id: SessionId, bytes: Vec<u8>) -> Result<yuke_ai::Blob, SessionsError>;

    /// Remove the pending input `input_id` of the open session `id`. Return `false` when the input is not pending.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn remove_input(&self, id: SessionId, input_id: InputId) -> Result<bool, SessionsError>;

    /// Give `response` to the open question `interaction_id` of session `id`.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    fn respond(
        &self,
        id: SessionId,
        interaction_id: InteractionId,
        response: InteractionResponse,
    ) -> Result<(), SessionsError>;

    /// The running jobs of the open session `id`.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    fn jobs(&self, id: SessionId) -> Result<Vec<Job>, SessionsError>;

    /// Stop the job `job_id` of the open session `id`, and wait for its end.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn stop_job(&self, id: SessionId, job_id: &str) -> Result<(), SessionsError>;

    /// The MCP servers of the open session `id`.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    fn mcp_servers(&self, id: SessionId) -> Result<Vec<McpServer>, SessionsError>;

    /// Close session `id` at once. Its running jobs stop.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn close(&self, id: SessionId) -> Result<(), SessionsError>;

    /// The providers of the catalog with their models: every provider with `all`, else only the ready ones.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn catalog(&self, all: bool) -> Result<ListCatalogResult, SessionsError>;

    /// The plugins of `config.json` with their state, as `plugin/list` gives them.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn list_plugins(&self) -> Result<ListPluginsResult, SessionsError>;

    /// Install the locked commits and lock the new Git plugins, as `plugin/sync` does.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn sync_plugins(&self, params: SyncPluginsParams) -> Result<SyncPluginsResult, SessionsError>;

    /// The new commits of the Git plugins of the target, as `plugin/check` gives them.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn check_plugins(&self, params: CheckPluginsParams) -> Result<CheckPluginsResult, SessionsError>;

    /// Write the new commits of changes into `plugins.lock`, as `plugin/apply` does.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn apply_plugins(&self, params: ApplyPluginsParams) -> Result<ApplyPluginsResult, SessionsError>;

    /// Add a Git plugin to `config.json`, and install and lock it, as `plugin/add` does.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn add_plugin(
        &self,
        params: yuke_protocol::AddPluginParams,
    ) -> Result<yuke_protocol::AddPluginResult, SessionsError>;

    /// Remove a plugin from `config.json` and `plugins.lock`, as `plugin/remove` does.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn remove_plugin(&self, params: yuke_protocol::RemovePluginParams) -> Result<(), SessionsError>;
}
