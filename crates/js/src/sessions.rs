//! The sessions and the model catalog of the consumer, for `ctx.get("sessions")` and `ctx.get("catalog")` of the
//! plugins. The methods mirror the session requests of the protocol.

use std::error::Error;
use std::sync::Arc;

use async_trait::async_trait;
use yuke_protocol::{
    EventNumber, Input, InputId, InteractionId, InteractionResponse, Job, ListCatalogResult, ListSessionsParams,
    ListSessionsResult, McpServer, SessionId, SessionRow, SessionSettings, SessionSnapshot, SessionUpdate, StoredEvent,
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
pub type ViewSink = Arc<dyn Fn(ViewEvent) + Send + Sync>;

/// The sessions and the catalog that the plugins use. The consumer gives one value to each runtime. Each async call runs
/// on the tokio runtime of the consumer. A sync call runs on the JavaScript thread, so it must not block.
#[async_trait]
pub trait Sessions: Send + Sync {
    /// Create a session with `settings`, and open it.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn create(&self, settings: SessionSettings) -> Result<SessionId, SessionsError>;

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

    /// Delete the saved session `id`, which is not open.
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
    async fn open(&self, id: SessionId, tail: usize, sink: ViewSink) -> Result<Box<dyn Send>, SessionsError>;

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

    /// Remove the pending input `input_id` of the open session `id`.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn remove_input(&self, id: SessionId, input_id: InputId) -> Result<(), SessionsError>;

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
    async fn stop_job(&self, id: SessionId, job_id: String) -> Result<(), SessionsError>;

    /// The MCP servers of the open session `id`.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    fn mcp_servers(&self, id: SessionId) -> Result<Vec<McpServer>, SessionsError>;

    /// Close session `id` at once. With `stop_jobs`, its running jobs stop. Without it, a running job makes the close fail.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn close(&self, id: SessionId, stop_jobs: bool) -> Result<(), SessionsError>;

    /// The providers of the catalog with their models: every provider with `all`, else only the ready ones.
    ///
    /// # Errors
    ///
    /// Returns why the request failed.
    async fn catalog(&self, all: bool) -> Result<ListCatalogResult, SessionsError>;
}
