//! One open session of the server: a task that runs its turns, and the parts that the server shares with that task.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use tokio::sync::Notify;
use tokio::task::JoinHandle;
use yuke_agent::{InputSender, Session, SessionError, Store, StoreError};
use yuke_ai::{Block, Target};
use yuke_engine::{CancellationToken, Driver, Toolset};
use yuke_js::{JobEnded, Processes, Runtime, SessionHost};
use yuke_protocol::{
    Input, InputId, InputSource, Job, LiveUpdate, NoticeLevel, ResponseError, SessionEvent, SessionId, SessionSettings,
    SessionState, SessionUpdate, StoredEvent,
};

use super::{Setup, Writer, canonical, error_with, internal, store_error, target_of};
use crate::print::{TokioTimer, describe};

/// The source of the input that a background job sends when it ends.
const JOBS_SOURCE: &str = "host:jobs";

/// What the server keeps of an open session.
pub(super) struct OpenSession {
    pub(super) inbox: Inbox,
    /// The session and its target. A turn holds the lock for its whole run, so new settings never meet a turn.
    core: Arc<tokio::sync::Mutex<Core>>,
    /// The cancellation token of the running turn, or `None` while the session is idle.
    turn: Arc<Mutex<Option<CancellationToken>>>,
    /// Ends the task. The token of each turn is a child of it.
    closed: CancellationToken,
    /// The host of the tools. The jobs of the session belong to it.
    host: Arc<Host>,
    processes: Arc<Processes>,
    task: JoinHandle<()>,
}

/// The parts of a session that only a turn or a change of the settings use.
struct Core {
    session: Session,
    target: Target,
}

