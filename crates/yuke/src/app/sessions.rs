//! The open sessions: the registry that admits each open and close, and the calls on one open session. Each method
//! takes `&self`, so several callers share the service.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};

use yuke_agent::{ListPosition, Session};
use yuke_ai::Block;
use yuke_engine::chain_text;
use yuke_js::Handle;
use yuke_protocol::{
    EventNumber, Input, InputId, InputKind, InputSource, InteractionId, InteractionResponse, Job, ListSessionsParams,
    ListSessionsResult, NoticeLevel, NoticeParams, ServerNotification, SessionActivity, SessionId, SessionRow,
    SessionSettings, SessionState, SessionSummary,
};

use super::live::LiveSession;
use super::{AppError, SOURCE, Shared, canonical, lock, model_of, save_settings, system_prompt};
use crate::providers::Providers;

/// The open sessions of the app and the calls on them.
///
/// # Cancel safety
///
/// The methods are not cancel safe. A caller awaits each call to its end. A dropped close can leave the jobs of a
/// session running, and a dropped settings change leaves the session stale until its next turn opens it again.
pub(crate) struct SessionService {
    shared: Arc<Shared>,
    /// Opens the plugins of a session in the runtime now. A reload replaces it.
    runtime: Mutex<Handle>,
    registry: Mutex<Registry>,
}

/// The slot of each session that is open, or that a call opens or closes now.
#[derive(Default)]
struct Registry {
    phase: Phase,
    slots: HashMap<SessionId, Slot>,
}

/// What the registry admits now.
#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum Phase {
    /// Each call can open and close sessions.
    #[default]
    Ready,
    /// A reload runs, so no session opens or closes.
    Reloading,
    /// The shutdown started, so no session opens.
    Stopped,
}

enum Slot {
    Opening,
    Open(Arc<LiveSession>),
    Closing,
}

/// The `Opening` or `Closing` slot of one call. Its drop removes the slot, unless [`Transition::open`] made it `Open`,
/// so a failed or dropped call leaves no slot.
struct Transition<'a> {
    service: &'a SessionService,
    id: SessionId,
}

impl Transition<'_> {
    /// Make the slot `Open` with `live`.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Stopped`] after the shutdown started.
    fn open(self, live: Arc<LiveSession>) -> Result<(), AppError> {
        let mut registry = lock(&self.service.registry);
        if registry.phase == Phase::Stopped {
            return Err(AppError::Stopped);
        }
        registry.slots.insert(self.id, Slot::Open(live));
        Ok(())
    }
}

impl Drop for Transition<'_> {
    fn drop(&mut self) {
        let mut registry = lock(&self.service.registry);
        if matches!(registry.slots.get(&self.id), Some(Slot::Opening | Slot::Closing)) {
            registry.slots.remove(&self.id);
        }
    }
}

/// A reload in progress: no session opens or closes until its drop.
pub(super) struct Reload<'a> {
    service: &'a SessionService,
    /// Each open session at the start of the reload.
    pub(super) sessions: Vec<Arc<LiveSession>>,
}

impl Drop for Reload<'_> {
    fn drop(&mut self) {
        let mut registry = lock(&self.service.registry);
        if registry.phase == Phase::Reloading {
            registry.phase = Phase::Ready;
        }
    }
}

impl SessionService {
    /// The service of `shared`, which opens the plugins of each session with `runtime`.
    pub(super) fn new(shared: Arc<Shared>, runtime: Handle) -> Self {
        SessionService {
            shared,
            runtime: Mutex::new(runtime),
            registry: Mutex::default(),
        }
    }

