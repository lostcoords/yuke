//! One open session: a task that runs its turns, and the parts that the app shares with that task.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tokio::sync::Notify;
use tokio::task::JoinHandle;
use yuke_agent::{InputSender, Loaded, Session, SessionError, SessionObserver, StoreError, system_notification};
use yuke_ai::{Block, ToolDefinition};
use yuke_engine::{CancellationToken, Driver, Toolset, chain_text};
use yuke_js::{JobEnded, Runtime, ScriptSession, ScriptTool, SessionHost};
use yuke_protocol::{
    EventNumber, Input, InputId, InputSource, Job, LiveUpdate, NoticeLevel, NoticeParams, ServerNotification,
    SessionEvent, SessionId, SessionSettings, SessionState, SessionUpdate, SessionUpdateParams, StoredEvent,
};

use super::{AppError, Observer, SOURCE, Shared, TokioTimer, lock, model_of, save_settings, warn};

/// The source of the input that a background job sends when it ends.
const JOBS_SOURCE: &str = "host:jobs";

/// An open session.
pub(super) struct LiveSession {
    /// The inbox of the session. The app saves and removes input through the inbox.
    pub(super) inbox: Inbox,
    /// A turn holds the lock for its whole run, so new settings never meet a turn.
    session: Arc<tokio::sync::Mutex<Session>>,
    /// The cancellation token of the running turn, or `None` while the session is idle.
    turn: Arc<Mutex<Option<CancellationToken>>>,
    /// Ends the task. The token of each turn is a child of it.
    closed: CancellationToken,
    /// The host of the tools. The jobs of the session belong to it.
    host: Arc<Host>,
    /// The session of the plugins. Each turn takes its tools.
    script: Arc<ScriptSession>,
    task: JoinHandle<()>,
}

impl LiveSession {
    /// Open the plugins of `session`, and start its task, which runs its turns. The open does not wait for the plugins;
    /// the first turn does.
    pub(super) async fn start(
        session: Session,
        runtime: &Runtime,
        shared: Arc<Shared>,
    ) -> Result<LiveSession, AppError> {
        let inbox = Inbox {
            input: session.input(),
            wake: Arc::new(Notify::new()),
            output: Arc::new(Output {
                session: session.id(),
                observer: Arc::clone(&shared.observer),
                sent: Mutex::default(),
            }),
        };
        let host = Arc::new(Host {
            folder: Mutex::new(session.settings().cwd.clone()),
            shared,
            inbox: inbox.clone(),
        });
        let script = Arc::new(
            runtime
                .open_session(Arc::clone(&host) as Arc<dyn SessionHost>)
                .await
                .map_err(|error| AppError::Internal(chain_text(&error)))?,
        );
        let session = Arc::new(tokio::sync::Mutex::new(session));
        let turn = Arc::default();
        let closed = CancellationToken::new();
        let task = SessionTask {
            session: Arc::clone(&session),
            script: Arc::clone(&script),
            host: Arc::clone(&host),
            inbox: inbox.clone(),
            turn: Arc::clone(&turn),
            closed: closed.clone(),
        };
        Ok(LiveSession {
            inbox,
            session,
            turn,
            closed,
            host,
            script,
            task: tokio::spawn(task.run()),
        })
    }

    /// Whether a turn runs.
    pub(super) fn state(&self) -> SessionState {
        if lock(&self.turn).is_some() {
            SessionState::Running
        } else {
            SessionState::Idle
        }
    }

    /// Cancel the running turn.
    pub(super) fn cancel(&self) {
        if let Some(token) = lock(&self.turn).as_ref() {
            token.cancel();
        }
    }

