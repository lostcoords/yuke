use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use yuke_ai::{Block, ToolCall, ToolResult};
use yuke_engine::{
    CancellationToken, Concurrency, Driver, Hooks, Outcome, Tool, ToolContent, ToolContext, ToolDecision, Toolset,
    TurnEvent, parse_arguments,
};

use crate::support::{
    NoWait, ScriptedTransport, assert_in_order, block_on, definition, target, text_reply, tool_reply, yield_once,
};

/// What the calls of a turn did, in order, and the most calls that ran at once.
#[derive(Default)]
struct Log {
    entries: Mutex<Vec<String>>,
    running: AtomicUsize,
    most: AtomicUsize,
}

impl Log {
    fn push(&self, entry: String) {
        self.entries.lock().unwrap().push(entry);
    }

    fn entries(&self) -> Vec<String> {
        self.entries.lock().unwrap().clone()
    }
}

/// The arguments of a [`Track`] call.
#[derive(serde::Deserialize)]
struct TrackArguments {
    /// The number of waits before the call returns.
    waits: usize,
    /// Whether the call cancels the turn after its first wait, when each call of its group runs.
    #[serde(default)]
    cancel: bool,
}

/// A tool that logs the start and the end of each call. It shows one line of output after its first wait. A call that
/// sees a cancel answers "stopped", else "result".
struct Track {
    concurrency: Concurrency,
    log: Arc<Log>,
}

#[async_trait]
impl Tool for Track {
    fn concurrency(&self) -> Concurrency {
        self.concurrency
    }

    async fn call(&self, arguments: &str, context: &ToolContext<'_>) -> Result<ToolContent, String> {
        let arguments: TrackArguments = parse_arguments(arguments)?;
        let call_id = context.call_id();
        self.log.push(format!("start {call_id}"));
        let running = self.log.running.fetch_add(1, Ordering::SeqCst) + 1;
        self.log.most.fetch_max(running, Ordering::SeqCst);
        for wait in 0..arguments.waits {
            yield_once().await;
            if wait == 0 {
                context.output(&format!("output of {call_id}"));
                if arguments.cancel {
                    context.cancellation_token().cancel();
                }
            }
        }
        self.log.running.fetch_sub(1, Ordering::SeqCst);
        self.log.push(format!("finish {call_id}"));
        let answer = if context.cancellation_token().is_cancelled() {
            "stopped"
        } else {
            "result"
        };
        Ok(format!("{answer} {call_id}").into())
    }
}

/// A toolset with the parallel tools `read` and `grep` and the serial tool `edit`, which share `log`.
fn toolset(log: &Arc<Log>) -> Toolset {
    let mut toolset = Toolset::new();
    for (name, concurrency) in [
        ("read", Concurrency::Parallel),
        ("grep", Concurrency::Parallel),
        ("edit", Concurrency::Serial),
    ] {
        let tool = Track {
            concurrency,
            log: Arc::clone(log),
        };
        toolset.add(definition(name), tool).unwrap();
    }
    toolset
}

/// Hooks that log each `before_tool`. The call of `cancel_at` cancels the turn in its hook.
struct LogHooks {
    log: Arc<Log>,
    cancel_at: Option<(&'static str, CancellationToken)>,
}

#[async_trait]
impl Hooks for LogHooks {
    async fn before_tool(&self, call: &ToolCall) -> ToolDecision {
        self.log.push(format!("before {}", call.call_id));
        if let Some((call_id, cancellation_token)) = &self.cancel_at
            && call.call_id == *call_id
        {
            cancellation_token.cancel();
        }
        ToolDecision::Run
    }
}

/// The tool results in `history`, as call id and text.
fn results(history: &[Block]) -> Vec<(String, String)> {
    history
        .iter()
        .filter_map(|block| match block {
            Block::ToolResult(ToolResult { call_id, content, .. }) => Some((call_id.clone(), content.clone())),
            _ => None,
        })
        .collect()
}

#[test]
fn two_parallel_calls_run_together_and_each_output_names_its_call() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "read", r#"{"waits": 2}"#), ("c2", "read", r#"{"waits": 2}"#)]),
        text_reply("done"),
    ]);
    let target = target();
    let log = Arc::new(Log::default());
    let toolset = toolset(&log);
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);
    let outputs = Mutex::new(Vec::new());

    block_on(
        driver
            .turn(&mut Vec::new(), vec![Block::user_text("go")])
            .observer(&|event: &TurnEvent<'_>| {
                if let TurnEvent::ToolOutput { call_id, text } = event {
                    outputs.lock().unwrap().push(format!("{call_id}: {text}"));
                }
            })
            .run(),
    )
    .unwrap();

    assert_eq!(log.most.load(Ordering::SeqCst), 2);
    assert_eq!(*outputs.lock().unwrap(), ["c1: output of c1", "c2: output of c2"]);
}