    /// Refuse each open and close until the drop of the result, and give each open session.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Changing`] while a call opens or closes a session, [`AppError::Reloading`], and
    /// [`AppError::Stopped`].
    pub(super) fn start_reload(&self) -> Result<Reload<'_>, AppError> {
        let mut registry = lock(&self.registry);
        admit(registry.phase)?;
        let mut sessions = Vec::with_capacity(registry.slots.len());
        for (id, slot) in &registry.slots {
            match slot {
                Slot::Open(live) => sessions.push(Arc::clone(live)),
                Slot::Opening | Slot::Closing => return Err(AppError::Changing(*id)),
            }
        }
        registry.phase = Phase::Reloading;
        Ok(Reload {
            service: self,
            sessions,
        })
    }

    /// Open the plugins of each later session with `runtime`.
    pub(super) fn set_runtime(&self, runtime: Handle) {
        *lock(&self.runtime) = runtime;
    }

    /// Refuse each later open, and close each open session. The sessions stop together before the first wait. A call
    /// that opens or closes a session now ends alone.
    pub(super) async fn close_all(&self) {
        let open: Vec<Arc<LiveSession>> = {
            let mut registry = lock(&self.registry);
            registry.phase = Phase::Stopped;
            std::mem::take(&mut registry.slots)
                .into_values()
                .filter_map(|slot| match slot {
                    Slot::Open(live) => Some(live),
                    Slot::Opening | Slot::Closing => None,
                })
                .collect()
        };
        for live in &open {
            live.stop();
        }
        for live in open {
            live.close().await;
        }
    }

    /// Check that the model of `settings` can run: the catalog knows it, and its credential source exists. An API key
    /// must be set. A login is read at each attempt.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for an unknown model, a missing API key, or a provider with no login flow.
    fn check_model(&self, settings: &SessionSettings) -> Result<(), AppError> {
        model_of(&settings.model, &self.shared).map(drop)
    }

    /// Create a session with `settings`, and open it. The folder loses its links, and the app builds the system prompt
    /// of that folder. A missing API key stops the create before the session exists.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for a folder that does not exist or a model that cannot run, [`AppError::Store`]
    /// when the store fails, [`AppError::Internal`] when the plugins do not open, [`AppError::Reloading`], and
    /// [`AppError::Stopped`].
    pub(crate) async fn create(&self, mut settings: SessionSettings) -> Result<SessionId, AppError> {
        // A refusal before the work saves no session in the common case. The reserve checks again.
        admit(lock(&self.registry).phase)?;
        settings.cwd = canonical(settings.cwd).await?;
        let prompt = system_prompt(
            settings.cwd.clone(),
            self.shared.machine.home.clone(),
            self.shared.plugin_folders().to_vec(),
        )
        .await?;
        self.check_model(&settings)?;
        let session = Session::create(Arc::clone(&self.shared.store), &settings, &prompt.sections).await?;
        let id = self.start_new(session).await?;
        for warning in prompt.warnings {
            self.shared.observer.notify(ServerNotification::Notice(NoticeParams {
                session_id: Some(id),
                level: NoticeLevel::Warn,
                source: SOURCE.to_owned(),
                message: warning,
            }));
        }
        Ok(id)
    }

    /// Fork session `id` through event `through`, and open the fork.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Store`] when the store fails, [`AppError::Invalid`] for a model that cannot run,
    /// [`AppError::Internal`] when the plugins do not open, [`AppError::Reloading`], and [`AppError::Stopped`].
    pub(crate) async fn fork(&self, id: SessionId, through: Option<EventNumber>) -> Result<SessionId, AppError> {
        admit(lock(&self.registry).phase)?;
        let session = Session::fork(Arc::clone(&self.shared.store), id, through).await?;
        self.start_new(session).await
    }

    /// A page of the saved sessions, newest first, with the activity of each one. `params.cursor` continues the list
    /// with the same `params.cwd`.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for a limit outside 1 to 100 or an invalid cursor, and [`AppError::Store`] when
    /// the store fails.
    pub(crate) async fn list(&self, params: ListSessionsParams) -> Result<ListSessionsResult, AppError> {
        let ListSessionsParams { cwd, limit, cursor } = params;
        let limit = limit.unwrap_or(PAGE_ROWS);
        if !(1..=MOST_PAGE_ROWS).contains(&limit) {
            return Err(AppError::Invalid(format!(
                "the limit {limit} must be between 1 and {MOST_PAGE_ROWS}"
            )));
        }
        let after = cursor
            .as_deref()
            .map(|cursor| position_of(cursor, cwd.as_deref()))
            .transpose()?;
        let page = self
            .shared
            .store
            .list_sessions(cwd.as_deref(), after, limit as usize)
            .await?;
        Ok(ListSessionsResult {
            sessions: page.sessions.into_iter().map(|session| self.row(session)).collect(),
            next_cursor: page.next.map(|next| cursor_of(next, cwd.as_deref())),
        })
    }

    /// The row of the saved session `id`, which can be closed.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Store`] for an unknown session or when the store fails.
    pub(crate) async fn get(&self, id: SessionId) -> Result<SessionRow, AppError> {
        let session = self.shared.store.session_summary(id).await?;
        Ok(self.row(session))
    }

    /// Delete the saved session `id` with its events, its pending inputs, and its blobs. Its forks stay.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Open`] for an open session, and [`AppError::Store`] for an unknown session, a session that
    /// another process holds, or a failed delete.
    pub(crate) async fn remove(&self, id: SessionId) -> Result<(), AppError> {
        if lock(&self.registry).slots.contains_key(&id) {
            return Err(AppError::Open(id));
        }
        Ok(self.shared.store.delete_session(id).await?)
    }

    /// The row of `session` with its activity in this app now.
    fn row(&self, session: SessionSummary) -> SessionRow {
        let activity = match self.live(session.session_id).map(|live| live.state()) {
            Err(_) => SessionActivity::Closed,
            Ok(SessionState::Idle) => SessionActivity::Idle,
            Ok(SessionState::Running) => SessionActivity::Running,
        };
        SessionRow { session, activity }
    }

    /// Open session `id`, which is not open. `change` gets the saved settings and the providers, and it can return new
    /// settings. The app saves them before the session starts, so a waiting input runs with them. An open runs no turn
    /// and sends no update. [`SessionService::load`] sends the saved events.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Store`] when the store fails. Returns [`AppError::Invalid`] for an open session or a model
    /// that cannot run, and [`AppError::Changing`] while another call opens or closes it. Returns
    /// [`AppError::Internal`] when the plugins do not open, [`AppError::Reloading`], and [`AppError::Stopped`]. Returns
    /// the error of `change` as it is.
    pub(crate) async fn open(
        &self,
        id: SessionId,
        change: impl FnOnce(&SessionSettings, &Providers) -> Result<Option<SessionSettings>, AppError>,
    ) -> Result<(), AppError> {
        self.open_live(id, change).await.map(drop)
    }

    /// [`SessionService::open`], which gives the open session.
    async fn open_live(
        &self,
        id: SessionId,
        change: impl FnOnce(&SessionSettings, &Providers) -> Result<Option<SessionSettings>, AppError>,
    ) -> Result<Arc<LiveSession>, AppError> {
        let transition = self.reserve(id)?;
        let mut session = Session::open(Arc::clone(&self.shared.store), id).await?;
        match change(session.settings(), &self.shared.providers())? {
            Some(settings) => drop(save_settings(&mut session, settings, &self.shared).await?),
            None => self.check_model(session.settings())?,
        }
        self.start_session(transition, session).await
    }

    /// Open session `id` when it is not open, and send it as updates: its saved events after `after`, its state, its
    /// pending inputs, and its running jobs. The live updates of the session that come during the load follow them.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Store`] when the store fails, [`AppError::Invalid`] for a model that cannot run, and
    /// [`AppError::Changing`] while another call opens or closes the session. An open also returns the errors of
    /// [`SessionService::open`].
    pub(crate) async fn load(&self, id: SessionId, after: Option<EventNumber>) -> Result<(), AppError> {
        let live = match self.live(id) {
            Ok(live) => live,
            Err(_) => self.open_live(id, |_, _| Ok(None)).await?,
        };
        live.load(after).await
    }

    /// Close session `id`: its turn stops, and its task ends. Waiting input stays saved. A session with running jobs
    /// closes only with `stop_jobs`, which stops them.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`], [`AppError::JobsRun`] for running jobs without `stop_jobs`,
    /// [`AppError::Changing`] while another call opens or closes the session, and [`AppError::Reloading`].
    pub(crate) async fn close(&self, id: SessionId, stop_jobs: bool) -> Result<(), AppError> {
        let live = {
            let mut registry = lock(&self.registry);
            admit(registry.phase)?;
            let live = match registry.slots.get(&id) {
                Some(Slot::Open(live)) => Arc::clone(live),
                Some(Slot::Opening | Slot::Closing) => return Err(AppError::Changing(id)),
                None => return Err(AppError::NotOpen(id)),
            };
            if !stop_jobs {
                let jobs = live.jobs();
                if !jobs.is_empty() {
                    return Err(AppError::JobsRun(jobs.into_iter().map(|job| job.id).collect()));
                }
            }
            registry.slots.insert(id, Slot::Closing);
            live
        };
        let _transition = Transition { service: self, id };
        live.close().await;
        Ok(())
    }

    /// Cancel the running turn of session `id`. A session that is not open or runs no turn has nothing to cancel.
    pub(crate) fn cancel(&self, id: SessionId) {
        if let Ok(live) = self.live(id) {
            live.cancel();
        }
    }

    /// Save `content` as an input of the user, and start a turn when the session is idle.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`], [`AppError::Invalid`] for content that is no input, and [`AppError::Store`] when
    /// the store fails.
    pub(crate) async fn input(&self, id: SessionId, content: Vec<Block>) -> Result<InputId, AppError> {
        let live = self.live(id)?;
        let input = Input::new(InputSource::User, InputKind::Message, content)
            .map_err(|error| AppError::Invalid(chain_text(&error)))?;
        Ok(live.accept(input).await?)
    }

    /// Remove the pending input `input_id` of session `id`.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`], and [`AppError::Store`] when the input is not pending or the store fails.
    pub(crate) async fn remove_input(&self, id: SessionId, input_id: InputId) -> Result<(), AppError> {
        Ok(self.live(id)?.remove_input(input_id).await?)
    }

    /// Save `settings` for session `id`. The session keeps its system prompt.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`], [`AppError::Busy`] while a turn runs or input waits, [`AppError::Invalid`] for a
    /// folder or a model that cannot work, and [`AppError::Store`] when the store fails.
    pub(crate) async fn set_settings(&self, id: SessionId, settings: SessionSettings) -> Result<(), AppError> {
        self.live(id)?.set_settings(settings).await
    }

    /// The running background jobs of session `id`, oldest first.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`].
    pub(crate) fn jobs(&self, id: SessionId) -> Result<Vec<Job>, AppError> {
        Ok(self.live(id)?.jobs())
    }

    /// Stop the job `job_id` of session `id`, and wait for its end. The `job` update with the end comes first.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`], and [`AppError::NoJob`] when the session runs no such job.
    pub(crate) async fn stop_job(&self, id: SessionId, job_id: &str) -> Result<(), AppError> {
        if self.live(id)?.stop_job(job_id).await {
            Ok(())
        } else {
            Err(AppError::NoJob(job_id.to_owned()))
        }
    }

    /// The MCP servers of session `id` and their states, in config order.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`].
    pub(crate) fn mcp_servers(&self, id: SessionId) -> Result<Vec<yuke_protocol::McpServer>, AppError> {
        Ok(self.live(id)?.mcp_servers())
    }

    /// Give `response` to the open question `interaction_id` of session `id`.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`], [`AppError::NoInteraction`] when the session has no such open question, and
    /// [`AppError::Invalid`] when the answer does not fit the question.
    pub(crate) fn respond(
        &self,
        id: SessionId,
        interaction_id: InteractionId,
        response: InteractionResponse,
    ) -> Result<(), AppError> {
        self.live(id)?.answer(interaction_id, response)
    }

    /// Open `session`, which this app saved just now. A session that cannot start is deleted again, so no session that
    /// cannot run stays in the store.
    async fn start_new(&self, session: Session) -> Result<SessionId, AppError> {
        let id = session.id();
        // The drop frees the lease of the session, and the delete refuses a session with a lease.
        let started = match self.check_model(session.settings()).and_then(|()| self.reserve(id)) {
            Ok(transition) => self.start_session(transition, session).await,
            Err(error) => {
                drop(session);
                Err(error)
            }
        };
        if started.is_err() {
            self.shared.store.delete_session(id).await?;
        }
        started.map(|_| id)
    }

    /// Mark session `id` as `Opening`.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for an open session, [`AppError::Changing`] while another call opens or closes it,
    /// [`AppError::Reloading`], and [`AppError::Stopped`].
    fn reserve(&self, id: SessionId) -> Result<Transition<'_>, AppError> {
        let mut registry = lock(&self.registry);
        admit(registry.phase)?;
        match registry.slots.get(&id) {
            Some(Slot::Open(_)) => Err(AppError::Invalid(format!("the session {id} is open already"))),
            Some(Slot::Opening | Slot::Closing) => Err(AppError::Changing(id)),
            None => {
                registry.slots.insert(id, Slot::Opening);
                Ok(Transition { service: self, id })
            }
        }
    }

    /// Start the task of `session`, and make its slot `Open`.
    async fn start_session(&self, transition: Transition<'_>, session: Session) -> Result<Arc<LiveSession>, AppError> {
        let runtime = lock(&self.runtime).clone();
        let live = Arc::new(LiveSession::start(session, &runtime, Arc::clone(&self.shared)).await?);
        if let Err(error) = transition.open(Arc::clone(&live)) {
            // The shutdown started during the open and closes no session that it did not see.
            live.close().await;
            return Err(error);
        }
        Ok(live)
    }

    /// The open session `id`.
    pub(super) fn live(&self, id: SessionId) -> Result<Arc<LiveSession>, AppError> {
        match lock(&self.registry).slots.get(&id) {
            Some(Slot::Open(live)) => Ok(Arc::clone(live)),
            Some(Slot::Opening | Slot::Closing) | None => Err(AppError::NotOpen(id)),
        }
    }
}

