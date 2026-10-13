//! Whole runs of `yuke -p` against a scripted provider.

use std::collections::VecDeque;
use std::pin::Pin;
use std::sync::Mutex;
use std::task::{Context, Poll};
use std::time::Instant;

use bytes::Bytes;
use yuke_agent::Access;
use yuke_ai::Effort;
use yuke_ai::transport::{Body, BoxBody, BoxFuture, Fault, Head, Outgoing};
use yuke_engine::Outcome;
use yuke_protocol::SessionEvent;

use super::*;

const MODEL: &str = "minimax/MiniMax-M3";

/// The folders of one test: the profile, the current folder, and the home folder.
struct Place {
    paths: Paths,
    cwd: PathBuf,
    home: PathBuf,
}

impl Place {
    /// New empty folders for the test `name`.
    fn new(name: &str) -> Place {
        let root = std::env::temp_dir().join(format!("yuke-print-tests-{}/{name}", std::process::id()));
        if root.exists() {
            std::fs::remove_dir_all(&root).unwrap();
        }
        let cwd = root.join("work");
        let home = root.join("home");
        std::fs::create_dir_all(&cwd).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        let root = root.canonicalize().unwrap();
        Place {
            paths: Paths {
                config: root.join("config"),
                data: root.join("data"),
                cache: root.join("cache"),
            },
            cwd: root.join("work"),
            home: root.join("home"),
        }
    }

    /// The store of the place, opened again.
    async fn store(&self) -> SqliteStore {
        SqliteStore::open(&self.paths.data).await.unwrap()
    }
}

/// The MiniMax key that every test environment holds.
fn with_key(name: &str) -> Option<OsString> {
    (name == "MINIMAX_API_KEY").then(|| OsString::from("test-key"))
}

fn no_variable(_: &str) -> Option<OsString> {
    None
}

/// Run `task` in `place` with `replies` as the answers of the provider. Answer the run and the request bodies.
async fn run_with(place: &Place, task: &Task, replies: &[String]) -> (Result<Finished, String>, Vec<String>) {
    run_in(place, task, replies, &with_key, CancellationToken::new()).await
}

async fn run_in(
    place: &Place,
    task: &Task,
    replies: &[String],
    variable: &(dyn Fn(&str) -> Option<OsString> + Sync),
    cancellation_token: CancellationToken,
) -> (Result<Finished, String>, Vec<String>) {
    let transport = ScriptedTransport::new(replies);
    let machine = Machine {
        paths: place.paths.clone(),
        cwd: place.cwd.clone(),
        home: Some(place.home.clone()),
        variable,
        transport: &transport,
    };
    let finished = run(task, &machine, cancellation_token).await;
    (finished, transport.requests())
}

fn task(prompt: &str, session: SessionChoice) -> Task {
    Task {
        prompt: prompt.to_owned(),
        model: Some(MODEL.to_owned()),
        reasoning: None,
        session,
    }
}

fn completed() -> TurnEnd {
    TurnEnd::Outcome(Outcome::Completed {
        finish_reason: yuke_ai::FinishReason::Stop,
    })
}

#[tokio::test]
async fn a_new_run_saves_a_session_in_the_current_folder_and_answers_the_last_text() {
    let place = Place::new("new_run");

    let (finished, requests) = run_with(&place, &task("Say hello.", SessionChoice::New), &[text_reply("Hello.")]).await;

    let finished = finished.unwrap();
    assert_eq!(finished.end, completed());
    assert_eq!(finished.text, "Hello.");
    let opened = place.store().await.open(finished.session, Access::Read).await.unwrap();
    assert_eq!(opened.settings.cwd, place.cwd);
    assert_eq!(opened.settings.model, ModelReference::new("minimax", "MiniMax-M3"));
    assert!(opened.settings.settings.system.starts_with("You are yuke"));
    assert_eq!(
        opened.context,
        [Block::user_text("Say hello."), Block::assistant_text("Hello.")]
    );
    assert_eq!(requests.len(), 1);
    assert!(requests[0].contains("You are yuke"), "{}", requests[0]);
}

