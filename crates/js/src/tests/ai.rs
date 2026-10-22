//! The module `yuke:ai` and the model of a session.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use yuke_ai::{Block, Effort, FinishReason, ReasoningSettings, Settings, Thinking, Usage};
use yuke_engine::CancellationToken;
use yuke_protocol::ModelReference;

use super::tools::{TestHost, Tools};
use super::{evaluate, folder, load_entry, options, write};
use crate::{CompleteAnswer, CompleteRequest, Models, Processes, Runtime, SessionHost};

/// Records each request and the name of its thread. With `answer`, it returns that answer. Without one, it waits for
/// the cancel.
#[derive(Default)]
struct Recorded {
    requests: Mutex<Vec<CompleteRequest>>,
    threads: Mutex<Vec<String>>,
    answer: Option<Result<CompleteAnswer, String>>,
    cancelled: Mutex<bool>,
}

#[async_trait]
impl Models for Recorded {
    async fn complete(
        &self,
        request: CompleteRequest,
        cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn std::error::Error + Send + Sync>> {
        self.requests.lock().unwrap().push(request);
        let thread = std::thread::current().name().unwrap_or_default().to_owned();
        self.threads.lock().unwrap().push(thread);
        if let Some(answer) = &self.answer {
            return Ok(answer.clone()?);
        }
        cancel.cancelled().await;
        *self.cancelled.lock().unwrap() = true;
        Err("the request was cancelled".into())
    }
}

/// A runtime of the test `name` whose plugins call `models`.
async fn runtime_with(name: &str, models: &Arc<Recorded>) -> Runtime {
    let folder = folder(name);
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let options = crate::Options {
        models: Arc::clone(models) as Arc<dyn Models>,
        ..options(&folder, processes)
    };
    Runtime::start(options).await.unwrap().0
}

fn reference(provider: &str, model: &str) -> ModelReference {
    ModelReference {
        provider: provider.to_owned(),
        model: model.to_owned(),
    }
}

#[tokio::test]
async fn generate_text_sends_its_options_and_answers_with_the_text_the_finish_and_the_usage() {
    let models = Arc::new(Recorded {
        answer: Some(Ok(CompleteAnswer {
            text: "A summary.".to_owned(),
            finish_reason: FinishReason::Length,
            usage: Usage {
                input: Some(42),
                output: Some(7),
                ..Usage::default()
            },
        })),
        ..Recorded::default()
    });
    let runtime = runtime_with(
        "generate_text_sends_its_options_and_answers_with_the_text_the_finish_and_the_usage",
        &models,
    )
    .await;

    let answers = evaluate::<Vec<String>>(
        &runtime,
        "const ai = await import('yuke:ai');
         const model = { provider: 'p', model: 'm' };
         const full = await ai.generateText({
           model,
           instructions: 'Summarize.',
           prompt: [{ user_text: 'the text' }],
           maxOutputTokens: 9,
           temperature: 0.5,
           topP: 0.9,
           reasoning: { thinking: 'off', effort: 'high' },
         });
         const bare = await ai.generateText({ model, prompt: 'the question', temperature: null, topP: undefined });
         return [JSON.stringify(full), String(Object.isFrozen(full)), JSON.stringify(bare.usage)];",
    )
    .await
    .unwrap();

    assert_eq!(
        answers,
        [
            r#"{"text":"A summary.","finishReason":"length","usage":{"input":42,"output":7,"reasoning":null,"cacheRead":null,"cacheWrite":null}}"#,
            "true",
            r#"{"input":42,"output":7,"reasoning":null,"cacheRead":null,"cacheWrite":null}"#,
        ]
    );
    // The JavaScript thread has no I/O driver, so a request runs on the runtime of the test.
    assert!(!models.threads.lock().unwrap().contains(&"yuke-js".to_owned()));
    assert_eq!(
        *models.requests.lock().unwrap(),
        [
            CompleteRequest {
                model: reference("p", "m"),
                system: "Summarize.".to_owned(),
                blocks: vec![Block::user_text("the text")],
                settings: Settings {
                    max_output_tokens: Some(9),
                    temperature: Some(0.5),
                    top_p: Some(0.9),
                    reasoning: ReasoningSettings {
                        thinking: Some(Thinking::Off),
                        effort: Some(Effort::High),
                    },
                    ..Settings::new()
                },
            },
            CompleteRequest {
                model: reference("p", "m"),
                system: String::new(),
                blocks: vec![Block::user_text("the question")],
                settings: Settings::new(),
            },
        ]
    );
}

#[tokio::test]
async fn a_misuse_of_generate_text_throws_a_type_error_and_sends_nothing() {
    // The model answers at once, so a misuse that the checks miss gives `none`, and the test does not hang.
    let models = Arc::new(Recorded {
        answer: Some(Ok(CompleteAnswer {
            text: String::new(),
            finish_reason: FinishReason::Stop,
            usage: Usage::default(),
        })),
        ..Recorded::default()
    });
    let runtime = runtime_with(
        "a_misuse_of_generate_text_throws_a_type_error_and_sends_nothing",
        &models,
    )
    .await;

    let errors = evaluate::<Vec<String>>(
        &runtime,
        "const ai = await import('yuke:ai');
         const model = { provider: 'p', model: 'm' };
         const misuses = [
           { model, prompt: [], tools: [] },
           { model: { provider: 'p' }, prompt: [] },
           { model, prompt: [], instructions: 3 },
           { model, prompt: 7 },
           { model, prompt: [{ nope: 1 }] },
           { model, prompt: [], temperature: 'hot' },
           { model, prompt: [], temperature: NaN },
           { model, prompt: [], temperature: Symbol('hot') },
         ];
         const errors = [];
         for (const options of misuses) {
           try { await ai.generateText(options); errors.push('none'); }
           catch (error) { errors.push(`${error.name}: ${error.message.split(':')[0]}`); }
         }
         return errors;",
    )
    .await
    .unwrap();

    assert_eq!(
        errors,
        [
            "TypeError: the options has the unknown field 'tools'",
            "TypeError: the option model has no string provider and model",
            "TypeError: the option instructions is not a string",
            "TypeError: the option prompt is not a string or an array",
            "TypeError: the blocks are not a list of blocks",
            "TypeError: the settings are not valid",
            "TypeError: a setting holds a number that is not finite",
            "TypeError: a setting holds a symbol, which JSON cannot hold",
        ]
    );
    assert!(models.requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_failed_request_rejects_with_an_error_that_holds_the_text_of_the_failure() {
    let models = Arc::new(Recorded {
        answer: Some(Err("the provider is overloaded".to_owned())),
        ..Recorded::default()
    });
    let runtime = runtime_with(
        "a_failed_request_rejects_with_an_error_that_holds_the_text_of_the_failure",
        &models,
    )
    .await;

    let failure = evaluate::<String>(
        &runtime,
        "const ai = await import('yuke:ai');
         try { await ai.generateText({ model: { provider: 'p', model: 'm' }, prompt: [] }); return 'none'; }
         catch (error) { return `${error.constructor.name}: ${error.message}`; }",
    )
    .await
    .unwrap();

    assert_eq!(failure, "Error: the provider is overloaded");
}

#[tokio::test]
async fn an_abort_stops_the_request_and_rejects_with_the_reason_of_the_signal() {
    let models = Arc::new(Recorded::default());
    let runtime = runtime_with(
        "an_abort_stops_the_request_and_rejects_with_the_reason_of_the_signal",
        &models,
    )
    .await;

    evaluate::<bool>(
        &runtime,
        "const ai = await import('yuke:ai');
         globalThis.controller = new AbortController();
         globalThis.answer = ai
           .generateText({ model: { provider: 'p', model: 'm' }, prompt: [], abortSignal: controller.signal })
           .catch((error) => error);
         return true;",
    )
    .await
    .unwrap();
    wait_for_requests(&models, 1).await;
    let reason = evaluate::<String>(
        &runtime,
        "controller.abort('stopped by the plugin'); return await globalThis.answer;",
    )
    .await
    .unwrap();

    assert_eq!(reason, "stopped by the plugin");
    assert!(*models.cancelled.lock().unwrap());
}

#[tokio::test]
async fn a_shutdown_stops_a_request_that_waits_for_its_answer() {
    let models = Arc::new(Recorded::default());
    let runtime = runtime_with("a_shutdown_stops_a_request_that_waits_for_its_answer", &models).await;
    evaluate::<bool>(
        &runtime,
        "const ai = await import('yuke:ai');
         globalThis.answer = ai.generateText({ model: { provider: 'p', model: 'm' }, prompt: [] });
         return true;",
    )
    .await
    .unwrap();
    wait_for_requests(&models, 1).await;

    runtime.shutdown().await.unwrap();

    let wait = async {
        while !*models.cancelled.lock().unwrap() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    };
    tokio::time::timeout(Duration::from_secs(5), wait).await.unwrap();
}

#[tokio::test]
async fn s_model_names_the_model_of_the_session_now() {
    let folder = folder("s_model_names_the_model_of_the_session_now");
    let models = Arc::new(Recorded::default());
    let runtime = runtime_with("s_model_names_the_model_of_the_session_now", &models).await;
    write(
        &folder,
        &[("entry.ts", "export function session(s) { globalThis.s = s; }")],
    );
    load_entry(&runtime, &folder.join("entry.ts")).await.unwrap();
    let host = Arc::new(TestHost::new(&folder));
    let _tools = Tools::open(&runtime, Arc::clone(&host) as Arc<dyn SessionHost>).await;

    let first = evaluate::<String>(&runtime, "return JSON.stringify(s.model);")
        .await
        .unwrap();
    *host.model.lock().unwrap() = reference("test", "other-model");
    let second = evaluate::<Vec<String>>(
        &runtime,
        "return [JSON.stringify(s.model), String(Object.isFrozen(s.model))];",
    )
    .await
    .unwrap();

    assert_eq!(first, r#"{"provider":"test","model":"test-model"}"#);
    assert_eq!(second, [r#"{"provider":"test","model":"other-model"}"#, "true"]);
}

/// Wait until `models` holds `count` requests. A wait past 5 seconds fails the test.
async fn wait_for_requests(models: &Recorded, count: usize) {
    let wait = async {
        while models.requests.lock().unwrap().len() < count {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    };
    tokio::time::timeout(Duration::from_secs(5), wait).await.unwrap();
}
