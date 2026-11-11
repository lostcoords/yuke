//! The open sessions: the registry that admits each open and close, and the calls on one open session. Each method
//! takes `&self`, so several callers share the service.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;
use std::rc::{Rc, Weak};
use std::sync::Arc;
use std::time::Duration;

use yuke_agent::{EventPage, ListPosition, Session};
use yuke_engine::chain_text;
use yuke_js::{FactSink, Handle, ViewSink};
use yuke_protocol::{
    EventNumber, Input, InputId, InteractionId, InteractionResponse, Job, ListSessionsParams, ListSessionsResult,
    NoticeLevel, NoticeParams, ServerNotification, SessionActivity, SessionId, SessionRow, SessionSettings,
    SessionState, SessionSummary, SessionTitle, StoredEvent,
};

use super::facts::Watch;
use super::live::{LiveSession, View};
use super::{AppError, SOURCE, Shared, canonical, model_of, save_settings, system_prompt};
use crate::providers::Providers;

/// The open sessions of the app and the calls on them.
///
/// # Cancel safety
///
/// The methods are not cancel safe. A caller awaits each call to its end. A dropped close can leave the jobs of a
/// session running, and a dropped settings change leaves the session stale until its next turn opens it again.
pub(crate) struct SessionService {
    /// The service itself, for the countdown tasks and the attachments.
    this: Weak<SessionService>,
    shared: Rc<Shared>,
    /// Opens the plugins of a session in the runtime now, or `None` before the first runtime starts. A reload replaces
    /// it.
    runtime: RefCell<Option<Handle>>,
    registry: RefCell<Registry>,
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
    Open(Open),
    Closing,
}

/// An open session and what keeps it open.
struct Open {
    live: Rc<LiveSession>,
    /// The holders of the session. The session counts down to its close only without a holder.
    attachments: usize,
    /// The idle deadline. An attachment or a turn clears it, so an older countdown closes nothing.
    deadline: Option<tokio::time::Instant>,
}

/// The wait of a session with no holder, no turn, and no running job before it closes.
const GRACE: Duration = Duration::from_secs(30);

/// A holder of an open session: the session does not close by itself while an attachment exists. After the drop of the
/// last attachment, the countdown starts when the task of the session runs no turn.
pub(crate) struct Attachment {
    service: Weak<SessionService>,
    id: SessionId,
    /// The open session that the attachment holds, so the drop never releases a later open of the same id.
    live: Weak<LiveSession>,
}

impl Drop for Attachment {
    fn drop(&mut self) {
        if let Some(service) = self.service.upgrade() {
            service.detach(self);
        }
    }
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
    fn open(self, live: Rc<LiveSession>) -> Result<(), AppError> {
        let announced = Rc::clone(&live);
        {
            let mut registry = self.service.registry.borrow_mut();
            if registry.phase == Phase::Stopped {
                return Err(AppError::Stopped);
            }
            registry.slots.insert(
                self.id,
                Slot::Open(Open {
                    live,
                    attachments: 0,
                    deadline: None,
                }),
            );
        }
        // A fact sink can call the service, so the registry borrow must end first.
        announced.announce(None);
        Ok(())
    }
}

impl Drop for Transition<'_> {
    fn drop(&mut self) {
        let mut registry = self.service.registry.borrow_mut();
        if matches!(registry.slots.get(&self.id), Some(Slot::Opening | Slot::Closing)) {
            registry.slots.remove(&self.id);
        }
    }
}

/// A reload in progress: no session opens or closes until its drop.
pub(super) struct Reload<'a> {
    service: &'a SessionService,
    /// Each open session at the start of the reload.
    pub(super) sessions: Vec<Rc<LiveSession>>,
}

impl Drop for Reload<'_> {
    fn drop(&mut self) {
        self.service.registry.borrow_mut().phase = Phase::Ready;
    }
}

impl SessionService {
    /// The service of `shared`. A session opens after [`SessionService::set_runtime`].
    pub(super) fn new(shared: Rc<Shared>) -> Rc<Self> {
        Rc::new_cyclic(|this| SessionService {
            this: this.clone(),
            shared,
            runtime: RefCell::new(None),
            registry: RefCell::default(),
        })
    }

