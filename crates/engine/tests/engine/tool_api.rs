use std::borrow::Cow;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use yuke_ai::{Blob, BlobStore, Block, Media, ToolCall, ToolResult};
use yuke_engine::{Driver, Hooks, Tool, ToolContent, ToolContext, ToolDecision, Toolset, TurnEvent, parse_arguments};
use yuke_testing::{NoWait, ScriptedTransport, model, text_reply, tool_reply};

use crate::support::{Recorder, block_on, definition, results_in_context};

/// Hooks that count the calls of `before_tool`.
#[derive(Default)]
struct CountBeforeTool {
    calls: AtomicUsize,
}

#[async_trait]
impl Hooks for CountBeforeTool {
    async fn before_tool(&self, _: &ToolCall) -> ToolDecision {
        self.calls.fetch_add(1, Ordering::Relaxed);
        ToolDecision::Run
    }
}

#[test]
fn arguments_that_are_not_valid_json_reach_no_hook_and_no_tool() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", r#"{"text": "#)]), text_reply("done")]);
    let model = model();
    let echo = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), echo.clone()).unwrap();
    let hooks = CountBeforeTool::default();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset).hooks(&hooks);

    let results = results_in_context(driver);

    assert_eq!(results.len(), 1);
    assert!(results[0].is_error);
    assert!(
        results[0]
            .content
            .starts_with(r#"Tool call "echo" was not executed: its arguments are not valid JSON: "#),
        "{}",
        results[0].content
    );
    assert_eq!(hooks.calls.load(Ordering::Relaxed), 0);
    assert_eq!(echo.calls(), Vec::<String>::new());
}

/// A tool that parses its arguments, answers their text, and counts its runs. Its clones share the count.
#[derive(Default, Clone)]
struct Echo {
    runs: Arc<AtomicUsize>,
}

/// The arguments of [`Echo`].
#[derive(serde::Deserialize)]
struct EchoArguments {
    text: String,
}

#[async_trait]
impl Tool for Echo {
    async fn call(&self, arguments: &str, _: &ToolContext<'_>) -> Result<ToolContent, String> {
        let arguments: EchoArguments = parse_arguments(arguments)?;
        self.runs.fetch_add(1, Ordering::Relaxed);
        Ok(format!("echo {}", arguments.text).into())
    }
}

#[test]
fn a_tool_receives_its_parsed_arguments() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", r#"{"text": "hi"}"#)]), text_reply("done")]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), Echo::default()).unwrap();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    assert_eq!(results_in_context(driver), [ToolResult::success("c1", "echo hi")]);
}

#[test]
fn a_parse_error_reaches_the_model_and_the_tool_body_does_not_run() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", r#"{"txt": "hi"}"#)]), text_reply("done")]);
    let model = model();
    let echo = Echo::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), echo.clone()).unwrap();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    let results = results_in_context(driver);

    assert!(results[0].is_error);
    assert!(
        results[0]
            .content
            .starts_with("The arguments are not valid: missing field `text`"),
        "{}",
        results[0].content
    );
    assert_eq!(echo.runs.load(Ordering::Relaxed), 0);
}

/// A tool that shows two lines of live output, and answers the call id that it saw.
struct Prints;

#[async_trait]
impl Tool for Prints {
    async fn call(&self, _: &str, context: &ToolContext<'_>) -> Result<ToolContent, String> {
        context.output("line 1\n");
        context.output("line 2\n");
        Ok(format!("printed for {}", context.call_id()).into())
    }
}

#[test]
fn tool_output_reaches_the_observer_between_the_start_and_the_end_of_its_call() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "print", "{}")]), text_reply("done")]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("print"), Prints).unwrap();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);
    let seen = Mutex::new(Vec::new());

    block_on(
        driver
            .turn(&mut Vec::new(), vec![Block::user_text("go")])
            .observer(&|event: &TurnEvent<'_>| match event {
                TurnEvent::ToolStarted { call, .. } => seen.lock().unwrap().push(format!("started {}", call.call_id)),
                TurnEvent::ToolOutput { block_index, text } => {
                    seen.lock().unwrap().push(format!("output {block_index} {text}"));
                }
                TurnEvent::ToolFinished { result, .. } => {
                    seen.lock().unwrap().push(format!("finished {}", result.content));
                }
                _ => {}
            })
            .run(),
    )
    .unwrap();

    assert_eq!(
        *seen.lock().unwrap(),
        [
            "started c1",
            "output 0 line 1\n",
            "output 0 line 2\n",
            "finished printed for c1"
        ]
    );
}

/// A blob store that holds the two bytes `ab` under each digest.
struct TwoBytes;

impl BlobStore for TwoBytes {
    fn read(&self, _: &yuke_ai::Digest) -> Result<Option<Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>> {
        Ok(Some(Cow::Borrowed(b"ab")))
    }
}

/// The image that [`ReadsImage`] answers.
fn image() -> Media {
    Media::new(
        Blob {
            digest: [7; 32],
            len: 2,
        },
        "image/png",
    )
}

/// A tool that answers an image beside its text.
struct ReadsImage;

#[async_trait]
impl Tool for ReadsImage {
    async fn call(&self, _: &str, _: &ToolContext<'_>) -> Result<ToolContent, String> {
        Ok(ToolContent {
            text: "a picture".to_owned(),
            media: vec![image()],
            is_error: false,
        })
    }
}

/// A tool that fails with an image beside its text, for example a screenshot of a failed render.
struct FailsWithImage;

#[async_trait]
impl Tool for FailsWithImage {
    async fn call(&self, _: &str, _: &ToolContext<'_>) -> Result<ToolContent, String> {
        Ok(ToolContent {
            text: "the render failed".to_owned(),
            media: vec![image()],
            is_error: true,
        })
    }
}

#[test]
fn an_error_result_of_a_tool_keeps_its_media() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "render", "{}")]), text_reply("done")]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("render"), FailsWithImage).unwrap();
    let driver = Driver::new(&transport, &model, &NoWait)
        .toolset(&toolset)
        .blobs(&TwoBytes);

    let results = results_in_context(driver);

    assert_eq!(
        results,
        [ToolResult::error("c1", "the render failed").with_media(vec![image()])]
    );
}

#[test]
fn tool_media_reaches_the_result_and_the_next_request() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "read", "{}")]), text_reply("done")]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset.add(definition("read"), ReadsImage).unwrap();
    let driver = Driver::new(&transport, &model, &NoWait)
        .toolset(&toolset)
        .blobs(&TwoBytes);

    let results = results_in_context(driver);

    assert_eq!(
        results,
        [ToolResult::success("c1", "a picture").with_media(vec![image()])]
    );
    // The bytes `ab` encode to `YWI=` in base64.
    let requests = transport.requests();
    assert!(requests[1].contains("YWI="), "{}", requests[1]);
}
