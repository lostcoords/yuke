use std::sync::Mutex;

use async_trait::async_trait;
use yuke_ai::{Block, Target, ToolCall, ToolDefinition, ToolResult};
use yuke_engine::{Bm25, Driver, Hooks, ToolNameError, ToolSearch, Toolset, TurnEvent};

use crate::support::{NoWait, Recorder, ScriptedTransport, block_on, definition, target, text_reply, tool_reply};

/// A deferred tool of `name` with `description` and any object as arguments.
fn deferred(name: &str, description: &str) -> ToolDefinition {
    ToolDefinition::new(name, description, r#"{"type":"object"}"#).deferred()
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

/// Run one turn, and return the tool results of the history.
fn results_in_history(driver: Driver<'_>) -> Vec<ToolResult> {
    let mut history = Vec::new();
    block_on(driver.turn(&mut history, vec![Block::user_text("go")]).run()).unwrap();
    history
        .iter()
        .filter_map(|block| match block {
            Block::ToolResult(result) => Some(result.clone()),
            _ => None,
        })
        .collect()
}

#[test]
fn toolset_add_refuses_the_reserved_names() {
    let mut toolset = Toolset::new();

    for name in ["tool_search", "tool_call"] {
        assert_eq!(
            toolset.add(definition(name), Recorder::default()),
            Err(ToolNameError::Reserved(name.to_owned()))
        );
    }
}

#[test]
fn a_toolset_without_deferred_tools_declares_no_search_tool() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let target = native_target();
    let mut toolset = Toolset::new();
    toolset.add(definition("read"), Recorder::default()).unwrap();
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);

    results_in_history(driver);

    let body = &transport.requests()[0];
    assert!(!body.contains("tool_search"), "{body}");
}

#[test]
fn on_the_bridge_path_the_declared_tools_stay_the_same_after_a_search() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "tool_search", r#"{"query": "create issue"}"#)]),
        text_reply("done"),
    ]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset.add(definition("read"), Recorder::default()).unwrap();
    toolset
        .add(deferred("create_issue", "Create an issue."), Recorder::default())
        .unwrap();
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);

    let results = results_in_history(driver);

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
    ToolDefinition::new(name, "Alpha tool.", schema).deferred()
}

#[test]
fn a_bridge_search_shows_the_schema_of_each_match_in_name_order() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "tool_search", r#"{"query": "alpha"}"#)]),
        text_reply("done"),
    ]);
    let target = target();
    let mut toolset = Toolset::new();
    // Large schemas show in full. Equal scores sort by name.
    for name in ["alpha_two", "alpha_one", "alpha_three"] {
        toolset.add(large(name, 7000), Recorder::default()).unwrap();
    }
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);

    let results = results_in_history(driver);

    let sections: Vec<&str> = results[0].content.split("\n\n").collect();
    assert_eq!(sections.len(), 4, "{}", results[0].content);
    for (section, name) in sections[1..].iter().zip(["alpha_one", "alpha_three", "alpha_two"]) {
        let schema = large(name, 7000).input_schema;
        assert_eq!(*section, format!("## {name}\nAlpha tool.\nInput schema: {schema}"));
    }
}

/// Hooks that keep the name and the arguments of each call that `before_tool` sees.
#[derive(Default)]
struct SeeCalls {
    calls: Mutex<Vec<(String, String)>>,
}

#[async_trait]
impl Hooks for SeeCalls {
    async fn before_tool(&self, call: &ToolCall) -> yuke_engine::ToolDecision {
        self.calls
            .lock()
            .unwrap()
            .push((call.name.clone(), call.arguments.clone()));
        yuke_engine::ToolDecision::Run
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
    let target = target();
    let issue = Recorder::default();
    let mut toolset = Toolset::new();
    toolset
        .add(deferred("create_issue", "Create an issue."), issue.clone())
        .unwrap();
    let hooks = SeeCalls::default();
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&hooks);
    let started = Mutex::new(Vec::new());
    let mut history = Vec::new();

    block_on(
        driver
            .turn(&mut history, vec![Block::user_text("go")])
            .observer(&|event: &TurnEvent<'_>| {
                if let TurnEvent::ToolStarted(call) = event {
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
        *hooks.calls.lock().unwrap(),
        [("create_issue".to_owned(), arguments.to_owned())]
    );
    assert_eq!(*started.lock().unwrap(), ["c1 create_issue"]);
    // The history keeps the call that the model wrote, and the result answers it.
    let history = history;
    assert!(matches!(&history[1], Block::ToolCall(call) if call.name == "tool_call"));
    assert_eq!(history[2], Block::ToolResult(ToolResult::success("c1", "result 1")));
}

#[test]
fn tool_call_refuses_an_eager_tool_and_an_unknown_name_and_runs_nothing() {
    let transport = ScriptedTransport::new([
        tool_reply(&[
            ("c1", "tool_call", r#"{"name": "read", "arguments": {}}"#),
            ("c2", "tool_call", r#"{"name": "nope", "arguments": {}}"#),
        ]),
        text_reply("done"),
    ]);
    let target = target();
    let read = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("read"), read.clone()).unwrap();
    toolset
        .add(deferred("create_issue", "Create an issue."), Recorder::default())
        .unwrap();
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);

    let results = results_in_history(driver);

    assert_eq!(
        results,
        [
            ToolResult::error("c1", "\"read\" is not a deferred tool. Call it directly."),
            ToolResult::error(
                "c2",
                "No deferred tool has the name \"nope\". Find one with tool_search."
            ),
        ]
    );
    assert_eq!(read.calls(), Vec::<String>::new());
}

#[test]
fn on_the_native_path_deferred_tools_carry_defer_loading_and_a_search_loads_its_matches() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "tool_search", r#"{"query": "issue"}"#)]),
        text_reply("done"),
    ]);
    let target = native_target();
    let mut toolset = Toolset::new();
    toolset
        .add(deferred("create_issue", "Create an issue."), Recorder::default())
        .unwrap();
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);

    let results = results_in_history(driver);

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
        .with_loaded(vec![deferred("create_issue", "Create an issue.")])]
    );
}

#[test]
fn a_search_limit_outside_one_to_twenty_gets_an_error_result() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "tool_search", r#"{"query": "issue", "limit": 0}"#)]),
        text_reply("done"),
    ]);
    let target = target();
    let mut toolset = Toolset::new();
    toolset
        .add(deferred("create_issue", "Create an issue."), Recorder::default())
        .unwrap();
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);

    assert_eq!(
        results_in_history(driver),
        [ToolResult::error("c1", "The limit must be 1 to 20.")]
    );
}

#[test]
fn bm25_ranks_word_matches_and_drops_tools_without_one() {
    let tools = [
        ToolDefinition::new("read_file", "Read a file.", "{}"),
        ToolDefinition::new("list_issues", "List the issues of a repository.", "{}"),
        ToolDefinition::new("createIssue", "Create a GitHub issue.", "{}"),
        ToolDefinition::new(
            "comment",
            "Add a comment.",
            r#"{"anyOf":[{"type":"object","properties":{"issue_number":{"type":"integer"}}}]}"#,
        ),
    ];
    let borrowed: Vec<&ToolDefinition> = tools.iter().collect();

    let found = block_on(Bm25.search("github issue", &borrowed, 5));

    // camelCase splits `createIssue`, and a property under `anyOf` gives `comment` the word `issue`.
    let names: Vec<&str> = found.iter().map(|&index| tools[index].name.as_str()).collect();
    assert_eq!(names, ["createIssue", "list_issues", "comment"]);
}
