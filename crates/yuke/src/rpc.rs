//! `yuke --rpc`: the protocol server on stdin and stdout. Each line is one JSON-RPC message. One process serves many
//! sessions.

mod session;
#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::ffi::OsString;
use std::hash::{BuildHasher, RandomState};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use serde::Serialize;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use yuke_agent::{Session, SessionObserver, Store, StoreError};
use yuke_ai::Target;
use yuke_ai::catalog;
use yuke_ai::transport::Transport;
use yuke_engine::CancellationToken;
use yuke_js::{Fault, Options, Processes, Runtime};
use yuke_protocol::{
    ClientNotification, ClientRequest, EmptyResult, EventNumber, ForkSessionResult, Implementation, InitializeResult,
    Input, InputResult, InputSource, JsonRpc, ListJobsResult, LoadSessionResult, NewSessionResult, NoticeLevel,
    NoticeParams, Notification, PROTOCOL_VERSION, Request, RequestId, Response, ResponseError, ResponseOutcome,
    ServerNotification, SessionId, SessionSettings, SessionUpdate, SessionUpdateParams,
};
use yuke_store::SqliteStore;

use self::session::OpenSession;
use crate::paths::Paths;
use crate::print::{LIMITS, describe, target, warn};
use crate::prompt::{self, Environment};

/// The most messages that wait for the client. A client that falls further behind loses its connection.
const OUTGOING_LIMIT: usize = 8192;

/// The source of the notices of the server.
const SERVER_SOURCE: &str = "host:rpc";

/// A function that reads one environment variable.
pub(crate) type Variable = dyn Fn(&str) -> Option<OsString> + Send + Sync;

/// The facts of the machine that the server reads.
pub(crate) struct Setup {
    /// The folders of the profile.
    pub(crate) paths: Paths,
    /// The home folder of the user.
    pub(crate) home: Option<PathBuf>,
    /// Reads one environment variable, for the API key of a provider.
    pub(crate) variable: Box<Variable>,
    /// Sends the requests of the model.
    pub(crate) transport: Box<dyn Transport>,
    /// The longest wait for the client to read the last messages after the end of its input.
    pub(crate) drain_limit: Duration,
}

/// Serve the client of `input` and `output` until `input` ends or the connection breaks.
///
/// # Errors
///
/// Returns a text for the user when the server cannot start.
pub(crate) async fn serve(
    setup: Setup,
    input: impl AsyncRead + Unpin,
    output: impl AsyncWrite + Unpin + Send + 'static,
) -> Result<(), String> {
    let drain_limit = setup.drain_limit;
    let setup = Arc::new(setup);
    let store: Arc<dyn Store> = Arc::new(
        SqliteStore::open(&setup.paths.data)
            .await
            .map_err(|error| describe(&error))?,
    );
    // The full outputs of the commands and the logs of the jobs go to a folder of this process.
    let processes_folder = std::env::temp_dir().join(format!(
        "yuke-{}-{:016x}",
        std::process::id(),
        RandomState::new().hash_one(0_u8)
    ));
    let processes = Arc::new(Processes::new(processes_folder.clone()));
    let (runtime, faults) = Runtime::start(Options {
        limits: LIMITS,
        cache: setup.paths.cache.join("js"),
        processes: Arc::clone(&processes),
    })
    .await
    .map_err(|error| describe(&error))?;
    let (writer, written) = Writer::start(output);
    let reporter = tokio::spawn(report(faults, writer.clone()));

    let served = match runtime.import("yuke:builtins").await {
        Ok(()) => {
            let mut server = Server {
                setup,
                store,
                runtime: &runtime,
                processes: Arc::clone(&processes),
                writer: writer.clone(),
                sessions: HashMap::new(),
                initialized: false,
            };
            server.serve(input).await;
            server.close().await;
            Ok(())
        }
        Err(error) => Err(describe(&error)),
    };

    if let Err(error) = runtime.shutdown().await {
        warn(&describe(&error));
    }
    // The shutdown of the runtime closes the channel of the faults, so the reporter ends.
    if let Err(error) = reporter.await {
        warn(&format!("yuke could not report the script faults: {error}"));
    }
    if let Err(error) = processes.shutdown().await {
        warn(&format!("{}: {error}", processes_folder.display()));
    }
    let closed = writer.closed.clone();
    drop(writer);
    let mut written = written;
    // A client that stops reading can block the last write forever, so the wait has a limit.
    let ended = if let Ok(ended) = tokio::time::timeout(drain_limit, &mut written).await {
        ended
    } else {
        warn("the client did not read the last messages");
        closed.cancel();
        written.await
    };
    if let Err(error) = ended {
        warn(&format!("the output task failed: {error}"));
    }
    served
}

