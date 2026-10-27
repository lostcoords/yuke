//! The host side of the hooks: a cancel, a close during a handler, and an ended JavaScript thread. It also covers the
//! parts of an answer that only Rust sees. The TypeScript tests of `yuke:test` cover the answers of the handlers.

use std::time::Duration;

use yuke_agent::PromptSection;
use yuke_ai::{
    Blob, Block, FinishReason, Media, Origin, Reasoning, ReasoningReplay, ReplayKind, Settings, ToolCall,
    ToolDefinition, ToolResult,
};
use yuke_engine::{CancellationToken, Hooks, RoundStart, ToolDecision};

use super::{evaluate, opened, wait_until, windowed};
use crate::ScriptSession;
use crate::native::ai::{block_tokens, context_tokens};

/// The hook points of a turn that a cancel ends: the late answer of each handler, and the decision that the host gives
/// at once.
const CANCELLED: [(&str, &str, &str); 5] = [
    ("tool.before", "{ block: 'too late' }", "Run"),
    ("tool.after", "{ text: 'too late' }", "None"),
    ("round.before", "{ settings: { temperature: 0.9 } }", "the round stays"),
    ("round.after", "{ stop: true }", "Ok(Proceed)"),
    (
        "prompt.build",
        "{ sections: { late: 'x' } }",
        r#"Ok([("base", "You are yuke."), ("environment", "workspace: /work")])"#,
    ),
];

fn call() -> ToolCall {
    ToolCall {
        call_id: "c1".to_owned(),
        name: "read".to_owned(),
        arguments: r#"{"path": "notes.md"}"#.to_owned(),
    }
}

/// The result of [`call`]: a text, a png of 3 bytes, and one loaded tool.
fn result() -> ToolResult {
    ToolResult {
        call_id: "c1".to_owned(),
        content: "secret: hunter2".to_owned(),
        is_error: false,
        media: vec![Media::new(
            Blob {
                digest: [1; 32],
                len: 3,
            },
            "image/png",
        )],
        loaded: vec![ToolDefinition {
            name: "lint".to_owned(),
            description: "d".to_owned(),
            input_schema: "{}".to_owned(),
            defer_loading: true,
        }],
    }
}

/// The decision of the hooks of `session` at `point` for a plain event under `token`, as its debug text.
async fn decide(session: &ScriptSession, point: &str, token: CancellationToken) -> String {
    let hooks = session.hooks(token.clone());
    let context = [Block::user_text("one")];
    let settings = Settings::new();
    let model = windowed(None);
    let round = RoundStart {
        context: &context,
        model: &model,
        settings: &settings,
        system: "",
        tools: &[],
        input_tokens: None,
    };
    let decided = async {
        match point {
            "tool.before" => format!("{:?}", hooks.before_tool(&call()).await),
            "tool.after" => format!(
                "{:?}",
                hooks.after_tool(&call(), &result()).await.map(|answer| answer.content)
            ),
            "round.before" => match hooks.before_round(&round).await {
                Ok(plan) if plan.replace.is_none() && plan.model.is_none() && plan.settings.is_none() => {
                    "the round stays".to_owned()
                }
                other => format!("{other:?}"),
            },
            "round.after" => format!(
                "{:?}",
                hooks
                    .after_round(&[Block::assistant_text("done")], Some(FinishReason::Stop))
                    .await
                    .map_err(|error| error.to_string())
            ),
            "prompt.build" => {
                let saved = [
                    PromptSection::new("base", "You are yuke."),
                    PromptSection::new("environment", "workspace: /work"),
                ];
                let built = session.build_prompt(&saved, &token).await;
                format!(
                    "{:?}",
                    built.map(|sections| sections
                        .into_iter()
                        .map(|section| (section.key, section.text))
                        .collect::<Vec<_>>())
                )
            }
            other => panic!("{other} is no hook point"),
        }
    };
    tokio::time::timeout(Duration::from_secs(5), decided).await.unwrap()
}