    /// Hold the open session `id`, so it does not close by itself until the drop of the result.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`].
    pub(crate) fn attach(&self, id: SessionId) -> Result<Attachment, AppError> {
        let mut registry = self.registry.borrow_mut();
        let Some(Slot::Open(open)) = registry.slots.get_mut(&id) else {
            return Err(AppError::NotOpen(id));
        };
        open.attachments += 1;
        open.deadline = None;
        Ok(Attachment {
            service: self.this.clone(),
            id,
            live: Rc::downgrade(&open.live),
        })
    }

    /// Release `attachment`. The last one wakes the task of the session, which reports when the session has no work.
    fn detach(&self, attachment: &Attachment) {
        let mut registry = self.registry.borrow_mut();
        if let Some(Slot::Open(open)) = registry.slots.get_mut(&attachment.id)
            && Weak::as_ptr(&attachment.live) == Rc::as_ptr(&open.live)
        {
            open.attachments -= 1;
            if open.attachments == 0 {
                open.live.wake();
            }
        }
    }

    /// Stop the countdown of session `id`, because a turn starts.
    pub(super) fn touch(&self, id: SessionId) {
        if let Some(Slot::Open(open)) = self.registry.borrow_mut().slots.get_mut(&id) {
            open.deadline = None;
        }
    }

    /// Start the countdown of session `id`, whose task runs no turn now. A session with a holder does not count down.
    /// The wait is [`GRACE`], or `sessionIdleMinutes` while a job of the session runs. An existing countdown keeps its
    /// deadline until a holder or a turn cancels it.
    pub(super) fn report_idle(&self, id: SessionId) {
        let mut registry = self.registry.borrow_mut();
        let Some(Slot::Open(open)) = registry.slots.get_mut(&id) else {
            return;
        };
        if open.attachments > 0 || open.deadline.is_some() {
            return;
        }
        let wait = if open.live.jobs().is_empty() {
            GRACE
        } else {
            self.shared.session_idle()
        };
        let timer = tokio::time::sleep(wait);
        let deadline = timer.deadline();
        open.deadline = Some(deadline);
        let service = self.this.clone();
        tokio::task::spawn_local(async move {
            timer.await;
            if let Some(service) = service.upgrade() {
                service.expire(id, deadline).await;
            }
        });
    }

    /// Close session `id` at `deadline` if no holder or turn cancelled it. During a reload, start a new countdown.
    async fn expire(&self, id: SessionId, deadline: tokio::time::Instant) {
        let live = {
            let mut registry = self.registry.borrow_mut();
            let reloading = registry.phase == Phase::Reloading;
            let Some(Slot::Open(open)) = registry.slots.get_mut(&id) else {
                return;
            };
            if open.deadline != Some(deadline) {
                return;
            }
            if reloading {
                open.deadline = None;
                drop(registry);
                self.report_idle(id);
                return;
            }
            let live = Rc::clone(&open.live);
            registry.slots.insert(id, Slot::Closing);
            live
        };
        let _transition = Transition { service: self, id };
        live.close().await;
    }

