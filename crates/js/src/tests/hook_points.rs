//! These tests cover the skip of a hook point without a handler: such a hook answers without the JavaScript thread.

use std::rc::Rc;
use std::time::Duration;

use rquickjs::Ctx;

use yuke_agent::PromptSection;
use yuke_ai::{Block, FinishReason, Settings, ToolCall, ToolResult};
use yuke_engine::{CancellationToken, Hooks, RoundDecision, RoundError, RoundStart, ToolDecision};

use super::prompt::opened;
use super::{evaluate, wait_until};
use crate::tools::Registry;
use crate::{Runtime, ScriptSession};

/// Keep the JavaScript thread busy for 1 second. The thread runs its calls in order, so a hook that enters
/// JavaScript after this call waits for the end of the script.
fn keep_busy(runtime: &Runtime) {
    let busy = async move |ctx: Ctx<'_>, _: Rc<Registry>| {
        ctx.eval::<(), _>("{ const end = Date.now() + 1000; while (Date.now() < end) {} }")
            .unwrap();
    };
    runtime.caller.post(busy).unwrap();
}

/// Whether each hook of `session` answers within 300 ms while the JavaScript thread of `runtime` is busy.
async fn answers_at_once(runtime: &Runtime, session: &ScriptSession) -> bool {
    let hooks = session.hooks(CancellationToken::new());
    let context = [Block::user_text("one")];
    let settings = Settings::new();
    let round = RoundStart {
        context: &context,
        settings: &settings,
        window: None,
        input_tokens: None,
    };
    let call = ToolCall {
        call_id: "c1".to_owned(),
        name: "read".to_owned(),
        arguments: "{}".to_owned(),
    };
    let result = ToolResult::success("c1", "done");
    let sections = [PromptSection::new("base", "You are yuke.")];
    let token = CancellationToken::new();
    keep_busy(runtime);
    let limit = Duration::from_millis(300);
    let plan = tokio::time::timeout(limit, hooks.before_round(&round)).await;
    let failure = RoundError::Credential("no login".into());
    let retry = tokio::time::timeout(limit, hooks.retry_round(&round, &failure)).await;
    let decision = tokio::time::timeout(limit, hooks.before_tool(&call)).await;
    let changed = tokio::time::timeout(limit, hooks.after_tool(&call, &result)).await;
    let round_end = tokio::time::timeout(limit, hooks.after_round(&context, Some(FinishReason::Stop))).await;
    let prompt = tokio::time::timeout(limit, session.build_prompt(&sections, &token)).await;
    // The next test waits behind the busy script, so it starts with a free thread.
    wait_until(runtime, "return true;").await;
    plan.is_ok_and(|plan| plan.is_ok_and(|plan| plan.replace.is_none()))
        && retry.is_ok_and(|retry| retry.is_ok_and(|retry| retry.is_none()))
        && decision.is_ok_and(|decision| decision == ToolDecision::Run)
        && changed.is_ok_and(|changed| changed.is_none())
        && round_end.is_ok_and(|end| end.is_ok_and(|end| end == RoundDecision::Proceed))
        && prompt.is_ok_and(|prompt| prompt.is_ok_and(|prompt| prompt == sections))
}

#[tokio::test]
async fn a_session_without_handlers_answers_each_hook_without_the_javascript_thread() {
    let (runtime, session, _reports) = opened(
        "a_session_without_handlers_answers_each_hook_without_the_javascript_thread",
        &[("quiet", "export function session(s) {}")],
    )
    .await;
    // The tools wait for the plugins, so the host knows the points after this.
    session.tools().await.unwrap();

    assert!(answers_at_once(&runtime, &session).await);
}

#[tokio::test]
async fn a_handler_of_each_point_makes_its_hook_wait_for_the_javascript_thread() {
    let points = [
        "round.before",
        "tool.before",
        "tool.after",
        "round.after",
        "prompt.build",
    ];
    for point in points {
        let (runtime, session, _reports) = opened(
            &format!("a_handler_of_each_point_makes_its_hook_wait_for_the_javascript_thread_{point}"),
            &[(
                "hooked",
                &format!("export function session(s) {{ s.hook('{point}', () => undefined); }}"),
            )],
        )
        .await;
        session.tools().await.unwrap();

        assert!(!answers_at_once(&runtime, &session).await, "{point}");
    }
}

#[tokio::test]
async fn a_handler_added_later_counts_and_a_removed_handler_or_a_failed_session_no_longer_counts() {
    let (runtime, session, _reports) = opened(
        "a_handler_added_later_counts_and_a_removed_handler_or_a_failed_session_no_longer_counts",
        &[
            (
                "later",
                "export function session(s) {
                   globalThis.add = () => { globalThis.remove = s.hook('round.before', () => undefined); };
                 }",
            ),
            (
                "failing",
                "export async function session(s) {
                   s.hook('tool.before', () => undefined);
                   await new Promise((resolve) => setTimeout(resolve, 0));
                   throw new Error('setup failed');
                 }",
            ),
        ],
    )
    .await;
    session.tools().await.unwrap();
    // The failed session dropped its handler, so no point holds one.
    assert!(answers_at_once(&runtime, &session).await);

    evaluate::<()>(&runtime, "globalThis.add();").await.unwrap();
    let added = answers_at_once(&runtime, &session).await;
    evaluate::<()>(&runtime, "globalThis.remove();").await.unwrap();
    let removed = answers_at_once(&runtime, &session).await;

    assert!(!added);
    assert!(removed);
}

#[tokio::test]
async fn a_hook_kept_after_the_close_of_its_session_answers_without_the_javascript_thread() {
    let (runtime, session, _reports) = opened(
        "a_hook_kept_after_the_close_of_its_session_answers_without_the_javascript_thread",
        &[(
            "hooked",
            "export function session(s) { s.hook('tool.before', () => undefined); }",
        )],
    )
    .await;
    session.tools().await.unwrap();
    let hooks = session.hooks(CancellationToken::new());
    session.close().await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), runtime.shutdown())
        .await
        .unwrap()
        .unwrap();
    let call = ToolCall {
        call_id: "c1".to_owned(),
        name: "read".to_owned(),
        arguments: "{}".to_owned(),
    };

    // The closed session holds no check, so the call runs and the end of the thread does not block it.
    assert_eq!(hooks.before_tool(&call).await, ToolDecision::Run);
}
