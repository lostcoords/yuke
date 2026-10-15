//! One open session: a task that runs its turns, and the parts that the app shares with that task.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tokio::sync::{Notify, OwnedMutexGuard};
use tokio::task::JoinHandle;
use yuke_agent::{InputSender, Session, SessionError, SessionObserver, StoreError};
use yuke_ai::{Block, Target};
use yuke_engine::{CancellationToken, Driver, Outcome, Toolset};
use yuke_js::{JobEnded, Runtime, SessionHost};
use yuke_protocol::{
    EventNumber, Input, InputId, InputSource, Job, LiveUpdate, LoadSessionResult, NoticeLevel, NoticeParams,
    ServerNotification, SessionEvent, SessionId, SessionSettings, SessionState, SessionUpdate, SessionUpdateParams,
    StoredEvent,
};

use super::{AppError, Observer, SOURCE, Shared, TokioTimer, canonical, describe, lock, target_of, warn};

/// The source of the input that a background job sends when it ends.
const JOBS_SOURCE: &str = "host:jobs";

/// An open session.
pub(super) struct LiveSession {
    inbox: Inbox,
    /// The session and its target. A turn holds the lock for its whole run, so new settings never meet a turn.
    core: Arc<tokio::sync::Mutex<Core>>,
    /// The cancellation token of the running turn, or `None` while the session is idle.
    turn: Arc<Mutex<Option<CancellationToken>>>,
    /// Ends the task. The token of each turn is a child of it.
    closed: CancellationToken,
    /// The host of the tools. The jobs of the session belong to it.
    host: Arc<Host>,
    shared: Arc<Shared>,
    task: JoinHandle<()>,
}

/// The parts of a session that only a turn or a change of the settings use.
struct Core {
    session: Session,
    target: Target,
}

