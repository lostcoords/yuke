//! The protocol server against a scripted provider, through a pair of pipes.

use std::collections::{BTreeMap, BTreeSet};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use yuke_agent::{Access, PromptSection, Session, Store};
use yuke_ai::transport::Transport;
use yuke_engine::CancellationToken;
use yuke_protocol::{Input, InputKind, InputSource, ModelReference, SessionId, SessionSettings};

use super::*;
use yuke_ai::scripted::{ScriptedTransport, Stalled, text_reply, tool_reply};

use crate::app::Machine;
use crate::providers::Providers;
use crate::testing::{Answers, PanicsOnce, Place, with_key};

/// Settings of a session in the work folder of `place`.
fn settings(place: &Place) -> Value {
    serde_json::to_value(SessionSettings {
        model: ModelReference {
            provider: "minimax".to_owned(),
            model: "MiniMax-M3".to_owned(),
        },
        settings: yuke_ai::Settings::new(),
        cwd: place.work.clone(),
    })
    .unwrap()
}

/// The params of an input of `text` to `session`.
fn input_params(session: &Value, text: &str) -> Value {
    json!({ "sessionId": session, "content": [{ "user_text": text }] })
}

/// The client side of a server that runs in this test.
struct Client {
    input: Box<dyn AsyncWrite + Unpin + Send>,
    output: Lines<BufReader<Box<dyn AsyncRead + Unpin + Send>>>,
    next_id: i64,
    /// The server task of a client on a pair of pipes. The clients of a socket share the task of `Listening`.
    server: Option<JoinHandle<Result<(), String>>>,
}

impl Client {
    fn new(input: impl AsyncWrite + Unpin + Send + 'static, output: impl AsyncRead + Unpin + Send + 'static) -> Client {
        Client {
            input: Box::new(input),
            output: BufReader::new(Box::new(output) as Box<dyn AsyncRead + Unpin + Send>).lines(),
            next_id: 0,
            server: None,
        }
    }

    /// The only client of a server, as on stdin and stdout.
    fn start(place: &Place, transport: Box<dyn Transport>) -> Client {
        Client::start_with(place, transport, Answers::default())
    }

    /// The only client of a server whose logins and refreshes get `exchange`.
    fn start_with(place: &Place, transport: Box<dyn Transport>, exchange: Answers) -> Client {
        let (input, server_input) = tokio::io::duplex(1 << 16);
        let (server_output, output) = tokio::io::duplex(1 << 16);
        let machine = Machine {
            exchange: Arc::new(exchange),
            ..place.machine(Box::new(with_key), transport)
        };
        let server = tokio::spawn(serve(
            machine,
            Duration::from_secs(10),
            Clients::One(Stream::new(server_input, server_output)),
            std::future::pending(),
        ));
        Client {
            server: Some(server),
            ..Client::new(input, output)
        }
    }

    /// A client after `initialize`.
    async fn initialized(place: &Place, transport: Box<dyn Transport>) -> Client {
        let mut client = Client::start(place, transport);
        client.initialize().await;
        client
    }

    /// Send `initialize`, and answer the result.
    async fn initialize(&mut self) -> Value {
        self.call(
            "initialize",
            json!({ "protocolVersion": 1, "clientInfo": { "name": "test", "version": "1" } }),
        )
        .await
        .unwrap()
    }

    async fn write(&mut self, line: &str) {
        self.input.write_all(line.as_bytes()).await.unwrap();
        self.input.write_all(b"\n").await.unwrap();
    }

    /// Send a request, and answer its id.
    async fn request(&mut self, method: &str, params: Value) -> i64 {
        self.next_id += 1;
        let message = json!({ "jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params });
        self.write(&message.to_string()).await;
        self.next_id
    }

    async fn notify(&mut self, method: &str, params: Value) {
        self.write(&json!({ "jsonrpc": "2.0", "method": method, "params": params }).to_string())
            .await;
    }

    /// The next message of the server. A test fails when none comes within ten seconds.
    async fn next(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(10), self.output.next_line())
            .await
            .expect("the server sent nothing for ten seconds")
            .unwrap()
            .expect("the server closed its output");
        serde_json::from_str(&line).unwrap()
    }

    /// The messages up to and with the first one that `stop` accepts.
    async fn until(&mut self, stop: impl Fn(&Value) -> bool) -> Vec<Value> {
        let mut messages = Vec::new();
        loop {
            let message = self.next().await;
            let last = stop(&message);
            messages.push(message);
            if last {
                return messages;
            }
        }
    }

    /// Send a request, and answer its result, or its error.
    async fn call(&mut self, method: &str, params: Value) -> Result<Value, Value> {
        let id = self.request(method, params).await;
        let response = self.until(|message| is_response(message, id)).await.pop().unwrap();
        match response.get("result") {
            Some(result) => Ok(result.clone()),
            None => Err(response["error"].clone()),
        }
    }

    /// End the input, and read the output to its end, so a full pipe cannot hold the server. Wait for the server task
    /// when the client has one.
    async fn end(self) {
        let Client {
            input,
            mut output,
            server,
            ..
        } = self;
        drop(input);
        let drain = async { while output.next_line().await.is_ok_and(|line| line.is_some()) {} };
        let server = async {
            match server {
                Some(server) => server.await.unwrap(),
                None => Ok(()),
            }
        };
        let (ended, ()) = tokio::time::timeout(Duration::from_secs(10), async { tokio::join!(server, drain) })
            .await
            .expect("the server did not end within ten seconds");
        ended.unwrap();
    }

    /// Skip the messages up to the end of the output. A test fails when the server keeps the connection for ten
    /// seconds.
    async fn expect_closed(&mut self) {
        tokio::time::timeout(Duration::from_secs(10), async {
            while self.output.next_line().await.is_ok_and(|line| line.is_some()) {}
        })
        .await
        .expect("the server kept the connection for ten seconds");
    }
}

/// A new short path for a socket. The path of a socket has a small length limit, so it is not in the place.
fn socket_path() -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let number = NEXT.fetch_add(1, Ordering::SeqCst);
    std::env::temp_dir().join(format!("yuke-{}-{number}.sock", std::process::id()))
}

