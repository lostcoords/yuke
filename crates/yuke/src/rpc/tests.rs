//! The protocol server against a scripted provider, through a pair of pipes.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use yuke_agent::{PromptSection, Session, Store};
use yuke_ai::transport::Transport;
use yuke_engine::CancellationToken;
use yuke_protocol::{Input, InputSource, ModelReference, SessionId, SessionSettings};

use super::*;
use yuke_testing::{ScriptedTransport, Stalled, text_reply, tool_reply};

use crate::testing::{PanicsOnce, Place, with_key};

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
        let (input, server_input) = tokio::io::duplex(1 << 16);
        let (server_output, output) = tokio::io::duplex(1 << 16);
        let server = tokio::spawn(serve(
            place.machine(Box::new(with_key), transport),
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
        let response = self.until(|message| message["id"] == json!(id)).await.pop().unwrap();
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
        let messages = self.until(|message| message["id"] == json!(id)).await;
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
    if message.get("id").is_some() {
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

fn is_idle(message: &Value) -> bool {
    message["params"]["update"]["state"] == "idle"
}

#[tokio::test]
async fn an_input_starts_a_turn_and_the_client_sees_its_updates_in_order() {
    let place = Place::new("rpc", "an_input_starts_a_turn_and_the_client_sees_its_updates_in_order");
    let transport = ScriptedTransport::new([text_reply("hello")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();

    client.request("session/input", input_params(&session, "hi")).await;
    let messages = client.until(is_idle).await;

    let labels: Vec<String> = messages.iter().filter_map(label).collect();
    assert_eq!(
        labels,
        [
            "input_accepted",
            "response",
            "state running",
            "saved 2",
            "draft_started",
            "saved 3",
            "draft_committed",
            "saved 4",
            "state idle"
        ]
    );
    assert_eq!(messages[1]["result"], json!({ "inputId": 1 }));
    assert!(
        transport.requests()[0].contains("\"hi\""),
        "{}",
        transport.requests()[0]
    );
    client.end().await;
}

#[tokio::test]
async fn a_load_sends_the_saved_events_then_the_state_then_an_empty_answer() {
    let place = Place::new(
        "rpc",
        "a_load_sends_the_saved_events_then_the_state_then_an_empty_answer",
    );
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([text_reply("hello")]))).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "hi")).await;
    client.until(is_idle).await;

    let loaded = client.load(&session, json!({})).await;

    let numbers: Vec<&Value> = loaded
        .messages
        .iter()
        .filter_map(|message| message["params"]["update"].get("seq"))
        .collect();
    assert_eq!(numbers, [&json!(1), &json!(2), &json!(3), &json!(4)]);
    let state = &loaded.messages[loaded.messages.len() - 2];
    assert_eq!(label(state).unwrap(), "state idle");
    assert_eq!((loaded.pending, loaded.jobs), (Vec::new(), Vec::new()));
    client.end().await;
}

#[tokio::test]
async fn a_running_session_refuses_new_settings_and_a_cancel_ends_its_turn() {
    let place = Place::new(
        "rpc",
        "a_running_session_refuses_new_settings_and_a_cancel_ends_its_turn",
    );
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "hi")).await;
    client
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;

    let mut settings = settings(&place);
    settings["sessionId"] = session.clone();
    let refused = client.call("session/set_settings", settings).await;
    client.notify("session/cancel", json!({ "sessionId": session })).await;
    let messages = client.until(is_idle).await;

    let refused = refused.unwrap_err();
    assert_eq!(refused["code"], json!(ResponseError::INVALID_REQUEST));
    let end = messages
        .iter()
        .rev()
        .find_map(|message| message["params"]["update"]["commit"]["end"].as_object())
        .unwrap();
    assert_eq!(end["outcome"], "cancelled");
    client.end().await;
}

#[tokio::test]
async fn the_server_builds_the_prompt_of_a_new_session_from_its_folder() {
    let place = Place::new("rpc", "the_server_builds_the_prompt_of_a_new_session_from_its_folder");
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;

    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();

    let id: SessionId = serde_json::from_value(session).unwrap();
    let prompt = place
        .store()
        .await
        .open(id, yuke_agent::Access::Read)
        .await
        .unwrap()
        .prompt;
    let prompt = yuke_agent::prompt_text(&prompt);
    assert!(prompt.starts_with("You are yuke"), "{prompt}");
    assert!(prompt.contains(place.work.to_str().unwrap()), "{prompt}");
    client.end().await;
}

#[tokio::test]
async fn a_regular_file_is_no_folder_for_a_new_session_or_new_settings() {
    let place = Place::new("rpc", "a_regular_file_is_no_folder_for_a_new_session_or_new_settings");
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;
    let file = place.work.join("notes.txt");
    std::fs::write(&file, "notes").unwrap();
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    let mut new = settings(&place);
    new["cwd"] = json!(file);
    let mut changed = settings(&place);
    changed["sessionId"] = session;
    changed["cwd"] = json!(file);

    let created = client.call("session/new", new).await;
    let refused = client.call("session/set_settings", changed).await;

    for error in [created.unwrap_err(), refused.unwrap_err()] {
        assert_eq!(error["code"], json!(ResponseError::INVALID_PARAMS), "{error}");
        assert!(error["message"].as_str().unwrap().ends_with("not a folder"), "{error}");
    }
    client.end().await;
}