    /// Send the session as updates: the saved events after `after`, the state, the pending inputs, and the running
    /// jobs. The live updates that come during the load follow them, without the ones that they hold.
    pub(super) async fn load(&self, after: Option<EventNumber>) -> Result<(), AppError> {
        let hold = Hold::start(&self.inbox.output);
        let loaded = self
            .host
            .shared
            .store
            .load(self.inbox.output.session, after)
            .await
            .map_err(AppError::Store)?;
        hold.release(loaded, || (self.state(), self.jobs()));
        Ok(())
    }

    /// Save `settings`. It fails while a turn runs or input waits, and it never waits for a turn. The session keeps its
    /// system prompt.
    pub(super) async fn set_settings(&self, settings: SessionSettings) -> Result<(), AppError> {
        let Ok(mut session) = self.session.try_lock() else {
            return Err(AppError::Busy);
        };
        // A turn starts only under the lock, so an input that comes after this check runs with the new settings.
        let waiting = self
            .host
            .shared
            .store
            .pending(self.inbox.output.session)
            .await
            .map_err(AppError::Store)?;
        if !waiting.is_empty() {
            return Err(AppError::Busy);
        }
        if session.is_stale() {
            recover(&mut session, &self.inbox.output).await?;
        }
        let saved = save_settings(&mut session, settings, &self.host.shared).await?;
        self.inbox.output.publish(SessionUpdate::Saved(saved));
        Ok(())
    }

    /// The running background jobs, oldest first.
    pub(super) fn jobs(&self) -> Vec<Job> {
        self.host.shared.processes.running_jobs(&self.owner())
    }

    /// Stop the running job `id`, and wait for its end. Answer `false` when no such job runs.
    pub(super) async fn stop_job(&self, id: &str) -> bool {
        self.host.shared.processes.stop_job(id, &self.owner()).await.is_some()
    }

    /// Stop the running turn, and start no other.
    pub(super) fn stop(&self) {
        // The task starts a turn under the same lock, so a turn starts either before the stop and ends cancelled, or
        // not at all and leaves its input pending.
        let _turn = lock(&self.turn);
        self.closed.cancel();
    }

    /// Stop the running turn, wait for the task to end, and stop the jobs. Waiting input stays saved and starts no
    /// turn.
    pub(super) async fn close(mut self) {
        self.stop();
        if let Err(error) = (&mut self.task).await {
            warn(&format!("a session task failed: {error}"));
        }
        // After the task, so no turn takes the tools of the closed plugins.
        if let Err(error) = self.script.close().await {
            warn(&format!(
                "the plugins of a session did not close: {}",
                chain_text(&error)
            ));
        }
        // After the task, so a job that the cancelled turn started also stops.
        self.host.shared.processes.close_owner(&self.owner()).await;
    }

    /// The owner of the jobs of the session.
    fn owner(&self) -> Arc<dyn SessionHost> {
        Arc::clone(&self.host) as Arc<dyn SessionHost>
    }
}

// A session that the app drops without a close still ends its task and its turn.
impl Drop for LiveSession {
    fn drop(&mut self) {
        self.closed.cancel();
    }
}

/// The input of one session: the saved queue, the observer, and the wake of the task.
#[derive(Clone)]
pub(super) struct Inbox {
    input: InputSender,
    /// Wakes the task to run the waiting input. Many wakes before the task runs count as one.
    wake: Arc<Notify>,
    output: Arc<Output>,
}

impl Inbox {
    /// Save `input`, show it to the observer, and wake the task. The task runs a turn when the session is idle.
    pub(super) async fn accept(&self, input: Input) -> Result<InputId, StoreError> {
        let input_id = self.input.send(input.clone()).await?;
        self.output
            .publish(SessionUpdate::Live(LiveUpdate::InputAccepted { input_id, input }));
        self.wake.notify_one();
        Ok(input_id)
    }

    /// Remove the pending input `input_id`, and tell the observer.
    pub(super) async fn remove(&self, input_id: InputId) -> Result<(), StoreError> {
        self.input.remove(input_id).await?;
        self.output
            .publish(SessionUpdate::Live(LiveUpdate::InputRemoved { input_id }));
        Ok(())
    }
}

