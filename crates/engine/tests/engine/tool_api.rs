use std::borrow::Cow;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use yuke_ai::scripted::{ScriptedTransport, text_reply, tool_reply};
use yuke_ai::{Blob, BlobStore, Block, Media, ToolResult};
use yuke_engine::NoWait;
use yuke_engine::{Driver, Tool, ToolContent, ToolContext, ToolNameError, Toolset, TurnEvent, parse_arguments};
use yuke_testing::{definition, model};

use crate::support::{Fixed, Recorder, Script, block_on, results_in_context, tool_results};

#[test]
fn toolset_add_refuses_invalid_reserved_and_duplicate_names_and_keeps_the_toolset() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", "{}")]), text_reply("done")]);
    let model = model();
    let first = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), first.clone()).unwrap();
    for name in ["Notes_search-2", &"a".repeat(64)] {
        assert_eq!(toolset.add(definition(name), Recorder::default()), Ok(()), "{name}");
    }

    let long = "a".repeat(65);
    let invalid = ["", "notes.search", "a b", "é", &long].map(|name| (name, ToolNameError::Invalid(name.to_owned())));
    let refused = [
        ("echo", ToolNameError::Duplicate("echo".to_owned())),
        ("tool_search", ToolNameError::Reserved("tool_search".to_owned())),
        ("tool_call", ToolNameError::Reserved("tool_call".to_owned())),
    ];
    for (name, error) in invalid.into_iter().chain(refused) {
        assert_eq!(toolset.add(definition(name), Recorder::default()), Err(error), "{name}");
    }

    // A refused name leaves the toolset unchanged, so the first `echo` answers the call.
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);
    block_on(driver.turn(&mut Vec::new(), vec![Block::user_text("go")]).run()).unwrap();
    assert_eq!(first.calls(), ["{}"]);
    assert_eq!(transport.requests()[0].matches(r#""name":"echo""#).count(), 1);
}

#[test]
fn arguments_that_are_not_valid_json_reach_no_hook_and_no_tool() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "echo", r#"{"text": "#)]), text_reply("done")]);
    let model = model();
    let echo = Recorder::default();
    let mut toolset = Toolset::new();
    toolset.add(definition("echo"), echo.clone()).unwrap();
    let hooks = Script::default();
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
    assert_eq!(hooks.tools(), Vec::<String>::new());
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

/// The image of [`image_content`].
fn image() -> Media {
    Media::new(
        Blob {
            digest: [7; 32],
            len: 2,
        },
        "image/png",
    )
}

/// The content of a tool that answers `text` and an image, for example a screenshot of a failed render.
fn image_content(text: &str, is_error: bool) -> ToolContent {
    ToolContent {
        text: text.to_owned(),
        media: vec![image()],
        is_error,
    }
}

#[test]
fn an_error_result_of_a_tool_keeps_its_media() {
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "render", "{}")]), text_reply("done")]);
    let model = model();
    let mut toolset = Toolset::new();
    toolset
        .add(
            definition("render"),
            Fixed(Ok(image_content("the render failed", true))),
        )
        .unwrap();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    let mut context = Vec::new();
    let turn = driver.turn(&mut context, vec![Block::user_text("go")]).blobs(&TwoBytes);
    block_on(turn.run()).unwrap();
    let results = tool_results(&context);

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
    toolset
        .add(definition("read"), Fixed(Ok(image_content("a picture", false))))
        .unwrap();
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    let mut context = Vec::new();
    let turn = driver.turn(&mut context, vec![Block::user_text("go")]).blobs(&TwoBytes);
    block_on(turn.run()).unwrap();
    let results = tool_results(&context);

    assert_eq!(
        results,
        [ToolResult::success("c1", "a picture").with_media(vec![image()])]
    );
    // The bytes `ab` encode to `YWI=` in base64.
    let requests = transport.requests();
    assert!(requests[1].contains("YWI="), "{}", requests[1]);
}
