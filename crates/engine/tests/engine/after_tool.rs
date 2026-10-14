use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;
use yuke_ai::{Block, ToolCall, ToolResult};
use yuke_engine::{
    CancellationToken, Driver, Hooks, Outcome, Tool, ToolContent, ToolContext, ToolDecision, Toolset, TurnEvent,
};

use crate::support::{NoWait, ScriptedTransport, block_on, definition, target, text_reply, tool_reply};

/// A tool that answers each call with one fixed text.
struct Answers(&'static str);

#[async_trait]
impl Tool for Answers {
    async fn call(&self, _: &str, _: &ToolContext<'_>) -> Result<ToolContent, String> {
        Ok(self.0.into())
    }
}

/// Run one turn in which the model calls `print` once. Return the tool result in the context.
fn result_in_context(driver: Driver<'_>) -> ToolResult {
    let mut context = Vec::new();
    let finished = Mutex::new(Vec::new());
    block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .observer(&|event: &TurnEvent<'_>| {
                if let TurnEvent::ToolFinished(result) = event {
                    finished.lock().unwrap().push((*result).clone());
                }
            })
            .run(),
    )
    .unwrap();
    let result = context
        .iter()
        .find_map(|block| match block {
            Block::ToolResult(result) => Some(result.clone()),
            _ => None,
        })
        .unwrap();
    // The observer receives the result that the model receives.
    assert_eq!(*finished.lock().unwrap(), std::slice::from_ref(&result));
    result
}

/// Hooks that replace each result under another call id, and keep the text that they saw.
#[derive(Default)]
struct ReplaceResult {
    seen: Mutex<Vec<String>>,
}

#[async_trait]
impl Hooks for ReplaceResult {
    async fn after_tool(&self, call: &ToolCall, result: &ToolResult) -> Option<ToolResult> {
        self.seen.lock().unwrap().push(result.content.clone());
        Some(ToolResult::error(format!("not-{}", call.call_id), "replaced"))
    }
}

#[test]
fn after_tool_replaces_a_result_and_the_replacement_keeps_its_call_id() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "print", "{}")]), text_reply("done")]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("print"), Answers("printed")).unwrap();
    let hooks = ReplaceResult::default();
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&hooks);

    let result = result_in_context(driver);

    assert_eq!(*hooks.seen.lock().unwrap(), ["printed"]);
    assert_eq!(result, ToolResult::error("c1", "replaced"));
}

/// Hooks that block each call, and count the calls of `after_tool`.
#[derive(Default)]
struct BlockAndCount {
    after_tool_calls: AtomicUsize,
}

#[async_trait]
impl Hooks for BlockAndCount {
    async fn before_tool(&self, _: &ToolCall) -> ToolDecision {
        ToolDecision::Block("The user blocked this call.".to_owned())
    }

    async fn after_tool(&self, _: &ToolCall, _: &ToolResult) -> Option<ToolResult> {
        self.after_tool_calls.fetch_add(1, Ordering::Relaxed);
        None
    }
}

#[test]
fn after_tool_does_not_run_for_a_blocked_call() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "print", "{}")]), text_reply("done")]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("print"), Answers("printed")).unwrap();
    let hooks = BlockAndCount::default();
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&hooks);

    let result = result_in_context(driver);

    assert_eq!(result, ToolResult::error("c1", "The user blocked this call."));
    assert_eq!(hooks.after_tool_calls.load(Ordering::Relaxed), 0);
}

/// Hooks that cancel the turn in `after_tool`, then wait forever.
struct CancelAfterTool(CancellationToken);

#[async_trait]
impl Hooks for CancelAfterTool {
    async fn after_tool(&self, _: &ToolCall, _: &ToolResult) -> Option<ToolResult> {
        self.0.cancel();
        std::future::pending().await
    }
}

#[test]
fn cancel_while_after_tool_waits_keeps_the_tool_result() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "print", "{}")])]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("print"), Answers("printed")).unwrap();
    let cancellation_token = CancellationToken::new();
    let hooks = CancelAfterTool(cancellation_token.clone());
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&hooks);
    let mut context = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert_eq!(
        context.last(),
        Some(&Block::ToolResult(ToolResult::success("c1", "printed")))
    );
}
