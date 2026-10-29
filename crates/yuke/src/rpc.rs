//! `yuke --rpc`: the protocol server. Each line is one JSON-RPC message. One process serves many sessions.
//!
//! Plain `--rpc` serves one client on stdin and stdout. The end of stdin ends the server. `--rpc --listen` serves the
//! clients of a Unix socket, one at a time. The sessions, turns, and jobs outlive each client. `--rpc --connect` joins
//! stdin and stdout to such a socket.

#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::fs::{File, OpenOptions, TryLockError};
use std::future::Future;
use std::io;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Serialize;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader, Lines};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc;
use tokio::task::{AbortHandle, JoinHandle};
use yuke_agent::StoreError;
use yuke_protocol::{
    ClientNotification, ClientRequest, EmptyParams, EmptyResult, Implementation, InitializeResult, Input, InputKind,
    InputResult, InputSource, InstanceId, JsonRpc, ListJobsResult, ListMcpServersResult, Notification,
    PROTOCOL_VERSION, RemoveInputResult, Request, RequestId, Response, ResponseError, ResponseOutcome,
    ServerNotification, SessionId, SessionResult,
};

use crate::app::{App, AppError, Attachment, Machine, Mode, Observer, TokioTimer, lock, open_store, warn};
use yuke_engine::chain_text;

/// The most messages that wait in the queue to the client. A client that falls further behind loses its connection.
const OUTGOING_LIMIT: usize = 8192;

/// The size at which a write stops taking queued lines. A single longer line still goes out whole.
const BATCH_BYTES: usize = 64 * 1024;

/// The wait after a failed accept, so an error that repeats does not spin the server or fill stderr.
const ACCEPT_RETRY: Duration = Duration::from_secs(1);

/// The input and the output of one client.
pub(crate) struct Stream {
    input: Box<dyn AsyncRead + Unpin + Send>,
    output: Box<dyn AsyncWrite + Unpin + Send>,
}

impl Stream {
    pub(crate) fn new(
        input: impl AsyncRead + Unpin + Send + 'static,
        output: impl AsyncWrite + Unpin + Send + 'static,
    ) -> Stream {
        Stream {
            input: Box::new(input),
            output: Box::new(output),
        }
    }
}

/// Where the clients of a server come from.
pub(crate) enum Clients {
    /// One client, such as stdin and stdout. The end of this client ends the server.
    One(Stream),
    /// The clients of a Unix socket, one after another.
    Socket(Socket),
}

/// A Unix socket that the server listens on. The server holds the lock file `PATH.lock` while it lives, so a second
/// server on the path fails. The drop removes the socket file and keeps the lock file.
pub(crate) struct Socket {
    listener: UnixListener,
    path: PathBuf,
    lock: File,
}

impl Socket {
    /// Take the lock file of `path`, and listen on `path` with mode 0600. A socket file without the lock is stale, so
    /// the bind replaces it.
    ///
    /// # Errors
    ///
    /// Returns a text for the user when another server holds the lock, when `path` is no socket, or when a file
    /// operation fails.
    pub(crate) fn bind(path: &Path) -> Result<Socket, String> {
        let failure = |error: io::Error| format!("{}: {error}", path.display());
        let lock = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .open(path.with_added_extension("lock"))
            .map_err(failure)?;
        // A check by a connection would be a client, and that client would replace the active one.
        match lock.try_lock() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => {
                return Err(format!("{}: another server listens on the socket", path.display()));
            }
            Err(TryLockError::Error(error)) => return Err(failure(error)),
        }
        match std::fs::symlink_metadata(path) {
            Ok(file) if file.file_type().is_socket() => std::fs::remove_file(path).map_err(failure)?,
            Ok(_) => return Err(format!("{}: the file is no socket", path.display())),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(failure(error)),
        }
        let socket = Socket {
            listener: UnixListener::bind(path).map_err(failure)?,
            path: path.to_path_buf(),
            lock,
        };
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(failure)?;
        Ok(socket)
    }

    /// The next client. A failed accept waits and tries again.
    async fn accept(&self) -> Stream {
        loop {
            match self.listener.accept().await {
                Ok((stream, _)) => {
                    let (input, output) = stream.into_split();
                    return Stream::new(input, output);
                }
                Err(error) => {
                    warn(&format!("{}: {error}", self.path.display()));
                    tokio::time::sleep(ACCEPT_RETRY).await;
                }
            }
        }
    }
}

