//! These tests cover the `round.retry` hook: its event, its count of retries, its plan, and the kind of a failure.

use std::time::Duration;

use yuke_ai::transport::Fault;
use yuke_ai::{AttemptError, AttemptInfo, Block, Failure, ProviderKind, Settings};
use yuke_engine::{CancellationToken, Hooks, RoundError, RoundPlan, RoundStart};

use super::evaluate;
use super::prompt::opened;
use super::windowed;
use crate::ScriptHooks;

/// A failed attempt of `cause`.
fn failed(cause: Failure) -> RoundError {
    RoundError::Model(yuke_ai::Error::Attempt(AttemptError {
        cause,
        info: AttemptInfo::default(),
        partial: Vec::new(),
    }))
}

/// The answer of the `round.retry` hooks of `hooks` after `failure` in a round of one block.
async fn retry(hooks: &ScriptHooks, failure: &RoundError) -> Result<Option<RoundPlan>, String> {
    let context = [Block::user_text("one")];
    let settings = Settings::new();
    let round = RoundStart {
        context: &context,
        model: &windowed(Some(1000)),
        settings: &settings,
        system: "",
        tools: &[],
        input_tokens: Some(900),
    };
    tokio::time::timeout(Duration::from_secs(5), hooks.retry_round(&round, failure))
        .await
        .unwrap()
        .map_err(|error| error.to_string())
}

#[tokio::test]
async fn an_answer_sends_the_round_again_and_each_round_counts_its_retries_from_zero() {
    let (runtime, session, _reports) = opened(
        "an_answer_sends_the_round_again_and_each_round_counts_its_retries_from_zero",
        &[(
            "compact",
            "globalThis.seen = [];
             export function session(s) {
               s.hook('round.retry', ({ failure, retries, window, inputTokens, blocks }) => {
                 globalThis.seen.push(`${failure.kind} ${retries} ${window} ${inputTokens} ${blocks}`);
                 return { replace: { head: [{ user_text: 'summary' }], keep: 0 } };
               });
             }",
        )],
    )
    .await;
    let hooks = session.hooks(CancellationToken::new());
    let overflow = failed(Failure::Provider(ProviderKind::ContextOverflow));

    let plan = retry(&hooks, &overflow).await.unwrap().unwrap();
    retry(&hooks, &overflow).await.unwrap();
    let context = [Block::user_text("next")];
    let settings = Settings::new();
    let round = RoundStart {
        context: &context,
        model: &windowed(Some(1000)),
        settings: &settings,
        system: "",
        tools: &[],
        input_tokens: None,
    };
    hooks.before_round(&round).await.unwrap();
    retry(&hooks, &overflow).await.unwrap();

    let replace = plan.replace.unwrap();
    assert_eq!(
        (replace.head.as_ref(), replace.keep),
        (&[Block::user_text("summary")][..], 0)
    );
    assert_eq!(
        evaluate::<Vec<String>>(&runtime, "return globalThis.seen;")
            .await
            .unwrap(),
        [
            "context_overflow 0 1000 900 1",
            "context_overflow 1 1000 900 1",
            "context_overflow 0 1000 900 1",
        ]
    );
}

#[tokio::test]
async fn without_an_answer_the_round_does_not_run_again() {
    let (_runtime, session, _reports) = opened(
        "without_an_answer_the_round_does_not_run_again",
        &[(
            "quiet",
            "export function session(s) { s.hook('round.retry', () => undefined); }",
        )],
    )
    .await;
    let hooks = session.hooks(CancellationToken::new());

    let plan = retry(&hooks, &failed(Failure::Provider(ProviderKind::ContextOverflow))).await;

    assert_eq!(plan.map(|plan| plan.is_some()), Ok(false));
}

#[tokio::test]
async fn the_failure_names_its_kind_and_its_text() {
    let (runtime, session, _reports) = opened(
        "the_failure_names_its_kind_and_its_text",
        &[(
            "watch",
            "globalThis.seen = [];
             export function session(s) {
               s.hook('round.retry', ({ failure }) => { globalThis.seen.push(`${failure.kind}: ${failure.message}`); });
             }",
        )],
    )
    .await;
    let hooks = session.hooks(CancellationToken::new());
    let failures = [
        failed(Failure::Provider(ProviderKind::RateLimited)),
        failed(Failure::Transport(Fault::ConnectFailed)),
        failed(Failure::IncompleteStream),
        RoundError::Credential("no login".into()),
    ];

    for failure in &failures {
        retry(&hooks, failure).await.unwrap();
    }

    let seen = evaluate::<Vec<String>>(&runtime, "return globalThis.seen;")
        .await
        .unwrap();
    let expected: Vec<String> = ["rate_limited", "transport", "incomplete_stream", "credential"]
        .iter()
        .zip(&failures)
        .map(|(kind, failure)| format!("{kind}: {}", yuke_engine::chain_text(failure)))
        .collect();
    assert_eq!(seen, expected);
}

#[tokio::test]
async fn a_bad_answer_fails_the_hook_and_names_the_point_and_the_plugin() {
    let (_runtime, session, _reports) = opened(
        "a_bad_answer_fails_the_hook_and_names_the_point_and_the_plugin",
        &[(
            "broken",
            "export function session(s) { s.hook('round.retry', () => ({ model: { provider: 'nope' } })); }",
        )],
    )
    .await;
    let hooks = session.hooks(CancellationToken::new());

    let failure = retry(&hooks, &failed(Failure::Provider(ProviderKind::ContextOverflow)))
        .await
        .unwrap_err();

    assert!(failure.starts_with("round.retry of plugin broken failed"), "{failure}");
}
