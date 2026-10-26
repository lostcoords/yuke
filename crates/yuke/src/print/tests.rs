//! Whole runs of `yuke -p` against a scripted provider.

use std::ffi::OsString;
use std::time::Instant;

use yuke_agent::{Access, EventPage, Store};
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
        reasoning: (session == SessionChoice::New).then_some(Reasoning::Default),
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
    assert!(yuke_agent::prompt_text(&opened.prompt).starts_with("You are yuke"));
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

// The window comes from the catalog of the app, so this test covers the way from the catalog to a plugin.
#[tokio::test]
async fn a_round_before_plugin_gets_the_window_of_the_catalog_and_replaces_the_context() {
    let place = Place::new("print", "round_before_window");
    let plugin = place.paths.config.join("windowed");
    std::fs::create_dir_all(&plugin).unwrap();
    std::fs::write(
        plugin.join("plugin.json"),
        r#"{ "name": "windowed", "extensions": { "sh.yuke": { "entry": "./index.ts" } } }"#,
    )
    .unwrap();
    std::fs::write(
        plugin.join("index.ts"),
        "export function session(s) {
           s.hook('round.before', ({ window }) => ({ replace: { head: [{ user_text: `window ${window}` }], keep: 1 } }));
         }",
    )
    .unwrap();
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["windowed"] }"#).unwrap();
    let task = Task {
        model: Some("local/small".to_owned()),
        ..task("Hi.", SessionChoice::New)
    };
    let providers = r#"{ "providers": [{
        "id": "local", "base_url": "http://127.0.0.1:8080/v1",
        "endpoints": [{ "protocol": "anthropic_messages" }],
        "models": [{ "id": "small", "limits": { "context_window": 64000, "max_output_tokens": 4096 } }]
    }] }"#;

    let (finished, transport) = run_with_providers(&place, &task, providers, Box::new(no_variable)).await;

    assert_eq!(finished.unwrap().end, completed());
    let request = &transport.requests()[0];
    assert!(request.contains("window 64000"), "{request}");
    assert!(request.contains("Hi."), "{request}");
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
        model: Some("minimax/MiniMax-M3.1-Flash".to_owned()),
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
    let page = place.store().await.list_sessions(None, None, 10).await.unwrap();
    assert_eq!(page.sessions, []);
}

#[tokio::test]
async fn a_level_that_the_model_does_not_take_is_an_error() {
    let place = Place::new("print", "bad_level");
    let task = Task {
        reasoning: Some(Reasoning::Low),
        ..task("Hi.", SessionChoice::New)
    };

    let (finished, _) = run_with(&place, &task, &[]).await;

    assert_eq!(
        finished,
        Err("minimax/MiniMax-M3: the model does not support that reasoning level".to_owned())
    );
}