/// The updates of one session on their way to the observer.
struct Output {
    session: SessionId,
    observer: Arc<dyn Observer>,
    sent: Mutex<Sent>,
}

/// What the output keeps under its lock.
#[derive(Default)]
struct Sent {
    /// The updates that wait for the end of a load, or `None` while no load runs.
    held: Option<Vec<SessionUpdate>>,
    /// The inputs that a sent commit consumed or a sent removal named. An `input_accepted` can come after them, because
    /// the store saves an input before the server sends it, so the output drops it.
    gone: HashSet<InputId>,
}

impl Output {
    /// Send `update` to the observer, or keep it while a load runs.
    fn publish(&self, update: SessionUpdate) {
        let mut sent = lock(&self.sent);
        match sent.held.as_mut() {
            Some(held) => held.push(update),
            None => self.send(&mut sent, update),
        }
    }

    fn send(&self, sent: &mut Sent, update: SessionUpdate) {
        match &update {
            SessionUpdate::Saved(StoredEvent {
                event: SessionEvent::Commit { consumed, .. },
                ..
            }) => sent.gone.extend(consumed.iter().map(|input| input.id)),
            SessionUpdate::Live(LiveUpdate::InputRemoved { input_id }) => {
                sent.gone.insert(*input_id);
            }
            SessionUpdate::Live(LiveUpdate::InputAccepted { input_id, .. }) if sent.gone.contains(input_id) => return,
            _ => {}
        }
        self.observer
            .notify(ServerNotification::SessionUpdate(SessionUpdateParams {
                session_id: self.session,
                update,
            }));
    }

    /// Tell the observer about the session.
    fn notice(&self, level: NoticeLevel, message: &str) {
        self.observer.notify(ServerNotification::Notice(NoticeParams {
            session_id: Some(self.session),
            level,
            source: SOURCE.to_owned(),
            message: message.to_owned(),
        }));
    }
}

// A turn sends its updates through the output, so they wait while a load runs.
impl SessionObserver for Output {
    fn update(&self, update: SessionUpdateParams) {
        self.publish(update.update);
    }
}

/// Keeps the live updates of a session while a load reads its saved events. A drop without a release sends the kept
/// updates.
struct Hold<'a> {
    output: &'a Output,
}

impl<'a> Hold<'a> {
    fn start(output: &'a Output) -> Self {
        lock(&output.sent).held.get_or_insert_with(Vec::new);
        Hold { output }
    }

    /// Send the snapshot: `loaded` from one store read, then the state and the running jobs from `now`. Then send the
    /// kept updates without the saved events that the snapshot holds. `now` runs under the lock, so no update comes
    /// between it and its send.
    fn release(self, loaded: Loaded, now: impl FnOnce() -> (SessionState, Vec<Job>)) {
        let mut sent = lock(&self.output.sent);
        let last = loaded.events.last().map(|event| event.event_number);
        let (state, jobs) = now();
        for event in loaded.events {
            self.output.send(&mut sent, SessionUpdate::Saved(event));
        }
        self.output
            .send(&mut sent, SessionUpdate::Live(LiveUpdate::State { state }));
        for pending in loaded.pending {
            let update = LiveUpdate::InputAccepted {
                input_id: pending.id,
                input: pending.input,
            };
            self.output.send(&mut sent, SessionUpdate::Live(update));
        }
        for job in jobs {
            self.output
                .send(&mut sent, SessionUpdate::Live(LiveUpdate::Job { job }));
        }
        for update in sent.held.take().unwrap_or_default() {
            let read =
                matches!(&update, SessionUpdate::Saved(event) if last.is_some_and(|last| event.event_number <= last));
            if !read {
                self.output.send(&mut sent, update);
            }
        }
    }
}

impl Drop for Hold<'_> {
    fn drop(&mut self) {
        let mut sent = lock(&self.output.sent);
        for update in sent.held.take().unwrap_or_default() {
            self.output.send(&mut sent, update);
        }
    }
}