// A cancel ends the turn, so the host answers at once, the handler sees its signal abort, and its late answer does not
// count.
#[tokio::test]
async fn a_cancel_aborts_the_signal_of_each_point_and_the_host_answers_at_once() {
    for (point, late, expected) in CANCELLED {
        let (runtime, session, _reports) = opened(
            &format!("a_cancel_aborts_the_signal_of_each_point_and_the_host_answers_at_once/{point}"),
            &[(
                "slow",
                &format!(
                    "export function session(s) {{
                       s.hook('{point}', ({{ signal }}) => new Promise((resolve) => {{
                         globalThis.started = true;
                         signal.addEventListener('abort', () => {{
                           globalThis.aborted = signal.reason.name;
                           resolve({late});
                         }});
                       }}));
                     }}"
                ),
            )],
        )
        .await;
        let token = CancellationToken::new();
        let cancel = async {
            wait_until(&runtime, "return globalThis.started === true;").await;
            token.cancel();
        };

        let (decision, ()) = tokio::join!(decide(&session, point, token.clone()), cancel);

        assert_eq!(decision, expected, "{point}");
        let aborted = evaluate::<String>(&runtime, "return globalThis.aborted ?? 'none';")
            .await
            .unwrap();
        assert_eq!(aborted, "AbortError", "{point}");
    }
}

// The driver drops the hook future at a cancel, as this `select!` does. The signal of the hook still aborts.
#[tokio::test]
async fn a_cancel_aborts_the_signal_also_when_the_driver_drops_the_hook_future() {
    let (runtime, session, _reports) = opened(
        "a_cancel_aborts_the_signal_also_when_the_driver_drops_the_hook_future",
        &[(
            "slow",
            "export function session(s) {
               s.hook('tool.before', ({ signal }) => {
                 globalThis.started = true;
                 signal.addEventListener('abort', () => { globalThis.aborted = signal.reason.name; });
                 return new Promise(() => {});
               });
             }",
        )],
    )
    .await;
    let token = CancellationToken::new();
    let hooks = session.hooks(token.clone());
    let call = call();

    let raced = async {
        tokio::select! {
            biased;
            () = token.cancelled() => None,
            decision = hooks.before_tool(&call) => Some(decision),
        }
    };
    let cancel = async {
        wait_until(&runtime, "return globalThis.started === true;").await;
        token.cancel();
    };
    let (decision, ()) = tokio::join!(raced, cancel);

    assert_eq!(decision, None);
    wait_until(&runtime, "return globalThis.aborted === 'AbortError';").await;
}

// A close during a handler ends the turn, so a late answer of the closed session does not count.
#[tokio::test]
async fn an_answer_that_comes_after_the_close_of_the_session_does_not_count() {
    for (point, answer, expected) in [
        ("tool.before", "{ block: 'too late' }", "Run"),
        ("tool.after", "{ text: 'too late' }", "None"),
    ] {
        let (runtime, session, _reports) = opened(
            &format!("an_answer_that_comes_after_the_close_of_the_session_does_not_count/{point}"),
            &[(
                "late",
                &format!(
                    "export function session(s) {{
                       s.hook('{point}', () => new Promise((resolve) => {{ globalThis.release = () => resolve({answer}); }}));
                     }}"
                ),
            )],
        )
        .await;
        let close = async {
            wait_until(&runtime, "return typeof globalThis.release === 'function';").await;
            session.close().await.unwrap();
            evaluate::<()>(&runtime, "globalThis.release();").await.unwrap();
        };

        let (decision, ()) = tokio::join!(decide(&session, point, CancellationToken::new()), close);

        assert_eq!(decision, expected, "{point}");
    }
}

// A hook that cannot answer never lets a call run, and never shows the original result.
#[tokio::test]
async fn tool_before_blocks_and_tool_after_gives_an_error_when_the_javascript_thread_has_ended() {
    let (runtime, session, _reports) = opened(
        "tool_before_blocks_and_tool_after_gives_an_error_when_the_javascript_thread_has_ended",
        &[("quiet", "export function session(s) {}")],
    )
    .await;
    let hooks = session.hooks(CancellationToken::new());
    tokio::time::timeout(Duration::from_secs(5), runtime.shutdown())
        .await
        .unwrap()
        .unwrap();

    let before = hooks.before_tool(&call()).await;
    let after = hooks.after_tool(&call(), &result()).await;

    assert_eq!(
        before,
        ToolDecision::Block("the tool.before hooks failed: the JavaScript thread has ended".to_owned())
    );
    let failed = ToolResult {
        content: "the tool.after hooks failed: the JavaScript thread has ended".to_owned(),
        is_error: true,
        media: Vec::new(),
        ..result()
    };
    assert_eq!(after, Some(failed));
}