#[tokio::test]
async fn the_model_of_a_new_session_comes_from_the_config_when_the_command_line_names_none() {
    let place = Place::new("config_model");
    std::fs::create_dir_all(&place.paths.config).unwrap();
    std::fs::write(
        place.paths.config.join("config.json"),
        "{\n  // The default.\n  \"model\": \"minimax/MiniMax-M2.7\"\n}\n",
    )
    .unwrap();
    let task = Task {
        model: None,
        ..task("Hi.", SessionChoice::New)
    };

    let (finished, _) = run_with(&place, &task, &[text_reply("Hi.")]).await;

    let opened = place
        .store()
        .await
        .open(finished.unwrap().session, Access::Read)
        .await
        .unwrap();
    assert_eq!(opened.settings.model, ModelReference::new("minimax", "MiniMax-M2.7"));
}

#[tokio::test]
async fn no_model_is_an_error_that_names_the_config_file() {
    let place = Place::new("no_model");
    let task = Task {
        model: None,
        ..task("Hi.", SessionChoice::New)
    };

    let (finished, requests) = run_with(&place, &task, &[]).await;

    assert_eq!(
        finished,
        Err(format!(
            "no model: pass --model <provider/model>, or set \"model\" in {}",
            place.paths.config.join("config.json").display()
        ))
    );
    assert_eq!(requests, Vec::<String>::new());
}

#[tokio::test]
async fn a_missing_or_empty_api_key_is_an_error_and_saves_no_session() {
    let place = Place::new("no_key");
    let empty = |_: &str| Some(OsString::new());

    for variable in [&no_variable as &(dyn Fn(&str) -> Option<OsString> + Sync), &empty] {
        let (finished, _) = run_in(
            &place,
            &task("Hi.", SessionChoice::New),
            &[],
            variable,
            CancellationToken::new(),
        )
        .await;

        assert_eq!(
            finished,
            Err("no API key: set MINIMAX_API_KEY for MiniMax (minimax.io)".to_owned())
        );
    }
    assert_eq!(place.store().await.newest_session(&place.cwd).await.unwrap(), None);
}

#[tokio::test]
async fn a_level_that_the_model_does_not_take_is_an_error() {
    let place = Place::new("bad_level");
    let task = Task {
        reasoning: Some(ReasoningLevel::Effort(Effort::Low)),
        ..task("Hi.", SessionChoice::New)
    };

    let (finished, _) = run_with(&place, &task, &[]).await;

    assert_eq!(
        finished,
        Err("minimax/MiniMax-M3: the model does not support that reasoning level".to_owned())
    );
}

#[tokio::test]
async fn continue_takes_the_session_of_the_folder_with_the_newest_event() {
    let place = Place::new("continue");
    run_with(&place, &task("First.", SessionChoice::New), &[text_reply("One.")])
        .await
        .0
        .unwrap();
    let second = run_with(&place, &task("Second.", SessionChoice::New), &[text_reply("Two.")])
        .await
        .0
        .unwrap();

    let (finished, requests) = run_with(&place, &task("Third.", SessionChoice::Newest), &[text_reply("Three.")]).await;

    assert_eq!(finished.unwrap().session, second.session);
    assert!(
        requests[0].contains("Second.") && !requests[0].contains("First."),
        "{}",
        requests[0]
    );
}

#[tokio::test]
async fn a_broken_config_does_not_block_a_continued_session() {
    let place = Place::new("broken_config");
    run_with(&place, &task("First.", SessionChoice::New), &[text_reply("One.")])
        .await
        .0
        .unwrap();
    std::fs::create_dir_all(&place.paths.config).unwrap();
    std::fs::write(place.paths.config.join("config.json"), "{ broken").unwrap();

    let (continued, _) = run_with(&place, &task("Second.", SessionChoice::Newest), &[text_reply("Two.")]).await;
    let (new, _) = run_with(&place, &task("Third.", SessionChoice::New), &[]).await;

    assert_eq!(continued.unwrap().text, "Two.");
    assert!(
        new.unwrap_err()
            .starts_with(&place.paths.config.join("config.json").display().to_string())
    );
}

