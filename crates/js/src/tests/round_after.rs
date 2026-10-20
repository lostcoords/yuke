//! These tests cover the `round.after` hook: its payload, its answers, its count, its failures, and its cancel.

use std::time::Duration;

use yuke_ai::{Block, FinishReason, ToolCall, ToolResult};
use yuke_engine::{CancellationToken, Hooks, RoundDecision};
use yuke_protocol::{InputKind, InputSource};

use super::evaluate;
use super::prompt::{opened, opened_with_host};
use crate::ScriptSession;

/// A final answer: the input, two texts of the answer, and the reason `stop`.
fn final_answer() -> Vec<Block> {
    vec![
        Block::user_text("go"),
        Block::assistant_text("first part"),
        Block::assistant_text("second part"),
    ]
}

/// The decision of `hooks` after a round of `context`.
async fn decide(
    hooks: &impl Hooks,
    context: &[Block],
    finish_reason: Option<FinishReason>,
) -> Result<RoundDecision, String> {
    tokio::time::timeout(Duration::from_secs(5), hooks.after_round(context, finish_reason))
        .await
        .unwrap()
        .map_err(|error| error.to_string())
}

/// The decision of a new turn of `session` after [`final_answer`].
async fn after_final(session: &ScriptSession) -> Result<RoundDecision, String> {
    decide(
        &session.hooks(CancellationToken::new()),
        &final_answer(),
        Some(FinishReason::Stop),
    )
    .await
}

#[tokio::test]
async fn a_handler_gets_the_text_and_the_reason_of_the_answer_and_no_answer_proceeds() {
    let (runtime, session, _reports) = opened(
        "a_handler_gets_the_text_and_the_reason_of_the_answer_and_no_answer_proceeds",
        &[(
            "watch",
            "export function session(s) {
               s.hook('round.after', ({ text, finishReason, continues }) => {
                 globalThis.seen = JSON.stringify({ text, finishReason, continues });
               });
             }",
        )],
    )
    .await;

    let decision = after_final(&session).await;

    assert_eq!(decision, Ok(RoundDecision::Proceed));
    let seen = evaluate::<String>(&runtime, "return globalThis.seen;").await.unwrap();
    assert_eq!(
        seen,
        r#"{"text":"first part\nsecond part","finishReason":"stop","continues":0}"#
    );
}

// After a round of calls, the turn goes on, so the reason is `null`, and the text is the text before the calls.
#[tokio::test]
async fn a_round_of_calls_has_no_reason_and_the_text_before_its_calls() {
    let (runtime, session, _reports) = opened(
        "a_round_of_calls_has_no_reason_and_the_text_before_its_calls",
        &[(
            "watch",
            "export function session(s) {
               s.hook('round.after', ({ text, finishReason }) => { globalThis.seen = `${text}|${finishReason}`; });
             }",
        )],
    )
    .await;
    let context = vec![
        Block::assistant_text("old answer"),
        Block::user_text("read it"),
        Block::assistant_text("checking"),
        Block::ToolCall(ToolCall {
            call_id: "c1".to_owned(),
            name: "read".to_owned(),
            arguments: "{}".to_owned(),
        }),
        Block::ToolResult(ToolResult {
            call_id: "c1".to_owned(),
            content: "text".to_owned(),
            is_error: false,
            media: Vec::new(),
            loaded: Vec::new(),
        }),
    ];

    let decision = decide(&session.hooks(CancellationToken::new()), &context, None).await;

    assert_eq!(decision, Ok(RoundDecision::Proceed));
    let seen = evaluate::<String>(&runtime, "return globalThis.seen;").await.unwrap();
    assert_eq!(seen, "checking|null");
}

