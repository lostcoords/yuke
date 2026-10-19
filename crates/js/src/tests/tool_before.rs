//! These tests cover the `tool.before` hook: its order, its payload, its answers, its failures, and its cancel.

use std::time::Duration;

use yuke_ai::ToolCall;
use yuke_engine::{CancellationToken, Hooks, ToolDecision};

use super::evaluate;
use super::prompt::opened;
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

#[tokio::test]
async fn a_call_runs_when_no_handler_blocks_it() {
    let (_runtime, session, _reports) = opened(
        "a_call_runs_when_no_handler_blocks_it",
        &[(
            "quiet",
            "export function session(s) { s.hook('tool.before', () => undefined); }",
        )],
    )
    .await;

    assert_eq!(decide(&session, "read", "{}").await, ToolDecision::Run);
}

// The first block ends the chain, so a later handler never sees the call.
#[tokio::test]
async fn the_first_block_in_plugin_order_then_in_addition_order_stops_the_call() {
    let (runtime, session, _reports) = opened(
        "the_first_block_in_plugin_order_then_in_addition_order_stops_the_call",
        &[
            (
                "first",
                "globalThis.seen = [];
                 export function session(s) {
                   s.hook('tool.before', () => { globalThis.seen.push('first one'); });
                   s.hook('tool.before', () => { globalThis.seen.push('first two'); return { block: 'first says no' }; });
                 }",
            ),
            (
                "second",
                "export function session(s) {
                   s.hook('tool.before', () => { globalThis.seen.push('second'); return { block: 'second says no' }; });
                 }",
            ),
        ],
    )
    .await;

    let decision = decide(&session, "read", "{}").await;
    let seen = evaluate::<Vec<String>>(&runtime, "return globalThis.seen;")
        .await
        .unwrap();

    assert_eq!(decision, block("first says no"));
    assert_eq!(seen, ["first one", "first two"]);
}

#[tokio::test]
async fn a_handler_gets_the_id_the_name_and_the_parsed_arguments_of_the_call() {
    let (_runtime, session, _reports) = opened(
        "a_handler_gets_the_id_the_name_and_the_parsed_arguments_of_the_call",
        &[(
            "reader",
            "export function session(s) {
               s.hook('tool.before', (call) => ({ block: `${call.id} ${call.name} ${call.arguments.path.join('/')}` }));
             }",
        )],
    )
    .await;

    let decision = decide(&session, "read", r#"{"path": ["src", "main.rs"]}"#).await;

    assert_eq!(decision, block("c1 read src/main.rs"));
}

// The call runs with the arguments of the model, so a change of them fails at once and stops the call.
#[tokio::test]
async fn a_change_of_the_arguments_at_any_depth_throws_and_stops_the_call() {
    let (_runtime, session, _reports) = opened(
        "a_change_of_the_arguments_at_any_depth_throws_and_stops_the_call",
        &[(
            "editor",
            "export function session(s) { s.hook('tool.before', (call) => { call.arguments.options.force = true; }); }",
        )],
    )
    .await;

    let decision = decide(&session, "write", r#"{"options": {"force": false}}"#).await;

    let ToolDecision::Block(reason) = decision else {
        panic!("the call runs: {decision:?}");
    };
    assert!(
        reason.starts_with("tool.before of plugin editor failed: TypeError: "),
        "{reason}"
    );
}

#[tokio::test]
async fn a_throw_or_an_answer_of_another_shape_stops_the_call_and_names_the_plugin() {
    let shape = "tool.before of plugin check gave an answer that is not undefined or { block: string }";
    let cases = [
        (
            "throw new Error('no check today');",
            "tool.before of plugin check failed: Error: no check today",
        ),
        ("return { block: 1 };", shape),
        ("return 'no';", shape),
        ("return {};", shape),
        ("return null;", shape),
    ];
    for (index, (body, expected)) in cases.into_iter().enumerate() {
        let (_runtime, session, _reports) = opened(
            &format!("a_throw_or_an_answer_of_another_shape_stops_the_call_and_names_the_plugin_{index}"),
            &[(
                "check",
                &format!("export function session(s) {{ s.hook('tool.before', () => {{ {body} }}); }}"),
            )],
        )
        .await;

        assert_eq!(decide(&session, "read", "{}").await, block(expected), "{body}");
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
               s.hook('tool.before', (call) => {
                 globalThis.started = true;
                 call.signal.addEventListener('abort', () => { globalThis.aborted = call.signal.reason.name; });
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
        while !evaluate::<bool>(&runtime, "return globalThis.started === true;")
            .await
            .unwrap()
        {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
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
        while !evaluate::<bool>(&runtime, "return typeof globalThis.release === 'function';")
            .await
            .unwrap()
        {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        session.close().await.unwrap();
        evaluate::<()>(&runtime, "globalThis.release();").await.unwrap();
    };

    let (decision, ()) = tokio::join!(decision, close);

    assert_eq!(decision, ToolDecision::Run);
}

#[tokio::test]
async fn a_removed_handler_and_the_handler_of_a_failed_session_block_nothing() {
    let (_runtime, session, _reports) = opened(
        "a_removed_handler_and_the_handler_of_a_failed_session_block_nothing",
        &[
            (
                "removed",
                "export function session(s) { s.hook('tool.before', () => ({ block: 'removed' }))(); }",
            ),
            (
                "failed",
                "export async function session(s) {
                   s.hook('tool.before', () => ({ block: 'failed' }));
                   await null;
                   throw new Error('broken');
                 }",
            ),
        ],
    )
    .await;

    assert_eq!(decide(&session, "read", "{}").await, ToolDecision::Run);
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