impl Drop for Socket {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_file(&self.path) {
            warn(&format!("{}: {error}", self.path.display()));
        }
        // A job process holds a copy of the file until its exec, and the copy keeps the lock. So the unlock is explicit.
        if self.lock.unlock().is_err() {
            // The close of the file releases the lock when no copy lives, so nothing is left to do.
        }
    }
}

/// Serve `clients` until `shutdown` comes, or until the one client ends. A new client of the socket replaces the
/// active one. The connection that is open at the end gets the updates of the shutdown, and it has `drain_limit` to
/// read the last messages.
///
/// # Errors
///
/// Returns a text for the user when the server cannot start.
pub(crate) async fn serve(
    machine: Machine,
    drain_limit: Duration,
    clients: Clients,
    shutdown: impl Future<Output = ()>,
) -> Result<(), String> {
    let outbox = Arc::new(Outbox::default());
    // The one client connects before the start, so it gets the notices of the start.
    let (mut current, socket) = match clients {
        Clients::One(stream) => (Some(Connection::open(stream, &outbox)), None),
        Clients::Socket(socket) => (None, Some(socket)),
    };
    let observer = Arc::clone(&outbox) as Arc<dyn Observer>;
    let started = async {
        let store = open_store(&machine.paths.data).await?;
        App::start(machine, Mode::Server, observer, store, Arc::new(TokioTimer)).await
    };
    let app = match started.await {
        Ok(app) => app,
        Err(error) => {
            outbox.detach();
            if let Some(connection) = current {
                connection.close(drain_limit).await;
            }
            return Err(error);
        }
    };
    let mut server = Server {
        app,
        instance_id: InstanceId::generate(),
        attachments: HashMap::new(),
    };
    tokio::pin!(shutdown);
    // Each request runs to its end before the next client or the shutdown, because the methods of the app are not cancel
    // safe.
    loop {
        tokio::select! {
            () = &mut shutdown => break,
            stream = accept(socket.as_ref()) => {
                if let Some(old) = current.take() {
                    old.retire(&outbox, drain_limit);
                }
                current = Some(Connection::open(stream, &outbox));
            }
            line = next_line(&mut current) => match (line, current.as_mut()) {
                (Some(line), Some(connection)) => server.handle(connection, &line).await,
                _ if socket.is_none() => break,
                _ => {
                    if let Some(old) = current.take() {
                        old.retire(&outbox, drain_limit);
                    }
                }
            },
        }
    }
    // No client comes during the shutdown.
    drop(socket);
    server.app.shutdown().await;
    outbox.detach();
    if let Some(connection) = current {
        connection.close(drain_limit).await;
    }
    Ok(())
}

/// The next client of `socket`. With no socket, it never comes.
async fn accept(socket: Option<&Socket>) -> Stream {
    match socket {
        Some(socket) => socket.accept().await,
        None => std::future::pending().await,
    }
}

/// The next line of the active client, or `None` when its connection ends. With no active client, it never comes.
async fn next_line(current: &mut Option<Connection>) -> Option<String> {
    let Some(connection) = current else {
        return std::future::pending().await;
    };
    tokio::select! {
        line = connection.lines.next_line() => match line {
            Ok(line) => line,
            Err(error) => {
                warn(&format!("the input broke: {error}"));
                None
            }
        },
        () = connection.writer.sender.closed() => None,
    }
}

/// Join `input` and `output` to the server of the socket at `path`, until the server closes the connection. The end of
/// `input` ends the requests, and the server still sends its last messages.
///
/// # Errors
///
/// Returns a text for the user when the connection fails.
pub(crate) async fn connect(
    path: &Path,
    mut input: impl AsyncRead + Unpin,
    mut output: impl AsyncWrite + Unpin,
) -> Result<(), String> {
    let (mut from_server, mut to_server) = UnixStream::connect(path)
        .await
        .map_err(|error| format!("{}: {error}", path.display()))?
        .into_split();
    let failure = |error: io::Error| format!("the bridge to {}: {error}", path.display());
    let requests = async {
        tokio::io::copy(&mut input, &mut to_server).await?;
        to_server.shutdown().await
    };
    let messages = async {
        tokio::io::copy(&mut from_server, &mut output).await?;
        output.flush().await
    };
    tokio::pin!(requests, messages);
    tokio::select! {
        sent = &mut requests => {
            sent.map_err(failure)?;
            messages.await.map_err(failure)
        }
        received = &mut messages => received.map_err(failure),
    }
}