/// The task of one session.
struct SessionTask {
    session: Arc<tokio::sync::Mutex<Session>>,
    script: Arc<ScriptSession>,
    host: Arc<Host>,
    inbox: Inbox,
    turn: Arc<Mutex<Option<CancellationToken>>>,
    closed: CancellationToken,
}

impl SessionTask {
    /// Run the waiting input at each wake, until the app closes the session.
    async fn run(self) {
        // An open alone runs nothing, so a load only reads. The waiting input runs at the next wake.
        loop {
            tokio::select! {
                () = self.inbox.wake.notified() => self.run_waiting_turns().await,
                () = self.closed.cancelled() => return,
            }
        }
    }

    /// Run one turn after another while input waits.
    async fn run_waiting_turns(&self) {
        let output = &self.inbox.output;
        loop {
            // The check comes before the lock, so a wake with no input never makes new settings fail.
            match self.host.shared.store.pending(output.session).await {
                Ok(pending) if !pending.is_empty() => {}
                Ok(_) => return,
                Err(error) => {
                    output.notice(NoticeLevel::Error, &chain_text(&error));
                    return;
                }
            }
            let mut session = Arc::clone(&self.session).lock_owned().await;
            if session.is_stale()
                && let Err(error) = recover(&mut session, output).await
            {
                output.notice(NoticeLevel::Error, &chain_text(&error));
                return;
            }
            // The settings name the model and the folder, so each turn takes both from the settings of that moment.
            let model = match model_of(session.settings(), &self.host.shared) {
                Ok(model) => model,
                Err(error) => {
                    output.notice(NoticeLevel::Error, &chain_text(&error));
                    return;
                }
            };
            lock(&self.host.folder).clone_from(&session.settings().cwd);
            let token = {
                let mut turn = lock(&self.turn);
                if self.closed.is_cancelled() {
                    return;
                }
                let token = self.closed.child_token();
                *turn = Some(token.clone());
                token
            };
            output.publish(SessionUpdate::Live(LiveUpdate::State {
                state: SessionState::Running,
            }));
            // The first turn waits for the plugins. A cancel or a close ends the wait, and the turn then ends as
            // cancelled, so it needs no tool.
            let toolset = tokio::select! {
                tools = self.script.tools() => toolset_of(tools),
                () = token.cancelled() => Ok(Toolset::new()),
            };
            let ended = match toolset {
                // The turn runs in its own task, so a panic of the turn cannot leave the session running.
                Ok(toolset) => {
                    let shared = Arc::clone(&self.host.shared);
                    let output = Arc::clone(output);
                    // The session saves a round failure as the end of the turn.
                    let turn = async move {
                        let mut session = session;
                        let driver = Driver::new(&*shared.machine.transport, &model, &TokioTimer).toolset(&toolset);
                        session
                            .turn(driver)
                            .observer(&*output)
                            .cancellation_token(token)
                            .run()
                            .await
                    };
                    Some(tokio::spawn(turn).await)
                }
                Err(error) => {
                    output.notice(NoticeLevel::Error, &error);
                    None
                }
            };
            *lock(&self.turn) = None;
            output.publish(SessionUpdate::Live(LiveUpdate::State {
                state: SessionState::Idle,
            }));
            // Without a turn, the input that waits runs at the next wake.
            let Some(ended) = ended else {
                return;
            };
            match ended {
                Ok(Ok(_) | Err(SessionError::Round(_) | SessionError::NoInput)) => {}
                // A stale session recovers at the next wake, so a store failure does not repeat at once.
                Ok(Err(error @ (SessionError::Store(_) | SessionError::Stale))) => {
                    output.notice(NoticeLevel::Error, &chain_text(&error));
                    return;
                }
                // The session in memory can be wrong after a panic, so it opens again from the store at once. The
                // input that waits runs at the next wake, so a panic does not repeat at once.
                Err(error) => {
                    output.notice(NoticeLevel::Error, &format!("the turn failed: {error}"));
                    let mut session = self.session.lock().await;
                    if let Err(error) = recover(&mut session, output).await {
                        output.notice(NoticeLevel::Error, &chain_text(&error));
                    }
                    return;
                }
            }
        }
    }
}

