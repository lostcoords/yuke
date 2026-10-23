//! One open session: a task that runs its turns, and the parts that the app shares with that task.

use std::collections::btree_map::Entry;
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tokio::sync::{Notify, oneshot};
use tokio::task::JoinHandle;
use yuke_agent::{Loaded, Session, SessionError, SessionObserver, Store, StoreError};
use yuke_ai::ToolDefinition;
use yuke_engine::{CancellationToken, Driver, MediaStore, Model, Toolset, chain_text};
use yuke_js::{Runtime, ScriptSession, ScriptTool, SessionHost};
use yuke_mcp::{McpTool, OnChange, Servers};
use yuke_protocol::{
    EventNumber, Input, InputId, InteractionId, InteractionRequest, InteractionResponse, Job, LiveUpdate, McpServer,
    ModelReference, NoticeLevel, NoticeParams, ServerNotification, SessionEvent, SessionId, SessionSettings,
    SessionState, SessionUpdate, SessionUpdateParams, StoredEvent,
};

use super::trust;
use super::{AppError, Mode, Observer, SOURCE, Shared, TokioTimer, lock, model_of, save_settings, warn};
use crate::config::read_json;

/// An open session.
pub(super) struct LiveSession {
    parts: Arc<Parts>,
    task: JoinHandle<()>,
}

