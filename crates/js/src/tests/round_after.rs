//! These tests cover the `round.after` hook: its payload, its answers, its count, its failures, and its cancel.

use std::time::Duration;

use yuke_ai::{Block, FinishReason};
use yuke_engine::{CancellationToken, Hooks, RoundDecision};

use super::opened;
use super::{evaluate, wait_until};
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
        wait_until(&runtime, "return globalThis.started === true;").await;
        token.cancel();
    };
    let (decision, ()) = tokio::join!(decide(&hooks, &context, Some(FinishReason::Stop)), cancel);

    assert_eq!(decision, Ok(RoundDecision::Proceed));
    let aborted = evaluate::<String>(&runtime, "return globalThis.aborted ?? 'none';")
        .await
        .unwrap();
    assert_eq!(aborted, "AbortError");
}
