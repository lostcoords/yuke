use std::sync::Mutex;

use async_trait::async_trait;
use yuke_ai::scripted::{ScriptedTransport, text_reply, tool_reply};
use yuke_ai::{Block, ToolCall, ToolResult};
use yuke_engine::NoWait;
use yuke_engine::{CancellationToken, Driver, Hooks, Outcome, Toolset};
use yuke_testing::{definition, model};

use crate::support::{Fixed, Script, block_on, results_in_context};

/// A toolset with the tool `print`, which answers "printed".
fn printer() -> Toolset {
    let mut toolset = Toolset::new();
    toolset.add(definition("print"), Fixed(Ok("printed".into()))).unwrap();
    toolset
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
    let model = model();
    let toolset = printer();
    let hooks = ReplaceResult::default();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);

    let results = results_in_context(driver);

    assert_eq!(*hooks.seen.lock().unwrap(), ["printed"]);
    assert_eq!(results, [ToolResult::error("c1", "replaced")]);
}

#[test]
fn after_tool_does_not_run_for_a_blocked_call() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "print", "{}")]), text_reply("done")]);
    let model = model();
    let toolset = printer();
    let hooks = Script::default().blocks("print");
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);

    let results = results_in_context(driver);

    assert_eq!(results, [ToolResult::error("c1", "The user blocked this call.")]);
    assert_eq!(hooks.tools(), ["before print {}"]);
}

#[test]
fn cancel_while_after_tool_waits_keeps_the_tool_result() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "print", "{}")])]);
    let model = model();
    let toolset = printer();
    let cancellation_token = CancellationToken::new();
    let hooks = Script::default().cancel_at("after_tool", cancellation_token.clone());
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);
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