/// Answers the requests of the clients with the app.
struct Server {
    app: App,
    instance_id: InstanceId,
    /// The sessions that the clients created, forked, or loaded. A client holds each one until `session/close`, also
    /// after it disconnects.
    attachments: HashMap<SessionId, Attachment>,
}

impl Server {
    /// Answer one line: a request gets a response, and a notification gets none.
    async fn handle(&mut self, connection: &mut Connection, line: &str) {
        let value: serde_json::Value = match serde_json::from_str(line) {
            Ok(value) => value,
            Err(error) => {
                return connection.respond(
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
                Ok(Notification {
                    message: ClientNotification::Cancel(params),
                    ..
                }) => self.app.sessions().cancel(params.session_id),
                Err(error) => warn(&format!("a notification does not read: {error}")),
            }
            return;
        }
        let id = value
            .get("id")
            .cloned()
            .and_then(|id| serde_json::from_value::<RequestId>(id).ok());
        let unknown_method = value
            .get("method")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|method| !ClientRequest::METHODS.contains(&method));
        let request = match serde_json::from_value::<Request>(value) {
            Ok(request) => request,
            Err(error) => {
                let code = if unknown_method {
                    ResponseError::METHOD_NOT_FOUND
                } else {
                    ResponseError::INVALID_PARAMS
                };
                return connection.respond(id, Err(error_with(code, &error.to_string())));
            }
        };
        let result = if !connection.initialized && !matches!(request.call, ClientRequest::Initialize(_)) {
            Err(error_with(ResponseError::INVALID_REQUEST, "send initialize first"))
        } else {
            connection.initialized = true;
            self.dispatch(request.call)
                .await
                .map_err(|error| response_error(&error))
        };
        connection.respond(Some(request.id), result);
    }