/// Send each script fault to the client as a notice.
async fn report(mut faults: mpsc::UnboundedReceiver<Fault>, writer: Writer) {
    while let Some(fault) = faults.recv().await {
        writer.notice(None, NoticeLevel::Warn, &fault.to_string());
    }
}

/// The server of one client.
struct Server<'a> {
    setup: Arc<Setup>,
    store: Arc<dyn Store>,
    runtime: &'a Runtime,
    processes: Arc<Processes>,
    writer: Writer,
    sessions: HashMap<SessionId, OpenSession>,
    initialized: bool,
}

impl Server<'_> {
    /// Answer each line of `input` until it ends or the connection breaks.
    async fn serve(&mut self, input: impl AsyncRead + Unpin) {
        let mut lines = BufReader::new(input).lines();
        loop {
            tokio::select! {
                line = lines.next_line() => match line {
                    Ok(Some(line)) => self.handle(&line).await,
                    Ok(None) => return,
                    Err(error) => {
                        warn(&format!("the input broke: {error}"));
                        return;
                    }
                },
                () = self.writer.closed.cancelled() => return,
            }
        }
    }

    /// Close each session: its turn stops, and its task ends.
    async fn close(&mut self) {
        for (_, open) in self.sessions.drain() {
            open.close().await;
        }
    }

    /// Answer one line: a request gets a response, and a notification gets none.
    async fn handle(&mut self, line: &str) {
        let value: serde_json::Value = match serde_json::from_str(line) {
            Ok(value) => value,
            Err(error) => {
                return self.respond(
                    None,
                    Err(error_with(
                        ResponseError::PARSE_ERROR,
                        &format!("the message is no JSON: {error}"),
                    )),
                );
            }
        };
        if value.get("id").is_none() {
            match serde_json::from_value::<Notification<ClientNotification>>(value) {
                Ok(notification) => self.notification(notification.message),
                Err(error) => warn(&format!("a notification does not read: {error}")),
            }
            return;
        }
        let id = value
            .get("id")
            .cloned()
            .and_then(|id| serde_json::from_value::<RequestId>(id).ok());
        let method = value.get("method").cloned();
        let request = match serde_json::from_value::<Request>(value) {
            Ok(request) => request,
            Err(error) => {
                // serde names an unknown method as an unknown variant. The method alone has no params, so in its read the
                // method is the only variant that can be unknown.
                let unknown_method = method.is_some_and(|method| {
                    serde_json::from_value::<ClientRequest>(serde_json::json!({ "method": method }))
                        .is_err_and(|probe| probe.to_string().starts_with("unknown variant"))
                });
                let code = if unknown_method {
                    ResponseError::METHOD_NOT_FOUND
                } else {
                    ResponseError::INVALID_PARAMS
                };
                return self.respond(id, Err(error_with(code, &error.to_string())));
            }
        };
        let result = self.call(request.call).await;
        self.respond(Some(request.id), result);
    }

    fn respond(&self, id: Option<RequestId>, result: Result<serde_json::Value, ResponseError>) {
        self.writer.send(&Response {
            jsonrpc: JsonRpc::V2,
            id,
            outcome: match result {
                Ok(value) => ResponseOutcome::Result(value),
                Err(error) => ResponseOutcome::Error(error),
            },
        });
    }

    fn notification(&self, notification: ClientNotification) {
        match notification {
            ClientNotification::Cancel(params) => {
                if let Some(open) = self.sessions.get(&params.session_id) {
                    open.cancel();
                }
            }
        }
    }

    async fn call(&mut self, call: ClientRequest) -> Result<serde_json::Value, ResponseError> {
        if !self.initialized && !matches!(call, ClientRequest::Initialize(_)) {
            return Err(error_with(ResponseError::INVALID_REQUEST, "send initialize first"));
        }
        match call {
            ClientRequest::Initialize(_) => {
                self.initialized = true;
                // The server speaks one version, so it answers that one.
                result(&InitializeResult {
                    protocol_version: PROTOCOL_VERSION,
                    agent_info: Implementation {
                        name: "yuke".to_owned(),
                        title: None,
                        version: env!("CARGO_PKG_VERSION").to_owned(),
                    },
                })
            }
            ClientRequest::NewSession(settings) => {
                let settings = self.new_settings(settings)?;
                let target = target_of(&settings, &*self.setup.variable)?;
                let session = Session::create(Arc::clone(&self.store), &settings)
                    .await
                    .map_err(|error| store_error(&error))?;
                let session_id = self.start(session, target).await?;
                result(&NewSessionResult { session_id })
            }
            ClientRequest::ForkSession(params) => {
                let session = Session::fork(Arc::clone(&self.store), params.session_id, params.through)
                    .await
                    .map_err(|error| store_error(&error))?;
                let target = match target_of(session.settings(), &*self.setup.variable) {
                    Ok(target) => target,
                    Err(error) => {
                        // A fork that cannot run is no use, so it goes again.
                        let id = session.id();
                        drop(session);
                        self.store
                            .delete_session(id)
                            .await
                            .map_err(|error| store_error(&error))?;
                        return Err(error);
                    }
                };
                let session_id = self.start(session, target).await?;
                result(&ForkSessionResult { session_id })
            }
            ClientRequest::LoadSession(params) => self.load(params.session_id, params.after).await,
            ClientRequest::CloseSession(params) => self.close_session(params.session_id, params.stop_jobs).await,
            ClientRequest::ListJobs(params) => result(&ListJobsResult {
                jobs: self.open(params.session_id)?.jobs(),
            }),
            ClientRequest::StopJob(params) => {
                if !self.open(params.session_id)?.stop_job(&params.job_id).await {
                    return Err(error_with(
                        ResponseError::JOB_NOT_FOUND,
                        &format!("the session runs no job {}", params.job_id),
                    ));
                }
                result(&EmptyResult {})
            }
            ClientRequest::Input(params) => self.input(params.session_id, params.content).await,
            ClientRequest::RemoveInput(params) => {
                self.open(params.session_id)?
                    .inbox
                    .remove(params.input_id)
                    .await
                    .map_err(|error| store_error(&error))?;
                result(&EmptyResult {})
            }
            ClientRequest::SetSettings(params) => {
                self.open(params.session_id)?
                    .set_settings(params.settings, &*self.store, &self.setup)
                    .await?;
                result(&EmptyResult {})
            }
            // No plugin asks yet, so no question is open.
            ClientRequest::InteractionRespond(params) => Err(error_with(
                ResponseError::INVALID_PARAMS,
                &format!("no question has the id {}", params.interaction_id.0),
            )),
        }
    }

    /// Open session `id` when it is not open, send its saved events after `after`, and answer its pending inputs and
    /// its state.
    async fn load(&mut self, id: SessionId, after: Option<EventNumber>) -> Result<serde_json::Value, ResponseError> {
        if !self.sessions.contains_key(&id) {
            let session = Session::open(Arc::clone(&self.store), id)
                .await
                .map_err(|error| store_error(&error))?;
            let target = target_of(session.settings(), &*self.setup.variable)?;
            self.start(session, target).await?;
        }
        let loaded = self.store.load(id, after).await.map_err(|error| store_error(&error))?;
        for event in loaded.events {
            self.writer.update(id, SessionUpdate::Saved(event));
        }
        result(&LoadSessionResult {
            pending: loaded.pending,
            state: self.open(id)?.state(),
        })
    }

    /// Close session `id`. A session with running jobs closes only with `stop_jobs`.
    async fn close_session(&mut self, id: SessionId, stop_jobs: bool) -> Result<serde_json::Value, ResponseError> {
        let jobs = self.open(id)?.jobs();
        if !jobs.is_empty() && !stop_jobs {
            let ids: Vec<String> = jobs.into_iter().map(|job| job.id).collect();
            return Err(error_with(
                ResponseError::INVALID_REQUEST,
                &format!(
                    "the session runs the jobs {}: stop them, or close with stopJobs: true",
                    ids.join(", ")
                ),
            ));
        }
        if let Some(open) = self.sessions.remove(&id) {
            open.close().await;
        }
        result(&EmptyResult {})
    }

    /// Save `content` as an input of the user, and start a turn when the session is idle.
    async fn input(&self, id: SessionId, content: Vec<yuke_ai::Block>) -> Result<serde_json::Value, ResponseError> {
        let open = self.open(id)?;
        let input = Input::new(InputSource::User, content).map_err(|error| invalid_params(&error))?;
        let input_id = open.inbox.accept(input).await.map_err(|error| store_error(&error))?;
        result(&InputResult { input_id })
    }

    /// The settings of a new session: the folder without links, and the system prompt of that folder.
    fn new_settings(&self, mut settings: SessionSettings) -> Result<SessionSettings, ResponseError> {
        settings.cwd = canonical(&settings.cwd)?;
        settings.settings.system = prompt::system_prompt(&Environment {
            workspace: &settings.cwd,
            home: self.setup.home.as_deref(),
            shell: yuke_js::shell(),
            now: SystemTime::now(),
        })
        .map_err(|error| internal(&error))?;
        Ok(settings)
    }

    /// Start the task of `session`, and answer its id.
    async fn start(&mut self, session: Session, target: Target) -> Result<SessionId, ResponseError> {
        let id = session.id();
        let open = OpenSession::start(
            session,
            target,
            Arc::clone(&self.store),
            self.runtime,
            Arc::clone(&self.setup),
            self.writer.clone(),
            Arc::clone(&self.processes),
        )
        .await?;
        self.sessions.insert(id, open);
        Ok(id)
    }

    /// The open session `id`.
    fn open(&self, id: SessionId) -> Result<&OpenSession, ResponseError> {
        self.sessions.get(&id).ok_or_else(|| not_open(id))
    }
}