/// Open `session` again from the store after a failed write or a panic, and publish the end of a turn that the store
/// held as open.
async fn recover(session: &mut Session, output: &Output) -> Result<(), AppError> {
    if let Some(event) = session.recover().await.map_err(AppError::Store)? {
        output.publish(SessionUpdate::Saved(event));
    }
    Ok(())
}

/// The toolset of a turn from the tools of the plugins.
fn toolset_of(tools: Result<Vec<(ToolDefinition, ScriptTool)>, yuke_js::Error>) -> Result<Toolset, String> {
    let mut toolset = Toolset::new();
    for (definition, tool) in tools.map_err(|error| chain_text(&error))? {
        toolset.add(definition, tool).map_err(|error| chain_text(&error))?;
    }
    Ok(toolset)
}

/// The session of the tools: its folder, its blob store, and the input of its background jobs.
struct Host {
    /// The folder of the session. Each turn sets it from the settings.
    folder: Mutex<PathBuf>,
    shared: Arc<Shared>,
    inbox: Inbox,
}

#[async_trait]
impl SessionHost for Host {
    fn session_id(&self) -> SessionId {
        self.inbox.output.session
    }

    fn folder(&self) -> PathBuf {
        lock(&self.folder).clone()
    }

    async fn put_media(&self, bytes: Vec<u8>) -> Result<yuke_ai::Blob, String> {
        self.shared
            .store
            .put_blob(self.inbox.output.session, bytes)
            .await
            .map_err(|error| chain_text(&error))
    }

    fn job_changed(&self, job: Job) {
        self.inbox.output.publish(SessionUpdate::Live(LiveUpdate::Job { job }));
    }

    // The end of a job is an input of `host:jobs`. The user sees a short line, and the model reads the whole text as a
    // notification of yuke. The input starts a turn when the session is idle.
    async fn job_ended(&self, ended: JobEnded) {
        let source = InputSource::Plugin {
            name: JOBS_SOURCE.to_owned(),
        };
        let job_input = Input::new(source, vec![Block::user_text(format!("{} ended", ended.id))])
            .and_then(|job_input| job_input.with_model_content(vec![system_notification(&ended.text)]));
        let accepted = match job_input {
            Ok(job_input) => self.inbox.accept(job_input).await.map_err(|error| chain_text(&error)),
            Err(error) => Err(chain_text(&error)),
        };
        if let Err(text) = accepted {
            self.inbox.output.notice(NoticeLevel::Error, &text);
        }
    }
}

#[cfg(test)]
mod tests {
    use yuke_protocol::ModelReference;

    use super::*;

    /// Keeps each session update that it receives.
    #[derive(Default)]
    struct Recorder(Mutex<Vec<SessionUpdate>>);

    impl Observer for Recorder {
        fn notify(&self, notification: ServerNotification) {
            if let ServerNotification::SessionUpdate(params) = notification {
                lock(&self.0).push(params.update);
            }
        }
    }

    fn output(recorder: &Arc<Recorder>) -> Output {
        Output {
            session: SessionId::generate(),
            observer: Arc::clone(recorder) as Arc<dyn Observer>,
            sent: Mutex::default(),
        }
    }

    fn stored(number: u64) -> StoredEvent {
        StoredEvent {
            event_number: EventNumber(number),
            event: SessionEvent::Settings(SessionSettings {
                model: ModelReference {
                    provider: "minimax".to_owned(),
                    model: "MiniMax-M3".to_owned(),
                },
                settings: yuke_ai::Settings::new(),
                cwd: PathBuf::from("/"),
            }),
        }
    }