/// The parts of an open session that the app and the task of the session share.
struct Parts {
    /// A turn holds the lock for its whole run, so new settings never meet a turn.
    session: Arc<tokio::sync::Mutex<Session>>,
    /// The cancellation token of the running turn, or `None` while the session is idle.
    turn: Mutex<Option<CancellationToken>>,
    /// The host of the tools. The jobs of the session belong to the host. The `closed` token of the host ends the task,
    /// and the token of each turn is a child of that token.
    host: Arc<Host>,
    /// The session of the plugins. Each turn takes its tools. A reload replaces it while it holds the session lock.
    script: Mutex<Arc<ScriptSession>>,
    /// The MCP servers of the session. Each turn takes their tools.
    servers: Servers,
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
            store: Arc::clone(&shared.store),
            wake: Arc::new(Notify::new()),
            output: Arc::new(Output {
                session: session.id(),
                observer: Arc::clone(&shared.observer),
                sent: Mutex::default(),
                last_question: Arc::clone(&shared.last_question),
            }),
        };
        let host = Arc::new(Host {
            settings: Mutex::new(session.settings().clone()),
            shared,
            inbox,
            closed: CancellationToken::new(),
        });
        let script = runtime
            .open_session(Arc::clone(&host) as Arc<dyn SessionHost>)
            .await
            .map_err(|error| AppError::Internal(chain_text(&error)))?;
        let servers = start_servers(&host, &session.settings().cwd);
        let parts = Arc::new(Parts {
            session: Arc::new(tokio::sync::Mutex::new(session)),
            turn: Mutex::default(),
            host,
            script: Mutex::new(Arc::new(script)),
            servers,
        });
        Ok(LiveSession {
            task: tokio::spawn(Arc::clone(&parts).run()),
            parts,
        })
    }

    /// The inbox of the session. The app saves and removes input through the inbox.
    pub(super) fn inbox(&self) -> &Inbox {
        &self.parts.host.inbox
    }

    /// Each MCP server of the session and its state.
    pub(super) fn mcp_servers(&self) -> Vec<McpServer> {
        self.parts.servers.states()
    }

    /// The lock of the session, so no turn starts while the caller holds it. `None` while a turn runs or starts.
    pub(super) fn hold(&self) -> Option<tokio::sync::OwnedMutexGuard<Session>> {
        Arc::clone(&self.parts.session).try_lock_owned().ok()
    }

    /// Open the plugins of the session in the JavaScript runtime `runtime`. The session keeps its host and its jobs.
    pub(super) async fn open_plugins(&self, runtime: &Runtime) -> Result<ScriptSession, AppError> {
        runtime
            .open_session(self.owner())
            .await
            .map_err(|error| AppError::Internal(chain_text(&error)))
    }

    /// Give the next turn the tools and hooks of `script`, and close the old plugins. The caller holds the guard of
    /// [`LiveSession::hold`], so no turn uses the old plugins.
    pub(super) async fn replace_plugins(&self, script: ScriptSession) {
        let old = std::mem::replace(&mut *lock(&self.parts.script), Arc::new(script));
        if let Err(error) = old.close().await {
            warn(&format!(
                "the plugins of a session did not close: {}",
                chain_text(&error)
            ));
        }
    }

    /// Whether a turn runs.
    pub(super) fn state(&self) -> SessionState {
        if lock(&self.parts.turn).is_some() {
            SessionState::Running
        } else {
            SessionState::Idle
        }
    }

    /// Give `response` to the open question `id`.
    pub(super) fn answer(&self, id: InteractionId, response: InteractionResponse) -> Result<(), AppError> {
        self.parts.host.inbox.output.answer(id, response)
    }

    /// Cancel the running turn.
    pub(super) fn cancel(&self) {
        if let Some(token) = lock(&self.parts.turn).as_ref() {
            token.cancel();
        }
    }

    /// Send the session as updates: the saved events after `after`, the state, the pending inputs, and the running
    /// jobs. The live updates that come during the load follow them, without the ones that they hold.
    pub(super) async fn load(&self, after: Option<EventNumber>) -> Result<(), AppError> {
        let host = &self.parts.host;
        let hold = Hold::start(&host.inbox.output);
        let loaded = host
            .shared
            .store
            .load(host.inbox.output.session, after)
            .await
            .map_err(AppError::Store)?;
        hold.release(loaded, || (self.state(), self.jobs(), self.parts.servers.states()));
        Ok(())
    }

    /// Save `settings`. It fails while a turn runs or input waits, and it never waits for a turn. The session keeps its
    /// system prompt.
    pub(super) async fn set_settings(&self, settings: SessionSettings) -> Result<(), AppError> {
        let Ok(mut session) = self.parts.session.try_lock() else {
            return Err(AppError::Busy);
        };
        let host = &self.parts.host;
        let output = &host.inbox.output;
        // A turn starts only under the lock, so an input that comes after this check runs with the new settings.
        let waiting = host
            .shared
            .store
            .pending(output.session)
            .await
            .map_err(AppError::Store)?;
        if !waiting.is_empty() {
            return Err(AppError::Busy);
        }
        if session.is_stale() {
            recover(&mut session, output).await?;
        }
        let saved = save_settings(&mut session, settings, &host.shared).await?;
        lock(&host.settings).clone_from(session.settings());
        output.publish(SessionUpdate::Saved(saved));
        Ok(())
    }

    /// The running background jobs, oldest first.
    pub(super) fn jobs(&self) -> Vec<Job> {
        self.parts.host.shared.processes.running_jobs(&self.owner())
    }

    /// Stop the running job `id`, and wait for its end. Answer `false` when no such job runs.
    pub(super) async fn stop_job(&self, id: &str) -> bool {
        self.parts
            .host
            .shared
            .processes
            .stop_job(id, &self.owner())
            .await
            .is_some()
    }

    /// Stop the running turn, and start no other.
    pub(super) fn stop(&self) {
        // The task starts a turn under the same lock, so a turn starts either before the stop and ends cancelled, or
        // not at all and leaves its input pending.
        let _turn = lock(&self.parts.turn);
        self.parts.host.closed.cancel();
    }

    /// Stop the running turn, wait for the task to end, and stop the jobs. Waiting input stays saved and starts no
    /// turn.
    pub(super) async fn close(mut self) {
        self.stop();
        if let Err(error) = (&mut self.task).await {
            warn(&format!("a session task failed: {error}"));
        }
        // After the task, so no turn takes the tools of the closed plugins.
        let script = Arc::clone(&lock(&self.parts.script));
        if let Err(error) = script.close().await {
            warn(&format!(
                "the plugins of a session did not close: {}",
                chain_text(&error)
            ));
        }
        // After the task, so a job that the cancelled turn started also stops.
        self.parts.host.shared.processes.close_owner(&self.owner()).await;
        self.parts.servers.close().await;
    }

    /// The owner of the jobs of the session.
    fn owner(&self) -> Arc<dyn SessionHost> {
        Arc::clone(&self.parts.host) as Arc<dyn SessionHost>
    }
}

