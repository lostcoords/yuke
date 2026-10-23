use std::sync::Mutex;

use yuke_ai::{Block, Target, ToolDefinition, ToolResult};
use yuke_engine::{Driver, RoundPlan, Toolset, TurnEvent};
use yuke_testing::{NoWait, ScriptedTransport, definition, model, model_of, target, text_reply, tool_reply};

use crate::support::{Recorder, Script, block_on, results_in_context};

/// A deferred `create_issue` tool with an object input schema.
fn create_issue_definition() -> ToolDefinition {
    ToolDefinition {
        name: "create_issue".into(),
        description: "Create an issue.".into(),
        input_schema: r#"{"type":"object"}"#.to_owned(),
        defer_loading: false,
    }
    .deferred()
}

/// The test target with a native tool search.
fn native_target() -> Target {
    Target {
        tool_search: true,
        ..target()
    }
}

/// The `tools` array of an Anthropic request body.
fn declared_tools(body: &str) -> &str {
    let start = body.find(r#""tools":"#).expect("a request with tools");
    let end = body.find(r#","messages""#).expect("a request with messages");
    &body[start..end]
}

#[test]
fn a_toolset_without_deferred_tools_declares_no_search_tool() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let model = model_of(native_target());
    let mut toolset = Toolset::new();
    toolset.add(definition("read"), Recorder::default()).unwrap();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    results_in_context(driver);

    let body = &transport.requests()[0];
    assert!(!body.contains("tool_search"), "{body}");
}

#[test]
fn on_the_bridge_path_the_declared_tools_stay_the_same_after_a_search() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "tool_search", r#"{"query": "create issue"}"#)]),
        text_reply("done"),
    ]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("read"), Recorder::default()).unwrap();
    toolset.add(create_issue_definition(), Recorder::default()).unwrap();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    let results = results_in_context(driver);

    let requests = transport.requests();
    assert_eq!(declared_tools(&requests[0]), declared_tools(&requests[1]));
    assert!(!requests[0].contains("create_issue"), "{}", requests[0]);
    assert!(requests[0].contains(r#""name":"tool_call""#), "{}", requests[0]);
    assert_eq!(
        results,
        [ToolResult::success(
            "c1",
            "Found 1 tools. Call one with tool_call.\n\n## create_issue\nCreate an issue.\nInput schema: {\"type\":\"object\"}"
        )]
    );
}

/// A deferred tool whose input schema holds `bytes` bytes of description.
fn large(name: &str, bytes: usize) -> ToolDefinition {
    let schema = format!(
        r#"{{"type":"object","properties":{{"x":{{"type":"string","description":"{}"}}}}}}"#,
        "z".repeat(bytes)
    );
    ToolDefinition {
        name: name.into(),
        description: "Alpha tool.".to_owned(),
        input_schema: schema,
        defer_loading: false,
    }
    .deferred()
}

#[test]
fn a_bridge_search_shows_the_schema_of_each_match_in_name_order() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "tool_search", r#"{"query": "alpha"}"#)]),
        text_reply("done"),
    ]);
    let model = model();
    let mut toolset = Toolset::new();
    // Large schemas show in full. Equal scores sort by name.
    for name in ["alpha_two", "alpha_one", "alpha_three"] {
        toolset.add(large(name, 7000), Recorder::default()).unwrap();
    }
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    let results = results_in_context(driver);

    let sections: Vec<&str> = results[0].content.split("\n\n").collect();
    assert_eq!(sections.len(), 4, "{}", results[0].content);
    for (section, name) in sections[1..].iter().zip(["alpha_one", "alpha_three", "alpha_two"]) {
        let schema = large(name, 7000).input_schema;
        assert_eq!(*section, format!("## {name}\nAlpha tool.\nInput schema: {schema}"));
    }
}

#[test]
fn tool_call_runs_a_deferred_tool_and_the_hooks_and_the_observer_see_the_real_call() {
    let transport = ScriptedTransport::new([
        tool_reply(&[(
            "c1",
            "tool_call",
            r#"{"name": "create_issue", "arguments": {"title": "Bug", "body": "x"}}"#,
        )]),
        text_reply("done"),
    ]);
    let model = model();
    let issue = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(create_issue_definition(), issue.clone()).unwrap();
    let hooks = Script::default();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);
    let started = Mutex::new(Vec::new());
    let mut context = Vec::new();

    block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .observer(&|event: &TurnEvent<'_>| {
                if let TurnEvent::ToolStarted { call, .. } = event {
                    started.lock().unwrap().push(format!("{} {}", call.call_id, call.name));
                }
            })
            .run(),
    )
    .unwrap();

    // The tool receives the argument text that the model wrote, in its order.
    let arguments = r#"{"title": "Bug", "body": "x"}"#;
    assert_eq!(issue.calls(), [arguments]);
    assert_eq!(
        hooks.tools(),
        [format!("before create_issue {arguments}"), "after c1".to_owned()]
    );
    assert_eq!(*started.lock().unwrap(), ["c1 create_issue"]);
    // The context keeps the call that the model wrote, and the result answers it.
    let context = context;
    assert!(matches!(&context[1], Block::ToolCall(call) if call.name == "tool_call"));
    assert_eq!(context[2], Block::ToolResult(ToolResult::success("c1", "result 1")));
}