#[tokio::test]
async fn process_and_session_notices_reach_the_client_and_a_failed_load_sends_a_notice() {
    let place = Place::new(
        "rpc",
        "process_and_session_notices_reach_the_client_and_a_failed_load_sends_a_notice",
    );
    place.plugin("broken", "export function apply() { throw new Error('no luck'); }");
    place.plugin(
        "loud",
        "export function apply(ctx) { ctx.notify('info', 'hello'); }
         export function session(s) { s.notify('info', `opened in ${s.folder}`); }",
    );
    std::fs::write(
        place.paths.config.join("config.json"),
        r#"{ "plugins": ["loud", "broken"] }"#,
    )
    .unwrap();
    let mut client = Client::start(&place, Box::new(ScriptedTransport::default()));

    let hello = client
        .until(|message| message["method"] == "notice")
        .await
        .pop()
        .unwrap();
    let notice = client
        .until(|message| message["method"] == "notice")
        .await
        .pop()
        .unwrap();
    client.initialize().await;
    // The notice of the new session can come before or after the response.
    let id = client.request("session/new", settings(&place)).await;
    let mut messages: Vec<Value> = Vec::new();
    while !(messages.iter().any(|message| message["id"] == json!(id))
        && messages.iter().any(|message| message["method"] == "notice"))
    {
        messages.push(client.next().await);
    }
    let session = &messages.iter().find(|message| message["id"] == json!(id)).unwrap()["result"]["sessionId"];
    let opened = messages.iter().find(|message| message["method"] == "notice").unwrap();

    assert_eq!(
        hello["params"],
        json!({
            "level": "info",
            "source": "loud",
            "message": "hello",
        })
    );
    assert_eq!(
        opened["params"],
        json!({
            "sessionId": session,
            "level": "info",
            "source": "loud",
            "message": format!("opened in {}", std::fs::canonicalize(&place.work).unwrap().display()),
        })
    );
    assert_eq!(notice["params"]["level"], "error");
    assert_eq!(notice["params"]["source"], "host:yuke");
    let message = notice["params"]["message"].as_str().unwrap();
    assert!(
        message.starts_with("plugin broken did not load: Error: no luck"),
        "{message}"
    );
    client.end().await;
}

#[tokio::test]
async fn a_request_before_initialize_an_unknown_method_and_no_json_get_errors() {
    let place = Place::new(
        "rpc",
        "a_request_before_initialize_an_unknown_method_and_no_json_get_errors",
    );
    let mut client = Client::start(&place, Box::new(ScriptedTransport::default()));

    let early = client.call("session/new", settings(&place)).await;
    client.initialize().await;
    let unknown = client.call("session/delete", json!({})).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    let bad_block = client
        .call(
            "session/input",
            json!({ "sessionId": session, "content": [{ "session/input": "hi" }] }),
        )
        .await;
    client.write("{ no json").await;
    let broken = client.next().await;

    assert_eq!(early.unwrap_err()["code"], json!(ResponseError::INVALID_REQUEST));
    assert_eq!(unknown.unwrap_err()["code"], json!(ResponseError::METHOD_NOT_FOUND));
    assert_eq!(bad_block.unwrap_err()["code"], json!(ResponseError::INVALID_PARAMS));
    assert_eq!(broken["id"], Value::Null);
    assert_eq!(broken["error"]["code"], json!(ResponseError::PARSE_ERROR));
    client.end().await;
}

#[tokio::test]
async fn a_background_job_tells_its_start_and_end_then_sends_an_input_that_the_model_reads() {
    let place = Place::new("rpc", "background_job_end");
    let arguments = json!({ "command": "exit 3", "background": true }).to_string();
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "exec", &arguments)]),
        text_reply("started"),
        text_reply("noted"),
    ]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client
        .request("session/input", input_params(&session, "start a job"))
        .await;

    // The job can end during the first turn or after it. Its input then joins that turn, or it starts a new one. The
    // wait ends at the first idle state after a commit that consumed the input.
    let mut messages = Vec::new();
    let mut job_input = None;
    let mut consumed = false;
    loop {
        let message = client.next().await;
        let update = &message["params"]["update"];
        if update["sessionUpdate"] == "input_accepted" && update["input"]["source"]["name"] == "host:jobs" {
            job_input = Some((messages.len(), update["inputId"].clone(), update["input"].clone()));
        } else if let Some((_, id, _)) = &job_input
            && update["sessionUpdate"] == "commit"
            && update["consumed"]
                .as_array()
                .unwrap()
                .iter()
                .any(|input| &input["id"] == id)
        {
            consumed = true;
        } else if consumed && is_idle(&message) {
            break;
        }
        messages.push(message);
    }

    let (input_index, _, job_input) = job_input.unwrap();
    let jobs: Vec<&Value> = messages[..input_index]
        .iter()
        .filter(|message| message["params"]["update"]["sessionUpdate"] == "job")
        .map(|message| &message["params"]["update"]["job"])
        .collect();
    // The start and the end update come before the end input.
    assert_eq!(jobs.len(), 2, "{jobs:?}");
    assert_eq!(jobs[0]["state"], "running");
    assert_eq!(jobs[0]["command"], "exit 3");
    // The end update holds the whole job.
    assert_eq!(
        (&jobs[1]["id"], &jobs[1]["command"], &jobs[1]["log"]),
        (&jobs[0]["id"], &jobs[0]["command"], &jobs[0]["log"])
    );
    assert_eq!(
        (&jobs[1]["state"], &jobs[1]["exitCode"], &jobs[1]["stopped"]),
        (&json!("ended"), &json!(3), &json!(false))
    );
    let shown = job_input["content"][0]["user_text"].as_str().unwrap();
    assert!(shown.starts_with("job-") && shown.ends_with(" ended"), "{shown}");
    let job = shown.trim_end_matches(" ended");
    let model_text = job_input["modelContent"][0]["user_text"].as_str().unwrap();
    assert!(
        model_text.starts_with(&format!("<system_notification>{job} exited 3.")),
        "{model_text}"
    );
    assert!(model_text.ends_with("</system_notification>"), "{model_text}");
    // The model reads the whole end text, as JSON in the body of a request.
    let quoted = serde_json::to_string(model_text).unwrap();
    let text = &quoted[1..quoted.len() - 1];
    assert!(
        transport.requests().iter().any(|request| request.contains(text)),
        "{text}"
    );
    client.end().await;
}