// A session that the app drops without a close still ends its task and its turn.
impl Drop for LiveSession {
    fn drop(&mut self) {
        self.parts.host.closed.cancel();
    }
}

/// The input of one session: the saved queue, the observer, and the wake of the task.
#[derive(Clone)]
pub(super) struct Inbox {
    store: Arc<dyn Store>,
    /// Wakes the task to run the waiting input. Many wakes before the task runs count as one.
    wake: Arc<Notify>,
    output: Arc<Output>,
}

impl Inbox {
    /// Save `input`, show it to the observer, and wake the task. The task runs a turn when the session is idle.
    pub(super) async fn accept(&self, input: Input) -> Result<InputId, StoreError> {
        let input_id = self.store.accept_input(self.output.session, input.clone()).await?;
        self.output
            .publish(SessionUpdate::Live(LiveUpdate::InputAccepted { input_id, input }));
        self.wake.notify_one();
        Ok(input_id)
    }

    /// Remove the pending input `input_id`, and tell the observer.
    pub(super) async fn remove(&self, input_id: InputId) -> Result<(), StoreError> {
        self.store.remove_input(self.output.session, input_id).await?;
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
    /// The id of the last question of any session, so an id names one question also after a close and a load.
    last_question: Arc<AtomicU64>,
}

/// What the output keeps under its lock.
#[derive(Default)]
struct Sent {
    /// The updates that wait for the end of a load, or `None` while no load runs.
    held: Option<Vec<SessionUpdate>>,
    /// The inputs that a sent commit consumed or a sent removal named. An `input_accepted` can come after them, because
    /// the store saves an input before the server sends it, so the output drops it.
    gone: HashSet<InputId>,
    /// The open questions. A load sends them, so they live under the same lock as the updates.
    questions: BTreeMap<InteractionId, Question>,
}

/// An open question of the session.
struct Question {
    source: String,
    request: InteractionRequest,
    /// Takes the answer of the user.
    answer: oneshot::Sender<InteractionResponse>,
}

impl Output {
    /// Send `update` to the observer, or keep it while a load runs.
    fn publish(&self, update: SessionUpdate) {
        let mut sent = lock(&self.sent);
        self.publish_in(&mut sent, update);
    }

    fn publish_in(&self, sent: &mut Sent, update: SessionUpdate) {
        match sent.held.as_mut() {
            Some(held) => held.push(update),
            None => self.send(sent, update),
        }
    }

    /// Open the question `request` of `source`, and return its id and the receiver of its answer.
    fn ask(
        &self,
        source: &str,
        request: InteractionRequest,
    ) -> (InteractionId, oneshot::Receiver<InteractionResponse>) {
        let mut sent = lock(&self.sent);
        let id = InteractionId(self.last_question.fetch_add(1, Ordering::Relaxed) + 1);
        let (answer, answered) = oneshot::channel();
        let update = LiveUpdate::InteractionRequested {
            interaction_id: id,
            source: source.to_owned(),
            request: request.clone(),
        };
        sent.questions.insert(
            id,
            Question {
                source: source.to_owned(),
                request,
                answer,
            },
        );
        self.publish_in(&mut sent, SessionUpdate::Live(update));
        (id, answered)
    }

    /// End the question `id` without an answer, when it is still open.
    fn close_question(&self, id: InteractionId) {
        let mut sent = lock(&self.sent);
        if sent.questions.remove(&id).is_some() {
            let update = LiveUpdate::InteractionClosed { interaction_id: id };
            self.publish_in(&mut sent, SessionUpdate::Live(update));
        }
    }