/// A server that runs in this test on a Unix socket.
struct Listening {
    path: PathBuf,
    shutdown: CancellationToken,
    server: JoinHandle<Result<(), String>>,
}

impl Listening {
    fn start(place: &Place, transport: Box<dyn Transport>) -> Listening {
        let path = socket_path();
        let socket = Socket::bind(&path).unwrap();
        let shutdown = CancellationToken::new();
        let server = tokio::spawn(serve(
            place.machine(Box::new(with_key), transport),
            Duration::from_secs(10),
            Clients::Socket(socket),
            shutdown.clone().cancelled_owned(),
        ));
        Listening { path, shutdown, server }
    }

    /// A new client of the socket.
    async fn client(&self) -> Client {
        let (output, input) = UnixStream::connect(&self.path).await.unwrap().into_split();
        Client::new(input, output)
    }

    /// Shut the server down, and wait for its end. A test fails when it takes ten seconds.
    async fn stop(self) {
        self.shutdown.cancel();
        tokio::time::timeout(Duration::from_secs(10), self.server)
            .await
            .expect("the server did not end within ten seconds")
            .unwrap()
            .unwrap();
    }
}

/// What a load sent before its empty answer: its messages, and the state, the pending inputs, and the running jobs that
/// its updates told.
struct LoadedSession {
    messages: Vec<Value>,
    state: Value,
    pending: Vec<Value>,
    jobs: Vec<Value>,
}

impl Client {
    /// Load `session` with the params `extra`, and answer what the load sent.
    async fn load(&mut self, session: &Value, extra: Value) -> LoadedSession {
        let mut params = json!({ "sessionId": session });
        for (key, value) in extra.as_object().unwrap() {
            params[key] = value.clone();
        }
        let id = self.request("session/load", params).await;
        let messages = self.until(|message| is_response(message, id)).await;
        assert_eq!(messages.last().unwrap()["result"], json!({}), "{messages:?}");
        let updates = |kind: &str| -> Vec<Value> {
            messages
                .iter()
                .map(|message| &message["params"]["update"])
                .filter(|update| update["sessionUpdate"] == kind)
                .cloned()
                .collect()
        };
        LoadedSession {
            state: updates("state")
                .last()
                .map_or(Value::Null, |update| update["state"].clone()),
            pending: updates("input_accepted")
                .into_iter()
                .map(|update| update["input"].clone())
                .collect(),
            jobs: updates("job").into_iter().map(|update| update["job"].clone()).collect(),
            messages,
        }
    }
}

/// A short name of a message, so a test can compare whole sequences. Model deltas have no name.
fn label(message: &Value) -> Option<String> {
    if message.get("id").is_some() && message.get("method").is_none() {
        return Some("response".to_owned());
    }
    let update = &message["params"]["update"];
    match update["sessionUpdate"].as_str()? {
        "state" => Some(format!("state {}", update["state"].as_str()?)),
        "model" => None,
        "commit" => Some(format!("saved {}", update["seq"])),
        other => Some(other.to_owned()),
    }
}

/// Whether `message` answers the request `id` of the client. A request of the server has an id too, and a method.
fn is_response(message: &Value, id: i64) -> bool {
    message["id"] == json!(id) && message.get("method").is_none()
}

fn is_idle(message: &Value) -> bool {
    message["params"]["update"]["state"] == "idle"
}

fn is_question(message: &Value) -> bool {
    message["params"]["update"]["sessionUpdate"] == "interaction_requested"
}

/// Send `text` to `session`, and wait until the session is idle again.
async fn turn(client: &mut Client, session: &Value, text: &str) {
    client.request("session/input", input_params(session, text)).await;
    client.until(is_idle).await;
}

mod auth;
mod jobs;
mod mcp;
mod questions;
mod reload;
mod requests;
mod sessions;
mod transport;
