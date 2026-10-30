//! The module `yuke:ai` and the model of a session.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use yuke_ai::{Block, Effort, FinishReason, OutputSchema, ReasoningSettings, Settings, Thinking, Usage};
use yuke_engine::CancellationToken;
use yuke_protocol::ModelReference;

use super::tools::{TestHost, Tools};
use super::{evaluate, folder, load_entry, options, write};
use crate::{Attachment, CompleteAnswer, CompleteRequest, Models, Processes, Runtime, SessionHost, SideRequest};

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
    async fn side_request(
        &self,
        _request: SideRequest,
        _cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn std::error::Error + Send + Sync>> {
        Err("no side request".into())
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
         await ai.generateText({ model, prompt: 'the effort', reasoning: { effort: 'low' } });
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
                attachments: Vec::new(),
            },
            CompleteRequest {
                model: reference("p", "m"),
                system: String::new(),
                blocks: vec![Block::user_text("the question")],
                settings: Settings::new(),
                attachments: Vec::new(),
            },
            // A missing reasoning field keeps the default of the endpoint.
            CompleteRequest {
                model: reference("p", "m"),
                system: String::new(),
                blocks: vec![Block::user_text("the effort")],
                settings: Settings {
                    reasoning: ReasoningSettings {
                        thinking: None,
                        effort: Some(Effort::Low),
                    },
                    ..Settings::new()
                },
                attachments: Vec::new(),
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

/// The JavaScript that defines `shape`, an output for an object with a required `summary` and an optional `count` of at
/// least 0.
const SHAPE: &str = "const ai = await import('yuke:ai');
     const shape = ai.Output.object({
       schema: {
         type: 'object',
         properties: { summary: { type: 'string' }, count: { type: 'integer', minimum: 0 } },
         required: ['summary'],
       },
     });";

/// A runtime of the test `name` whose model answers `text` with the finish `finish_reason`.
async fn answering(name: &str, text: &str, finish_reason: FinishReason) -> (Runtime, Arc<Recorded>) {
    let models = Arc::new(Recorded {
        answer: Some(Ok(CompleteAnswer {
            text: text.to_owned(),
            finish_reason,
            usage: Usage {
                output: Some(5),
                ..Usage::default()
            },
        })),
        ..Recorded::default()
    });
    (runtime_with(name, &models).await, models)
}

#[tokio::test]
async fn an_output_sends_the_schema_and_answers_with_the_checked_object() {
    let (runtime, models) = answering(
        "an_output_sends_the_schema_and_answers_with_the_checked_object",
        r#"{"summary":"done","count":null}"#,
        FinishReason::Stop,
    )
    .await;

    let answers = evaluate::<Vec<String>>(
        &runtime,
        &format!(
            "{SHAPE}
             const answer = await ai.generateText({{ model: {{ provider: 'p', model: 'm' }}, prompt: 'go', output: shape }});
             const plain = await ai.generateText({{ model: {{ provider: 'p', model: 'm' }}, prompt: 'go' }});
             return [JSON.stringify(answer.output), String(plain.output)];"
        ),
    )
    .await
    .unwrap();

    // A `null` optional field counts as absent, as in the arguments of a tool.
    assert_eq!(answers, [r#"{"summary":"done"}"#, "undefined"]);
    let requests = models.requests.lock().unwrap();
    assert_eq!(
        requests[0].settings.output_schema,
        Some(OutputSchema {
            name: "response".to_owned(),
            // Anthropic refuses a bound and an object without `additionalProperties: false`.
            schema: r#"{"type":"object","properties":{"summary":{"type":"string"},"count":{"type":"integer","description":"{\"minimum\":0}"}},"required":["summary"],"additionalProperties":false}"#.to_owned(),
            strict: false,
        })
    );
    assert_eq!(requests[1].settings.output_schema, None);
}

#[tokio::test]
async fn an_answer_that_is_not_the_object_throws_a_no_object_generated_error_that_keeps_the_answer() {
    // The engine words a JSON error itself, so only the start of the cause counts.
    let cases = [
        ("not json", FinishReason::Stop, "SyntaxError: "),
        (
            r#"{"summary":3}"#,
            FinishReason::Stop,
            "Error: Set summary to a string.",
        ),
        (
            r#"{"summary":"cu"#,
            FinishReason::Length,
            "Error: the answer stopped with length",
        ),
        (
            r#"{"summary":"done"}"#,
            FinishReason::ContentFilter,
            "Error: the answer stopped with content_filter",
        ),
    ];
    for (index, (text, finish_reason, cause)) in cases.into_iter().enumerate() {
        let (runtime, _models) = answering(
            &format!("an_answer_that_is_not_the_object_throws_a_no_object_generated_error_{index}"),
            text,
            finish_reason,
        )
        .await;

        let error = evaluate::<Vec<String>>(
            &runtime,
            &format!(
                "{SHAPE}
                 try {{
                   await ai.generateText({{ model: {{ provider: 'p', model: 'm' }}, prompt: 'go', output: shape }});
                   return ['none'];
                 }} catch (error) {{
                   return [
                     String(error instanceof ai.NoObjectGeneratedError),
                     error.name,
                     error.message,
                     error.text,
                     error.finishReason,
                     String(error.usage.output),
                     `${{error.cause.name}}: ${{error.cause.message}}`,
                   ];
                 }}"
            ),
        )
        .await
        .unwrap();

        let finish = serde_json::to_value(finish_reason).unwrap();
        assert!(error[6].starts_with(cause), "{error:?}");
        assert_eq!(
            error[..6],
            [
                "true",
                "NoObjectGeneratedError",
                "the answer is not the requested object",
                text,
                finish.as_str().unwrap(),
                "5",
            ],
            "{text}"
        );
    }
}

#[tokio::test]
async fn a_bad_output_throws_a_type_error_and_sends_nothing() {
    // The model answers at once, so a bad output that the checks miss gives `none`, and the test does not hang.
    let (runtime, models) = answering(
        "a_bad_output_throws_a_type_error_and_sends_nothing",
        "{}",
        FinishReason::Stop,
    )
    .await;

    let errors = evaluate::<Vec<String>>(
        &runtime,
        "const ai = await import('yuke:ai');
         const attempts = [
           () => ai.Output.object({ schema: { type: 'string' } }),
           () => ai.Output.object({ schema: { type: 'object', properties: {}, oneOf: [] } }),
           () => ai.Output.object({ schema: { type: 'object', properties: {} }, name: 3 }),
           () => ai.Output.object({ schema: { type: 'object', properties: {} }, name: 'a name' }),
         ];
         const errors = [];
         for (const attempt of attempts) {
           try { await attempt(); errors.push('none'); }
           catch (error) { errors.push(`${error.name}: ${error.message}`); }
         }
         return errors;",
    )
    .await
    .unwrap();

    assert_eq!(
        errors,
        [
            "TypeError: schema.type is not object",
            "TypeError: schema: yuke does not check the keyword 'oneOf'",
            "TypeError: the option name is not 1 to 64 letters, digits, _, or -",
            "TypeError: the option name is not 1 to 64 letters, digits, _, or -",
        ]
    );
    assert!(models.requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn attachments_reach_the_request_after_a_read_of_each_path() {
    let folder = folder("attachments_reach_the_request_after_a_read_of_each_path");
    write(&folder, &[("shot.png", "file bytes")]);
    let (runtime, models) = answering(
        "attachments_reach_the_request_after_a_read_of_each_path_runtime",
        "seen",
        FinishReason::Stop,
    )
    .await;

    let text = evaluate::<String>(
        &runtime,
        &format!(
            "const ai = await import('yuke:ai');
             const bytes = new Uint8Array([1, 2, 3]);
             const answer = await ai.generateText({{
               model: {{ provider: 'p', model: 'm' }},
               prompt: 'Describe.',
               attachments: [{{ mimeType: 'image/png', bytes }}, {{ mimeType: 'image/png', path: {path:?} }}],
             }});
             return answer.text;",
            path = folder.join("shot.png").to_str().unwrap()
        ),
    )
    .await
    .unwrap();

    assert_eq!(text, "seen");
    let attachments = &models.requests.lock().unwrap()[0].attachments;
    assert_eq!(
        *attachments,
        [
            Attachment {
                bytes: vec![1, 2, 3],
                mime_type: "image/png".to_owned(),
            },
            Attachment {
                bytes: b"file bytes".to_vec(),
                mime_type: "image/png".to_owned(),
            },
        ]
    );
}

#[tokio::test]
async fn a_bad_attachment_fails_before_a_request() {
    let folder = folder("a_bad_attachment_fails_before_a_request");
    let (runtime, models) = answering(
        "a_bad_attachment_fails_before_a_request_runtime",
        "{}",
        FinishReason::Stop,
    )
    .await;
    let missing = folder.join("missing.png");

    let errors = evaluate::<Vec<String>>(
        &runtime,
        &format!(
            "const ai = await import('yuke:ai');
             const model = {{ provider: 'p', model: 'm' }};
             const attachments = [
               [{{ mimeType: 'image/png', path: 'shot.png' }}],
               [{{ mimeType: 'image/png' }}],
               'shot.png',
               [{{ mimeType: 'image/png', path: {missing:?} }}],
               [{{ mimeType: 'image/png', bytes: new Uint8Array({too_large}) }}],
             ];
             const errors = [];
             for (const list of attachments) {{
               try {{ await ai.generateText({{ model, prompt: 'go', attachments: list }}); errors.push('none'); }}
               catch (error) {{ errors.push(`${{error.name}}: ${{error.message}}`); }}
             }}
             return errors;",
            missing = missing.to_str().unwrap(),
            too_large = yuke_ai::MAX_MEDIA_BYTES + 1,
        ),
    )
    .await
    .unwrap();

    assert_eq!(
        errors[..3],
        [
            "TypeError: attachments[0].path is not an absolute path",
            "TypeError: attachments[0] needs exactly one of path and bytes",
            "TypeError: the option attachments is not an array",
        ]
    );
    assert!(
        errors[3].starts_with(&format!("Error: {}: ", missing.to_str().unwrap())),
        "{errors:?}"
    );
    assert!(
        errors[4].starts_with("Error: the media is larger than the limit"),
        "{errors:?}"
    );
    assert!(models.requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn an_abort_ends_the_wait_for_an_attachment_that_does_not_read() {
    let folder = folder("an_abort_ends_the_wait_for_an_attachment_that_does_not_read");
    let fifo = folder.join("input.fifo");
    let made = std::process::Command::new("mkfifo").arg(&fifo).status().unwrap();
    assert!(made.success());
    let models = Arc::new(Recorded::default());
    let runtime = runtime_with(
        "an_abort_ends_the_wait_for_an_attachment_that_does_not_read_runtime",
        &models,
    )
    .await;

    // The open of a FIFO without a writer blocks, so the read never ends by itself.
    let reason = tokio::time::timeout(
        Duration::from_secs(5),
        evaluate::<String>(
            &runtime,
            &format!(
                "const ai = await import('yuke:ai');
                 const controller = new AbortController();
                 const answer = ai
                   .generateText({{
                     model: {{ provider: 'p', model: 'm' }},
                     prompt: 'go',
                     attachments: [{{ mimeType: 'image/png', path: {fifo:?} }}],
                     abortSignal: controller.signal,
                   }})
                   .catch((error) => error);
                 await new Promise((resolve) => setTimeout(resolve, 50));
                 controller.abort('stopped by the plugin');
                 return await answer;",
                fifo = fifo.to_str().unwrap()
            ),
        ),
    )
    .await;
    // A writer ends the blocked open, so the thread of the read ends too.
    drop(std::fs::OpenOptions::new().write(true).open(&fifo).unwrap());

    assert_eq!(reason.unwrap().unwrap(), "stopped by the plugin");
    assert!(models.requests.lock().unwrap().is_empty());
}