#[test]
fn a_serial_call_waits_for_the_group_before_it_and_runs_alone() {
    let call = |id, name| (id, name, r#"{"waits": 1}"#);
    let transport = ScriptedTransport::new([
        tool_reply(&[
            call("c1", "read"),
            call("c2", "grep"),
            call("c3", "edit"),
            call("c4", "read"),
            call("c5", "read"),
        ]),
        text_reply("done"),
    ]);
    let target = target();
    let log = Arc::new(Log::default());
    let toolset = toolset(&log);
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);

    block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run()).unwrap();

    assert_eq!(
        log.entries(),
        [
            "start c1",
            "start c2",
            "finish c1",
            "finish c2",
            "start c3",
            "finish c3",
            "start c4",
            "start c5",
            "finish c4",
            "finish c5",
        ]
    );
}

#[test]
fn results_go_back_in_call_order_when_the_finish_order_differs() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "read", r#"{"waits": 3}"#), ("c2", "read", r#"{"waits": 0}"#)]),
        text_reply("done"),
    ]);
    let target = target();
    let log = Arc::new(Log::default());
    let toolset = toolset(&log);
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);
    let finished = Mutex::new(Vec::new());
    let mut history = Vec::new();

    block_on(
        driver
            .turn(&mut history, vec![Block::user_text("go")])
            .observer(&|event: &TurnEvent<'_>| {
                if let TurnEvent::ToolFinished(result) = event {
                    finished.lock().unwrap().push(result.call_id.clone());
                }
            })
            .run(),
    )
    .unwrap();

    assert_eq!(*finished.lock().unwrap(), ["c2", "c1"]);
    assert_in_order(&transport.requests()[1], &["result c1", "result c2"]);
    assert_eq!(
        results(&history),
        [
            ("c1".to_owned(), "result c1".to_owned()),
            ("c2".to_owned(), "result c2".to_owned())
        ]
    );
}

#[test]
fn every_before_tool_of_a_group_runs_before_any_call_of_the_group_starts() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "read", r#"{"waits": 1}"#), ("c2", "grep", r#"{"waits": 1}"#)]),
        text_reply("done"),
    ]);
    let target = target();
    let log = Arc::new(Log::default());
    let toolset = toolset(&log);
    let hooks = LogHooks {
        log: Arc::clone(&log),
        cancel_at: None,
    };
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&hooks);

    block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run()).unwrap();

    assert_eq!(
        log.entries(),
        [
            "before c1",
            "before c2",
            "start c1",
            "start c2",
            "finish c1",
            "finish c2"
        ]
    );
}

#[test]
fn cancel_during_a_group_keeps_the_results_of_the_running_calls_and_runs_no_later_group() {
    let transport = ScriptedTransport::new([tool_reply(&[
        ("c1", "read", r#"{"waits": 1, "cancel": true}"#),
        ("c2", "read", r#"{"waits": 2}"#),
        ("c3", "edit", r#"{"waits": 1}"#),
    ])]);
    let target = target();
    let log = Arc::new(Log::default());
    let toolset = toolset(&log);
    let cancellation_token = CancellationToken::new();
    let driver = Driver::new(&transport, &target, &NoWait).toolset(&toolset);
    let mut history = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut history, vec![Block::user_text("go")])
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert!(!log.entries().contains(&"start c3".to_owned()), "{:?}", log.entries());
    assert_eq!(
        results(&history),
        [
            ("c1".to_owned(), "stopped c1".to_owned()),
            ("c2".to_owned(), "stopped c2".to_owned()),
            (
                "c3".to_owned(),
                "Tool call \"edit\" was not executed: the user cancelled the turn.".to_owned()
            ),
        ]
    );
}

#[test]
fn cancel_during_the_hooks_of_a_group_starts_no_call_of_the_group() {
    let transport = ScriptedTransport::new([tool_reply(&[
        ("c1", "read", r#"{"waits": 1}"#),
        ("c2", "read", r#"{"waits": 1}"#),
    ])]);
    let target = target();
    let log = Arc::new(Log::default());
    let toolset = toolset(&log);
    let cancellation_token = CancellationToken::new();
    let hooks = LogHooks {
        log: Arc::clone(&log),
        cancel_at: Some(("c2", cancellation_token.clone())),
    };
    let driver = Driver::new(&transport, &target, &NoWait)
        .toolset(&toolset)
        .hooks(&hooks);
    let mut history = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut history, vec![Block::user_text("go")])
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)));
    assert_eq!(log.entries(), ["before c1", "before c2"]);
    let cancelled = |name: &str| format!("Tool call \"{name}\" was not executed: the user cancelled the turn.");
    assert_eq!(
        results(&history),
        [
            ("c1".to_owned(), cancelled("read")),
            ("c2".to_owned(), cancelled("read"))
        ]
    );
}
