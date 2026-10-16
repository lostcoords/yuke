//! The protocol server against a scripted provider, through a pair of pipes.

use std::ffi::OsString;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, Lines};
use yuke_agent::{Session, Store};
use yuke_ai::transport::Transport;
use yuke_protocol::{Input, InputSource, ModelReference, SessionId, SessionSettings};
use yuke_store::SqliteStore;

use super::*;
use crate::paths::Paths;
use yuke_testing::{ScriptedTransport, Stalled, text_reply, tool_reply};

use crate::testing::PanicsOnce;

/// The folders of one test: the profile and the folder of its sessions.
struct Place {
    paths: Paths,
    work: PathBuf,
}

impl Place {
    fn new(name: &str) -> Place {
        let root = std::env::temp_dir().join(format!("yuke-rpc-tests-{}/{name}", std::process::id()));
        if root.exists() {
            std::fs::remove_dir_all(&root).unwrap();
        }
        std::fs::create_dir_all(root.join("work")).unwrap();
        let root = root.canonicalize().unwrap();
        Place {
            paths: Paths {
                config: root.join("config"),
                data: root.join("data"),
                cache: root.join("cache"),
            },
            work: root.join("work"),
        }
    }

    /// The machine of a server in the place, with the key of MiniMax.
    fn machine(&self, transport: Box<dyn Transport>) -> Machine {
        Machine {
            paths: self.paths.clone(),
            home: None,
            variable: Box::new(|name| (name == "MINIMAX_API_KEY").then(|| OsString::from("test-key"))),
            transport,
        }
    }

    /// Settings of a session in the folder of the place.
    fn settings(&self) -> Value {
        serde_json::to_value(SessionSettings {
            model: ModelReference {
                provider: "minimax".to_owned(),
                model: "MiniMax-M3".to_owned(),
            },
            settings: yuke_ai::Settings::new(),
            cwd: self.work.clone(),
        })
        .unwrap()
    }
}

/// The client side of a server that runs in this test.
struct Client {
    input: DuplexStream,
    output: Lines<BufReader<DuplexStream>>,
    next_id: i64,
    server: JoinHandle<Result<(), String>>,
}

impl Client {
    fn start(place: &Place, transport: Box<dyn Transport>) -> Client {
        let (input, server_input) = tokio::io::duplex(1 << 16);
        let (server_output, output) = tokio::io::duplex(1 << 16);
        let server = tokio::spawn(serve(
            place.machine(transport),
            Duration::from_secs(10),
            server_input,
            server_output,
        ));
        Client {
            input,
            output: BufReader::new(output).lines(),
            next_id: 0,
            server,
        }
    }