#[test]
fn tool_call_runs_any_tool_of_the_toolset_and_an_unknown_name_gets_an_error_after_the_hooks() {
    let transport = ScriptedTransport::new([
        tool_reply(&[
            ("c1", "tool_call", r#"{"name": "read", "arguments": {}}"#),
            ("c2", "tool_call", r#"{"name": "nope", "arguments": {}}"#),
        ]),
        text_reply("done"),
    ]);
    let model = model();
    let read = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("read"), read.clone()).unwrap();
    toolset.add(create_issue_definition(), Recorder::default()).unwrap();
    let hooks = Script::default();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);

    let results = results_in_context(driver);

    assert_eq!(
        results,
        [
            ToolResult::success("c1", "result 1"),
            ToolResult::error("c2", "Unknown tool: nope"),
        ]
    );
    assert_eq!(read.calls(), ["{}"]);
    // The hooks see each bridged call under its real name, also a name without a tool.
    assert_eq!(
        hooks.tools(),
        ["before read {}", "after c1", "before nope {}", "after c2"]
    );
}

#[test]
fn on_the_native_path_deferred_tools_carry_defer_loading_and_a_search_loads_its_matches() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "tool_search", r#"{"query": "issue"}"#)]),
        text_reply("done"),
    ]);
    let model = model_of(native_target());
    let mut toolset = Toolset::new();
    toolset.add(create_issue_definition(), Recorder::default()).unwrap();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    let results = results_in_context(driver);

    let requests = transport.requests();
    assert!(
        requests[0].contains(r#"{"name":"create_issue","description":"Create an issue.","defer_loading":true"#),
        "{}",
        requests[0]
    );
    assert!(!requests[0].contains("tool_call"), "{}", requests[0]);
    assert!(
        requests[1].contains(r#"{"type":"tool_reference","tool_name":"create_issue"}"#),
        "{}",
        requests[1]
    );
    assert_eq!(
        results,
        [ToolResult::success(
            "c1",
            "Loaded 1 tools. Call each one by its name:\n- create_issue: Create an issue."
        )
        .with_loaded(vec![create_issue_definition()])]
    );
}

#[test]
fn a_search_uses_its_round_target_mode_after_a_hook_changes_the_target() {
    for native_first in [true, false] {
        let transport = ScriptedTransport::new([
            tool_reply(&[("c1", "tool_search", r#"{"query":"issue"}"#)]),
            tool_reply(&[("c2", "tool_search", r#"{"query":"issue"}"#)]),
            text_reply("done"),
        ]);
        let (first, default) = if native_first {
            (native_target(), target())
        } else {
            (target(), native_target())
        };
        // The plan sends the first round to `first`. The two later rounds go to the driver's model.
        let hooks = Script::default().plans([
            RoundPlan {
                model: Some(model_of(first)),
                ..RoundPlan::default()
            },
            RoundPlan::default(),
            RoundPlan::default(),
        ]);
        let mut toolset = Toolset::new();
        toolset.add(create_issue_definition(), Recorder::default()).unwrap();
        let default = model_of(default);
        let driver = Driver::new(&transport, &default, &NoWait)
            .toolset(&toolset)
            .hooks(&hooks);

        let results = results_in_context(driver);

        let native_text = "Loaded 1 tools. Call each one by its name:\n- create_issue: Create an issue.";
        let bridge_text = "Found 1 tools. Call one with tool_call.\n\n## create_issue\nCreate an issue.\nInput schema: {\"type\":\"object\"}";
        let observed: Vec<_> = results
            .iter()
            .map(|result| {
                (
                    result.call_id.as_str(),
                    result.content.as_str(),
                    result.is_error,
                    result.loaded.iter().map(|tool| tool.name.as_str()).collect::<Vec<_>>(),
                )
            })
            .collect();
        let expected = if native_first {
            [
                ("c1", native_text, false, vec!["create_issue"]),
                ("c2", bridge_text, false, vec![]),
            ]
        } else {
            [
                ("c1", bridge_text, false, vec![]),
                ("c2", native_text, false, vec!["create_issue"]),
            ]
        };
        assert_eq!(observed, expected);

        let requests = transport.requests();
        assert_eq!(requests.len(), 3);
        for (request, native) in requests.iter().zip([native_first, !native_first, !native_first]) {
            let tools = declared_tools(request);
            assert_eq!(tools.contains(r#""defer_loading":true"#), native, "{request}");
            assert_eq!(tools.contains(r#""name":"tool_call""#), !native, "{request}");
        }
    }
}

#[test]
fn a_search_limit_outside_one_to_twenty_gets_an_error_result() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "tool_search", r#"{"query": "issue", "limit": 0}"#)]),
        text_reply("done"),
    ]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(create_issue_definition(), Recorder::default()).unwrap();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    assert_eq!(
        results_in_context(driver),
        [ToolResult::error("c1", "The limit must be 1 to 20.")]
    );
}