impl LiveSession {
    /// Load the tools of `session`, and start its task, which runs its turns on `target`.
    pub(super) async fn start(
        session: Session,
        target: Target,
        runtime: &Runtime,
        shared: Arc<Shared>,
    ) -> Result<LiveSession, AppError> {
        let inbox = Inbox {
            input: session.input(),
            wake: Arc::new(Notify::new()),
            output: Arc::new(Output {
                session: session.id(),
                observer: Arc::clone(&shared.observer),
                held: Mutex::default(),
            }),
        };
        let host = Arc::new(Host {
            folder: Mutex::new(session.settings().cwd.clone()),
            shared: Arc::clone(&shared),
            inbox: inbox.clone(),
        });
        // The tools read the folder of the host at each call, so a change of the folder needs no new tools.
        let mut toolset = Toolset::new();
        let tools = runtime
            .tools(Arc::clone(&host) as Arc<dyn SessionHost>)
            .await
            .map_err(|error| AppError::Internal(describe(&error)))?;
        for (definition, tool) in tools {
            toolset
                .add(definition, tool)
                .map_err(|error| AppError::Internal(describe(&error)))?;
        }
        let core = Arc::new(tokio::sync::Mutex::new(Core { session, target }));
        let turn = Arc::default();
        let closed = CancellationToken::new();
        let task = SessionTask {
            core: Arc::clone(&core),
            toolset: Arc::new(toolset),
            shared: Arc::clone(&shared),
            inbox: inbox.clone(),
            turn: Arc::clone(&turn),
            closed: closed.clone(),
        };
        Ok(LiveSession {
            inbox,
            core,
            turn,
            closed,
            host,
            shared,
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

    /// Save `input`, show it to the observer, and wake the task.
    pub(super) async fn accept(&self, input: Input) -> Result<InputId, StoreError> {
        self.inbox.accept(input).await
    }

    /// Remove the pending input `input_id`, and tell the observer.
    pub(super) async fn remove(&self, input_id: InputId) -> Result<(), StoreError> {
        self.inbox.remove(input_id).await
    }

    /// Send the saved events after `after`, and answer the pending inputs and the state. The live updates that come
    /// during the read wait, so the observer sees each saved event in order and once.
    pub(super) async fn load(&self, after: Option<EventNumber>) -> Result<LoadSessionResult, AppError> {
        let hold = Hold::start(&self.inbox.output);
        let loaded = self
            .shared
            .store
            .load(self.inbox.output.session, after)
            .await
            .map_err(AppError::Store)?;
        hold.release(loaded.events);
        Ok(LoadSessionResult {
            pending: loaded.pending,
            state: self.state(),
        })
    }

    /// Save `settings`. It fails while a turn runs or input waits, and it never waits for a turn. The session keeps its
    /// system prompt.
    pub(super) async fn set_settings(&self, mut settings: SessionSettings) -> Result<(), AppError> {
        let Ok(mut core) = self.core.try_lock() else {
            return Err(AppError::Busy);
        };
        // A turn starts only under the lock, so an input that comes after this check runs with the new settings.
        let waiting = self
            .shared
            .store
            .pending(self.inbox.output.session)
            .await
            .map_err(AppError::Store)?;
        if !waiting.is_empty() {
            return Err(AppError::Busy);
        }
        settings
            .settings
            .system
            .clone_from(&core.session.settings().settings.system);
        settings.cwd = canonical(settings.cwd).await?;
        let target = target_of(&settings, &*self.shared.machine.variable)?;
        let event_number = core
            .session
            .set_settings(settings.clone())
            .await
            .map_err(AppError::Store)?;
        core.target = target;
        lock(&self.host.folder).clone_from(&settings.cwd);
        self.inbox.output.publish(SessionUpdate::Saved(StoredEvent {
            event_number,
            event: SessionEvent::Settings(settings),
        }));
        Ok(())
    }

    /// The running background jobs, oldest first.
    pub(super) fn jobs(&self) -> Vec<Job> {
        self.shared.processes.running_jobs(&self.owner())
    }

    /// Stop the running job `id`, and wait for its end. Answer `false` when no such job runs.
    pub(super) async fn stop_job(&self, id: &str) -> bool {
        self.shared.processes.stop_job(id, &self.owner()).await.is_some()
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
        // After the task, so a job that the cancelled turn started also stops.
        self.shared.processes.close_owner(&self.owner()).await;
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
struct Inbox {
    input: InputSender,
    /// Wakes the task to run the waiting input. Many wakes before the task runs count as one.
    wake: Arc<Notify>,
    output: Arc<Output>,
}

impl Inbox {
    /// Save `input`, show it to the observer, and wake the task. The task runs a turn when the session is idle.
    async fn accept(&self, input: Input) -> Result<InputId, StoreError> {
        let input_id = self.input.send(input.clone()).await?;
        self.output
            .publish(SessionUpdate::Live(LiveUpdate::InputAccepted { input_id, input }));
        self.wake.notify_one();
        Ok(input_id)
    }

    /// Remove the pending input `input_id`, and tell the observer.
    async fn remove(&self, input_id: InputId) -> Result<(), StoreError> {
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
    /// The updates that wait for the end of a load, or `None` while no load runs.
    held: Mutex<Option<Vec<SessionUpdate>>>,
}

impl Output {
    /// Send `update` to the observer, or keep it while a load runs.
    fn publish(&self, update: SessionUpdate) {
        let mut held = lock(&self.held);
        match held.as_mut() {
            Some(held) => held.push(update),
            None => self.send(update),
        }
    }

    fn send(&self, update: SessionUpdate) {
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
        lock(&output.held).get_or_insert_with(Vec::new);
        Hold { output }
    }

    /// Send `events`, then the kept updates without the saved events that `events` already holds.
    fn release(self, events: Vec<StoredEvent>) {
        let mut held = lock(&self.output.held);
        let last = events.last().map(|event| event.event_number);
        for event in events {
            self.output.send(SessionUpdate::Saved(event));
        }
        for update in held.take().unwrap_or_default() {
            let sent =
                matches!((&update, last), (SessionUpdate::Saved(event), Some(last)) if event.event_number <= last);
            if !sent {
                self.output.send(update);
            }
        }
    }
}

impl Drop for Hold<'_> {
    fn drop(&mut self) {
        let mut held = lock(&self.output.held);
        for update in held.take().unwrap_or_default() {
            self.output.send(update);
        }
    }
}

/// The task of one session.
struct SessionTask {
    core: Arc<tokio::sync::Mutex<Core>>,
    toolset: Arc<Toolset>,
    shared: Arc<Shared>,
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
            match self.shared.store.pending(output.session).await {
                Ok(pending) if !pending.is_empty() => {}
                Ok(_) => return,
                Err(error) => {
                    output.notice(NoticeLevel::Error, &describe(&error));
                    return;
                }
            }
            let core = Arc::clone(&self.core).lock_owned().await;
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
            // The turn runs in its own task, so a panic of the turn cannot leave the session running.
            let ended = tokio::spawn(run_turn(
                core,
                Arc::clone(&self.shared),
                Arc::clone(&self.toolset),
                Arc::clone(output),
                token,
            ))
            .await;
            *lock(&self.turn) = None;
            output.publish(SessionUpdate::Live(LiveUpdate::State {
                state: SessionState::Idle,
            }));
            match ended {
                Ok(Ok(_) | Err(SessionError::Model(_) | SessionError::NoInput)) => {}
                // A store failure waits for the next wake, so it does not repeat at once.
                Ok(Err(SessionError::Store(error))) => {
                    output.notice(NoticeLevel::Error, &describe(&error));
                    return;
                }
                // The session in memory can be wrong after a panic, so the task ends. A load opens it again.
                Err(error) => {
                    output.notice(
                        NoticeLevel::Error,
                        &format!("the turn failed: {error}. Close the session and load it again."),
                    );
                    self.closed.cancel();
                    return;
                }
            }
        }
    }
}

/// Run one turn of the session in `core`. A model failure is saved as the end of the turn.
async fn run_turn(
    mut core: OwnedMutexGuard<Core>,
    shared: Arc<Shared>,
    toolset: Arc<Toolset>,
    output: Arc<Output>,
    token: CancellationToken,
) -> Result<Outcome, SessionError> {
    let Core { session, target } = &mut *core;
    let driver = Driver::new(&*shared.machine.transport, target, &TokioTimer).toolset(&toolset);
    session
        .turn(driver)
        .observer(&*output)
        .cancellation_token(token)
        .run()
        .await
}

/// The session of the tools: its folder, its blob store, and the input of its background jobs.
struct Host {
    /// The folder of the session. New settings change it between turns.
    folder: Mutex<PathBuf>,
    shared: Arc<Shared>,
    inbox: Inbox,
}

#[async_trait]
impl SessionHost for Host {
    fn folder(&self) -> PathBuf {
        lock(&self.folder).clone()
    }

    async fn put_media(&self, bytes: Vec<u8>) -> Result<yuke_ai::Blob, String> {
        self.shared
            .store
            .put_blob(self.inbox.output.session, bytes)
            .await
            .map_err(|error| describe(&error))
    }

    // The end of a job is an input of `host:jobs`. The user sees a short line, and the model reads the whole text. The
    // input starts a turn when the session is idle.
    async fn job_ended(&self, ended: JobEnded) {
        let source = InputSource::Plugin {
            name: JOBS_SOURCE.to_owned(),
        };
        let job_input = Input::new(source, vec![Block::user_text(format!("{} ended", ended.id))])
            .and_then(|job_input| job_input.with_model_content(vec![Block::user_text(ended.text)]));
        let accepted = match job_input {
            Ok(job_input) => self.inbox.accept(job_input).await.map_err(|error| describe(&error)),
            Err(error) => Err(describe(&error)),
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
            held: Mutex::default(),
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

    #[test]
    fn updates_during_a_load_follow_its_saved_events_and_each_saved_event_comes_once() {
        let recorder = Arc::new(Recorder::default());
        let output = output(&recorder);

        output.publish(removed(1));
        let hold = Hold::start(&output);
        output.publish(saved(5));
        output.publish(removed(2));
        output.publish(saved(6));
        hold.release(vec![stored(4), stored(5)]);
        output.publish(removed(3));

        assert_eq!(
            *lock(&recorder.0),
            [removed(1), saved(4), saved(5), removed(2), saved(6), removed(3)]
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