/// Save a session of `model` with one waiting input in the store of `place`, before a server runs.
async fn saved_session(place: &Place, provider: &str, model: &str) -> SessionId {
    let store: Arc<dyn Store> = Arc::new(place.store().await);
    let settings = SessionSettings {
        model: ModelReference {
            provider: provider.to_owned(),
            model: model.to_owned(),
        },
        settings: yuke_ai::Settings::new(),
        cwd: place.work.clone(),
    };
    let session = Session::create(store, &settings, &[PromptSection::new("base", "the prompt")])
        .await
        .unwrap();
    let input = Input::new(InputSource::User, vec![yuke_ai::Block::user_text("waiting")]).unwrap();
    session.input().send(input).await.unwrap();
    session.id()
}

#[tokio::test]
async fn a_load_only_reads_and_waiting_input_blocks_new_settings() {
    let place = Place::new("rpc", "a_load_only_reads_and_waiting_input_blocks_new_settings");
    let session = saved_session(&place, "minimax", "MiniMax-M3").await;
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;

    let loaded = client.load(&json!(session), json!({})).await;
    let mut settings = settings(&place);
    settings["sessionId"] = json!(session);
    let id = client.request("session/set_settings", settings).await;
    let refused = client.until(|message| message["id"] == json!(id)).await;
    let reloaded = client.load(&json!(session), json!({ "after": 1 })).await;

    let labels: Vec<String> = loaded.messages.iter().filter_map(label).collect();
    assert_eq!(labels, ["settings", "state idle", "input_accepted", "response"]);
    // No turn started: the session is still idle, and the input still waits.
    assert!(
        !refused
            .iter()
            .chain(&reloaded.messages)
            .any(|message| message["params"]["update"]["state"] == "running")
    );
    assert_eq!(reloaded.state, "idle");
    // The session has one saved event, and the reload asked for the events after it.
    assert!(
        !reloaded
            .messages
            .iter()
            .any(|message| message["params"]["update"].get("seq").is_some()),
        "{:?}",
        reloaded.messages
    );
    assert_eq!(loaded.state, "idle");
    assert_eq!(loaded.pending.len(), 1);
    assert_eq!(loaded.pending[0]["content"][0]["user_text"], "waiting");
    assert_eq!(reloaded.pending, loaded.pending);
    assert_eq!(
        refused.last().unwrap()["error"]["code"],
        json!(ResponseError::INVALID_REQUEST)
    );
    client.end().await;
}

#[tokio::test]
async fn a_fork_that_has_no_credential_fails_and_leaves_no_session() {
    let place = Place::new("rpc", "a_fork_that_has_no_credential_fails_and_leaves_no_session");
    let source = saved_session(&place, "anthropic", "claude-sonnet-4-5").await;
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;

    let forked = client.call("session/fork", json!({ "sessionId": source })).await;
    client.end().await;

    assert_eq!(forked.unwrap_err()["code"], json!(ResponseError::INVALID_PARAMS));
    let store = place.store().await;
    assert_eq!(store.newest_session(&place.work).await.unwrap(), Some(source));
}

/// Send the request `method`, keep each message up to its response in `messages`, and return the response. The
/// request must succeed.
async fn exchange(client: &mut Client, messages: &mut Vec<Value>, method: &str, params: Value) -> Value {
    let id = client.request(method, params).await;
    let received = client.until(|message| message["id"] == json!(id)).await;
    messages.extend(received.iter().cloned());
    let response = received.last().unwrap().clone();
    assert!(response.get("error").is_none(), "{method}: {response}");
    response
}

#[tokio::test]
async fn a_create_a_reopen_and_a_fork_each_run_session_once_and_a_repeated_load_does_not() {
    let place = Place::new(
        "rpc",
        "a_create_a_reopen_and_a_fork_each_run_session_once_and_a_repeated_load_does_not",
    );
    place.plugin(
        "counter",
        "let count = 0; export function session(s) { count += 1; s.notify('info', `open ${count}`); }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["counter"] }"#).unwrap();
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;
    let mut messages = Vec::new();

    let created = exchange(&mut client, &mut messages, "session/new", settings(&place)).await;
    let session = created["result"]["sessionId"].clone();
    exchange(
        &mut client,
        &mut messages,
        "session/load",
        json!({ "sessionId": session }),
    )
    .await;
    let close = json!({ "sessionId": session, "stopJobs": false });
    exchange(&mut client, &mut messages, "session/close", close).await;
    exchange(
        &mut client,
        &mut messages,
        "session/load",
        json!({ "sessionId": session }),
    )
    .await;
    let forked = exchange(
        &mut client,
        &mut messages,
        "session/fork",
        json!({ "sessionId": session }),
    )
    .await;
    // A last load of an open session runs no `session`, and its response comes after the notices before it.
    let fork = forked["result"]["sessionId"].clone();
    exchange(&mut client, &mut messages, "session/load", json!({ "sessionId": fork })).await;

    let notices: Vec<&Value> = messages
        .iter()
        .filter(|message| message["method"] == "notice")
        .map(|message| &message["params"]["message"])
        .collect();
    assert_eq!(notices, [&json!("open 1"), &json!("open 2"), &json!("open 3")]);
    client.end().await;
}

#[tokio::test]
async fn a_cancel_and_a_close_end_a_turn_that_waits_for_the_plugins_of_its_session() {
    let place = Place::new(
        "rpc",
        "a_cancel_and_a_close_end_a_turn_that_waits_for_the_plugins_of_its_session",
    );
    place.plugin(
        "slow",
        "export function session(s) { return new Promise((resolve) => s.signal.addEventListener('abort', resolve)); }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["slow"] }"#).unwrap();
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "hi")).await;
    client
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;

    client.notify("session/cancel", json!({ "sessionId": session })).await;
    let cancelled = client.until(is_idle).await;
    client.request("session/input", input_params(&session, "again")).await;
    client
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;
    let id = client
        .request("session/close", json!({ "sessionId": session, "stopJobs": false }))
        .await;
    let closed = client.until(|message| message["id"] == json!(id)).await;

    let end = cancelled
        .iter()
        .find_map(|message| message["params"]["update"]["commit"]["end"].as_object())
        .unwrap();
    assert_eq!(end["outcome"], "cancelled");
    assert_eq!(closed.last().unwrap()["result"], json!({}));
    client.end().await;
}