/// Refuse an open or a close in `phase`.
fn admit(phase: Phase) -> Result<(), AppError> {
    match phase {
        Phase::Ready => Ok(()),
        Phase::Reloading => Err(AppError::Reloading),
        Phase::Stopped => Err(AppError::Stopped),
    }
}

/// The rows of a `session/list` page without a limit, and the most rows of one page.
const PAGE_ROWS: u32 = 50;
const MOST_PAGE_ROWS: u32 = 100;

/// The cursor of the page after `next` in the list of `cwd`. It holds the folder, so a cursor of another list does not
/// read.
fn cursor_of(next: ListPosition, cwd: Option<&Path>) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut cursor = format!("{}.", next.0);
    for byte in cwd.map_or(&[][..], |cwd| cwd.as_os_str().as_encoded_bytes()) {
        cursor.push(char::from(HEX[usize::from(byte >> 4)]));
        cursor.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    cursor
}

/// The position that `cursor`, a cursor of the list of `cwd`, names.
fn position_of(cursor: &str, cwd: Option<&Path>) -> Result<ListPosition, AppError> {
    let invalid = || AppError::Invalid(format!("the cursor '{cursor}' is invalid for this list"));
    let (position, _) = cursor.split_once('.').ok_or_else(invalid)?;
    // A store gives no position above `i64::MAX`, the largest SQLite integer.
    let position: i64 = position.parse().map_err(|_| invalid())?;
    let position = ListPosition(position.unsigned_abs());
    // A cursor of this list encodes to the same text again.
    if cursor_of(position, cwd) == cursor {
        Ok(position)
    } else {
        Err(invalid())
    }
}

#[cfg(test)]
mod tests;