    /// A client after `initialize`.
    async fn initialized(place: &Place, transport: Box<dyn Transport>) -> Client {
        let mut client = Client::start(place, transport);
        client
            .call(
                "initialize",
                json!({ "protocolVersion": 1, "clientInfo": { "name": "test", "version": "1" } }),
            )
            .await
            .unwrap();
        client
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

    /// End the input, and wait for the server to end.
    /// End the input, and wait for the server to end. The rest of the output is read, so a full pipe cannot hold the
    /// server.
    async fn end(self) {
        let Client {
            input,
            mut output,
            server,
            ..
        } = self;
        drop(input);
        let drain = async { while output.next_line().await.is_ok_and(|line| line.is_some()) {} };
        let (ended, ()) = tokio::time::timeout(Duration::from_secs(10), async { tokio::join!(server, drain) })
            .await
            .expect("the server did not end within ten seconds");
        ended.unwrap().unwrap();
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
    let place = Place::new("an_input_starts_a_turn_and_the_client_sees_its_updates_in_order");
    let transport = ScriptedTransport::new([text_reply("hello")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", place.settings()).await.unwrap()["sessionId"].clone();

    client
        .request(
            "session/input",
            json!({ "sessionId": session, "content": [{ "user_text": "hi" }] }),
        )
        .await;
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
    let place = Place::new("a_load_sends_the_saved_events_then_the_state_then_an_empty_answer");
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([text_reply("hello")]))).await;
    let session = client.call("session/new", place.settings()).await.unwrap()["sessionId"].clone();
    client
        .request(
            "session/input",
            json!({ "sessionId": session, "content": [{ "user_text": "hi" }] }),
        )
        .await;
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
    let place = Place::new("a_running_session_refuses_new_settings_and_a_cancel_ends_its_turn");
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;
    let session = client.call("session/new", place.settings()).await.unwrap()["sessionId"].clone();
    client
        .request(
            "session/input",
            json!({ "sessionId": session, "content": [{ "user_text": "hi" }] }),
        )
        .await;
    client
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;

    let mut settings = place.settings();
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
async fn the_server_writes_the_system_prompt_of_a_new_session() {
    let place = Place::new("the_server_writes_the_system_prompt_of_a_new_session");
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;
    let mut settings = place.settings();
    settings["settings"]["system"] = json!("the prompt of the client");

    let session = client.call("session/new", settings).await.unwrap()["sessionId"].clone();
    let id = client.request("session/load", json!({ "sessionId": session })).await;
    let messages = client.until(|message| message["id"] == json!(id)).await;

    let system = messages[0]["params"]["update"]["settings"]["system"].as_str().unwrap();
    assert!(!system.contains("the prompt of the client"), "{system}");
    assert!(system.contains(place.work.to_str().unwrap()), "{system}");
    client.end().await;
}

#[tokio::test]
async fn a_regular_file_is_no_folder_for_a_new_session_or_new_settings() {
    let place = Place::new("a_regular_file_is_no_folder_for_a_new_session_or_new_settings");
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;
    let file = place.work.join("notes.txt");
    std::fs::write(&file, "notes").unwrap();
    let session = client.call("session/new", place.settings()).await.unwrap()["sessionId"].clone();
    let mut new = place.settings();
    new["cwd"] = json!(file);
    let mut changed = place.settings();
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
async fn a_request_before_initialize_an_unknown_method_and_no_json_get_errors() {
    let place = Place::new("a_request_before_initialize_an_unknown_method_and_no_json_get_errors");
    let mut client = Client::start(&place, Box::new(ScriptedTransport::default()));

    let early = client.call("session/new", place.settings()).await;
    client
        .call(
            "initialize",
            json!({ "protocolVersion": 1, "clientInfo": { "name": "test", "version": "1" } }),
        )
        .await
        .unwrap();
    let unknown = client.call("session/delete", json!({})).await;
    let session = client.call("session/new", place.settings()).await.unwrap()["sessionId"].clone();
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
async fn a_background_job_that_ends_sends_its_input_and_the_model_reads_it() {
    let place = Place::new("a_background_job_that_ends_sends_its_input_and_the_model_reads_it");
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "exec", r#"{"command":"echo done","background":true}"#)]),
        text_reply("started"),
        text_reply("noted"),
    ]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", place.settings()).await.unwrap()["sessionId"].clone();
    client
        .request(
            "session/input",
            json!({ "sessionId": session, "content": [{ "user_text": "start a job" }] }),
        )
        .await;

    // The job can end during the first turn or after it. Its input then joins that turn, or it starts a new one. The
    // wait ends at the first idle state after a commit that consumed the input.
    let mut job_input = None;
    let mut consumed = false;
    loop {
        let message = client.next().await;
        let update = &message["params"]["update"];
        if update["sessionUpdate"] == "input_accepted" && update["input"]["source"]["name"] == "host:jobs" {
            job_input = Some((update["inputId"].clone(), update["input"].clone()));
        } else if let Some((id, _)) = &job_input
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
    }

    let (_, job_input) = job_input.unwrap();
    let shown = job_input["content"][0]["user_text"].as_str().unwrap();
    assert!(shown.starts_with("job-") && shown.ends_with(" ended"), "{shown}");
    let job = shown.trim_end_matches(" ended");
    let model_text = job_input["modelContent"][0]["user_text"].as_str().unwrap();
    assert!(
        model_text.starts_with(&format!("<system_notification>{job} exited 0.")),
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
    let store: Arc<dyn Store> = Arc::new(SqliteStore::open(&place.paths.data).await.unwrap());
    let settings = SessionSettings {
        model: ModelReference {
            provider: provider.to_owned(),
            model: model.to_owned(),
        },
        settings: yuke_ai::Settings::new(),
        cwd: place.work.clone(),
    };
    let session = Session::create(store, &settings).await.unwrap();
    let input = Input::new(InputSource::User, vec![yuke_ai::Block::user_text("waiting")]).unwrap();
    session.input().send(input).await.unwrap();
    session.id()
}

#[tokio::test]
async fn a_load_only_reads_and_waiting_input_blocks_new_settings() {
    let place = Place::new("a_load_only_reads_and_waiting_input_blocks_new_settings");
    let session = saved_session(&place, "minimax", "MiniMax-M3").await;
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;

    let loaded = client.load(&json!(session), json!({})).await;
    let mut settings = place.settings();
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
    let place = Place::new("a_fork_that_has_no_credential_fails_and_leaves_no_session");
    let source = saved_session(&place, "anthropic", "claude-sonnet-4-5").await;
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;

    let forked = client.call("session/fork", json!({ "sessionId": source })).await;
    client.end().await;

    assert_eq!(forked.unwrap_err()["code"], json!(ResponseError::INVALID_PARAMS));
    let store = SqliteStore::open(&place.paths.data).await.unwrap();
    assert_eq!(store.newest_session(&place.work).await.unwrap(), Some(source));
}

#[tokio::test]
async fn a_close_ends_the_turn_keeps_waiting_input_and_a_load_opens_the_session_again() {
    let place = Place::new("a_close_ends_the_turn_keeps_waiting_input_and_a_load_opens_the_session_again");
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;
    let session = client.call("session/new", place.settings()).await.unwrap()["sessionId"].clone();
    client
        .request(
            "session/input",
            json!({ "sessionId": session, "content": [{ "user_text": "first" }] }),
        )
        .await;
    client
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;
    client
        .call(
            "session/input",
            json!({ "sessionId": session, "content": [{ "user_text": "second" }] }),
        )
        .await
        .unwrap();

    let id = client
        .request("session/close", json!({ "sessionId": session, "stopJobs": false }))
        .await;
    let closed = client.until(|message| message["id"] == json!(id)).await;
    let refused = client
        .call(
            "session/input",
            json!({ "sessionId": session, "content": [{ "user_text": "third" }] }),
        )
        .await;
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
    let session = client.call("session/new", place.settings()).await.unwrap()["sessionId"].clone();
    client
        .request(
            "session/input",
            json!({ "sessionId": session, "content": [{ "user_text": "start a job" }] }),
        )
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
    let place = Place::new("after_a_folder_change_the_tools_work_in_the_new_folder_and_stop_the_old_jobs");
    let (mut client, session, transport) = session_with_a_job(&place).await;
    let job = the_job(&mut client, &session).await;
    let other = place.work.join("other");
    std::fs::create_dir(&other).unwrap();
    let mut settings = place.settings();
    settings["sessionId"] = session.clone();
    settings["cwd"] = json!(other);
    client.call("session/set_settings", settings).await.unwrap();
    transport.push(tool_reply(&[("c2", "stop", &json!({ "id": job }).to_string())]));
    transport.push(tool_reply(&[("c3", "exec", r#"{"command":"pwd"}"#)]));
    transport.push(text_reply("stopped"));

    client
        .request(
            "session/input",
            json!({ "sessionId": session, "content": [{ "user_text": "stop the job" }] }),
        )
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
    let place = Place::new("a_close_needs_stop_jobs_while_jobs_run_and_then_ends_them");
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
    let place = Place::new("job_stop_waits_for_the_end_and_its_job_update_comes_first");
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
async fn job_updates_tell_the_start_and_the_end_before_the_end_input() {
    let place = Place::new("job_updates_tell_the_start_and_the_end_before_the_end_input");
    let arguments = json!({ "command": "exit 3", "background": true }).to_string();
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "exec", &arguments)]),
        text_reply("started"),
        text_reply("noted"),
    ]);
    let mut client = Client::initialized(&place, Box::new(transport)).await;
    let session = client.call("session/new", place.settings()).await.unwrap()["sessionId"].clone();

    client
        .request(
            "session/input",
            json!({ "sessionId": session, "content": [{ "user_text": "start a job" }] }),
        )
        .await;
    let messages = client
        .until(|message| message["params"]["update"]["input"]["source"]["name"] == "host:jobs")
        .await;

    let jobs: Vec<&Value> = messages
        .iter()
        .filter(|message| message["params"]["update"]["sessionUpdate"] == "job")
        .map(|message| &message["params"]["update"]["job"])
        .collect();
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
    // The end update comes before the end input, which is the last message.
    assert_eq!(label(messages.last().unwrap()).unwrap(), "input_accepted");
    client.until(is_idle).await;
    client.end().await;
}

#[tokio::test]
async fn a_session_cannot_stop_the_job_of_another_session() {
    let place = Place::new("a_session_cannot_stop_the_job_of_another_session");
    let (mut client, owner, _transport) = session_with_a_job(&place).await;
    let job = the_job(&mut client, &owner).await;
    let other = client.call("session/new", place.settings()).await.unwrap()["sessionId"].clone();

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
    let place = Place::new("a_client_that_stops_reading_cannot_hold_the_server_after_its_input_ends");
    let (mut input, server_input) = tokio::io::duplex(1 << 16);
    // The client keeps its end of the output and never reads it, so the small pipe fills.
    let (server_output, _unread) = tokio::io::duplex(1 << 10);
    let machine = place.machine(Box::new(ScriptedTransport::default()));
    let server = tokio::spawn(serve(machine, Duration::from_millis(100), server_input, server_output));
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
    let place = Place::new("a_panic_in_a_turn_ends_the_turn_and_the_next_input_runs_with_a_note_about_it");
    let transport = PanicsOnce::new([text_reply("back")]);
    let mut client = Client::initialized(&place, Box::new(transport)).await;
    let session = client.call("session/new", place.settings()).await.unwrap()["sessionId"].clone();
    client
        .request(
            "session/input",
            json!({ "sessionId": session, "content": [{ "user_text": "first" }] }),
        )
        .await;

    let failed = client.until(|message| message["method"] == "notice").await;
    // The recovery ends the turn that the panic left open, and the client sees that end.
    let repaired = client
        .until(|message| message["params"]["update"]["sessionUpdate"] == "commit")
        .await;
    client
        .call(
            "session/input",
            json!({ "sessionId": session, "content": [{ "user_text": "second" }] }),
        )
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
    let place = Place::new("a_server_that_ends_without_its_shutdown_still_stops_its_turns");
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;
    let session = client.call("session/new", place.settings()).await.unwrap()["sessionId"].clone();
    client
        .request(
            "session/input",
            json!({ "sessionId": session, "content": [{ "user_text": "hi" }] }),
        )
        .await;
    client
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;

    client.server.abort();
    // Each running task holds the output open, so its end shows that the stalled turn stopped.
    let drained = tokio::time::timeout(Duration::from_secs(5), async {
        while client.output.next_line().await.is_ok_and(|line| line.is_some()) {}
    })
    .await;

    assert!(drained.is_ok(), "a turn still runs after the server ended");
}