    /// End the open question `id` with `response`.
    fn answer(&self, id: InteractionId, response: InteractionResponse) -> Result<(), AppError> {
        let mut sent = lock(&self.sent);
        let Entry::Occupied(open) = sent.questions.entry(id) else {
            return Err(AppError::NoInteraction(id));
        };
        check_answer(&open.get().request, &response)?;
        let question = open.remove();
        let update = LiveUpdate::InteractionClosed { interaction_id: id };
        self.publish_in(&mut sent, SessionUpdate::Live(update));
        // The asker closes the question before it stops waiting, so an open question has a receiver.
        question.answer.send(response).map_err(|_| AppError::NoInteraction(id))
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
    fn update(&self, update: SessionUpdate) {
        self.publish(update);
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
    fn release(self, loaded: Loaded, now: impl FnOnce() -> (SessionState, Vec<Job>, Vec<McpServer>)) {
        let mut sent = lock(&self.output.sent);
        let last = loaded.events.last().map(|event| event.event_number);
        let (state, jobs, servers) = now();
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
        for server in servers {
            self.output
                .send(&mut sent, SessionUpdate::Live(LiveUpdate::McpServer { server }));
        }
        let questions: Vec<LiveUpdate> = sent
            .questions
            .iter()
            .map(|(id, question)| LiveUpdate::InteractionRequested {
                interaction_id: *id,
                source: question.source.clone(),
                request: question.request.clone(),
            })
            .collect();
        for update in questions {
            self.output.send(&mut sent, SessionUpdate::Live(update));
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

impl Parts {
    /// Run the task of the session. Each wake runs the pending input, until the app closes the session.
    async fn run(self: Arc<Self>) {
        // An open alone runs nothing, so a load only reads. The waiting input runs at the next wake.
        loop {
            tokio::select! {
                () = self.host.inbox.wake.notified() => self.run_waiting_turns().await,
                () = self.host.closed.cancelled() => return,
            }
        }
    }

    /// The tools of the next turn: the tools of the plugins and of the MCP servers. The first turn waits for the plugins
    /// and the servers. A cancel or a close ends the wait, and the turn then ends as cancelled, so it needs no tool.
    async fn toolset(&self, script: &ScriptSession, token: &CancellationToken) -> Result<Toolset, String> {
        tokio::select! {
            tools = async {
                let tools = script.tools().await;
                self.servers.ready().await;
                tools
            } => toolset_of(tools, self.servers.tools()),
            () = token.cancelled() => Ok(Toolset::new()),
        }
    }

    /// Run one turn after another while input waits.
    async fn run_waiting_turns(&self) {
        let output = &self.host.inbox.output;
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
            let model = match model_of(&session.settings().model, &self.host.shared) {
                Ok(model) => model,
                Err(error) => {
                    output.notice(NoticeLevel::Error, &chain_text(&error));
                    return;
                }
            };
            lock(&self.host.settings).clone_from(session.settings());
            let token = {
                let mut turn = lock(&self.turn);
                if self.host.closed.is_cancelled() {
                    return;
                }
                let token = self.host.closed.child_token();
                *turn = Some(token.clone());
                token
            };
            output.publish(SessionUpdate::Live(LiveUpdate::State {
                state: SessionState::Running,
            }));
            // The session lock is held, so a reload cannot replace the plugins during this turn.
            let script = Arc::clone(&lock(&self.script));
            let toolset = self.toolset(&script, &token).await;
            let prepared = match toolset {
                Ok(toolset) => script
                    .build_prompt(session.prompt(), &token)
                    .await
                    .map(|prompt| (toolset, prompt))
                    .map_err(|error| chain_text(&error)),
                Err(error) => Err(error),
            };
            let ended = match prepared {
                // The turn runs in its own task, so a panic of the turn cannot leave the session running.
                Ok((toolset, prompt)) => {
                    let hooks = script.hooks(token.clone());
                    let shared = Arc::clone(&self.host.shared);
                    let output = Arc::clone(output);
                    // The session saves a round failure as the end of the turn.
                    let turn = async move {
                        let mut session = session;
                        let driver = Driver::new(&*shared.machine.transport, &model, &TokioTimer)
                            .toolset(&toolset)
                            .hooks(&hooks);
                        session
                            .turn(driver)
                            .input_hook(&hooks)
                            .prompt(prompt)
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
                // A stale session recovers at the next wake, so a store failure does not repeat at once. A failed input
                // hook leaves its input pending for the next wake too.
                Ok(Err(error @ (SessionError::Store(_) | SessionError::Stale | SessionError::InputHook(_)))) => {
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
fn toolset_of(
    tools: Result<Vec<(ToolDefinition, ScriptTool)>, yuke_js::Error>,
    mcp: Vec<(ToolDefinition, McpTool)>,
) -> Result<Toolset, String> {
    let mut toolset = Toolset::new();
    for (definition, tool) in tools.map_err(|error| chain_text(&error))? {
        toolset.add(definition, tool).map_err(|error| chain_text(&error))?;
    }
    for (definition, tool) in mcp {
        toolset.add(definition, tool).map_err(|error| chain_text(&error))?;
    }
    Ok(toolset)
}

/// The source of the questions about MCP servers.
const MCP_SOURCE: &str = "host:mcp";

/// Start the MCP servers of the user config and of `.mcp.json` in `folder` for the session of `host`. The project
/// servers start after the trust. Each change of a server state is a live update of the session.
fn start_servers(host: &Arc<Host>, folder: &Path) -> Servers {
    let output = Arc::clone(&host.inbox.output);
    let project = match read_json::<yuke_mcp::Config>(&folder.join(".mcp.json")) {
        Ok(project) => project.unwrap_or_default(),
        Err(error) => {
            output.notice(NoticeLevel::Error, &error);
            yuke_mcp::Config::default()
        }
    };
    let on_change: OnChange =
        Arc::new(move |server| output.publish(SessionUpdate::Live(LiveUpdate::McpServer { server })));
    let shared = &host.shared;
    let variable = |name: &str| (shared.machine.variable)(name).and_then(|value| value.into_string().ok());
    let user: Vec<_> = shared.mcp.servers.clone().into_iter().collect();
    let entries: Vec<_> = project.servers.clone().into_iter().collect();
    let trust = trust_of(Arc::clone(host), folder.to_owned(), project);
    let media = Arc::clone(host) as Arc<dyn MediaStore>;
    Servers::start(&user, &entries, trust, &variable, folder, media, on_change)
}

/// Whether the user trusts the project servers `project` of `folder`: a kept confirm, or a yes to the question now. A
/// yes is kept. The close of the session ends the question.
async fn trust_of(host: Arc<Host>, folder: PathBuf, project: yuke_mcp::Config) -> bool {
    let output = &host.inbox.output;
    let data = &host.shared.machine.paths.data;
    let key = match trust::key(&folder, &project) {
        Ok(key) => key,
        Err(error) => {
            output.notice(
                NoticeLevel::Error,
                &format!("the project MCP servers have no key: {error}"),
            );
            return false;
        }
    };
    if trust::trusted(data, &key) {
        return true;
    }
    let question = trust::question(&folder, &project);
    if host.ask(MCP_SOURCE, question, host.closed.clone()).await != (InteractionResponse::Confirm { value: true }) {
        return false;
    }
    if let Err(error) = trust::trust(data, &key) {
        output.notice(
            NoticeLevel::Warn,
            &format!("yuke did not keep the trust of the MCP servers: {error}"),
        );
    }
    true
}

/// Closes an open question when its asker stops waiting.
struct Open<'a> {
    output: &'a Output,
    id: InteractionId,
}

impl Drop for Open<'_> {
    fn drop(&mut self) {
        self.output.close_question(self.id);
    }
}

/// Fail an answer that does not fit `request`: another kind, or an option that `request` does not offer.
fn check_answer(request: &InteractionRequest, response: &InteractionResponse) -> Result<(), AppError> {
    match (request, response) {
        (_, InteractionResponse::Canceled)
        | (InteractionRequest::Confirm { .. }, InteractionResponse::Confirm { .. })
        | (InteractionRequest::Input { .. }, InteractionResponse::Input { .. }) => Ok(()),
        (InteractionRequest::Select { options, .. }, InteractionResponse::Select { value }) => {
            if options.contains(value) {
                Ok(())
            } else {
                Err(AppError::Invalid(format!("the question offers no option {value:?}")))
            }
        }
        _ => Err(AppError::Invalid(
            "the answer is of another kind than the question".to_owned(),
        )),
    }
}

/// The session of the tools: its folder, its blob store, and the input of its background jobs.
struct Host {
    /// The settings of the session now. A saved change of the settings and each turn set them.
    settings: Mutex<SessionSettings>,
    shared: Arc<Shared>,
    inbox: Inbox,
    /// The close of the session. It ends each open question.
    closed: CancellationToken,
}

#[async_trait]
impl MediaStore for Host {
    async fn put_media(&self, bytes: Vec<u8>) -> Result<yuke_ai::Blob, String> {
        self.shared
            .store
            .put_blob(self.inbox.output.session, bytes)
            .await
            .map_err(|error| chain_text(&error))
    }
}

#[async_trait]
impl SessionHost for Host {
    fn session_id(&self) -> SessionId {
        self.inbox.output.session
    }

    fn folder(&self) -> PathBuf {
        lock(&self.settings).cwd.clone()
    }

    fn job_changed(&self, job: Job) {
        self.inbox.output.publish(SessionUpdate::Live(LiveUpdate::Job { job }));
    }

    async fn accept_input(&self, input: Input) {
        if let Err(error) = self.inbox.accept(input).await {
            self.inbox.output.notice(NoticeLevel::Error, &chain_text(&error));
        }
    }

    async fn ask(&self, source: &str, request: InteractionRequest, cancel: CancellationToken) -> InteractionResponse {
        let output = &self.inbox.output;
        if self.shared.mode == Mode::Print {
            output.notice(
                NoticeLevel::Warn,
                &format!("no client can answer the question of {source}: {}", request.title()),
            );
            return InteractionResponse::Canceled;
        }
        let (id, answered) = output.ask(source, request);
        // A dropped wait closes the question too, so an open question always has a waiter.
        let open = Open { output, id };
        let response = tokio::select! {
            answered = answered => answered.unwrap_or(InteractionResponse::Canceled),
            () = cancel.cancelled() => InteractionResponse::Canceled,
            () = self.closed.cancelled() => InteractionResponse::Canceled,
        };
        drop(open);
        response
    }

    fn model(&self, reference: &ModelReference) -> Result<Model, String> {
        model_of(reference, &self.shared).map_err(|error| chain_text(&error))
    }

    fn model_reference(&self) -> ModelReference {
        lock(&self.settings).model.clone()
    }
}

#[cfg(test)]
mod tests {
    use yuke_ai::Block;
    use yuke_protocol::{InputKind, InputSource, ModelReference};
    use yuke_testing::ScriptedTransport;

    use super::*;
    use crate::app::App;
    use crate::testing::{Place, with_key};

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
            last_question: Arc::default(),
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
                    kind: InputKind::Message,
                    display_content: None,
                    block_count: 0,
                }],
            },
        }
    }

    fn input() -> Input {
        Input::new(InputSource::User, InputKind::Message, vec![Block::user_text("go")]).unwrap()
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
        hold.release(loaded, || (SessionState::Running, vec![running_job()], Vec::new()));
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

    fn confirm() -> InteractionRequest {
        InteractionRequest::Confirm {
            title: "Run the migration?".to_owned(),
            message: String::new(),
        }
    }

    fn requested(id: u64, request: InteractionRequest) -> SessionUpdate {
        SessionUpdate::Live(LiveUpdate::InteractionRequested {
            interaction_id: InteractionId(id),
            source: "guard".to_owned(),
            request,
        })
    }

    fn closed(id: u64) -> SessionUpdate {
        SessionUpdate::Live(LiveUpdate::InteractionClosed {
            interaction_id: InteractionId(id),
        })
    }

    #[test]
    fn an_answer_closes_its_question_and_reaches_the_asker_once() {
        let recorder = Arc::new(Recorder::default());
        let output = output(&recorder);

        let (id, mut answered) = output.ask("guard", confirm());
        let first = output.answer(id, InteractionResponse::Confirm { value: true });
        let second = output.answer(id, InteractionResponse::Confirm { value: false });

        assert!(first.is_ok(), "{first:?}");
        assert!(
            matches!(second, Err(AppError::NoInteraction(InteractionId(1)))),
            "{second:?}"
        );
        assert_eq!(answered.try_recv(), Ok(InteractionResponse::Confirm { value: true }));
        assert_eq!(*lock(&recorder.0), [requested(1, confirm()), closed(1)]);
    }

    #[test]
    fn an_answer_of_another_kind_or_an_option_that_the_question_lacks_leaves_the_question_open() {
        let recorder = Arc::new(Recorder::default());
        let output = output(&recorder);
        let select = InteractionRequest::Select {
            title: "Deploy to?".to_owned(),
            options: vec!["staging".to_owned(), "production".to_owned()],
        };

        let (id, mut answered) = output.ask("guard", select.clone());
        let other_kind = output.answer(id, InteractionResponse::Confirm { value: true });
        let other_option = output.answer(
            id,
            InteractionResponse::Select {
                value: "local".to_owned(),
            },
        );
        let fitting = output.answer(
            id,
            InteractionResponse::Select {
                value: "staging".to_owned(),
            },
        );

        assert!(matches!(other_kind, Err(AppError::Invalid(_))), "{other_kind:?}");
        assert!(matches!(other_option, Err(AppError::Invalid(_))), "{other_option:?}");
        assert!(fitting.is_ok(), "{fitting:?}");
        assert_eq!(
            answered.try_recv(),
            Ok(InteractionResponse::Select {
                value: "staging".to_owned()
            })
        );
    }

    #[test]
    fn a_dropped_wait_closes_its_question_and_a_later_answer_finds_none() {
        let recorder = Arc::new(Recorder::default());
        let output = output(&recorder);

        let (id, _answered) = output.ask("guard", confirm());
        drop(Open { output: &output, id });
        let late = output.answer(id, InteractionResponse::Canceled);

        assert!(matches!(late, Err(AppError::NoInteraction(_))), "{late:?}");
        assert_eq!(*lock(&recorder.0), [requested(1, confirm()), closed(1)]);
    }

    #[test]
    fn a_load_sends_each_open_question() {
        let recorder = Arc::new(Recorder::default());
        let output = output(&recorder);

        let (first, _first) = output.ask("guard", confirm());
        let hold = Hold::start(&output);
        // The second question opens during the load, and the third opens and closes during it.
        let (_second, _second_answer) = output.ask("guard", confirm());
        let (third, _third_answer) = output.ask("guard", confirm());
        output.close_question(third);
        let loaded = Loaded {
            events: Vec::new(),
            pending: Vec::new(),
        };
        hold.release(loaded, || (SessionState::Idle, Vec::new(), Vec::new()));
        output.close_question(first);

        assert_eq!(
            *lock(&recorder.0),
            [
                requested(1, confirm()),
                SessionUpdate::Live(LiveUpdate::State {
                    state: SessionState::Idle
                }),
                requested(1, confirm()),
                requested(2, confirm()),
                // A client drops the second copy of question 2.
                requested(2, confirm()),
                requested(3, confirm()),
                closed(3),
                closed(1),
            ]
        );
    }

    #[tokio::test]
    async fn after_new_settings_the_host_names_their_model_and_folder_before_any_turn() {
        let place = Place::new(
            "live",
            "after_new_settings_the_host_names_their_model_and_folder_before_any_turn",
        );
        let machine = place.machine(Box::new(with_key), Box::new(ScriptedTransport::default()));
        let mut app = App::start(machine, Mode::Print, Arc::new(Recorder::default()))
            .await
            .unwrap();
        let first = SessionSettings {
            model: ModelReference {
                provider: "minimax".to_owned(),
                model: "MiniMax-M3".to_owned(),
            },
            settings: yuke_ai::Settings::new(),
            cwd: place.work.clone(),
        };
        let id = app.create(first.clone()).await.unwrap();
        let other = place.work.join("other");
        std::fs::create_dir(&other).unwrap();
        let model = ModelReference {
            provider: "minimax".to_owned(),
            model: "MiniMax-M2.7".to_owned(),
        };
        let changed = SessionSettings {
            model: model.clone(),
            cwd: other.clone(),
            ..first
        };

        app.set_settings(id, changed).await.unwrap();
        let host = &app.sessions[&id].parts.host;
        let named = (host.model_reference(), host.folder());
        app.shutdown().await;

        assert_eq!(named, (model, other));
    }
}