    fn saved(number: u64) -> SessionUpdate {
        SessionUpdate::Saved(stored(number))
    }

    fn removed(id: u64) -> SessionUpdate {
        SessionUpdate::Live(LiveUpdate::InputRemoved { input_id: InputId(id) })
    }

    /// A commit numbered `number` that consumed the input `input`.
    fn consuming(number: u64, input: u64) -> StoredEvent {
        StoredEvent {
            event_number: EventNumber(number),
            event: SessionEvent::Commit {
                commit: yuke_engine::Commit {
                    replaced: None,
                    blocks: Vec::new().into(),
                    answer: None,
                    end: None,
                },
                consumed: vec![yuke_protocol::ConsumedInput {
                    id: InputId(input),
                    source: InputSource::User,
                    display_content: None,
                    block_count: 0,
                }],
            },
        }
    }

    fn input() -> Input {
        Input::new(InputSource::User, vec![Block::user_text("go")]).unwrap()
    }

    fn accepted(id: u64) -> SessionUpdate {
        SessionUpdate::Live(LiveUpdate::InputAccepted {
            input_id: InputId(id),
            input: input(),
        })
    }

    fn job() -> SessionUpdate {
        SessionUpdate::Live(LiveUpdate::Job { job: running_job() })
    }

    fn running_job() -> Job {
        Job {
            id: "job-1a2b".to_owned(),
            command: "sleep 30".to_owned(),
            log: PathBuf::from("/tmp/job-1a2b.log"),
            state: yuke_protocol::JobState::Running,
        }
    }

    #[test]
    fn a_load_sends_its_snapshot_then_only_the_kept_updates_that_the_snapshot_does_not_hold() {
        let recorder = Arc::new(Recorder::default());
        let output = output(&recorder);

        output.publish(removed(1));
        let hold = Hold::start(&output);
        // The read holds the commit 5, which consumed the input 8, and the pending input 7.
        output.publish(accepted(7));
        output.publish(accepted(8));
        output.publish(saved(5));
        output.publish(accepted(9));
        output.publish(saved(6));
        output.publish(job());
        let loaded = Loaded {
            events: vec![stored(4), consuming(5, 8)],
            pending: vec![yuke_protocol::PendingInput {
                id: InputId(7),
                input: input(),
            }],
        };
        hold.release(loaded, || (SessionState::Running, vec![running_job()]));
        output.publish(removed(3));

        assert_eq!(
            *lock(&recorder.0),
            [
                removed(1),
                saved(4),
                SessionUpdate::Saved(consuming(5, 8)),
                SessionUpdate::Live(LiveUpdate::State {
                    state: SessionState::Running
                }),
                accepted(7),
                job(),
                // A client drops the second copy of input 7. The commit 5 consumed input 8, so its copy is gone.
                accepted(7),
                accepted(9),
                saved(6),
                job(),
                removed(3),
            ]
        );
    }

    #[test]
    fn an_input_accepted_that_comes_after_its_consumption_or_removal_is_dropped() {
        let recorder = Arc::new(Recorder::default());
        let output = output(&recorder);

        output.publish(SessionUpdate::Saved(consuming(5, 8)));
        output.publish(accepted(8));
        output.publish(removed(9));
        output.publish(accepted(9));
        output.publish(accepted(10));

        assert_eq!(
            *lock(&recorder.0),
            [SessionUpdate::Saved(consuming(5, 8)), removed(9), accepted(10)]
        );
    }

    #[test]
    fn a_load_that_fails_sends_the_kept_updates() {
        let recorder = Arc::new(Recorder::default());
        let output = output(&recorder);

        let hold = Hold::start(&output);
        output.publish(saved(5));
        drop(hold);
        output.publish(removed(1));

        assert_eq!(*lock(&recorder.0), [saved(5), removed(1)]);
    }
}
