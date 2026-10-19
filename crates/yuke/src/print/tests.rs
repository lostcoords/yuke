//! Whole runs of `yuke -p` against a scripted provider.

use std::ffi::OsString;
use std::time::Instant;

use yuke_agent::{Access, Store};
use yuke_ai::Effort;
use yuke_ai::transport::{BoxBody, BoxFuture, Fault, Head, Outgoing, Transport};

use super::*;
use crate::app::Variable;
use yuke_testing::{ScriptedTransport, Stalled, assert_in_order, text_reply, tool_reply};

use crate::testing::{Place, Rejecting, with_key};

const MODEL: &str = "minimax/MiniMax-M3";

fn no_variable(_: &str) -> Option<OsString> {
    None
}

/// Run `task` in `place` with `replies` as the answers of the provider. Answer the run and the request bodies.
async fn run_with(place: &Place, task: &Task, replies: &[String]) -> (Result<Finished, String>, Vec<String>) {
    run_in(place, task, replies, Box::new(with_key), CancellationToken::new()).await
}

async fn run_in(
    place: &Place,
    task: &Task,
    replies: &[String],
    variable: Box<Variable>,
    cancellation_token: CancellationToken,
) -> (Result<Finished, String>, Vec<String>) {
    let transport = ScriptedTransport::new(replies.to_vec());
    let finished = run(
        task,
        place.machine(variable, Box::new(transport.clone())),
        &place.work,
        cancellation_token,
    )
    .await;
    (finished, transport.requests())
}

fn task(prompt: &str, session: SessionChoice) -> Task {
    Task {
        prompt: prompt.to_owned(),
        // Only a new session gets a model and a reasoning choice here; a continued session keeps its saved ones.
        model: (session == SessionChoice::New).then(|| MODEL.to_owned()),
        reasoning: (session == SessionChoice::New).then_some(ReasoningChoice::Endpoint),
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
    let place = Place::new("print", "new_run");

    let (finished, requests) = run_with(&place, &task("Say hello.", SessionChoice::New), &[text_reply("Hello.")]).await;

    let finished = finished.unwrap();
    assert_eq!(finished.end, completed());
    assert_eq!(finished.text, "Hello.");
    let opened = place.store().await.open(finished.session, Access::Read).await.unwrap();
    assert_eq!(opened.settings.cwd, place.work);
    assert_eq!(
        opened.settings.model,
        ModelReference {
            provider: "minimax".to_owned(),
            model: "MiniMax-M3".to_owned()
        }
    );
    assert!(opened.settings.settings.system.starts_with("You are yuke"));
    assert_eq!(
        opened.context,
        [Block::user_text("Say hello."), Block::assistant_text("Hello.")]
    );
    assert_eq!(requests.len(), 1);
    assert!(requests[0].contains("You are yuke"), "{}", requests[0]);
}

/// Run `task` in `place` with `providers` as the text of `providers.json`. Answer the run and the transport.
async fn run_with_providers(
    place: &Place,
    task: &Task,
    providers: &str,
    variable: Box<Variable>,
) -> (Result<Finished, String>, ScriptedTransport) {
    std::fs::create_dir_all(&place.paths.config).unwrap();
    std::fs::write(place.paths.config.join("providers.json"), providers).unwrap();
    let transport = ScriptedTransport::new([text_reply("Hi.")]);
    let finished = run(
        task,
        place.machine(variable, Box::new(transport.clone())),
        &place.work,
        CancellationToken::new(),
    )
    .await;
    (finished, transport)
}

#[tokio::test]
async fn a_provider_that_providers_json_adds_serves_a_run_without_a_credential() {
    let place = Place::new("print", "added_provider");
    let task = Task {
        model: Some("local/small".to_owned()),
        ..task("Hi.", SessionChoice::New)
    };
    let providers = r#"{ "providers": [{
        "id": "local", "base_url": "http://127.0.0.1:8080/v1",
        "endpoints": [{ "protocol": "anthropic_messages" }],
        "models": [{ "id": "small", "upstream_id": "vendor/small", "limits": { "max_output_tokens": 4096 } }]
    }] }"#;

    let (finished, transport) = run_with_providers(&place, &task, providers, Box::new(no_variable)).await;

    assert_eq!(finished.unwrap().end, completed());
    assert_eq!(transport.urls(), ["http://127.0.0.1:8080/v1/messages"]);
    assert!(
        transport.requests()[0].contains(r#""model":"vendor/small""#),
        "{}",
        transport.requests()[0]
    );
    assert_eq!(transport.header("Authorization"), [None]);
    assert_eq!(transport.header("x-api-key"), [None]);
    // A continued session finds the model in the file too.
    let task = Task {
        session: SessionChoice::Newest,
        ..task
    };
    let (finished, _) = run_with_providers(&place, &task, providers, Box::new(no_variable)).await;
    assert_eq!(finished.unwrap().end, completed());
}

