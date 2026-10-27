//! These tests cover the `tool.before` hook: its order, its payload, its answers, its failures, and its cancel.

use std::time::Duration;

use yuke_ai::ToolCall;
use yuke_engine::{CancellationToken, Hooks, ToolDecision};

use super::opened;
use super::{evaluate, wait_until};
use crate::ScriptSession;

/// The decision of the hooks of `session` for one call. `name` is the tool, and `arguments` is the JSON text.
async fn decide(session: &ScriptSession, name: &str, arguments: &str) -> ToolDecision {
    let call = ToolCall {
        call_id: "c1".to_owned(),
        name: name.to_owned(),
        arguments: arguments.to_owned(),
    };
    let hooks = session.hooks(CancellationToken::new());
    tokio::time::timeout(Duration::from_secs(5), hooks.before_tool(&call))
        .await
        .unwrap()
}

fn block(reason: &str) -> ToolDecision {
    ToolDecision::Block(reason.to_owned())
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
    let call = ToolCall {
        call_id: "c1".to_owned(),
        name: "read".to_owned(),
        arguments: "{}".to_owned(),
    };

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
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let aborted = loop {
        let aborted = evaluate::<Option<String>>(&runtime, "return globalThis.aborted;")
            .await
            .unwrap();
        if aborted.is_some() || tokio::time::Instant::now() > deadline {
            break aborted;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    };
    assert_eq!(aborted.as_deref(), Some("AbortError"));
}

// A close during a handler ends the turn, so a late block of the closed session does not count.
#[tokio::test]
async fn a_block_that_comes_after_the_close_of_the_session_does_not_count() {
    let (runtime, session, _reports) = opened(
        "a_block_that_comes_after_the_close_of_the_session_does_not_count",
        &[(
            "late",
            "export function session(s) {
               s.hook('tool.before', () => new Promise((resolve) => {
                 globalThis.release = () => resolve({ block: 'too late' });
               }));
             }",
        )],
    )
    .await;
    let decision = decide(&session, "read", "{}");
    let close = async {
        wait_until(&runtime, "return typeof globalThis.release === 'function';").await;
        session.close().await.unwrap();
        evaluate::<()>(&runtime, "globalThis.release();").await.unwrap();
    };

    let (decision, ()) = tokio::join!(decision, close);

    assert_eq!(decision, ToolDecision::Run);
}

// A hook that cannot answer never lets a call run.
#[tokio::test]
async fn a_call_is_blocked_when_the_javascript_thread_has_ended() {
    let (runtime, session, _reports) = opened(
        "a_call_is_blocked_when_the_javascript_thread_has_ended",
        &[("quiet", "export function session(s) {}")],
    )
    .await;
    let hooks = session.hooks(CancellationToken::new());
    tokio::time::timeout(Duration::from_secs(5), runtime.shutdown())
        .await
        .unwrap()
        .unwrap();
    let call = ToolCall {
        call_id: "c1".to_owned(),
        name: "read".to_owned(),
        arguments: "{}".to_owned(),
    };

    assert_eq!(
        hooks.before_tool(&call).await,
        block("the tool.before hooks failed: the JavaScript thread has ended")
    );
}