// A summary through `yuke:ai` covers the way from a plugin to the catalog, the credentials, and the transport.
#[tokio::test]
async fn a_plugin_summarizes_the_context_with_the_model_of_the_session_and_replaces_it() {
    let place = Place::new("print", "summary");
    place.plugin(
        "summary",
        "import { generateText } from 'yuke:ai';
         export function session(s) {
           s.hook('round.before', async ({ blocks, context, signal }) => {
             if (blocks < 3) return undefined;
             const instructions = 'Summarize the conversation.';
             const summary = await generateText({ model: s.model, instructions, prompt: context(), abortSignal: signal });
             return { replace: { head: [{ user_text: `Summary: ${summary.text}` }], keep: 0 } };
           });
         }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["summary"] }"#).unwrap();
    let replies = [
        tool_reply(&[("c1", "read", r#"{"path":"missing.txt"}"#)]),
        text_reply("They said hi."),
        text_reply("Done."),
    ];

    let (finished, requests) = run_with(&place, &task("Hi.", SessionChoice::New), &replies).await;

    assert_eq!(finished.unwrap().text, "Done.");
    assert_eq!(requests.len(), 3);
    let summary = &requests[1];
    assert_in_order(summary, &["Summarize the conversation.", "Hi."]);
    assert!(
        !summary.contains("You are yuke") && !summary.contains(r#""tools""#),
        "{summary}"
    );
    assert!(requests[2].contains("Summary: They said hi."), "{}", requests[2]);
    assert!(!requests[2].contains(r#""Hi.""#), "{}", requests[2]);
}

// The overflow error comes from the stream of the provider, so this test covers the way from its classification to a plugin.
#[tokio::test]
async fn a_round_retry_plugin_replaces_the_context_after_an_overflow_and_the_round_goes_again() {
    let place = Place::new("print", "round_retry_overflow");
    place.plugin(
        "shrink",
        "export function session(s) {
           s.hook('round.retry', ({ failure, retries }) => {
             if (failure.kind !== 'context_overflow' || retries > 0) return undefined;
             return { replace: { head: [{ user_text: 'Shorter.' }], keep: 0 } };
           });
         }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["shrink"] }"#).unwrap();
    let overflow = yuke_testing::sse(&[
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#,
        r#"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 300000 tokens > 200000 maximum"}}"#,
    ]);

    let (finished, requests) = run_with(
        &place,
        &task("Hi.", SessionChoice::New),
        &[overflow, text_reply("Done.")],
    )
    .await;

    assert_eq!(finished.unwrap().text, "Done.");
    assert_eq!(requests.len(), 2);
    assert!(
        requests[1].contains("Shorter.") && !requests[1].contains(r#""Hi.""#),
        "{}",
        requests[1]
    );
}

// The prompt cache of a provider matches a prefix, so a side request must repeat the bytes of its round.
#[tokio::test]
async fn a_side_request_repeats_the_bytes_of_its_round_with_one_more_block() {
    let place = Place::new("print", "side_request");
    place.plugin(
        "aside",
        "export function session(s) {
           let asked = false;
           s.hook('round.before', async (event) => {
             if (asked) return undefined;
             asked = true;
             await event.sideRequest({ prompt: 'Summarize.' });
           });
         }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["aside"] }"#).unwrap();

    let (finished, requests) = run_with(
        &place,
        &task("Hi.", SessionChoice::New),
        &[text_reply("A summary."), text_reply("Done.")],
    )
    .await;

    assert_eq!(finished.unwrap().text, "Done.");
    let [side, round] = &requests[..] else {
        panic!("{requests:?}")
    };
    let input = r#"{"type":"text","text":"Hi."}"#;
    let expected = round.replacen(input, &format!(r#"{input},{{"type":"text","text":"Summarize."}}"#), 1);
    assert_ne!(&expected, round, "the round has no input: {round}");
    assert_eq!(side, &expected);
}

/// A user text of about `tokens` estimated tokens: 4 characters each.
fn long(letter: &str, tokens: usize) -> String {
    letter.repeat(tokens * 4)
}

/// The input tokens that the first answer reports. The window of the test model is 1,048,576 tokens, so the next round
/// nears it.
const NEAR_WINDOW: u64 = 950_000;

#[tokio::test]
async fn a_session_near_the_window_compacts_before_the_round_and_keeps_the_summary() {
    let place = Place::new("print", "compaction_before");
    let first = long("a", 25_000);
    let second = long("b", 25_000);
    run_with(
        &place,
        &task(&first, SessionChoice::New),
        &[yuke_testing::counted(&text_reply("One."), NEAR_WINDOW)],
    )
    .await
    .0
    .unwrap();

    let (finished, requests) = run_with(
        &place,
        &task(&second, SessionChoice::Newest),
        &[text_reply("## Goal\nThe work."), text_reply("Two.")],
    )
    .await;
    let (_, third) = run_with(&place, &task("Third.", SessionChoice::Newest), &[text_reply("Three.")]).await;

    assert_eq!(finished.unwrap().text, "Two.");
    let [summary_request, round] = &requests[..] else {
        panic!("{requests:?}")
    };
    // The summary request sends the whole context, then the prompt.
    assert_in_order(summary_request, &[&first, "One.", &second]);
    assert!(summary_request.contains("The conversation above is the history to summarize."));
    assert!(
        round.contains("## Goal\\nThe work.") && round.contains(&second),
        "{round}"
    );
    assert!(!round.contains(&first), "{round}");
    // The store keeps the replacement, so the next run starts from the summary.
    assert!(third[0].contains("## Goal\\nThe work.") && !third[0].contains(&first));
}

#[tokio::test]
async fn an_overflow_compacts_the_part_before_the_cut_and_the_round_goes_again() {
    let place = Place::new("print", "compaction_overflow");
    let first = long("a", 25_000);
    let second = long("b", 25_000);
    run_with(&place, &task(&first, SessionChoice::New), &[text_reply("One.")])
        .await
        .0
        .unwrap();
    let overflow = yuke_testing::sse(&[
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0}}}"#,
        r#"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 1100000 tokens > 1048576 maximum"}}"#,
    ]);

    let (finished, requests) = run_with(
        &place,
        &task(&second, SessionChoice::Newest),
        &[overflow, text_reply("A summary."), text_reply("Two.")],
    )
    .await;

    assert_eq!(finished.unwrap().text, "Two.");
    let [_, summary_request, round] = &requests[..] else {
        panic!("{requests:?}")
    };
    assert!(summary_request.contains(&first) && !summary_request.contains(&second));
    assert!(round.contains("A summary.") && round.contains(&second) && !round.contains(&first));
}

#[tokio::test]
async fn disable_in_the_config_turns_the_compaction_off() {
    let place = Place::new("print", "compaction_disabled");
    std::fs::create_dir_all(&place.paths.config).unwrap();
    std::fs::write(
        place.paths.config.join("config.json"),
        r#"{ "disable": ["compaction"] }"#,
    )
    .unwrap();
    let first = long("a", 25_000);
    run_with(
        &place,
        &task(&first, SessionChoice::New),
        &[yuke_testing::counted(&text_reply("One."), NEAR_WINDOW)],
    )
    .await
    .0
    .unwrap();

    let (finished, requests) = run_with(
        &place,
        &task(&long("b", 25_000), SessionChoice::Newest),
        &[text_reply("Two.")],
    )
    .await;

    assert_eq!(finished.unwrap().text, "Two.");
    assert_eq!(requests.len(), 1);
    assert!(requests[0].contains(&first));
}

#[tokio::test]
async fn an_input_that_a_plugin_replaces_reaches_the_model_as_the_new_blocks() {
    let place = Place::new("print", "input_before_replace");
    place.plugin(
        "skills",
        "export function session(s) {
           s.hook('input.before', (event) => {
             const { blocks } = event;
             if (blocks[0]?.user_text !== '/skill:pdf') return undefined;
             return { replace: { blocks: [{ user_text: 'Read PDF files with care.' }] } };
           });
         }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["skills"] }"#).unwrap();

    let (finished, requests) = run_with(&place, &task("/skill:pdf", SessionChoice::New), &[text_reply("Done.")]).await;

    assert_eq!(finished.unwrap().text, "Done.");
    assert!(
        requests[0].contains("Read PDF files with care.") && !requests[0].contains("/skill:pdf"),
        "{}",
        requests[0]
    );
}

#[tokio::test]
async fn an_input_that_a_plugin_handles_starts_no_turn_and_the_run_stops() {
    let place = Place::new("print", "input_before_handled");
    place.plugin(
        "commands",
        "export function session(s) { s.hook('input.before', () => ({ handled: true })); }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["commands"] }"#).unwrap();

    let (finished, requests) = run_with(&place, &task("/compact", SessionChoice::New), &[]).await;

    let finished = finished.unwrap();
    assert_eq!(finished.end, TurnEnd::Outcome(Outcome::Stopped));
    assert_eq!(finished.text, "");
    assert_eq!(requests, Vec::<String>::new());
    let pending = place
        .store()
        .await
        .load(finished.session, EventPage::After(None))
        .await
        .unwrap()
        .pending;
    assert!(pending.is_empty(), "{pending:?}");
}

#[tokio::test]
async fn the_skills_of_the_workspace_and_of_a_plugin_folder_reach_the_system_prompt() {
    let place = Place::new("print", "skills");
    place.plugin("helper", "export function session(s) {}");
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["helper"] }"#).unwrap();
    let plugin_skill = place.paths.config.join("helper/skills/charts");
    std::fs::create_dir_all(&plugin_skill).unwrap();
    std::fs::write(
        plugin_skill.join("SKILL.md"),
        "---\nname: charts\ndescription: Draw charts.\n---\n",
    )
    .unwrap();
    let workspace_skill = place.work.join(".agents/skills/pdf");
    std::fs::create_dir_all(&workspace_skill).unwrap();
    std::fs::write(
        workspace_skill.join("SKILL.md"),
        "---\nname: pdf\ndescription: Read PDF files.\n---\n",
    )
    .unwrap();

    let (finished, requests) = run_with(&place, &task("Hi.", SessionChoice::New), &[text_reply("Hello.")]).await;

    finished.unwrap();
    let request = &requests[0];
    let at = |text: &str| {
        request
            .find(text)
            .unwrap_or_else(|| panic!("{text} is not in {request}"))
    };
    assert!(at("<name>charts</name>") < at("Draw charts.") && at("Draw charts.") < at("<name>pdf</name>"));
    assert!(at("Read PDF files.") < at("<environment>"));
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
        reasoning: Some(Reasoning::High),
        ..task("Second.", SessionChoice::Newest)
    };
    let model = Task {
        model: Some("minimax/MiniMax-M3.1-Flash".to_owned()),
        reasoning: Some(Reasoning::Default),
        ..task("Third.", SessionChoice::Newest)
    };

    run_with(&place, &level, &[text_reply("Two.")]).await.0.unwrap();
    run_with(&place, &model, &[text_reply("Three.")]).await.0.unwrap();

    let events = place
        .store()
        .await
        .load(first.session, EventPage::After(None))
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
            model: "MiniMax-M3.1-Flash".to_owned()
        }
    );
    assert_eq!(settings[2].settings.reasoning, yuke_ai::ReasoningSettings::default());
}