    /// Refuse each open and close until the drop of the result, and give each open session.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Changing`] while a call opens or closes a session, [`AppError::Reloading`], and
    /// [`AppError::Stopped`].
    pub(super) fn start_reload(&self) -> Result<Reload<'_>, AppError> {
        let mut registry = self.registry.borrow_mut();
        admit(registry.phase)?;
        let mut sessions = Vec::with_capacity(registry.slots.len());
        for (id, slot) in &registry.slots {
            match slot {
                Slot::Open(open) => sessions.push(Rc::clone(&open.live)),
                Slot::Opening | Slot::Closing => return Err(AppError::Changing(*id)),
            }
        }
        registry.phase = Phase::Reloading;
        Ok(Reload {
            service: self,
            sessions,
        })
    }

    /// Watch the facts with `sink`: first the open of each open session, then each later fact. The watch holds no
    /// session. A session that opens meanwhile gets one open fact.
    pub(super) fn watch_facts(&self, sink: FactSink) -> Watch {
        let watch = self.shared.facts.watch(sink);
        let open: Vec<Rc<LiveSession>> = self
            .registry
            .borrow()
            .slots
            .values()
            .filter_map(|slot| match slot {
                Slot::Open(open) => Some(Rc::clone(&open.live)),
                Slot::Opening | Slot::Closing => None,
            })
            .collect();
        for live in open {
            live.announce(Some(watch.id));
        }
        watch
    }

    /// The handle of the plugins of the runtime now, or `None` before the first runtime starts.
    pub(super) fn plugins(&self) -> Option<Handle> {
        self.runtime.borrow().clone()
    }

    /// Open the plugins of each later session with `runtime`.
    pub(super) fn set_runtime(&self, runtime: Handle) {
        *self.runtime.borrow_mut() = Some(runtime);
    }

    /// Refuse each later open, and close each open session. The sessions stop together before the first wait. A call
    /// that opens or closes a session now ends alone.
    pub(super) async fn close_all(&self) {
        let open: Vec<Rc<LiveSession>> = {
            let mut registry = self.registry.borrow_mut();
            registry.phase = Phase::Stopped;
            std::mem::take(&mut registry.slots)
                .into_values()
                .filter_map(|slot| match slot {
                    Slot::Open(open) => Some(open.live),
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
    /// of that folder.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for a folder that does not exist or a model that cannot run, [`AppError::Store`]
    /// when the store fails, [`AppError::Internal`] when the plugins do not open, [`AppError::Reloading`], and
    /// [`AppError::Stopped`].
    pub(crate) async fn create(
        &self,
        mut settings: SessionSettings,
        parent: Option<SessionId>,
    ) -> Result<SessionId, AppError> {
        // A refusal before the work saves no session in the common case. The reserve checks again.
        admit(self.registry.borrow().phase)?;
        if let Some(parent) = parent {
            self.shared.store.session_summary(parent).await?;
        }
        settings.cwd = canonical(settings.cwd).await?;
        let prompt = system_prompt(
            settings.cwd.clone(),
            self.shared.machine.home.clone(),
            self.shared.plugin_folders().to_vec(),
        )
        .await?;
        let session = Session::create(Arc::clone(&self.shared.store), &settings, &prompt.sections, parent).await?;
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
        admit(self.registry.borrow().phase)?;
        let session = Session::fork(Arc::clone(&self.shared.store), id, through).await?;
        self.start_new(session).await
    }

    /// A page of the saved sessions, newest first, with the activity of each one. `params.cursor` continues the list
    /// with the same `params.cwd` and `params.parent`.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for a limit outside 1 to 100 or an invalid cursor, and [`AppError::Store`] when
    /// the store fails.
    pub(crate) async fn list(&self, params: ListSessionsParams) -> Result<ListSessionsResult, AppError> {
        let ListSessionsParams {
            cwd,
            parent,
            limit,
            cursor,
        } = params;
        let limit = limit.unwrap_or(PAGE_ROWS);
        if !(1..=MOST_PAGE_ROWS).contains(&limit) {
            return Err(AppError::Invalid(format!(
                "the limit {limit} must be between 1 and {MOST_PAGE_ROWS}"
            )));
        }
        let after = cursor
            .as_deref()
            .map(|cursor| position_of(cursor, cwd.as_deref(), parent))
            .transpose()?;
        let page = self
            .shared
            .store
            .list_sessions(cwd.as_deref(), parent, after, limit as usize)
            .await?;
        Ok(ListSessionsResult {
            sessions: page.sessions.into_iter().map(|session| self.row(session)).collect(),
            next_cursor: page.next.map(|next| cursor_of(next, cwd.as_deref(), parent)),
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

    /// Rename session `id` without changing its turn, events, or activity times. The session can be closed.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Store`] for an unknown session or when the save fails, [`AppError::Reloading`], and
    /// [`AppError::Stopped`].
    pub(crate) async fn rename(&self, id: SessionId, title: SessionTitle) -> Result<(), AppError> {
        admit(self.registry.borrow().phase)?;
        Ok(self.shared.store.rename_session(id, &title).await?)
    }

    /// Delete the saved session `id` and its descendants, with their events, pending inputs, and blobs. Its forks stay. A
    /// failed delete leaves a valid tree, because children go first, so a second call can finish the work.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Open`] for an open session, and [`AppError::Store`] for an unknown session, a session that
    /// another process holds, or a failed delete.
    pub(crate) async fn remove(&self, id: SessionId) -> Result<(), AppError> {
        // The parents come first in the tree, so a reverse walk removes each child before its parent.
        let mut tree = vec![id];
        let mut next = 0;
        while let Some(&parent) = tree.get(next) {
            next += 1;
            // One read of all children, so a child that moves in the list during a walk of pages stays in the tree.
            let children = self
                .shared
                .store
                .list_sessions(None, Some(parent), None, ALL_CHILDREN)
                .await?;
            tree.extend(children.sessions.iter().map(|child| child.session_id));
        }
        {
            let registry = self.registry.borrow();
            if let Some(open) = tree.iter().find(|session| registry.slots.contains_key(session)) {
                return Err(AppError::Open(*open));
            }
        }
        for session in tree.into_iter().rev() {
            self.shared.store.delete_session(session).await?;
        }
        Ok(())
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
    ) -> Result<Rc<LiveSession>, AppError> {
        let transition = self.reserve(id)?;
        let mut session = Session::open(Arc::clone(&self.shared.store), id).await?;
        match change(session.settings(), &self.shared.providers())? {
            Some(settings) => drop(save_settings(&mut session, settings, &self.shared).await?),
            None => self.check_model(session.settings())?,
        }
        self.start_session(transition, session).await
    }

    /// Open session `id` when it is not open, and send it as updates: its saved events after `after`, its state, its
    /// pending inputs, its running jobs, its MCP servers, and its open questions. The live updates that come during the
    /// load and that the snapshot does not hold follow them.
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

    /// Watch the open session `id`: `sink` receives its snapshot with its last `tail` saved events, then each later
    /// update that the snapshot does not hold, until the drop of the result. The other listeners get no snapshot.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`], and [`AppError::Store`] when the store fails.
    pub(crate) async fn view(&self, id: SessionId, tail: usize, sink: ViewSink) -> Result<View, AppError> {
        self.live(id)?.view(tail, sink).await
    }

    /// At most `limit` saved events of session `id` with a number below `before`, or its last `limit` events, in
    /// number order. The session can be closed.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Store`] for an unknown session or when the store fails.
    pub(crate) async fn events_before(
        &self,
        id: SessionId,
        before: Option<EventNumber>,
        limit: usize,
    ) -> Result<Vec<StoredEvent>, AppError> {
        Ok(self
            .shared
            .store
            .load(id, EventPage::Before { before, limit })
            .await?
            .events)
    }

    /// Close session `id`: its turn stops, its task ends, and its jobs stop. Waiting input stays saved.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`], [`AppError::Changing`] while another call opens or closes the session, and
    /// [`AppError::Reloading`].
    pub(crate) async fn close(&self, id: SessionId) -> Result<(), AppError> {
        let live = {
            let mut registry = self.registry.borrow_mut();
            admit(registry.phase)?;
            let live = match registry.slots.get(&id) {
                Some(Slot::Open(open)) => Rc::clone(&open.live),
                Some(Slot::Opening | Slot::Closing) => return Err(AppError::Changing(id)),
                None => return Err(AppError::NotOpen(id)),
            };
            registry.slots.insert(id, Slot::Closing);
            live
        };
        let _transition = Transition { service: self, id };
        live.close().await;
        Ok(())
    }

    /// Move each job that a call of session `id` waits for out of its call. A session without such a job does nothing.
    pub(crate) fn background(&self, id: SessionId) {
        if let Ok(live) = self.live(id) {
            live.background();
        }
    }

    /// Whether [`SessionService::background`] moves a job of session `id` now.
    pub(crate) fn has_movable(&self, id: SessionId) -> bool {
        self.live(id).is_ok_and(|live| live.has_movable())
    }

    /// Cancel the running turn of session `id`. A session that is not open or runs no turn has nothing to cancel.
    pub(crate) fn cancel(&self, id: SessionId) {
        if let Ok(live) = self.live(id) {
            live.cancel();
        }
    }

    /// Save `input`, and start a turn when the session is idle.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`], and [`AppError::Store`] when the store fails.
    pub(crate) async fn input(&self, id: SessionId, input: Input) -> Result<InputId, AppError> {
        Ok(self.live(id)?.accept(input).await?)
    }

    /// Wait until session `id` runs no turn and has handled each input that it accepted before the call, or until its
    /// close. A failed turn counts as handled, and its input waits for the next wake.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`].
    pub(crate) async fn idle(&self, id: SessionId) -> Result<(), AppError> {
        self.live(id)?.idle().await;
        Ok(())
    }

    /// Save `bytes` in the store of session `id`, and return the blob that names them.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Store`] when the store fails, as for an unknown session.
    pub(crate) async fn put_blob(&self, id: SessionId, bytes: Vec<u8>) -> Result<yuke_ai::Blob, AppError> {
        Ok(self.shared.store.put_blob(id, bytes).await?)
    }

    /// The bytes of `blob` in the saved session `id`, which can be closed.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NoBlob`] when the session has no such blob, and [`AppError::Store`] for an unknown session or
    /// when the store fails.
    pub(crate) async fn read_blob(&self, id: SessionId, blob: yuke_ai::Blob) -> Result<Vec<u8>, AppError> {
        let store = Arc::clone(&self.shared.store);
        super::blocking(move || store.read_blob(id, &blob.digest)?.ok_or(AppError::NoBlob)).await
    }

    /// Remove the pending input `input_id` of session `id`. Return `false` when the input is not pending.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`], and [`AppError::Store`] when the store fails.
    pub(crate) async fn remove_input(&self, id: SessionId, input_id: InputId) -> Result<bool, AppError> {
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
        // The caller learns why the start failed. A failed delete is a warning beside it.
        if started.is_err()
            && let Err(error) = self.shared.store.delete_session(id).await
        {
            self.shared.warn(&format!(
                "the session {id} that did not start stays: {}",
                chain_text(&error)
            ));
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
        let mut registry = self.registry.borrow_mut();
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
    async fn start_session(&self, transition: Transition<'_>, session: Session) -> Result<Rc<LiveSession>, AppError> {
        let id = session.id();
        let runtime = self
            .runtime
            .borrow()
            .clone()
            .ok_or_else(|| AppError::Internal("the JavaScript runtime has not started".to_owned()))?;
        let live = Rc::new(LiveSession::start(session, &runtime, Rc::clone(&self.shared), self.this.clone()).await?);
        if let Err(error) = transition.open(Rc::clone(&live)) {
            // The shutdown started during the open and closes no session that it did not see.
            live.close().await;
            return Err(error);
        }
        // A session that nobody attaches counts down too. A saved input still waits for a wake.
        self.report_idle(id);
        Ok(live)
    }

    /// The open session `id`.
    pub(super) fn live(&self, id: SessionId) -> Result<Rc<LiveSession>, AppError> {
        match self.registry.borrow().slots.get(&id) {
            Some(Slot::Open(open)) => Ok(Rc::clone(&open.live)),
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

/// The limit of a read of all children of a session.
const ALL_CHILDREN: usize = u32::MAX as usize;

/// The cursor of the page after `next` in the list of `cwd` and `parent`. It holds both, so a cursor of another list does
/// not read.
fn cursor_of(next: ListPosition, cwd: Option<&Path>, parent: Option<SessionId>) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut cursor = format!("{}.", next.0);
    if let Some(parent) = parent {
        cursor.push_str(&parent.to_string());
        cursor.push('.');
    }
    for byte in cwd.map_or(&[][..], |cwd| cwd.as_os_str().as_encoded_bytes()) {
        cursor.push(char::from(HEX[usize::from(byte >> 4)]));
        cursor.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    cursor
}

/// The position that `cursor`, a cursor of the list of `cwd` and `parent`, names.
fn position_of(cursor: &str, cwd: Option<&Path>, parent: Option<SessionId>) -> Result<ListPosition, AppError> {
    let invalid = || AppError::Invalid(format!("the cursor '{cursor}' is invalid for this list"));
    let (position, _) = cursor.split_once('.').ok_or_else(invalid)?;
    // A store gives no position above `i64::MAX`, the largest SQLite integer.
    let position: i64 = position.parse().map_err(|_| invalid())?;
    let position = ListPosition(position.unsigned_abs());
    // A cursor of this list encodes to the same text again.
    if cursor_of(position, cwd, parent) == cursor {
        Ok(position)
    } else {
        Err(invalid())
    }
}

#[cfg(test)]
mod tests;