#[tokio::test]
async fn the_prompt_hook_edits_the_request_of_each_turn_and_the_session_keeps_its_saved_prompt() {
    let place = Place::new(
        "rpc",
        "the_prompt_hook_edits_the_request_of_each_turn_and_the_session_keeps_its_saved_prompt",
    );
    place.plugin(
        "counted",
        "let count = 0;
         export function session(s) {
           s.hook('prompt.build', (build) => { count += 1; build.sections.turn = `number ${count}`; });
         }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["counted"] }"#).unwrap();
    let transport = ScriptedTransport::new([text_reply("one"), text_reply("two")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    let id: SessionId = serde_json::from_value(session.clone()).unwrap();
    let created = place
        .store()
        .await
        .open(id, yuke_agent::Access::Read)
        .await
        .unwrap()
        .prompt;

    client.request("session/input", input_params(&session, "first")).await;
    client.until(is_idle).await;
    client.request("session/input", input_params(&session, "second")).await;
    client.until(is_idle).await;

    let requests = transport.requests();
    assert!(requests[0].contains(r"<turn>\nnumber 1\n</turn>"), "{}", requests[0]);
    assert!(requests[1].contains(r"<turn>\nnumber 2\n</turn>"), "{}", requests[1]);
    assert!(!requests[1].contains("number 1"), "{}", requests[1]);
    let saved = place
        .store()
        .await
        .open(id, yuke_agent::Access::Read)
        .await
        .unwrap()
        .prompt;
    assert_eq!(saved, created);
    client.end().await;
}

#[tokio::test]
async fn a_failed_prompt_hook_sends_a_notice_starts_no_turn_and_leaves_the_input_pending() {
    let place = Place::new(
        "rpc",
        "a_failed_prompt_hook_sends_a_notice_starts_no_turn_and_leaves_the_input_pending",
    );
    place.plugin(
        "broken",
        "export function session(s) { s.hook('prompt.build', () => { throw new Error('no prompt'); }); }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["broken"] }"#).unwrap();
    let transport = ScriptedTransport::new([text_reply("unused")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();

    client.request("session/input", input_params(&session, "hi")).await;
    let messages = client.until(is_idle).await;

    let notice = messages.iter().find(|message| message["method"] == "notice").unwrap();
    let text = notice["params"]["message"].as_str().unwrap();
    assert!(
        text.contains("prompt.build of plugin broken failed: Error: no prompt"),
        "{text}"
    );
    // The notice keeps the stack of the throw, which names the entry of the plugin.
    assert!(text.contains("broken/index.ts"), "{text}");
    assert_eq!(transport.requests(), Vec::<String>::new());
    let id: SessionId = serde_json::from_value(session).unwrap();
    assert_eq!(place.store().await.pending(id).await.unwrap().len(), 1);
    client.end().await;
}

#[tokio::test]
async fn a_close_ends_the_turn_keeps_waiting_input_and_a_load_opens_the_session_again() {
    let place = Place::new(
        "rpc",
        "a_close_ends_the_turn_keeps_waiting_input_and_a_load_opens_the_session_again",
    );
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "first")).await;
    // The turn takes the waiting input when it starts, so the second input comes after its request.
    client
        .until(|message| message["params"]["update"]["sessionUpdate"] == "draft_started")
        .await;
    client
        .call("session/input", input_params(&session, "second"))
        .await
        .unwrap();

    let id = client
        .request("session/close", json!({ "sessionId": session, "stopJobs": false }))
        .await;
    let closed = client.until(|message| message["id"] == json!(id)).await;
    let refused = client.call("session/input", input_params(&session, "third")).await;
    let closed_again = client
        .call("session/close", json!({ "sessionId": session, "stopJobs": false }))
        .await;
    let loaded = client.load(&session, json!({})).await;

    let labels: Vec<String> = closed.iter().filter_map(label).collect();
    assert_eq!(labels.last().unwrap(), "response");
    // A turn that started after the close would stall, and the close would not answer.
    assert!(labels.contains(&"state idle".to_owned()), "{labels:?}");
    assert_eq!(closed.last().unwrap()["result"], json!({}));
    assert_eq!(refused.unwrap_err()["code"], json!(ResponseError::SESSION_NOT_FOUND));
    assert_eq!(
        closed_again.unwrap_err()["code"],
        json!(ResponseError::SESSION_NOT_FOUND)
    );
    assert_eq!(loaded.state, "idle");
    let pending: Vec<&Value> = loaded
        .pending
        .iter()
        .map(|input| &input["content"][0]["user_text"])
        .collect();
    assert_eq!(pending, [&json!("second")]);
    client.end().await;
}

/// A client with a session whose first turn started a background job, the id of that session, and the transport. The
/// job writes its process id to the file `pid` of the place in one rename, so a reader never sees a part of it. Then
/// it sleeps far longer than any test runs.
async fn session_with_a_job(place: &Place) -> (Client, Value, ScriptedTransport) {
    let pid = place.work.join("pid");
    let command = format!(
        "echo $$ > {pid}.part && mv {pid}.part {pid} && exec sleep 3600",
        pid = pid.display()
    );
    let arguments = json!({ "command": command, "background": true }).to_string();
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "exec", &arguments)]), text_reply("started")]);
    let mut client = Client::initialized(place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(place)).await.unwrap()["sessionId"].clone();
    client
        .request("session/input", input_params(&session, "start a job"))
        .await;
    client.until(is_idle).await;
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !place.work.join("pid").exists() {
        assert!(std::time::Instant::now() < deadline, "the job did not start");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    (client, session, transport)
}

