use std::sync::Mutex;

use async_trait::async_trait;
use yuke_ai::ToolCall;
use yuke_ai::scripted::{ScriptedTransport, cut_reply, text_reply, tool_reply};
use yuke_engine::{
    CallDisplay, CancellationToken, CommitDisplay, DisplayBlock, Driver, Hooks, NoWait, Observer, Preview,
    ResultDisplay, Subject, SubjectKind, Tool, ToolContent, ToolContext, ToolHints, ToolOutcome, Toolset, TurnEvent,
};
use yuke_testing::{definition, model};

use crate::support::{Replay, block_on};

/// The hints of the tool `show`.
fn hints() -> ToolHints {
    ToolHints {
        title: Some("Show".to_owned()),
        subject: Some(Subject {
            argument: "path".to_owned(),
            kind: SubjectKind::File,
        }),
        preview: Preview::Tail,
    }
}

fn shown(text: &str) -> DisplayBlock {
    DisplayBlock::Markdown { text: text.to_owned() }
}

/// A tool with hints that answers "ok" and shows `*shown*`. With a token, it cancels the turn before it returns.
struct Show(Option<CancellationToken>);

#[async_trait]
impl Tool for Show {
    fn hints(&self) -> ToolHints {
        hints()
    }

    async fn call(&self, _arguments: &str, _context: &ToolContext<'_>) -> Result<ToolContent, String> {
        if let Some(token) = &self.0 {
            token.cancel();
        }
        Ok(ToolContent {
            display: vec![shown("*shown*")],
            ..ToolContent::from("ok")
        })
    }
}

/// The toolset with `show`, run in `/repo`.
fn toolset(tool: Show) -> Toolset {
    let mut toolset = Toolset::new();
    toolset.add(definition("show"), tool).unwrap();
    toolset.set_folder("/repo");
    toolset
}

/// An observer that keeps the display of each finish.
#[derive(Default)]
struct Shows(Mutex<Vec<String>>);

impl Observer for Shows {
    fn event(&self, event: &TurnEvent<'_>) {
        let line = match event {
            TurnEvent::ToolFinished { result, display, .. } => format!("finish {} {display:?}", result.call_id),
            _ => return,
        };
        self.0.lock().unwrap().push(line);
    }
}

// The answer commit holds the calls, so their hints come before any call runs. A name that no tool has gets the
// default hints.
#[test]
fn the_answer_saves_the_hints_and_the_folder_of_each_call_and_the_results_save_their_display() {
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "show", r#"{"path":"a"}"#), ("c2", "missing", "{}")]),
        text_reply("done"),
    ]);
    let model = model();
    let toolset = toolset(Show(None));
    let journal = Replay::default();
    let shows = Shows::default();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    block_on(
        driver
            .turn(&mut Vec::new(), Vec::new())
            .journal(&journal)
            .observer(&shows)
            .run(),
    )
    .unwrap();

    let saved = journal.saved();
    let call = |block_index, hints| CallDisplay {
        block_index,
        hints,
        folder: Some("/repo".to_owned()),
    };
    assert_eq!(
        saved[0].display,
        CommitDisplay {
            calls: vec![call(0, hints()), call(1, ToolHints::default())],
            results: Vec::new(),
        }
    );
    assert_eq!(
        saved[1].display,
        CommitDisplay {
            calls: Vec::new(),
            results: vec![ResultDisplay {
                block_index: 0,
                blocks: vec![shown("*shown*")],
            }],
        }
    );
    assert!(saved[2..].iter().all(|commit| commit.display.is_empty()));
    assert_eq!(
        *shows.0.lock().unwrap(),
        [r#"finish c1 [Markdown { text: "*shown*" }]"#, "finish c2 []",]
    );
}

/// Hooks that replace the display of each result.
struct Replace;

#[async_trait]
impl Hooks for Replace {
    async fn after_tool(&self, _call: &ToolCall, outcome: &ToolOutcome) -> Option<ToolOutcome> {
        Some(ToolOutcome {
            result: outcome.result.clone(),
            display: vec![shown("*redacted*")],
        })
    }
}

#[test]
fn a_replacement_of_after_tool_replaces_the_display() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "show", "{}")]), text_reply("done")]);
    let model = model();
    let toolset = toolset(Show(None));
    let journal = Replay::default();
    let driver = Driver::new(&transport, &model, &NoWait)
        .toolset(&toolset)
        .hooks(&Replace);

    block_on(driver.turn(&mut Vec::new(), Vec::new()).journal(&journal).run()).unwrap();

    assert_eq!(
        journal.saved()[1].display.results,
        [ResultDisplay {
            block_index: 0,
            blocks: vec![shown("*redacted*")],
        }]
    );
}

// The cancel ends the turn after the call, so the end commit holds the result and its display.
#[test]
fn a_turn_cancelled_during_a_call_keeps_the_display_in_its_end_commit() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "show", "{}")])]);
    let model = model();
    let token = CancellationToken::new();
    let toolset = toolset(Show(Some(token.clone())));
    let journal = Replay::default();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    block_on(
        driver
            .turn(&mut Vec::new(), Vec::new())
            .journal(&journal)
            .cancellation_token(token)
            .run(),
    )
    .unwrap();

    let end = journal.saved().pop().unwrap();
    assert!(end.end.is_some());
    assert_eq!(
        end.display.results,
        [ResultDisplay {
            block_index: 0,
            blocks: vec![shown("*shown*")],
        }]
    );
}

// A call that the output limit cut never runs, but the transcript still shows it with the hints of its tool.
#[test]
fn a_call_that_never_runs_still_saves_its_hints() {
    let transport = ScriptedTransport::new([cut_reply(&[("c1", "show", "{}")]), text_reply("done")]);
    let model = model();
    let toolset = toolset(Show(None));
    let journal = Replay::default();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    block_on(driver.turn(&mut Vec::new(), Vec::new()).journal(&journal).run()).unwrap();

    let calls: Vec<_> = journal
        .saved()
        .into_iter()
        .flat_map(|commit| commit.display.calls)
        .collect();
    assert_eq!(
        calls,
        [CallDisplay {
            block_index: 0,
            hints: hints(),
            folder: Some("/repo".to_owned()),
        }]
    );
}