#[tokio::test]
async fn continue_in_a_folder_without_a_session_is_an_error() {
    let place = Place::new("continue_none");

    let (finished, _) = run_with(&place, &task("Hi.", SessionChoice::Newest), &[]).await;

    assert_eq!(finished, Err(format!("no session works in {}", place.cwd.display())));
}

#[tokio::test]
async fn a_session_id_continues_that_session_and_an_unknown_id_is_an_error() {
    let place = Place::new("session_id");
    let first = run_with(&place, &task("First.", SessionChoice::New), &[text_reply("One.")])
        .await
        .0
        .unwrap();
    run_with(&place, &task("Second.", SessionChoice::New), &[text_reply("Two.")])
        .await
        .0
        .unwrap();

    let (finished, requests) = run_with(
        &place,
        &task("Again.", SessionChoice::Id(first.session)),
        &[text_reply("Back.")],
    )
    .await;
    let unknown = SessionId::generate();
    let (missing, _) = run_with(&place, &task("Hi.", SessionChoice::Id(unknown)), &[]).await;

    assert_eq!(finished.unwrap().session, first.session);
    assert!(
        requests[0].contains("First.") && !requests[0].contains("Second."),
        "{}",
        requests[0]
    );
    assert_eq!(missing, Err(format!("no session has the id {unknown}")));
}

#[tokio::test]
async fn a_level_or_a_model_on_a_continued_session_saves_new_settings() {
    let place = Place::new("new_settings");
    let first = run_with(&place, &task("First.", SessionChoice::New), &[text_reply("One.")])
        .await
        .0
        .unwrap();
    let level = Task {
        model: None,
        reasoning: Some(ReasoningLevel::Effort(Effort::High)),
        ..task("Second.", SessionChoice::Newest)
    };
    let model = Task {
        model: Some("minimax/MiniMax-M2.7".to_owned()),
        ..task("Third.", SessionChoice::Newest)
    };

    run_with(&place, &level, &[text_reply("Two.")]).await.0.unwrap();
    run_with(&place, &model, &[text_reply("Three.")]).await.0.unwrap();

    let events = place.store().await.events(first.session, None).await.unwrap();
    let settings: Vec<&SessionSettings> = events
        .iter()
        .filter_map(|stored| match &stored.event {
            SessionEvent::Settings(settings) => Some(settings),
            SessionEvent::Commit { .. } => None,
        })
        .collect();
    let minimax_m3 = ModelReference::new("minimax", "MiniMax-M3");
    assert_eq!(settings.len(), 3);
    assert_eq!(settings[1].model, minimax_m3);
    assert_eq!(
        settings[1].settings.reasoning,
        yuke_ai::ReasoningSettings {
            thinking: Some(yuke_ai::Thinking::Adaptive(None)),
            effort: None,
        }
    );
    // A new model without a level takes the default level.
    assert_eq!(settings[2].model, ModelReference::new("minimax", "MiniMax-M2.7"));
    assert_eq!(settings[2].settings.reasoning, yuke_ai::ReasoningSettings::default());
    assert_eq!(settings[2].settings.system, settings[0].settings.system);
}