    /// Do what `call` asks of the app, and answer its result.
    async fn dispatch(&mut self, call: ClientRequest) -> Result<serde_json::Value, AppError> {
        let app = &self.app;
        match call {
            ClientRequest::Initialize(_) => {
                // The server speaks one version, so it answers that one.
                result(&InitializeResult {
                    protocol_version: PROTOCOL_VERSION,
                    agent_info: Implementation {
                        name: "yuke".to_owned(),
                        title: None,
                        version: env!("YUKE_VERSION").to_owned(),
                    },
                    instance_id: self.instance_id,
                })
            }
            ClientRequest::NewSession(settings) => {
                let session_id = app.sessions().create(settings).await?;
                self.attachments.insert(session_id, app.sessions().attach(session_id)?);
                result(&SessionResult { session_id })
            }
            ClientRequest::ForkSession(params) => {
                let session_id = app.sessions().fork(params.session_id, params.through).await?;
                self.attachments.insert(session_id, app.sessions().attach(session_id)?);
                result(&SessionResult { session_id })
            }
            ClientRequest::LoadSession(params) => {
                app.sessions().load(params.session_id, params.after).await?;
                // A new attachment replaces the one of an earlier open of the same id.
                let attachment = app.sessions().attach(params.session_id)?;
                self.attachments.insert(params.session_id, attachment);
                result(&EmptyResult {})
            }
            ClientRequest::CloseSession(params) => {
                app.sessions().close(params.session_id, params.stop_jobs).await?;
                self.attachments.remove(&params.session_id);
                result(&EmptyResult {})
            }
            ClientRequest::ListSessions(params) => result(&app.sessions().list(params).await?),
            ClientRequest::GetSession(params) => result(&app.sessions().get(params.session_id).await?),
            ClientRequest::Login(params) => result(&app.login(params.provider).await?),
            ClientRequest::CancelLogin(params) => {
                app.cancel_login(params.login_id)?;
                result(&EmptyResult {})
            }
            ClientRequest::Logout(params) => {
                app.logout(&params.provider).await?;
                result(&EmptyResult {})
            }
            ClientRequest::SetApiKey(params) => {
                app.set_api_key(&params.provider, params.api_key).await?;
                result(&EmptyResult {})
            }
            ClientRequest::ListCatalog(params) => result(&app.catalog(params.all.unwrap_or(false)).await?),
            ClientRequest::RemoveSession(params) => {
                app.sessions().remove(params.session_id).await?;
                result(&EmptyResult {})
            }
            ClientRequest::ListJobs(params) => result(&ListJobsResult {
                jobs: app.sessions().jobs(params.session_id)?,
            }),
            ClientRequest::StopJob(params) => {
                app.sessions().stop_job(params.session_id, &params.job_id).await?;
                result(&EmptyResult {})
            }
            ClientRequest::Input(params) => {
                let input = Input::new(InputSource::User, InputKind::Message, params.content);
                let input = match params.model_content {
                    Some(model_content) => input.and_then(|input| input.with_model_content(model_content)),
                    None => input,
                }
                .map_err(|error| AppError::Invalid(chain_text(&error)))?;
                result(&InputResult {
                    input_id: app.sessions().input(params.session_id, input).await?,
                })
            }
            ClientRequest::ListMcpServers(params) => result(&ListMcpServersResult {
                servers: app.sessions().mcp_servers(params.session_id)?,
            }),
            ClientRequest::InteractionRespond(params) => {
                app.sessions()
                    .respond(params.session_id, params.interaction_id, params.response)?;
                result(&EmptyResult {})
            }
            ClientRequest::RemoveInput(params) => result(&RemoveInputResult {
                removed: app.sessions().remove_input(params.session_id, params.input_id).await?,
            }),
            ClientRequest::SetSettings(params) => {
                app.sessions().set_settings(params.session_id, params.settings).await?;
                result(&EmptyResult {})
            }
            ClientRequest::UpdateCredential(params) => {
                app.update_credential(params)?;
                result(&EmptyResult {})
            }
            ClientRequest::ReloadProfile(EmptyParams {}) => {
                self.app.reload().await?;
                result(&EmptyResult {})
            }
        }
    }
}

/// The connection of one client.
struct Connection {
    lines: Lines<BufReader<Box<dyn AsyncRead + Unpin + Send>>>,
    writer: Writer,
    written: JoinHandle<()>,
    initialized: bool,
}

impl Connection {
    /// Start writing to the output of `stream`, and make it the receiver of the notifications of `outbox`.
    fn open(stream: Stream, outbox: &Outbox) -> Connection {
        let (writer, written) = Writer::start(stream.output);
        outbox.attach(writer.clone());
        Connection {
            lines: BufReader::new(stream.input).lines(),
            writer,
            written,
            initialized: false,
        }
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

    /// Stop the notifications of `outbox` to this connection, and close it in the background.
    fn retire(self, outbox: &Outbox, drain_limit: Duration) {
        outbox.detach();
        tokio::spawn(self.close(drain_limit));
    }

    /// Write the messages that wait, and end the connection. The outbox must not hold its writer.
    async fn close(self, drain_limit: Duration) {
        let Connection {
            writer, mut written, ..
        } = self;
        drop(writer);
        // A client that stops reading can block the last write forever, so the wait has a limit.
        let ended = if let Ok(ended) = tokio::time::timeout(drain_limit, &mut written).await {
            ended
        } else {
            warn("the client did not read the last messages");
            written.abort();
            written.await
        };
        // A full queue and the drain limit abort the task, so only a panic is a failure.
        if let Err(error) = ended
            && !error.is_cancelled()
        {
            warn(&format!("the output task failed: {error}"));
        }
    }
}

/// Sends the notifications of the app to the active client. With no active client, a notice goes to stderr. A session
/// update, an extension event, or a login end is dropped. `session/load` sends the saved events again, and
/// `catalog/list` gives the state of a login.
#[derive(Default)]
struct Outbox {
    writer: Mutex<Option<Writer>>,
}

impl Outbox {
    fn attach(&self, writer: Writer) {
        *lock(&self.writer) = Some(writer);
    }