// An answer replaces only its own fields, so the media and the loaded tools of the result stay. The test host of
// `yuke:test` shows no loaded tools.
#[tokio::test]
async fn an_answer_keeps_the_media_and_the_loaded_tools_of_the_result() {
    let (_runtime, session, _reports) = opened(
        "an_answer_keeps_the_media_and_the_loaded_tools_of_the_result",
        &[(
            "redact",
            "export function session(s) {
               s.hook('tool.after', ({ result }) => ({ text: result.text.replace('hunter2', '***'), isError: true }));
             }",
        )],
    )
    .await;

    let changed = session
        .hooks(CancellationToken::new())
        .after_tool(&call(), &result())
        .await;

    let expected = ToolResult {
        content: "secret: ***".to_owned(),
        is_error: true,
        ..result()
    };
    assert_eq!(changed, Some(expected));
}

// The test host of `yuke:test` builds one text block, so only Rust gives an answer of several texts.
#[tokio::test]
async fn round_after_joins_the_texts_of_the_answer_with_newlines() {
    let (runtime, session, _reports) = opened(
        "round_after_joins_the_texts_of_the_answer_with_newlines",
        &[(
            "watch",
            "export function session(s) {
               s.hook('round.after', ({ text, finishReason }) => { globalThis.seen = `${text}|${finishReason}`; });
             }",
        )],
    )
    .await;
    let answer = [
        Block::user_text("go"),
        Block::assistant_text("first part"),
        Block::assistant_text("second part"),
    ];

    let decision = session
        .hooks(CancellationToken::new())
        .after_round(&answer, Some(FinishReason::Stop))
        .await
        .map_err(|error| error.to_string());

    assert_eq!(
        decision.map(|decision| format!("{decision:?}")),
        Ok("Proceed".to_owned())
    );
    let seen = evaluate::<String>(&runtime, "return globalThis.seen;").await.unwrap();
    assert_eq!(seen, "first part\nsecond part|stop");
}

#[test]
fn an_estimate_charges_each_media_item_and_the_larger_of_the_reasoning_text_and_its_state() {
    let media = Media::new(
        Blob {
            digest: [0; 32],
            len: 3,
        },
        "image/png",
    );
    let mut result = ToolResult::success("c1", "abcd");
    result.media = vec![media.clone(), media.clone()];
    let reasoning = |text: &str, state: &str| {
        Block::Reasoning(Reasoning {
            text: text.to_owned(),
            replay: Some(ReasoningReplay {
                origin: Origin {
                    model: "m".to_owned(),
                    base_url: "https://example.test".to_owned(),
                },
                kind: ReplayKind::AnthropicSignature,
                data: state.to_owned(),
            }),
        })
    };

    assert_eq!(block_tokens(&Block::Media(media)), 1600);
    assert_eq!(block_tokens(&Block::ToolResult(result)), 1 + 2 * 1600);
    assert_eq!(block_tokens(&reasoning("12345678", &"s".repeat(40))), 10);
    assert_eq!(block_tokens(&reasoning(&"t".repeat(40), "")), 10);
}

#[test]
fn a_count_adds_the_whole_newest_answer_and_the_blocks_after_it() {
    let call = Block::ToolCall(ToolCall {
        call_id: "c1".to_owned(),
        name: "read".to_owned(),
        arguments: "{}".to_owned(),
    });
    // The answer is the text and the call. The result and the input come after it.
    let context = [
        Block::user_text("aaaaaaaa"),
        Block::assistant_text("bbbb"),
        call,
        Block::ToolResult(ToolResult::success("c1", "cccc")),
        Block::user_text("dddd"),
    ];

    assert_eq!(context_tokens(&context, Some(100)), 100 + 1 + 2 + 1 + 1);
    assert_eq!(context_tokens(&context, None), 2 + 1 + 2 + 1 + 1);
    assert_eq!(context_tokens(&context[..1], Some(100)), 100 + 2);
}