impl OpenSession {
    /// Load the tools of `session`, and start its task, which runs its turns on `target`.
    pub(super) async fn start(
        session: Session,
        target: Target,
        store: Arc<dyn Store>,
        runtime: &Runtime,
        setup: Arc<Setup>,
        writer: Writer,
        processes: Arc<Processes>,
    ) -> Result<OpenSession, ResponseError> {
        let inbox = Inbox {
            session: session.id(),
            input: session.input(),
            wake: Arc::new(Notify::new()),
            writer,
        };
        let host = Arc::new(Host {
            folder: Mutex::new(session.settings().cwd.clone()),
            store: Arc::clone(&store),
            inbox: inbox.clone(),
        });
        // The tools read the folder of the host at each call, so a change of the folder needs no new tools.
        let mut toolset = Toolset::new();
        let tools = runtime
            .tools(Arc::clone(&host) as Arc<dyn SessionHost>)
            .await
            .map_err(|error| internal(&describe(&error)))?;
        for (definition, tool) in tools {
            toolset
                .add(definition, tool)
                .map_err(|error| internal(&describe(&error)))?;
        }
        let core = Arc::new(tokio::sync::Mutex::new(Core { session, target }));
        let turn = Arc::default();
        let closed = CancellationToken::new();
        let task = SessionTask {
            core: Arc::clone(&core),
            toolset,
            store,
            setup,
            inbox: inbox.clone(),
            turn: Arc::clone(&turn),
            closed: closed.clone(),
        };
        Ok(OpenSession {
            inbox,
            core,
            turn,
            closed,
            host,
            processes,
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

    /// Save `settings`. It fails while a turn runs or input waits, and it never waits for a turn. The server keeps the
    /// system prompt of the session.
    pub(super) async fn set_settings(
        &self,
        mut settings: SessionSettings,
        store: &dyn Store,
        setup: &Setup,
    ) -> Result<(), ResponseError> {
        let busy = || {
            error_with(
                ResponseError::INVALID_REQUEST,
                "a turn runs or waits: change the settings after it ends",
            )
        };
        let Ok(mut core) = self.core.try_lock() else {
            return Err(busy());
        };
        // A turn starts only under the lock, so an input that comes after this check runs with the new settings.
        let waiting = store
            .pending(self.inbox.session)
            .await
            .map_err(|error| store_error(&error))?;
        if !waiting.is_empty() {
            return Err(busy());
        }
        settings
            .settings
            .system
            .clone_from(&core.session.settings().settings.system);
        settings.cwd = canonical(&settings.cwd)?;
        let target = target_of(&settings, &*setup.variable)?;
        let event_number = core
            .session
            .set_settings(settings.clone())
            .await
            .map_err(|error| store_error(&error))?;
        core.target = target;
        lock(&self.host.folder).clone_from(&settings.cwd);
        self.inbox.writer.update(
            self.inbox.session,
            SessionUpdate::Saved(StoredEvent {
                event_number,
                event: SessionEvent::Settings(settings),
            }),
        );
        Ok(())
    }

    /// The running background jobs, oldest first.
    pub(super) fn jobs(&self) -> Vec<Job> {
        self.processes.running_jobs(&self.owner())
    }

    /// Stop the running job `id`, and wait for its end. Answer `false` when no such job runs.
    pub(super) async fn stop_job(&self, id: &str) -> bool {
        self.processes.stop_job(id, &self.owner()).await.is_some()
    }

    /// Stop the running turn, wait for the task to end, and stop the jobs. Waiting input stays saved and starts no
    /// turn.
    pub(super) async fn close(self) {
        let owner = self.owner();
        {
            // The task starts a turn under the same lock, so a turn starts either before the close and ends cancelled,
            // or not at all and leaves its input pending.
            let _turn = lock(&self.turn);
            self.closed.cancel();
        }
        if let Err(error) = self.task.await {
            crate::print::warn(&format!("a session task failed: {error}"));
        }
        // After the task, so a job that the cancelled turn started also stops.
        self.processes.close_owner(&owner).await;
    }

    /// The owner of the jobs of the session.
    fn owner(&self) -> Arc<dyn SessionHost> {
        Arc::clone(&self.host) as Arc<dyn SessionHost>
    }
}

/// The input of one session: the saved queue, the client, and the wake of the task.
#[derive(Clone)]
pub(super) struct Inbox {
    session: SessionId,
    input: InputSender,
    /// Wakes the task to run the waiting input. Many wakes before the task runs count as one.
    wake: Arc<Notify>,
    writer: Writer,
}

impl Inbox {
    /// Save `input`, show it to the client, and wake the task. The task runs a turn when the session is idle.
    pub(super) async fn accept(&self, input: Input) -> Result<InputId, StoreError> {
        let input_id = self.input.send(input.clone()).await?;
        self.writer.update(
            self.session,
            SessionUpdate::Live(LiveUpdate::InputAccepted { input_id, input }),
        );
        self.wake.notify_one();
        Ok(input_id)
    }

    /// Remove the pending input `input_id`, and tell the client.
    pub(super) async fn remove(&self, input_id: InputId) -> Result<(), StoreError> {
        self.input.remove(input_id).await?;
        self.writer
            .update(self.session, SessionUpdate::Live(LiveUpdate::InputRemoved { input_id }));
        Ok(())
    }
}

/// The task of one session.
struct SessionTask {
    core: Arc<tokio::sync::Mutex<Core>>,
    toolset: Toolset,
    store: Arc<dyn Store>,
    setup: Arc<Setup>,
    inbox: Inbox,
    turn: Arc<Mutex<Option<CancellationToken>>>,
    closed: CancellationToken,
}

impl SessionTask {
    /// Run the waiting input at each wake, until the server closes the session.
    async fn run(mut self) {
        // An open alone runs nothing, so a load only reads. The waiting input runs at the next wake.
        loop {
            tokio::select! {
                () = self.inbox.wake.notified() => self.run_waiting_turns().await,
                () = self.closed.cancelled() => return,
            }
        }
    }

    /// Run one turn after another while input waits.
    async fn run_waiting_turns(&mut self) {
        let id = self.inbox.session;
        loop {
            // The check comes before the lock, so a wake with no input never makes new settings fail.
            match self.store.pending(id).await {
                Ok(pending) if !pending.is_empty() => {}
                Ok(_) => return,
                Err(error) => {
                    self.inbox
                        .writer
                        .notice(Some(id), NoticeLevel::Error, &describe(&error));
                    return;
                }
            }
            let mut core = self.core.lock().await;
            let token = {
                let mut turn = lock(&self.turn);
                if self.closed.is_cancelled() {
                    return;
                }
                let token = self.closed.child_token();
                *turn = Some(token.clone());
                token
            };
            self.inbox.writer.update(
                id,
                SessionUpdate::Live(LiveUpdate::State {
                    state: SessionState::Running,
                }),
            );
            let Core { session, target } = &mut *core;
            let driver = Driver::new(&*self.setup.transport, target, &TokioTimer).toolset(&self.toolset);
            let ended = session
                .turn(driver)
                .observer(&self.inbox.writer)
                .cancellation_token(token)
                .run()
                .await;
            *lock(&self.turn) = None;
            drop(core);
            self.inbox.writer.update(
                id,
                SessionUpdate::Live(LiveUpdate::State {
                    state: SessionState::Idle,
                }),
            );
            // A model failure is saved as the end of its turn. A store failure waits for the next wake, so it does
            // not repeat at once.
            if let Err(SessionError::Store(error)) = ended {
                self.inbox
                    .writer
                    .notice(Some(id), NoticeLevel::Error, &describe(&error));
                return;
            }
        }
    }
}

/// The session of the tools: its folder, its blob store, and the input of its background jobs.
struct Host {
    /// The folder of the session. New settings change it between turns.
    folder: Mutex<PathBuf>,
    store: Arc<dyn Store>,
    inbox: Inbox,
}

#[async_trait]
impl SessionHost for Host {
    fn folder(&self) -> PathBuf {
        lock(&self.folder).clone()
    }

    async fn put_media(&self, bytes: Vec<u8>) -> Result<yuke_ai::Blob, String> {
        self.store
            .put_blob(self.inbox.session, bytes)
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
            self.inbox
                .writer
                .notice(Some(self.inbox.session), NoticeLevel::Error, &text);
        }
    }
}

/// Lock `mutex`. A panic of another holder leaves a valid value.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
