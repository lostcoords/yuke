//! These tests cover `sideRequest` of a round event: the request of the round, with the context that the handler sees.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use yuke_ai::{Block, FinishReason, Settings, ToolDefinition, Usage};
use yuke_engine::{CancellationToken, Hooks, RoundStart};

use super::plugins::plugin;
use super::tools::TestHost;
use super::{evaluate, folder, options, windowed};
use crate::{CompleteAnswer, CompleteRequest, Models, Processes, Runtime, ScriptSession, SideRequest};

/// Records each side request. With `answer`, it returns that answer. Without one, it waits for the cancel.
#[derive(Default)]
pub(super) struct Recorded {
    pub(super) requests: Mutex<Vec<SideRequest>>,
    pub(super) answer: Option<Result<CompleteAnswer, String>>,
    pub(super) cancelled: Mutex<bool>,
}

#[async_trait]
impl Models for Recorded {
    async fn complete(
        &self,
        _request: CompleteRequest,
        _cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn std::error::Error + Send + Sync>> {
        Err("no complete request".into())
    }

    async fn side_request(
        &self,
        request: SideRequest,
        cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn std::error::Error + Send + Sync>> {
        self.requests.lock().unwrap().push(request);
        if let Some(answer) = &self.answer {
            return Ok(answer.clone()?);
        }
        cancel.cancelled().await;
        *self.cancelled.lock().unwrap() = true;
        Err("the request was cancelled".into())
    }
}

/// An answer with the text `text`.
pub(super) fn answered(text: &str) -> Recorded {
    Recorded {
        answer: Some(Ok(CompleteAnswer {
            text: text.to_owned(),
            finish_reason: FinishReason::Stop,
            usage: Usage {
                input: Some(900),
                output: Some(12),
                ..Usage::default()
            },
        })),
        ..Recorded::default()
    }
}

/// A session of the test `name` with `plugins`, whose side requests go to `models`, and its host.
async fn opened(
    name: &str,
    plugins: &[(&str, &str)],
    models: &Arc<Recorded>,
) -> (Runtime, ScriptSession, Arc<TestHost>) {
    let folder = folder(name);
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let options = crate::Options {
        models: Arc::clone(models) as Arc<dyn Models>,
        ..options(&folder, processes)
    };
    let runtime = Runtime::start(options).await.unwrap().0;
    let specs: Vec<_> = plugins
        .iter()
        .map(|(plugin_name, source)| plugin(&folder, plugin_name, Some(source), &[], &[]))
        .collect();
    assert!(runtime.load_plugins(&specs).await.is_empty());
    let host = Arc::new(TestHost::new(&folder));
    let session = runtime.open_session(host.clone()).await.unwrap();
    (runtime, session, host)
}

/// The context of the round: an input, an answer, and a second input.
fn context() -> Vec<Block> {
    vec![
        Block::user_text("one"),
        Block::assistant_text("two"),
        Block::user_text("three"),
    ]
}

fn definition(name: &str) -> ToolDefinition {
    ToolDefinition {
        name: name.into(),
        description: "A test tool.".to_owned(),
        input_schema: r#"{"type":"object"}"#.to_owned(),
        defer_loading: false,
    }
}

/// Run the `round.before` hooks of `session` for a round of [`context`] with the system prompt "Be brief.", the tool
/// "echo", and the temperature 0.5. A failed hook gives its text.
async fn run_round(session: &ScriptSession) -> Result<(), String> {
    let context = context();
    let settings = Settings::new().temperature(0.5);
    let tools = [definition("echo")];
    let round = RoundStart {
        context: &context,
        model: &windowed(Some(1000)),
        settings: &settings,
        system: "Be brief.",
        tools: &tools,
        input_tokens: Some(900),
    };
    let hooks = session.hooks(CancellationToken::new());
    tokio::time::timeout(Duration::from_secs(5), hooks.before_round(&round))
        .await
        .unwrap()
        .map(drop)
        .map_err(|error| error.to_string())
}

#[tokio::test]
async fn a_side_request_repeats_the_round_with_the_context_that_the_handler_sees_then_the_prompt() {
    let models = Arc::new(answered("A summary."));
    let (runtime, session, host) = opened(
        "a_side_request_repeats_the_round_with_the_context_that_the_handler_sees_then_the_prompt",
        &[
            (
                "first",
                "export function session(s) {
                   s.hook('round.before', () => ({ replace: { head: [{ user_text: 'summary' }], keep: 1 } }));
                 }",
            ),
            (
                "second",
                "export function session(s) {
                   s.hook('round.before', async (event) => {
                     const answer = await event.sideRequest({ prompt: 'Summarize.', maxOutputTokens: 100 });
                     globalThis.answer = [JSON.stringify(answer), String(Object.isFrozen(answer))];
                   });
                 }",
            ),
        ],
        &models,
    )
    .await;