/// The error of a request for session `id` when the server has not opened it.
fn not_open(id: SessionId) -> ResponseError {
    error_with(
        ResponseError::SESSION_NOT_FOUND,
        &format!("the session {id} is not open: create, fork, or load it first"),
    )
}

/// Writes the messages to the client, one per line, from a bounded queue.
#[derive(Clone)]
struct Writer {
    sender: mpsc::Sender<String>,
    /// Cancelled when the connection ends: the output broke, or the client fell behind.
    closed: CancellationToken,
}

// A turn sends its updates straight to the client.
impl SessionObserver for Writer {
    fn update(&self, update: SessionUpdateParams) {
        self.notify(ServerNotification::SessionUpdate(update));
    }
}

impl Writer {
    /// Start the task that writes to `output`.
    fn start(mut output: impl AsyncWrite + Unpin + Send + 'static) -> (Writer, JoinHandle<()>) {
        let (sender, mut receiver) = mpsc::channel::<String>(OUTGOING_LIMIT);
        let closed = CancellationToken::new();
        let task_closed = closed.clone();
        let task = tokio::spawn(async move {
            while let Some(line) = receiver.recv().await {
                let written = async {
                    output.write_all(line.as_bytes()).await?;
                    output.write_all(b"\n").await?;
                    output.flush().await
                };
                // A closed connection stops the write, because a client that stopped reading can block it forever.
                tokio::select! {
                    written = written => if let Err(error) = written {
                        warn(&format!("the output broke: {error}"));
                        task_closed.cancel();
                        return;
                    },
                    () = task_closed.cancelled() => return,
                }
            }
        });
        (Writer { sender, closed }, task)
    }