#[tokio::test]
async fn providers_json_changes_the_url_and_the_key_of_a_built_in_provider() {
    let place = Place::new("print", "changed_provider");
    let providers = r#"{ "providers": [
        { "id": "minimax", "base_url": "http://127.0.0.1:9/anthropic", "api_key_env": "PROXY_KEY" }
    ] }"#;
    let variable: Box<Variable> = Box::new(|name| (name == "PROXY_KEY").then(|| OsString::from("proxy-key")));

    let (finished, transport) = run_with_providers(&place, &task("Hi.", SessionChoice::New), providers, variable).await;

    assert_eq!(finished.unwrap().end, completed());
    assert_eq!(transport.urls(), ["http://127.0.0.1:9/anthropic/messages"]);
    assert_eq!(transport.header("Authorization"), [Some("Bearer proxy-key".to_owned())]);
}

#[tokio::test]
async fn a_bad_providers_json_stops_the_run_before_a_request() {
    let place = Place::new("print", "bad_providers");

    let (finished, transport) = run_with_providers(
        &place,
        &task("Hi.", SessionChoice::New),
        r#"{ "providers": [{ "id": "minimax", "base_url": "ftp://h" }] }"#,
        Box::new(with_key),
    )
    .await;

    assert_eq!(
        finished,
        Err(format!(
            "{}: provider minimax: base_url: the URL must start with http:// or https://",
            place.paths.config.join("providers.json").display()
        ))
    );
    assert_eq!(transport.urls(), Vec::<String>::new());
}

#[tokio::test]
async fn a_run_without_a_model_or_a_reasoning_choice_is_an_error_and_sends_nothing() {
    let place = Place::new("print", "no_model");
    run_with(&place, &task("First.", SessionChoice::New), &[text_reply("One.")])
        .await
        .0
        .unwrap();
    let no_model = Task {
        model: None,
        ..task("Hi.", SessionChoice::New)
    };
    let no_reasoning = Task {
        reasoning: None,
        ..task("Hi.", SessionChoice::New)
    };
    // The level of the session may not fit a new model.
    let new_model_only = Task {
        model: Some("minimax/MiniMax-M2.7".to_owned()),
        ..task("Hi.", SessionChoice::Newest)
    };
    let no_level = "no reasoning choice: pass --reasoning <choice>, or --reasoning default to let the endpoint choose";

    for (task, expected) in [
        (no_model, "no model: pass --model <provider/model>"),
        (no_reasoning, no_level),
        (new_model_only, no_level),
    ] {
        let (finished, requests) = run_with(&place, &task, &[]).await;
        assert_eq!(finished, Err(expected.to_owned()), "{task:?}");
        assert_eq!(requests, Vec::<String>::new());
    }
}