#[tokio::test]
async fn a_new_model_on_a_continued_session_also_answers_the_input_that_waits() {
    let place = Place::new("print", "waiting_input");
    let first = run_with(&place, &task("First.", SessionChoice::New), &[text_reply("One.")])
        .await
        .0
        .unwrap();
    // The store holds an input that waits, as a failed run leaves it.
    let waiting = Input::new(InputSource::User, InputKind::Message, vec![Block::user_text("Waits.")]).unwrap();
    place.store().await.accept_input(first.session, waiting).await.unwrap();
    let model = Task {
        model: Some("minimax/MiniMax-M3.1-Flash".to_owned()),
        reasoning: Some(Reasoning::Default),
        ..task("Next.", SessionChoice::Newest)
    };

    let (finished, requests) = run_with(&place, &model, &[text_reply("Two.")]).await;

    assert_eq!(finished.unwrap().end, completed());
    assert_eq!(requests.len(), 1);
    assert!(
        requests[0].contains(r#""model":"MiniMax-M3.1-Flash""#),
        "{}",
        requests[0]
    );
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
async fn a_question_of_a_plugin_gets_no_answer_because_the_run_has_no_client() {
    let place = Place::new("print", "question");
    place.plugin(
        "asker",
        "export function session(s) {
           s.tools.define({
             name: 'ask', description: 'Ask.', concurrency: 'serial',
             parameters: { type: 'object', properties: {} },
             execute: async () => `answer: ${await s.confirm('Run the migration?')}`,
           });
         }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["asker"] }"#).unwrap();

    let (finished, requests) = run_with(
        &place,
        &task("Ask.", SessionChoice::New),
        &[tool_reply(&[("call-1", "ask", "{}")]), text_reply("Done.")],
    )
    .await;

    assert_eq!(finished.unwrap().text, "Done.");
    assert!(requests[1].contains("answer: undefined"), "{}", requests[1]);
}

#[tokio::test]
async fn a_project_mcp_server_stays_off_because_the_run_has_no_client_to_confirm_it() {
    let place = Place::new("print", "project_mcp");
    // The program does not exist, so a start would fail the server instead of leaving it untrusted.
    let config = r#"{ "mcpServers": { "proj": { "command": "/no/such/program" } } }"#;
    std::fs::write(place.work.join(".mcp.json"), config).unwrap();

    let (finished, requests) = run_with(&place, &task("Hi.", SessionChoice::New), &[text_reply("Done.")]).await;

    assert_eq!(finished.unwrap().text, "Done.");
    assert_eq!(requests.len(), 1);
    assert!(!place.paths.data.join("mcp-trust").exists());
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
fn only_an_error_notice_of_yuke_fails_the_run() {
    let watcher = Watcher::default();
    let id = SessionId::generate();
    let notice = |source: &str| {
        ServerNotification::Notice(NoticeParams {
            session_id: Some(id),
            level: NoticeLevel::Error,
            source: source.to_owned(),
            message: format!("from {source}"),
        })
    };

    watcher.notify(notice("loud"));
    let after_plugin = lock(&watcher.watched)
        .get(&id)
        .and_then(|watched| watched.failure.clone());
    watcher.notify(notice(SOURCE));

    assert_eq!(after_plugin, None);
    assert_eq!(lock(&watcher.watched)[&id].failure.as_deref(), Some("from host:yuke"));
}

#[test]
fn the_end_of_another_session_does_not_end_the_run() {
    let watcher = Watcher::default();
    let (id, other) = (SessionId::generate(), SessionId::generate());
    let idle = |session_id| {
        ServerNotification::SessionUpdate(SessionUpdateParams {
            session_id,
            update: SessionUpdate::Live(LiveUpdate::State {
                state: SessionState::Idle,
            }),
        })
    };

    watcher.notify(idle(other));
    let after_other = watcher.has_ended(id);
    watcher.notify(idle(id));

    assert!(!after_other);
    assert!(watcher.has_ended(id));
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