    /// Queue `message` as one line. A full queue ends the connection, because the client fell behind.
    fn send(&self, message: &impl Serialize) {
        let line = match serde_json::to_string(message) {
            Ok(line) => line,
            Err(error) => {
                warn(&format!("a message does not write as JSON: {error}"));
                return;
            }
        };
        if self.sender.try_send(line).is_err() {
            self.closed.cancel();
        }
    }

    fn notify(&self, message: ServerNotification) {
        self.send(&Notification {
            jsonrpc: JsonRpc::V2,
            message,
        });
    }

    fn update(&self, session_id: SessionId, update: SessionUpdate) {
        self.notify(ServerNotification::SessionUpdate(SessionUpdateParams {
            session_id,
            update,
        }));
    }

    fn notice(&self, session_id: Option<SessionId>, level: NoticeLevel, message: &str) {
        self.notify(ServerNotification::Notice(NoticeParams {
            session_id,
            level,
            source: SERVER_SOURCE.to_owned(),
            message: message.to_owned(),
        }));
    }
}

/// The target of the model of `settings`, with its credential from the environment.
fn target_of(
    settings: &SessionSettings,
    variable: &(dyn Fn(&str) -> Option<OsString> + Sync),
) -> Result<Target, ResponseError> {
    let selector = format!("{}/{}", settings.model.provider, settings.model.model);
    let entry = catalog::lookup(&selector).map_err(|error| invalid_params(&format!("{selector}: {error}")))?;
    target(&entry, variable).map_err(|error| invalid_params(&error))
}

/// `folder` without links. It must exist.
fn canonical(folder: &Path) -> Result<PathBuf, ResponseError> {
    folder
        .canonicalize()
        .map_err(|error| invalid_params(&format!("{}: {error}", folder.display())))
}

/// The JSON of `value` as a result.
fn result(value: &impl Serialize) -> Result<serde_json::Value, ResponseError> {
    serde_json::to_value(value).map_err(|error| internal(&error.to_string()))
}

fn error_with(code: i32, message: &str) -> ResponseError {
    ResponseError {
        code,
        message: message.to_owned(),
        data: None,
    }
}

fn internal(message: &str) -> ResponseError {
    error_with(ResponseError::INTERNAL_ERROR, message)
}

fn invalid_params(message: &impl ToString) -> ResponseError {
    error_with(ResponseError::INVALID_PARAMS, &message.to_string())
}

/// The response error of a store failure.
fn store_error(error: &StoreError) -> ResponseError {
    let code = match error {
        StoreError::NotFound => ResponseError::SESSION_NOT_FOUND,
        StoreError::Owned => ResponseError::SESSION_OWNED,
        StoreError::NotACompletedTurn => ResponseError::NOT_A_COMPLETED_TURN,
        StoreError::InputNotPending(_) | StoreError::InputBlocksExceedCommit => ResponseError::INVALID_PARAMS,
        StoreError::Failed(_) => ResponseError::INTERNAL_ERROR,
    };
    error_with(code, &describe(error))
}