/// Whether the job of [`session_with_a_job`] in `place` still runs.
fn job_runs(place: &Place) -> bool {
    let pid: u32 = std::fs::read_to_string(place.work.join("pid"))
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success()
}

/// The id of the one running job of `session`: the job of [`session_with_a_job`]. Its log file exists.
async fn the_job(client: &mut Client, session: &Value) -> Value {
    let listed = client.call("job/list", json!({ "sessionId": session })).await.unwrap();
    let jobs = listed["jobs"].as_array().unwrap();
    assert_eq!(jobs.len(), 1, "{listed}");
    assert!(
        jobs[0]["command"].as_str().unwrap().ends_with(" && exec sleep 3600"),
        "{listed}"
    );
    let id = jobs[0]["id"].as_str().unwrap();
    let log = PathBuf::from(jobs[0]["log"].as_str().unwrap());
    assert_eq!(log.file_name().unwrap(), format!("{id}.log").as_str(), "{listed}");
    assert!(log.exists(), "{listed}");
    jobs[0]["id"].clone()
}

#[tokio::test]
async fn after_a_folder_change_the_tools_work_in_the_new_folder_and_stop_the_old_jobs() {
    let place = Place::new(
        "rpc",
        "after_a_folder_change_the_tools_work_in_the_new_folder_and_stop_the_old_jobs",
    );
    let (mut client, session, transport) = session_with_a_job(&place).await;
    let job = the_job(&mut client, &session).await;
    let other = place.work.join("other");
    std::fs::create_dir(&other).unwrap();
    let mut settings = settings(&place);
    settings["sessionId"] = session.clone();
    settings["cwd"] = json!(other);
    client.call("session/set_settings", settings).await.unwrap();
    transport.push(tool_reply(&[("c2", "stop", &json!({ "id": job }).to_string())]));
    transport.push(tool_reply(&[("c3", "exec", r#"{"command":"pwd"}"#)]));
    transport.push(text_reply("stopped"));

    client
        .request("session/input", input_params(&session, "stop the job"))
        .await;
    client.until(is_idle).await;
    let after = client.call("job/list", json!({ "sessionId": session })).await;

    assert_eq!(after.unwrap(), json!({ "jobs": [] }));
    assert!(!job_runs(&place));
    let last_request = transport.requests().pop().unwrap();
    assert!(
        last_request.contains(&format!("{}\\n", other.display())),
        "{last_request}"
    );
    client.end().await;
}

#[tokio::test]
async fn a_close_needs_stop_jobs_while_jobs_run_and_then_ends_them() {
    let place = Place::new("rpc", "a_close_needs_stop_jobs_while_jobs_run_and_then_ends_them");
    let (mut client, session, _transport) = session_with_a_job(&place).await;
    let job = the_job(&mut client, &session).await;

    let refused = client
        .call("session/close", json!({ "sessionId": session, "stopJobs": false }))
        .await;
    let runs_after_refusal = job_runs(&place);
    let id = client
        .request("session/close", json!({ "sessionId": session, "stopJobs": true }))
        .await;
    let closed = client.until(|message| message["id"] == json!(id)).await;
    let loaded = client.load(&session, json!({})).await;

    let refused = refused.unwrap_err();
    assert_eq!(refused["code"], json!(ResponseError::INVALID_REQUEST));
    assert!(
        refused["message"].as_str().unwrap().contains(job.as_str().unwrap()),
        "{refused}"
    );
    assert!(runs_after_refusal);
    let labels: Vec<String> = closed.iter().filter_map(label).collect();
    assert_eq!(labels, ["job", "response"]);
    let ended = &closed[0]["params"]["update"]["job"];
    assert_eq!(
        (&ended["id"], &ended["state"], &ended["stopped"]),
        (&job, &json!("ended"), &json!(true))
    );
    assert_eq!(closed[1]["result"], json!({}));
    // The close waits for the end of the job, so its process is gone.
    assert!(!job_runs(&place));
    assert_eq!((loaded.state, loaded.jobs), (json!("idle"), Vec::new()));
    client.end().await;
}

#[tokio::test]
async fn job_stop_waits_for_the_end_and_its_job_update_comes_first() {
    let place = Place::new("rpc", "job_stop_waits_for_the_end_and_its_job_update_comes_first");
    let (mut client, session, _transport) = session_with_a_job(&place).await;
    let job = the_job(&mut client, &session).await;

    let loaded = client.load(&session, json!({})).await;
    let id = client
        .request("job/stop", json!({ "sessionId": session, "jobId": job }))
        .await;
    let stopped = client.until(|message| message["id"] == json!(id)).await;
    let again = client
        .call("job/stop", json!({ "sessionId": session, "jobId": job }))
        .await;
    // The close waits for the job task, so an end input of the stopped job would come before its response.
    let id = client
        .request("session/close", json!({ "sessionId": session, "stopJobs": false }))
        .await;
    let closed = client.until(|message| message["id"] == json!(id)).await;

    assert_eq!(loaded.jobs.len(), 1);
    let loaded_job = &loaded.jobs[0];
    assert_eq!((&loaded_job["id"], &loaded_job["state"]), (&job, &json!("running")));
    // The snapshot holds the whole job.
    assert!(
        loaded_job["command"].as_str().unwrap().ends_with(" && exec sleep 3600"),
        "{loaded_job}"
    );
    let log = PathBuf::from(loaded_job["log"].as_str().unwrap());
    assert_eq!(
        log.file_name().unwrap(),
        format!("{}.log", job.as_str().unwrap()).as_str()
    );
    // The stop waits, so the process is gone, and the end update comes before the answer.
    assert!(!job_runs(&place));
    assert_eq!(
        stopped.iter().filter_map(label).collect::<Vec<_>>(),
        ["job", "response"]
    );
    assert_eq!(stopped[1]["result"], json!({}));
    let ended = &stopped[0]["params"]["update"]["job"];
    assert_eq!(ended["id"], job);
    assert_eq!(ended["state"], "ended");
    assert_eq!(ended["stopped"], true);
    // The job is `exec sleep`, so SIGTERM ends it.
    assert_eq!(ended["signal"], 15, "{ended}");
    assert_eq!(again.unwrap_err()["code"], json!(ResponseError::JOB_NOT_FOUND));
    assert_eq!(closed.iter().filter_map(label).collect::<Vec<_>>(), ["response"]);
    assert_eq!(closed[0]["result"], json!({}));
    client.end().await;
}

#[tokio::test]
async fn a_session_cannot_stop_the_job_of_another_session() {
    let place = Place::new("rpc", "a_session_cannot_stop_the_job_of_another_session");
    let (mut client, owner, _transport) = session_with_a_job(&place).await;
    let job = the_job(&mut client, &owner).await;
    let other = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();

    let refused = client
        .call("job/stop", json!({ "sessionId": other, "jobId": job }))
        .await;
    let listed = client.call("job/list", json!({ "sessionId": other })).await;

    assert_eq!(refused.unwrap_err()["code"], json!(ResponseError::JOB_NOT_FOUND));
    assert_eq!(listed.unwrap(), json!({ "jobs": [] }));
    assert!(job_runs(&place));
    assert_eq!(the_job(&mut client, &owner).await, job);
    client.end().await;
}

#[tokio::test]
async fn a_client_that_stops_reading_cannot_hold_the_server_after_its_input_ends() {
    let place = Place::new(
        "rpc",
        "a_client_that_stops_reading_cannot_hold_the_server_after_its_input_ends",
    );
    let (mut input, server_input) = tokio::io::duplex(1 << 16);
    // The client keeps its end of the output and never reads it, so the small pipe fills.
    let (server_output, _unread) = tokio::io::duplex(1 << 10);
    let machine = place.machine(Box::new(with_key), Box::new(ScriptedTransport::default()));
    let server = tokio::spawn(serve(
        machine,
        Duration::from_millis(100),
        Clients::One(Stream::new(server_input, server_output)),
        std::future::pending(),
    ));
    let request = json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": 1, "clientInfo": { "name": "test", "version": "1" }
    } });
    for _ in 0..200 {
        input.write_all(format!("{request}\n").as_bytes()).await.unwrap();
    }

    drop(input);
    let ended = tokio::time::timeout(Duration::from_secs(5), server).await;

    ended.expect("the server still waits for the client").unwrap().unwrap();
}

#[tokio::test]
async fn a_panic_in_a_turn_ends_the_turn_and_the_next_input_runs_with_a_note_about_it() {
    let place = Place::new(
        "rpc",
        "a_panic_in_a_turn_ends_the_turn_and_the_next_input_runs_with_a_note_about_it",
    );
    let transport = PanicsOnce::new([text_reply("back")]);
    let mut client = Client::initialized(&place, Box::new(transport)).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "first")).await;

    let failed = client.until(|message| message["method"] == "notice").await;
    // The recovery ends the turn that the panic left open, and the client sees that end.
    let repaired = client
        .until(|message| message["params"]["update"]["sessionUpdate"] == "commit")
        .await;
    client
        .call("session/input", input_params(&session, "second"))
        .await
        .unwrap();
    let again = client.until(is_idle).await;

    let labels: Vec<String> = failed.iter().filter_map(label).collect();
    assert!(labels.contains(&"state running".to_owned()), "{labels:?}");
    // The unwind drops the turn, which tells the client that its provisional state is gone.
    assert_eq!(labels[labels.len() - 2..], ["turn_unconfirmed", "state idle"]);
    let notice = &failed.last().unwrap()["params"];
    assert!(
        notice["message"].as_str().unwrap().starts_with("the turn failed:"),
        "{notice}"
    );
    assert_eq!(notice["level"], "error");
    let end = &repaired.last().unwrap()["params"]["update"]["commit"]["end"];
    assert_eq!(end["failed"], "the turn stopped before it saved its end", "{end}");
    let saved: Vec<&Value> = again
        .iter()
        .filter(|message| message["params"]["update"]["sessionUpdate"] == "commit")
        .collect();
    let first = saved.first().unwrap()["params"]["update"].to_string();
    assert!(
        first.contains("<system_notification>The previous turn ended with an error: the turn stopped before it saved its end</system_notification>"),
        "{first}"
    );
    assert!(
        saved.iter().any(|message| message.to_string().contains("back")),
        "{again:?}"
    );
    client.end().await;
}