// The count belongs to the hooks of one turn, so a plugin can guard its loop with it.
#[tokio::test]
async fn the_first_answer_decides_and_a_continue_is_a_counted_notification_of_its_plugin() {
    let (runtime, session, host, _reports) = opened_with_host(
        "the_first_answer_decides_and_a_continue_is_a_counted_notification_of_its_plugin",
        &[
            (
                "tests-guard",
                "export function session(s) {
                   s.hook('round.after', ({ continues }) => continues === 0 ? { continue: 'Run the tests.' } : undefined);
                 }",
            ),
            (
                "second",
                "globalThis.second = 0;
                 export function session(s) {
                   s.hook('round.after', () => { globalThis.second += 1; return { stop: true }; });
                 }",
            ),
        ],
    )
    .await;
    let hooks = session.hooks(CancellationToken::new());

    let first = decide(&hooks, &final_answer(), Some(FinishReason::Stop)).await;
    let second = decide(&hooks, &final_answer(), Some(FinishReason::Stop)).await;
    let next_turn = after_final(&session).await;

    // The turn takes the notification from the session after the round, so the hook proceeds.
    assert_eq!(first, Ok(RoundDecision::Proceed));
    assert_eq!(second, Ok(RoundDecision::Stop));
    assert_eq!(next_turn, Ok(RoundDecision::Proceed));
    let inputs = host.inputs.lock().unwrap().clone();
    assert_eq!(inputs.len(), 2);
    for input in inputs {
        assert_eq!(
            input.source(),
            &InputSource::Plugin {
                name: "tests-guard".to_owned()
            }
        );
        assert_eq!(input.kind(), InputKind::Notification);
        assert_eq!(input.content(), [Block::user_text("Run the tests.")]);
        assert_eq!(
            input.model_content(),
            [Block::user_text(
                r#"<system_notification plugin="tests-guard">Run the tests.</system_notification>"#
            )]
        );
    }
    let second_runs = evaluate::<i32>(&runtime, "return globalThis.second;").await.unwrap();
    assert_eq!(second_runs, 1);
}

#[tokio::test]
async fn a_throw_or_an_answer_of_another_shape_fails_the_turn_and_names_the_plugin() {
    let cases = [
        ("throw new Error('no verdict');", "Error: no verdict"),
        (
            "return {};",
            "TypeError: the answer needs exactly one of stop and continue",
        ),
        (
            "return { stop: true, continue: 'x' };",
            "TypeError: the answer needs exactly one of stop and continue",
        ),
        (
            "return { stop: false };",
            "TypeError: the stop of the answer is not true",
        ),
        (
            "return { continue: 1 };",
            "TypeError: the continue of the answer is not a string",
        ),
        (
            "return { continue: '' };",
            "TypeError: the continue of the answer is empty",
        ),
        (
            "return { stop: true, why: 'x' };",
            "TypeError: the answer has the unknown field 'why'",
        ),
        ("return 'stop';", "TypeError: the answer is not an object"),
    ];
    for (index, (body, error)) in cases.into_iter().enumerate() {
        let (_runtime, session, _reports) = opened(
            &format!("a_throw_or_an_answer_of_another_shape_fails_the_turn_and_names_the_plugin_{index}"),
            &[(
                "judge",
                &format!("export function session(s) {{ s.hook('round.after', () => {{ {body} }}); }}"),
            )],
        )
        .await;

        let expected = format!("round.after of plugin judge failed: {error}");
        assert_eq!(after_final(&session).await, Err(expected), "{body}");
    }
}

#[tokio::test]
async fn a_cancel_aborts_the_signal_and_the_hook_proceeds_at_once() {
    let (runtime, session, _reports) = opened(
        "a_cancel_aborts_the_signal_and_the_hook_proceeds_at_once",
        &[(
            "slow",
            "export function session(s) {
               s.hook('round.after', ({ signal }) => {
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
    let context = final_answer();

    let cancel = async {
        while !evaluate::<bool>(&runtime, "return globalThis.started === true;")
            .await
            .unwrap()
        {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        token.cancel();
    };
    let (decision, ()) = tokio::join!(decide(&hooks, &context, Some(FinishReason::Stop)), cancel);

    assert_eq!(decision, Ok(RoundDecision::Proceed));
    let aborted = evaluate::<String>(&runtime, "return globalThis.aborted ?? 'none';")
        .await
        .unwrap();
    assert_eq!(aborted, "AbortError");
}