#[tokio::test]
async fn a_missing_or_empty_api_key_is_an_error_and_saves_no_session() {
    let place = Place::new("print", "no_key");
    let empty: Box<Variable> = Box::new(|_| Some(OsString::new()));

    for variable in [Box::new(no_variable) as Box<Variable>, empty] {
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
    assert_eq!(place.store().await.newest_session(&place.work).await.unwrap(), None);
}

#[tokio::test]
async fn a_level_that_the_model_does_not_take_is_an_error() {
    let place = Place::new("print", "bad_level");
    let task = Task {
        reasoning: Some(ReasoningChoice::Level(ReasoningLevel::Effort(Effort::Low))),
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
    let place = Place::new("print", "continue");
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
async fn continue_in_a_folder_without_a_session_is_an_error() {
    let place = Place::new("print", "continue_none");

    let (finished, _) = run_with(&place, &task("Hi.", SessionChoice::Newest), &[]).await;

    assert_eq!(finished, Err(format!("no session works in {}", place.work.display())));
}

#[tokio::test]
async fn a_session_id_continues_that_session_and_an_unknown_id_is_an_error() {
    let place = Place::new("print", "session_id");
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
    let place = Place::new("print", "new_settings");
    let first = run_with(&place, &task("First.", SessionChoice::New), &[text_reply("One.")])
        .await
        .0
        .unwrap();
    let level = Task {
        model: None,
        reasoning: Some(ReasoningChoice::Level(ReasoningLevel::Effort(Effort::High))),
        ..task("Second.", SessionChoice::Newest)
    };
    let model = Task {
        model: Some("minimax/MiniMax-M2.7".to_owned()),
        reasoning: Some(ReasoningChoice::Endpoint),
        ..task("Third.", SessionChoice::Newest)
    };

    run_with(&place, &level, &[text_reply("Two.")]).await.0.unwrap();
    run_with(&place, &model, &[text_reply("Three.")]).await.0.unwrap();

    let events = place
        .store()
        .await
        .load(first.session, None)
        .await
        .map(|loaded| loaded.events)
        .unwrap();
    let settings: Vec<&SessionSettings> = events
        .iter()
        .filter_map(|stored| match &stored.event {
            SessionEvent::Settings(settings) => Some(settings),
            SessionEvent::Commit { .. } => None,
        })
        .collect();
    let minimax_m3 = ModelReference {
        provider: "minimax".to_owned(),
        model: "MiniMax-M3".to_owned(),
    };
    assert_eq!(settings.len(), 3);
    assert_eq!(settings[1].model, minimax_m3);
    assert_eq!(
        settings[1].settings.reasoning,
        yuke_ai::ReasoningSettings {
            thinking: Some(yuke_ai::Thinking::Adaptive(None)),
            effort: None,
        }
    );
    // `--reasoning default` lets the endpoint choose the level of the new model.
    assert_eq!(
        settings[2].model,
        ModelReference {
            provider: "minimax".to_owned(),
            model: "MiniMax-M2.7".to_owned()
        }
    );
    assert_eq!(settings[2].settings.reasoning, yuke_ai::ReasoningSettings::default());
    assert_eq!(settings[2].settings.system, settings[0].settings.system);
}

#[tokio::test]
async fn a_new_model_on_a_continued_session_also_answers_the_input_that_waits() {
    let place = Place::new("print", "waiting_input");
    let first = run_with(&place, &task("First.", SessionChoice::New), &[text_reply("One.")])
        .await
        .0
        .unwrap();
    // The store holds an input that waits, as a failed run leaves it.
    let waiting =
        yuke_protocol::Input::new(yuke_protocol::InputSource::User, vec![Block::user_text("Waits.")]).unwrap();
    place.store().await.accept_input(first.session, waiting).await.unwrap();
    let model = Task {
        model: Some("minimax/MiniMax-M2.7".to_owned()),
        reasoning: Some(ReasoningChoice::Endpoint),
        ..task("Next.", SessionChoice::Newest)
    };

    let (finished, requests) = run_with(&place, &model, &[text_reply("Two.")]).await;

    assert_eq!(finished.unwrap().end, completed());
    assert_eq!(requests.len(), 1);
    assert!(requests[0].contains(r#""model":"MiniMax-M2.7""#), "{}", requests[0]);
    assert_in_order(&requests[0], &["Waits.", "Next."]);
}

#[tokio::test]
async fn the_model_runs_the_built_in_tools_in_the_folder_of_the_session() {
    let place = Place::new("print", "tools");

    let (finished, requests) = run_with(
        &place,
        &task("Where are you?", SessionChoice::New),
        &[
            tool_reply(&[("call-1", "exec", r#"{"command":"pwd"}"#)]),
            text_reply("Done."),
        ],
    )
    .await;

    assert_eq!(finished.unwrap().text, "Done.");
    assert!(
        requests[1].contains(&format!("{}\\n[exit code: 0]", place.work.display())),
        "{}",
        requests[1]
    );
}

#[tokio::test]
async fn the_model_calls_a_tool_of_a_plugin_from_the_config() {
    let place = Place::new("print", "plugin_tool");
    place.plugin(
        "greeter",
        "let name;
         export function apply(ctx) { name = ctx.name; }
         export function session(s) {
           s.tools.define({
             name: 'greet', description: 'Greet.', concurrency: 'serial',
             parameters: { type: 'object', properties: {} },
             execute: () => `hello from ${name}`,
           });
         }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["greeter"] }"#).unwrap();

    let (finished, requests) = run_with(
        &place,
        &task("Greet.", SessionChoice::New),
        &[tool_reply(&[("call-1", "greet", "{}")]), text_reply("Done.")],
    )
    .await;

    assert_eq!(finished.unwrap().text, "Done.");
    assert!(requests[0].contains(r#""name":"greet""#), "{}", requests[0]);
    assert!(requests[1].contains("hello from greeter"), "{}", requests[1]);
}

#[tokio::test]
async fn a_background_command_fails_because_the_run_ends_with_its_turn() {
    let place = Place::new("print", "background");

    let (_, requests) = run_with(
        &place,
        &task("Start a server.", SessionChoice::New),
        &[
            tool_reply(&[("call-1", "exec", r#"{"command":"touch started","background":true}"#)]),
            text_reply("Done."),
        ],
    )
    .await;

    assert!(
        requests[1].contains("This run ends with its turn, so it cannot start a background job."),
        "{}",
        requests[1]
    );
    assert!(!place.work.join("started").exists());
}

#[tokio::test]
async fn a_run_cancelled_before_its_turn_ends_as_cancelled_and_leaves_no_input() {
    let place = Place::new("print", "cancelled");
    let cancellation_token = CancellationToken::new();
    cancellation_token.cancel();

    let (finished, requests) = run_in(
        &place,
        &task("Hi.", SessionChoice::New),
        &[text_reply("Hi.")],
        Box::new(with_key),
        cancellation_token,
    )
    .await;

    let finished = finished.unwrap();
    assert_eq!(finished.end, TurnEnd::Outcome(Outcome::Cancelled));
    assert_eq!(requests, Vec::<String>::new());
    // A later run of the session must not answer this prompt.
    assert_eq!(place.store().await.pending(finished.session).await.unwrap(), []);
}

/// Cancels a run when the turn sends its request, and then holds the answer open.
struct CancelsAtRequest(CancellationToken);

impl Transport for CancelsAtRequest {
    fn open<'a>(
        &'a self,
        request: &'a Outgoing<'_>,
        deadline: Option<Instant>,
    ) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        self.0.cancel();
        Stalled.open(request, deadline)
    }
}

#[tokio::test]
async fn a_run_cancelled_during_its_turn_saves_the_turn_as_cancelled() {
    let place = Place::new("print", "cancelled_turn");
    let cancellation_token = CancellationToken::new();
    let transport = CancelsAtRequest(cancellation_token.clone());

    let finished = run(
        &task("Hi.", SessionChoice::New),
        place.machine(Box::new(with_key), Box::new(transport)),
        &place.work,
        cancellation_token,
    )
    .await;

    let finished = finished.unwrap();
    assert_eq!(finished.end, TurnEnd::Outcome(Outcome::Cancelled));
    let opened = place.store().await.open(finished.session, Access::Read).await.unwrap();
    assert_eq!(opened.context.first(), Some(&Block::user_text("Hi.")));
}

#[tokio::test]
async fn a_rejected_credential_ends_the_turn_with_its_text_once() {
    let place = Place::new("print", "rejected");
    let machine = place.machine(Box::new(with_key), Box::new(Rejecting));

    let finished = run(
        &task("Hi.", SessionChoice::New),
        machine,
        &place.work,
        CancellationToken::new(),
    )
    .await;

    assert_eq!(
        finished.unwrap().end,
        TurnEnd::Failed("the provider rejected the credential (status 401): {}".to_owned())
    );
}

#[test]
fn the_answer_text_is_the_text_of_the_last_run_of_assistant_blocks() {
    let context = [
        Block::user_text("Go."),
        Block::assistant_text("Early."),
        Block::ToolResult(yuke_ai::ToolResult::error("call-1", "failed")),
        Block::assistant_text("One."),
        Block::assistant_text("Two."),
        Block::ToolCall(yuke_ai::ToolCall {
            call_id: "call-2".to_owned(),
            name: "exec".to_owned(),
            arguments: "{}".to_owned(),
        }),
        Block::ToolResult(yuke_ai::ToolResult::error("call-2", "not run")),
    ];

    assert_eq!(answer_text(&context), "One.\nTwo.");
    assert_eq!(answer_text(&context[..1]), "");
}

#[test]
fn only_an_error_notice_of_yuke_fails_the_run() {
    let watcher = Watcher::default();
    let session_id = Some(SessionId::generate());
    let notice = |source: &str| {
        ServerNotification::Notice(yuke_protocol::NoticeParams {
            session_id,
            level: NoticeLevel::Error,
            source: source.to_owned(),
            message: format!("from {source}"),
        })
    };

    watcher.notify(notice("loud"));
    let after_plugin = lock(&watcher.watched).failure.clone();
    watcher.notify(notice(SOURCE));

    assert_eq!(after_plugin, None);
    assert_eq!(lock(&watcher.watched).failure.as_deref(), Some("from host:yuke"));
}

#[test]
fn the_json_report_names_the_session_the_end_and_the_text() {
    let finished = Finished {
        session: SessionId::from_bytes([1; 16]),
        end: TurnEnd::Outcome(Outcome::Completed {
            finish_reason: yuke_ai::FinishReason::Stop,
        }),
        text: "done".to_owned(),
    };

    assert_eq!(
        serde_json::to_string(&finished).unwrap(),
        r#"{"sessionId":"01010101-0101-0101-0101-010101010101","end":{"outcome":{"completed":{"finishReason":"stop"}}},"text":"done"}"#
    );
}