#[tokio::test]
async fn a_server_that_ends_without_its_shutdown_still_stops_its_turns() {
    let place = Place::new("rpc", "a_server_that_ends_without_its_shutdown_still_stops_its_turns");
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "hi")).await;
    client
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;

    client.server.as_ref().unwrap().abort();
    // Each running task holds the output open, so its end shows that the stalled turn stopped.
    let drained = tokio::time::timeout(Duration::from_secs(5), async {
        while client.output.next_line().await.is_ok_and(|line| line.is_some()) {}
    })
    .await;

    assert!(drained.is_ok(), "a turn still runs after the server ended");
}

/// A place where `xai-grok/test` speaks Anthropic Messages, as the scripted replies do.
fn place_with_login_model(name: &str) -> Place {
    let place = Place::new("rpc", name);
    std::fs::create_dir_all(&place.paths.config).unwrap();
    let providers = json!({ "providers": [{
        "id": "xai-grok",
        "endpoints": [
            { "protocol": "openai_responses", "credential_header": "authorization_bearer" },
            { "protocol": "anthropic_messages", "credential_header": "authorization_bearer" }
        ],
        "models": [{ "id": "test", "protocol": "anthropic_messages", "limits": { "max_output_tokens": 1000 } }]
    }] });
    std::fs::write(place.paths.config.join("providers.json"), providers.to_string()).unwrap();
    place
}