#[tokio::test]
async fn the_model_runs_the_built_in_tools_in_the_folder_of_the_session() {
    let place = Place::new("tools");

    let (finished, requests) = run_with(
        &place,
        &task("Where are you?", SessionChoice::New),
        &[
            tool_reply("call-1", "exec", r#"{"command":"pwd"}"#),
            text_reply("Done."),
        ],
    )
    .await;

    assert_eq!(finished.unwrap().text, "Done.");
    assert!(
        requests[1].contains(&format!("{}\\n[exit code: 0]", place.cwd.display())),
        "{}",
        requests[1]
    );
}

#[tokio::test]
async fn a_background_command_fails_because_the_run_ends_with_its_turn() {
    let place = Place::new("background");

    let (_, requests) = run_with(
        &place,
        &task("Start a server.", SessionChoice::New),
        &[
            tool_reply("call-1", "exec", r#"{"command":"touch started","background":true}"#),
            text_reply("Done."),
        ],
    )
    .await;

    assert!(
        requests[1].contains("This run ends with its turn, so it cannot start a background job."),
        "{}",
        requests[1]
    );
    assert!(!place.cwd.join("started").exists());
}

#[tokio::test]
async fn a_cancelled_run_ends_its_turn_as_cancelled() {
    let place = Place::new("cancelled");
    let cancellation_token = CancellationToken::new();
    cancellation_token.cancel();

    let (finished, _) = run_in(
        &place,
        &task("Hi.", SessionChoice::New),
        &[text_reply("Hi.")],
        &with_key,
        cancellation_token,
    )
    .await;

    assert_eq!(finished.unwrap().end, TurnEnd::Outcome(Outcome::Cancelled));
}

#[test]
fn the_answer_text_is_the_text_after_the_last_block_of_the_user() {
    let context = [
        Block::user_text("Go."),
        Block::assistant_text("Early."),
        Block::ToolResult(yuke_ai::ToolResult::error("call-1", "failed")),
        Block::assistant_text("One."),
        Block::assistant_text("Two."),
    ];

    assert_eq!(answer_text(&context), "One.\nTwo.");
    assert_eq!(answer_text(&context[..1]), "");
}

/// One complete Anthropic text answer, as SSE.
fn text_reply(text: &str) -> String {
    sse(&[
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#.to_owned(),
        r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#.to_owned(),
        format!(r#"{{"type":"content_block_delta","index":0,"delta":{{"type":"text_delta","text":"{text}"}}}}"#),
        r#"{"type":"content_block_stop","index":0}"#.to_owned(),
        r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#.to_owned(),
        r#"{"type":"message_stop"}"#.to_owned(),
    ])
}

/// One complete Anthropic answer that calls `name` with the JSON `arguments`, as SSE.
fn tool_reply(id: &str, name: &str, arguments: &str) -> String {
    let partial = serde_json::Value::String(arguments.to_owned()).to_string();
    sse(&[
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#.to_owned(),
        format!(
            r#"{{"type":"content_block_start","index":0,"content_block":{{"type":"tool_use","id":"{id}","name":"{name}","input":{{}}}}}}"#
        ),
        format!(
            r#"{{"type":"content_block_delta","index":0,"delta":{{"type":"input_json_delta","partial_json":{partial}}}}}"#
        ),
        r#"{"type":"content_block_stop","index":0}"#.to_owned(),
        r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}"#.to_owned(),
        r#"{"type":"message_stop"}"#.to_owned(),
    ])
}

fn sse(events: &[String]) -> String {
    events.iter().map(|json| ["data: ", json, "\n\n"].concat()).collect()
}

/// Answers each request with the next scripted reply, and keeps each request body.
struct ScriptedTransport {
    replies: Mutex<VecDeque<String>>,
    requests: Mutex<Vec<String>>,
}

impl ScriptedTransport {
    fn new(replies: &[String]) -> Self {
        ScriptedTransport {
            replies: Mutex::new(replies.iter().cloned().collect()),
            requests: Mutex::default(),
        }
    }

    fn requests(&self) -> Vec<String> {
        self.requests.lock().unwrap().clone()
    }
}

impl Transport for ScriptedTransport {
    fn open<'a>(
        &'a self,
        request: &'a Outgoing<'_>,
        _: Option<Instant>,
    ) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        let body = String::from_utf8(request.body().flatten().copied().collect()).unwrap();
        self.requests.lock().unwrap().push(body);
        let reply = self
            .replies
            .lock()
            .unwrap()
            .pop_front()
            .expect("the script has no reply left");
        let body: BoxBody = Box::pin(OneChunk(Some(Bytes::from(reply))));
        Box::pin(std::future::ready(Ok((Head::new(200), body))))
    }
}

/// A body of one chunk.
struct OneChunk(Option<Bytes>);

impl Body for OneChunk {
    fn poll_chunk(mut self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Option<Result<Bytes, Fault>>> {
        Poll::Ready(self.0.take().map(Ok))
    }
}
