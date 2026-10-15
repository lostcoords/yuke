//! `yuke --rpc`: the protocol server on stdin and stdout. Each line is one JSON-RPC message. One process serves many
//! sessions.

#[cfg(test)]
mod tests;

use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use yuke_agent::StoreError;
use yuke_engine::CancellationToken;
use yuke_protocol::{
    ClientNotification, ClientRequest, EmptyResult, ForkSessionResult, Implementation, InitializeResult, InputResult,
    JsonRpc, ListJobsResult, NewSessionResult, Notification, PROTOCOL_VERSION, Request, RequestId, Response,
    ResponseError, ResponseOutcome, ServerNotification,
};

use crate::app::{App, AppError, Jobs, Machine, Observer, describe, warn};

/// The most messages that wait for the client. A client that falls further behind loses its connection.
const OUTGOING_LIMIT: usize = 8192;

/// Serve the client of `input` and `output` until `input` ends or the connection breaks. After the end of `input`, the
/// client has `drain_limit` to read the last messages.
///
/// # Errors
///
/// Returns a text for the user when the server cannot start.
pub(crate) async fn serve(
    machine: Machine,
    drain_limit: Duration,
    input: impl AsyncRead + Unpin,
    output: impl AsyncWrite + Unpin + Send + 'static,
) -> Result<(), String> {
    let (writer, written) = Writer::start(output);
    let served = match App::start(machine, Jobs::Allowed, Arc::new(writer.clone())).await {
        Ok(app) => {
            let mut server = Server {
                app,
                writer: writer.clone(),
                initialized: false,
            };
            server.serve(input).await;
            server.app.shutdown().await;
            Ok(())
        }
        Err(error) => Err(error),
    };

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

/// The server of one client.
struct Server {
    app: App,
    writer: Writer,
    initialized: bool,
}

impl Server {
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
            ClientNotification::Cancel(params) => self.app.cancel(params.session_id),
        }
    }

    async fn call(&mut self, call: ClientRequest) -> Result<serde_json::Value, ResponseError> {
        if !self.initialized && !matches!(call, ClientRequest::Initialize(_)) {
            return Err(error_with(ResponseError::INVALID_REQUEST, "send initialize first"));
        }
        self.dispatch(call).await.map_err(|error| response_error(&error))
    }

    /// Do what `call` asks of the app, and answer its result.
    async fn dispatch(&mut self, call: ClientRequest) -> Result<serde_json::Value, AppError> {
        let app = &mut self.app;
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
            ClientRequest::NewSession(settings) => result(&NewSessionResult {
                session_id: app.create(settings).await?,
            }),
            ClientRequest::ForkSession(params) => result(&ForkSessionResult {
                session_id: app.fork(params.session_id, params.through).await?,
            }),
            ClientRequest::LoadSession(params) => result(&app.load(params.session_id, params.after).await?),
            ClientRequest::CloseSession(params) => {
                app.close(params.session_id, params.stop_jobs).await?;
                result(&EmptyResult {})
            }
            ClientRequest::ListJobs(params) => result(&ListJobsResult {
                jobs: app.jobs(params.session_id)?,
            }),
            ClientRequest::StopJob(params) => {
                app.stop_job(params.session_id, &params.job_id).await?;
                result(&EmptyResult {})
            }
            ClientRequest::Input(params) => result(&InputResult {
                input_id: app.input(params.session_id, params.content).await?,
            }),
            ClientRequest::RemoveInput(params) => {
                app.remove_input(params.session_id, params.input_id).await?;
                result(&EmptyResult {})
            }
            ClientRequest::SetSettings(params) => {
                app.set_settings(params.session_id, params.settings).await?;
                result(&EmptyResult {})
            }
            // No plugin asks yet, so no question is open.
            ClientRequest::InteractionRespond(params) => Err(AppError::Invalid(format!(
                "no question has the id {}",
                params.interaction_id.0
            ))),
        }
    }
}

/// Writes the messages to the client, one per line, from a bounded queue.
#[derive(Clone)]
struct Writer {
    sender: mpsc::Sender<String>,
    /// Cancelled when the connection ends: the output broke, or the client fell behind.
    closed: CancellationToken,
}

// The app sends its notifications straight to the client.
impl Observer for Writer {
    fn notify(&self, notification: ServerNotification) {
        self.send(&Notification {
            jsonrpc: JsonRpc::V2,
            message: notification,
        });
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
        AppError::Busy | AppError::JobsRun(_) => ResponseError::INVALID_REQUEST,
        AppError::NoJob(_) => ResponseError::JOB_NOT_FOUND,
        AppError::Store(error) => match error {
            StoreError::NotFound => ResponseError::SESSION_NOT_FOUND,
            StoreError::Owned => ResponseError::SESSION_OWNED,
            StoreError::NotACompletedTurn => ResponseError::NOT_A_COMPLETED_TURN,
            StoreError::InputNotPending(_) | StoreError::InputBlocksExceedCommit => ResponseError::INVALID_PARAMS,
            StoreError::Failed(_) => ResponseError::INTERNAL_ERROR,
        },
        AppError::Internal(_) => ResponseError::INTERNAL_ERROR,
    };
    error_with(code, &describe(error))
}