/// Push `token` for `xai-grok`, valid for an hour.
async fn push(client: &mut Client, token: &str) -> Result<Value, Value> {
    let expires_at = crate::auth::millis(std::time::SystemTime::now()) + 3_600_000;
    client
        .call(
            "credential/update",
            json!({ "provider": "xai-grok", "accessToken": token, "expiresAt": expires_at }),
        )
        .await
}

/// A new session of `xai-grok/test`, and the params of an input to it.
async fn login_session(client: &mut Client, place: &Place) -> Value {
    let mut settings = settings(place);
    settings["model"] = json!({ "provider": "xai-grok", "model": "test" });
    let session = client.call("session/new", settings).await.unwrap()["sessionId"].clone();
    input_params(&session, "hi")
}

#[tokio::test]
async fn a_pushed_token_serves_each_open_session_and_a_new_push_serves_the_next_request() {
    let place = place_with_login_model("pushed_token");
    let transport = ScriptedTransport::new([text_reply("one"), text_reply("two")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let first_session = login_session(&mut client, &place).await;
    let second_session = login_session(&mut client, &place).await;

    assert_eq!(push(&mut client, "first").await, Ok(json!({})));
    client.request("session/input", first_session).await;
    client.until(is_idle).await;
    push(&mut client, "second").await.unwrap();
    client.request("session/input", second_session).await;
    client.until(is_idle).await;

    assert_eq!(
        transport.header("Authorization"),
        [Some("Bearer first".to_owned()), Some("Bearer second".to_owned())]
    );
    client.end().await;
}

#[tokio::test]
async fn a_credential_update_that_cannot_serve_is_refused_and_keeps_the_token_before_it() {
    let place = place_with_login_model("refused_push");
    let transport = ScriptedTransport::new([text_reply("one")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    push(&mut client, "kept").await.unwrap();
    let later = crate::auth::millis(std::time::SystemTime::now()) + 3_600_000;
    let update = |provider: &str, token: &str, expires_at: u64, account: Option<&str>| {
        let mut params = json!({ "provider": provider, "accessToken": token, "expiresAt": expires_at });
        if let Some(account) = account {
            params["accountId"] = json!(account);
        }
        params
    };
    let bad_token = "accessToken: send a value that is not empty and has no control character";
    let bad_account = "accountId: send a value that is not empty and has no control character";
    let cases = [
        (
            update("openai", "t", later, None),
            "provider: openai has no login flow, so it takes no credential/update",
        ),
        (
            update("nobody", "t", later, None),
            "provider: nobody has no login flow, so it takes no credential/update",
        ),
        (update("xai-grok", "", later, None), bad_token),
        (update("xai-grok", "a\nb", later, None), bad_token),
        (update("xai-grok", "a\tb", later, None), bad_token),
        (update("xai-grok", "t", 1, None), "expiresAt: the token already expired"),
        (
            update("xai-grok", "t", later, Some("account")),
            "accountId: xai-grok names no account, so send none",
        ),
        (update("openai-codex", "t", later, Some("")), bad_account),
    ];

    for (params, message) in cases {
        let error = client.call("credential/update", params.clone()).await.unwrap_err();
        assert_eq!(error["code"], json!(-32602), "{params}");
        assert_eq!(error["message"], json!(message), "{params}");
    }
    let missing = client
        .call(
            "credential/update",
            json!({ "provider": "xai-grok", "accessToken": "t" }),
        )
        .await
        .unwrap_err();
    assert_eq!(missing["code"], json!(-32602), "{missing}");
    let input = login_session(&mut client, &place).await;
    client.request("session/input", input).await;
    client.until(is_idle).await;
    assert_eq!(transport.header("Authorization"), [Some("Bearer kept".to_owned())]);
    client.end().await;
}

#[tokio::test]
async fn a_turn_outlives_its_socket_client_and_the_next_client_takes_it_over() {
    let place = Place::new("rpc", "turn_outlives_client");
    let listening = Listening::start(&place, Box::new(Stalled));
    let mut first = listening.client().await;
    let first_instance = first.initialize().await["instanceId"].clone();
    let session = first.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    first.request("session/input", input_params(&session, "hi")).await;
    first
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;

    drop(first);
    let mut second = listening.client().await;
    let second_instance = second.initialize().await["instanceId"].clone();
    let loaded = second.load(&session, json!({})).await;
    second.notify("session/cancel", json!({ "sessionId": session })).await;
    let ended = second.until(is_idle).await;

    // A missing id would pass the equality as null.
    assert!(first_instance.is_string(), "{first_instance}");
    assert_eq!(second_instance, first_instance);
    assert_eq!(loaded.state, "running");
    assert!(
        ended
            .iter()
            .any(|message| message["params"]["update"]["sessionUpdate"] == "commit"),
        "{ended:?}"
    );
    listening.stop().await;
}

#[tokio::test]
async fn a_new_socket_client_replaces_the_active_client() {
    let place = Place::new("rpc", "new_client_replaces");
    let listening = Listening::start(&place, Box::new(ScriptedTransport::default()));
    let mut first = listening.client().await;
    first.initialize().await;

    let mut second = listening.client().await;
    second.initialize().await;
    let created = second.call("session/new", settings(&place)).await;

    first.expect_closed().await;
    assert!(created.is_ok(), "{created:?}");
    listening.stop().await;
}

#[tokio::test]
async fn a_socket_server_outlives_its_clients_and_its_shutdown_ends_the_turns_then_the_connection() {
    let place = Place::new("rpc", "socket_shutdown");
    let listening = Listening::start(&place, Box::new(Stalled));
    let mut first = listening.client().await;
    first.initialize().await;
    first.end().await;
    let mut second = listening.client().await;
    second.initialize().await;
    let session = second.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    second.request("session/input", input_params(&session, "hi")).await;
    second
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;
    let path = listening.path.clone();

    listening.stop().await;
    let ended = second.until(is_idle).await;

    assert!(
        ended
            .iter()
            .any(|message| message["params"]["update"]["sessionUpdate"] == "commit"),
        "{ended:?}"
    );
    second.expect_closed().await;
    assert!(!path.exists());
}

#[tokio::test]
async fn a_bind_replaces_a_stale_socket_and_refuses_a_held_lock_and_a_file_that_is_no_socket() {
    let stale = socket_path();
    // The standard listener leaves its socket file when it drops, as a server that ends without its shutdown does.
    drop(std::os::unix::net::UnixListener::bind(&stale).unwrap());
    let regular = socket_path();
    std::fs::write(&regular, "kept").unwrap();

    let replaced = Socket::bind(&stale);
    let held = Socket::bind(&stale);
    let not_socket = Socket::bind(&regular);

    assert!(replaced.is_ok(), "{:?}", replaced.as_ref().err());
    let mode = std::fs::metadata(&stale).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    assert!(held.err().unwrap().ends_with("another server listens on the socket"));
    assert!(not_socket.err().unwrap().ends_with("the file is no socket"));
    assert_eq!(std::fs::read_to_string(&regular).unwrap(), "kept");
    drop(replaced);
    assert!(!stale.exists());
    // The drop frees the lock, so the next server binds.
    assert!(Socket::bind(&stale).is_ok());
    for file in [
        stale.with_added_extension("lock"),
        regular.with_added_extension("lock"),
        regular,
    ] {
        std::fs::remove_file(file).unwrap();
    }
}

#[tokio::test]
async fn a_refused_bind_opens_no_connection_to_the_running_server() {
    let path = socket_path();
    let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
    listener.set_nonblocking(true).unwrap();
    let lock = File::create(path.with_added_extension("lock")).unwrap();
    lock.try_lock().unwrap();

    let refused = Socket::bind(&path);

    assert!(refused.is_err());
    // A connection would replace the active client of the server.
    assert_eq!(listener.accept().unwrap_err().kind(), io::ErrorKind::WouldBlock);
    for file in [path.with_added_extension("lock"), path] {
        std::fs::remove_file(file).unwrap();
    }
}

#[tokio::test]
async fn connect_bridges_the_socket_until_the_end_of_its_input() {
    let place = Place::new("rpc", "connect_bridges");
    let listening = Listening::start(&place, Box::new(ScriptedTransport::default()));
    let (input, bridge_input) = tokio::io::duplex(1 << 16);
    let (bridge_output, output) = tokio::io::duplex(1 << 16);
    let path = listening.path.clone();
    let bridge = tokio::spawn(async move { connect(&path, bridge_input, bridge_output).await });
    let mut client = Client::new(input, output);

    let initialized = client.initialize().await;
    // The end of the input ends the connection, and so the bridge.
    client.end().await;
    let bridged = tokio::time::timeout(Duration::from_secs(10), bridge).await;

    assert_eq!(initialized["agentInfo"]["name"], "yuke");
    bridged.expect("the bridge did not end").unwrap().unwrap();
    listening.stop().await;
}

#[tokio::test]
async fn a_shutdown_ends_a_stdio_server_while_its_input_stays_open() {
    let place = Place::new("rpc", "stdio_shutdown");
    let (_input, server_input) = tokio::io::duplex(1 << 16);
    let (server_output, _output) = tokio::io::duplex(1 << 16);
    let shutdown = CancellationToken::new();
    let server = tokio::spawn(serve(
        place.machine(Box::new(with_key), Box::new(ScriptedTransport::default())),
        Duration::from_secs(10),
        Clients::One(Stream::new(server_input, server_output)),
        shutdown.clone().cancelled_owned(),
    ));

    shutdown.cancel();
    let served = tokio::time::timeout(Duration::from_secs(10), server).await;

    served.expect("the server did not end").unwrap().unwrap();
}