    run_round(&session).await.unwrap();

    assert_eq!(
        evaluate::<Vec<String>>(&runtime, "return globalThis.answer;")
            .await
            .unwrap(),
        [
            r#"{"text":"A summary.","finishReason":"stop","usage":{"input":900,"output":12,"reasoning":null,"cacheRead":null,"cacheWrite":null}}"#,
            "true",
        ]
    );
    let requests = models.requests.lock().unwrap();
    let [request] = &requests[..] else {
        panic!("{requests:?}")
    };
    assert_eq!(request.model.context_window, Some(1000));
    assert_eq!(request.system, "Be brief.");
    assert_eq!(request.tools, [definition("echo")]);
    assert_eq!(
        request.settings,
        Settings::new().temperature(0.5).max_output_tokens(100)
    );
    assert_eq!(request.session_id, host.session);
    assert_eq!(request.blocks, [Block::user_text("summary"), Block::user_text("three")]);
    assert_eq!(request.prompt, "Summarize.");
}

#[tokio::test]
async fn the_blocks_option_sends_only_the_oldest_blocks_of_the_context() {
    let models = Arc::new(answered("A summary."));
    let (_runtime, session, _host) = opened(
        "the_blocks_option_sends_only_the_oldest_blocks_of_the_context",
        &[(
            "compact",
            "export function session(s) {
               s.hook('round.before', async (event) => { await event.sideRequest({ prompt: 'Summarize.', blocks: 2 }); });
             }",
        )],
        &models,
    )
    .await;

    run_round(&session).await.unwrap();

    let requests = models.requests.lock().unwrap();
    assert_eq!(
        requests[0].blocks,
        [Block::user_text("one"), Block::assistant_text("two")]
    );
    assert_eq!(requests[0].settings, Settings::new().temperature(0.5));
}

#[tokio::test]
async fn bad_options_throw_a_type_error_and_send_nothing() {
    let models = Arc::new(answered("A summary."));
    let (runtime, session, _host) = opened(
        "bad_options_throw_a_type_error_and_send_nothing",
        &[(
            "compact",
            "globalThis.errors = [];
             export function session(s) {
               s.hook('round.before', async (event) => {
                 for (const options of [
                   {},
                   { prompt: 'x', blocks: 4 },
                   { prompt: 'x', blocks: 1.5 },
                   { prompt: 'x', maxOutputTokens: 0 },
                   { prompt: 'x', model: 'other' },
                 ]) {
                   try {
                     await event.sideRequest(options);
                   } catch (error) {
                     globalThis.errors.push(`${error.name}: ${error.message}`);
                   }
                 }
               });
             }",
        )],
        &models,
    )
    .await;

    run_round(&session).await.unwrap();

    let errors = evaluate::<Vec<String>>(&runtime, "return globalThis.errors;")
        .await
        .unwrap();
    assert_eq!(errors.len(), 5, "{errors:?}");
    assert!(
        errors.iter().all(|error| error.starts_with("TypeError: ")),
        "{errors:?}"
    );
    assert!(
        errors[1].ends_with("the option blocks is not a whole number from 0 to 3"),
        "{errors:?}"
    );
    assert!(models.requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn an_abort_stops_the_request_and_rejects_with_the_reason_of_the_signal() {
    let models = Arc::new(Recorded::default());
    let (runtime, session, _host) = opened(
        "an_abort_stops_the_request_and_rejects_with_the_reason_of_the_signal",
        &[(
            "compact",
            "export function session(s) {
               s.hook('round.before', async (event) => {
                 const controller = new AbortController();
                 const request = event.sideRequest({ prompt: 'Summarize.', abortSignal: controller.signal });
                 setTimeout(() => controller.abort(new Error('too slow')), 10);
                 try {
                   await request;
                 } catch (error) {
                   globalThis.rejected = error.message;
                 }
               });
             }",
        )],
        &models,
    )
    .await;

    run_round(&session).await.unwrap();

    assert_eq!(
        evaluate::<String>(&runtime, "return globalThis.rejected;")
            .await
            .unwrap(),
        "too slow"
    );
    assert!(*models.cancelled.lock().unwrap());
}

#[tokio::test]
async fn a_failed_request_rejects_with_its_text() {
    let models = Arc::new(Recorded {
        answer: Some(Err("the provider is down".to_owned())),
        ..Recorded::default()
    });
    let (_runtime, session, _host) = opened(
        "a_failed_request_rejects_with_its_text",
        &[(
            "compact",
            "export function session(s) {
               s.hook('round.before', (event) => event.sideRequest({ prompt: 'Summarize.' }));
             }",
        )],
        &models,
    )
    .await;

    let error = run_round(&session).await.unwrap_err();

    assert!(error.ends_with("the provider is down"), "{error}");
}
