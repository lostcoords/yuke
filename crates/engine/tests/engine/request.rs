use std::sync::Mutex;

use async_trait::async_trait;
use yuke_ai::{AnthropicWire, Block, Content, FinishReason, Request, Settings, Target, ToolDefinition, Wire};
use yuke_engine::{CancellationToken, Driver, Hooks, Model, RoundPlan, RoundStart, Toolset};
use yuke_testing::{NoWait, ScriptedTransport, model, model_of, overloaded_reply, target, text_reply, tool_reply};

use crate::support::{Recorder, Script, block_on, definition};

/// The model, the settings, the system prompt, the tools, and the context of the newest round start.
type Start = (Model, Settings, String, Vec<ToolDefinition>, Vec<Block>);

/// Keeps the newest round start.
#[derive(Default)]
struct Newest(Mutex<Option<Start>>);

#[async_trait]
impl Hooks for Newest {
    async fn before_round(
        &self,
        round: &RoundStart<'_>,
    ) -> Result<RoundPlan, Box<dyn std::error::Error + Send + Sync>> {
        let start = (
            round.model.clone(),
            round.settings.clone(),
            round.system.to_owned(),
            round.tools.to_vec(),
            round.context.to_vec(),
        );
        *self.0.lock().unwrap() = Some(start);
        Ok(RoundPlan::default())
    }
}

// The prompt cache of a provider matches a prefix, so a request from the round start must repeat the round's bytes,
// with the cache marker where the round puts it.
#[test]
fn a_request_from_a_round_start_repeats_the_round_request_and_its_cache_marker_and_adds_its_blocks() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")]), text_reply("done")]);
    let model = model_of(Target {
        wire: Wire::AnthropicMessages(AnthropicWire {
            max_tokens: 64,
            cache: true,
        }),
        ..target()
    });
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Recorder::default()).unwrap();
    let settings = Settings::new().temperature(0.25);
    let hooks = Newest::default();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);
    block_on(
        driver
            .turn(&mut Vec::new(), vec![Block::user_text("go")])
            .system("Be brief.")
            .settings(&settings)
            .session_id("s1")
            .run(),
    )
    .unwrap();

    let (model, settings, system, tools, mut context) = hooks.0.lock().unwrap().take().unwrap();
    let cached = context.len();
    context.push(Block::user_text("Summarize."));
    let side = ScriptedTransport::new([text_reply("summary")]);
    let request = Request::new(&context)
        .system(&system)
        .settings(&settings)
        .session_id("s1")
        .tools(&tools)
        .cached(cached);
    block_on(Driver::new(&side, &model, &NoWait).request(request, &CancellationToken::new())).unwrap();

    let round = transport.requests()[1].clone();
    let result = r#"{"type":"tool_result","tool_use_id":"c1","content":"result 1","is_error":false,"cache_control":{"type":"ephemeral"}}"#;
    let expected = round.replacen(result, &format!(r#"{result},{{"type":"text","text":"Summarize."}}"#), 1);
    assert_ne!(expected, round, "the round body has no tool result: {round}");
    assert_eq!(side.requests(), [expected]);
}

#[test]
fn a_request_offers_its_tools_and_runs_no_tool_and_no_hook() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")])]);
    let model = model();
    let recorder = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), recorder.clone()).unwrap();
    let hooks = Script::default();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);

    let blocks = [Block::user_text("go")];
    let tools = [definition("look")];
    let request = Request::new(&blocks).tools(&tools);
    let response = block_on(driver.request(request, &CancellationToken::new()))
        .unwrap()
        .unwrap();

    assert_eq!(response.completion.finish_reason, FinishReason::ToolCalls);
    assert!(matches!(&response.completion.content[..], [Content::ToolCall(call)] if call.name == "echo"));
    assert_eq!(recorder.calls(), Vec::<String>::new());
    assert!(hooks.calls().is_empty(), "{:?}", hooks.calls());
    let request = &transport.requests()[0];
    assert!(request.contains(r#""name":"look""#), "{request}");
    assert!(!request.contains(r#""name":"echo""#), "{request}");
}

#[test]
fn a_request_sends_again_after_an_overload() {
    let transport = ScriptedTransport::new([overloaded_reply(), text_reply("done")]);
    let model = model();
    let driver = Driver::new(&transport, &model, &NoWait);

    let blocks = [Block::user_text("go")];
    let response = block_on(driver.request(Request::new(&blocks), &CancellationToken::new()))
        .unwrap()
        .unwrap();

    assert_eq!(response.completion.text(), "done");
    assert_eq!(transport.requests().len(), 2);
}

#[test]
fn a_cancelled_request_answers_none_and_sends_nothing() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let model = model();
    let driver = Driver::new(&transport, &model, &NoWait);
    let token = CancellationToken::new();
    token.cancel();

    let blocks = [Block::user_text("go")];
    let response = block_on(driver.request(Request::new(&blocks), &token)).unwrap();

    assert!(response.is_none());
    assert_eq!(transport.requests(), Vec::<String>::new());
}
