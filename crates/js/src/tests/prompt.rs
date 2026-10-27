//! These tests cover the `prompt.build` hook: its order, its answers, its checks, its failures, and its cancel.

use std::time::Duration;

use yuke_agent::PromptSection;
use yuke_engine::CancellationToken;

use super::{evaluate, opened};

/// The sections of a new session before any hook.
fn saved() -> Vec<PromptSection> {
    vec![
        PromptSection::new("base", "You are yuke."),
        PromptSection::new("environment", "workspace: /work"),
    ]
}

#[tokio::test]
async fn a_cancel_aborts_the_signal_and_returns_the_sections_of_the_caller_at_once() {
    let (runtime, session, _reports) = opened(
        "a_cancel_aborts_the_signal_and_returns_the_sections_of_the_caller_at_once",
        &[(
            "slow",
            "export function session(s) {
               s.hook('prompt.build', ({ signal }) => {
                 signal.addEventListener('abort', () => { globalThis.aborted = signal.reason.name; });
                 return new Promise(() => {});
               });
             }",
        )],
    )
    .await;
    let token = CancellationToken::new();
    let sections = saved();

    let built = tokio::join!(session.build_prompt(&sections, &token), async {
        tokio::time::sleep(Duration::from_millis(20)).await;
        token.cancel();
    })
    .0
    .unwrap();

    assert_eq!(built, saved());
    let aborted = evaluate::<String>(&runtime, "return globalThis.aborted;")
        .await
        .unwrap();
    assert_eq!(aborted, "AbortError");
}