    fn detach(&self) {
        *lock(&self.writer) = None;
    }
}

impl Observer for Outbox {
    fn notify(&self, notification: ServerNotification) {
        let writer = lock(&self.writer).clone();
        match (writer, notification) {
            (Some(writer), notification) => writer.send(&Notification {
                jsonrpc: JsonRpc::V2,
                message: notification,
            }),
            (None, ServerNotification::Notice(notice)) => warn(&format!("{}: {}", notice.source, notice.message)),
            (
                None,
                ServerNotification::SessionUpdate(_)
                | ServerNotification::ExtensionEvent(_)
                | ServerNotification::LoginFinished(_),
            ) => {}
        }
    }
}

/// Writes the messages to the client, one per line, from a bounded queue. The connection ends when the task ends: the
/// output broke, or an abort stopped it.
#[derive(Clone)]
struct Writer {
    sender: mpsc::Sender<String>,
    task: AbortHandle,
}

impl Writer {
    /// Start the task that writes to `output`.
    fn start(mut output: impl AsyncWrite + Unpin + Send + 'static) -> (Writer, JoinHandle<()>) {
        let (sender, mut receiver) = mpsc::channel::<String>(OUTGOING_LIMIT);
        let task = tokio::spawn(async move {
            let mut batch = Vec::new();
            while let Some(mut line) = receiver.recv().await {
                batch.clear();
                // Each write and flush of stdout is a task on another thread, so one write takes the lines that queued
                // meanwhile. The size bound keeps the buffer small and the queue limit meaningful.
                loop {
                    batch.extend_from_slice(line.as_bytes());
                    batch.push(b'\n');
                    if batch.len() >= BATCH_BYTES {
                        break;
                    }
                    let Ok(next) = receiver.try_recv() else { break };
                    line = next;
                }
                let written = async {
                    output.write_all(&batch).await?;
                    output.flush().await
                };
                if let Err(error) = written.await {
                    warn(&format!("the output broke: {error}"));
                    return;
                }
            }
        });
        let writer = Writer {
            sender,
            task: task.abort_handle(),
        };
        (writer, task)
    }

    /// Queue `message` as one line. A full queue ends the connection, because the client fell behind and a write can
    /// block forever.
    fn send(&self, message: &impl Serialize) {
        let line = match serde_json::to_string(message) {
            Ok(line) => line,
            Err(error) => {
                warn(&format!("a message does not write as JSON: {error}"));
                return;
            }
        };
        if self.sender.try_send(line).is_err() {
            self.task.abort();
        }
    }
}

/// The JSON of `value` as a result.
fn result(value: &impl Serialize) -> Result<serde_json::Value, AppError> {
    serde_json::to_value(value).map_err(|error| AppError::Internal(error.to_string()))
}

fn error_with(code: i32, message: &str) -> ResponseError {
    ResponseError {
        code,
        message: message.to_owned(),
        data: None,
    }
}

/// The response error of a refusal or a failure of the app.
fn response_error(error: &AppError) -> ResponseError {
    let code = match error {
        AppError::NotOpen(_) => ResponseError::SESSION_NOT_FOUND,
        AppError::Invalid(_) => ResponseError::INVALID_PARAMS,
        AppError::Open(_)
        | AppError::Busy
        | AppError::TurnRuns
        | AppError::JobsRun(_)
        | AppError::Changing(_)
        | AppError::Reloading
        | AppError::Stopped => ResponseError::INVALID_REQUEST,
        AppError::NoJob(_) => ResponseError::JOB_NOT_FOUND,
        AppError::NoInteraction(_) => ResponseError::INTERACTION_NOT_FOUND,
        AppError::NoLogin(_) => ResponseError::LOGIN_NOT_FOUND,
        AppError::Store(error) => match error {
            StoreError::NotFound => ResponseError::SESSION_NOT_FOUND,
            StoreError::Owned => ResponseError::SESSION_OWNED,
            StoreError::NotACompletedTurn => ResponseError::NOT_A_COMPLETED_TURN,
            StoreError::InputNotPending(_) | StoreError::InputBlocksExceedCommit => ResponseError::INVALID_PARAMS,
            StoreError::Failed(_) => ResponseError::INTERNAL_ERROR,
        },
        AppError::Internal(_) => ResponseError::INTERNAL_ERROR,
    };
    error_with(code, &chain_text(error))
}
