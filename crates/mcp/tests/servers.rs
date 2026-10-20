//! These tests run the MCP test server of this crate: its start, its tools in a turn, a cancel, and the entries that
//! do not start.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use yuke_ai::{Blob, Block, Target};
use yuke_engine::{CancellationToken, Driver, MediaStore, Toolset};
use yuke_mcp::{ServerConfig, ServerState, Servers};
use yuke_testing::{NoWait, ScriptedTransport, model_of, target, text_reply, tool_reply};

/// The base64 PNG of one pixel, as the `picture` tool of the test server sends it.
const PIXEL: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

/// Keeps the bytes of each stored attachment.
#[derive(Default)]
struct Recorded(Mutex<Vec<Vec<u8>>>);

impl yuke_ai::BlobStore for Recorded {
    fn read(
        &self,
        _digest: &yuke_ai::Digest,
    ) -> Result<Option<std::borrow::Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>> {
        Ok(self.0.lock().unwrap().last().cloned().map(std::borrow::Cow::Owned))
    }
}

#[async_trait]
impl MediaStore for Recorded {
    async fn put_media(&self, bytes: Vec<u8>) -> Result<Blob, String> {
        let blob = Blob {
            digest: [7; 32],
            len: bytes.len(),
        };
        self.0.lock().unwrap().push(bytes);
        Ok(blob)
    }
}

/// The entry of the test server, with `env` beside the environment of the tests.
fn test_server(env: &[(&str, &str)]) -> ServerConfig {
    ServerConfig {
        command: Some(env!("CARGO_BIN_EXE_yuke-mcp-test-server").to_owned()),
        args: Vec::new(),
        env: env
            .iter()
            .map(|(name, value)| ((*name).to_owned(), (*value).to_owned()))
            .collect(),
        cwd: None,
        url: None,
        enabled: true,
    }
}

/// A new empty folder for the test `name`.
fn folder(name: &str) -> PathBuf {
    yuke_testing::folder("mcp", name)
}

/// The servers of `entries`, after each start ended.
async fn started(entries: Vec<(String, ServerConfig)>, folder: &Path, media: Arc<Recorded>) -> Servers {
    let variable = |name: &str| (name == "SET").then(|| "set".to_owned());
    let servers = Servers::start(entries, &variable, folder, media);
    tokio::time::timeout(Duration::from_secs(10), servers.ready())
        .await
        .unwrap();
    servers
}

/// The test target with a native tool search, so the model calls a deferred tool by its name.
fn native_target() -> Target {
    Target {
        tool_search: true,
        ..target()
    }
}

fn toolset(servers: &Servers) -> Toolset {
    let mut toolset = Toolset::new();
    for (definition, tool) in servers.tools() {
        toolset.add(definition, tool).unwrap();
    }
    toolset
}

#[tokio::test]
async fn a_server_starts_and_gives_its_tools_deferred_with_their_names_and_schemas() {
    let folder = folder("a_server_starts");
    let log = folder.join("log");
    let entry = test_server(&[("MCP_TEST_LOG", log.to_str().unwrap())]);
    let servers = started(vec![("test".to_owned(), entry)], &folder, Arc::default()).await;

    let tools = servers.tools();

    assert_eq!(
        servers.states(),
        [("test".to_owned(), ServerState::Connected { tools: 7 })]
    );
    // The newest version with `initialize`, which each server of this era speaks.
    assert_eq!(std::fs::read_to_string(&log).unwrap(), "initialize \"2025-11-25\"\n");
    let names: Vec<_> = tools.iter().map(|(definition, _)| definition.name.as_str()).collect();
    assert_eq!(
        names,
        [
            "mcp__test__echo",
            "mcp__test__picture",
            "mcp__test__huge",
            "mcp__test__fail",
            "mcp__test__structured",
            "mcp__test__wait",
            "mcp__test__exit"
        ]
    );
    let (echo, _) = &tools[0];
    assert!(echo.defer_loading);
    assert_eq!(echo.description, "Echo the text.");
    assert_eq!(
        echo.input_schema,
        r#"{"properties":{"text":{"type":"string"}},"type":"object"}"#
    );
    servers.close().await;
}

#[tokio::test]
async fn the_model_reads_the_text_the_image_the_error_and_the_structure_of_the_results() {
    let folder = folder("the_model_reads_the_results");
    let media = Arc::new(Recorded::default());
    let servers = started(vec![("test".to_owned(), test_server(&[]))], &folder, Arc::clone(&media)).await;
    let toolset = toolset(&servers);
    let transport = ScriptedTransport::new([
        tool_reply(&[
            ("c1", "mcp__test__echo", r#"{"text":"hello"}"#),
            ("c2", "mcp__test__picture", "{}"),
            ("c5", "mcp__test__huge", "{}"),
            ("c3", "mcp__test__fail", "{}"),
            ("c4", "mcp__test__structured", "{}"),
        ]),
        text_reply("done"),
    ]);
    let model = model_of(native_target());
    let driver = Driver::new(&transport, &model, &NoWait)
        .toolset(&toolset)
        .blobs(&*media);

    driver
        .turn(&mut Vec::new(), vec![Block::user_text("go")])
        .run()
        .await
        .unwrap();

    let request = &transport.requests()[1];
    let lost = "[an image of type image/png was lost: it is larger than the limit of 3932160 bytes]";
    for text in ["hello", "a picture", lost, "it broke", r#"{\"answer\":42}"#] {
        assert!(request.contains(text), "{text}: {request}");
    }
    assert_eq!(
        *media.0.lock().unwrap(),
        [yuke_ai::decode_base64(PIXEL.as_bytes()).unwrap()]
    );
    servers.close().await;
}

#[tokio::test]
async fn a_cancel_of_a_call_sends_the_cancel_to_the_server() {
    let folder = folder("a_cancel_of_a_call");
    let log = folder.join("log");
    let entry = test_server(&[("MCP_TEST_LOG", log.to_str().unwrap())]);
    let servers = started(vec![("test".to_owned(), entry)], &folder, Arc::default()).await;
    let toolset = toolset(&servers);
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "mcp__test__wait", "{}")]), text_reply("done")]);
    let model = model_of(native_target());
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);
    let token = CancellationToken::new();
    let cancel = token.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(200)).await;
        cancel.cancel();
    });

    let mut context = Vec::new();
    driver
        .turn(&mut context, vec![Block::user_text("go")])
        .cancellation_token(token)
        .run()
        .await
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    while !std::fs::read_to_string(&log).unwrap().contains("cancelled") {
        assert!(Instant::now() < deadline, "the server got no cancel");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let lines = std::fs::read_to_string(&log).unwrap();
    assert!(lines.lines().any(|line| line.starts_with("cancelled ")), "{lines}");
    let results: Vec<_> = context
        .iter()
        .filter_map(|block| match block {
            Block::ToolResult(result) => Some(result.content.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(results, ["The user cancelled the call."]);
    servers.close().await;
}

#[tokio::test]
async fn two_servers_with_one_valid_name_both_keep_their_tools() {
    let folder = folder("two_servers_with_one_valid_name");
    let entries = vec![
        ("a b".to_owned(), test_server(&[])),
        ("a_b".to_owned(), test_server(&[])),
    ];
    let servers = started(entries, &folder, Arc::default()).await;

    let tools = servers.tools();

    let names: Vec<_> = tools.iter().map(|(definition, _)| definition.name.clone()).collect();
    assert_eq!(names.len(), 14);
    assert_eq!(names[0], "mcp__a_b__echo");
    assert!(
        names[7].starts_with("mcp__a_b__echo_") && names[7].len() == 23,
        "{names:?}"
    );
    servers.close().await;
}

#[tokio::test]
async fn a_server_that_exits_fails_and_loses_its_tools() {
    let folder = folder("a_server_that_exits");
    let servers = started(vec![("test".to_owned(), test_server(&[]))], &folder, Arc::default()).await;
    let toolset = toolset(&servers);
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "mcp__test__exit", "{}")]), text_reply("done")]);
    let model = model_of(native_target());
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    driver
        .turn(&mut Vec::new(), vec![Block::user_text("go")])
        .run()
        .await
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    while servers.states()[0].1
        != (ServerState::Failed {
            error: "the server stopped".to_owned(),
        })
    {
        assert!(Instant::now() < deadline, "{:?}", servers.states());
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(servers.tools().is_empty());
    assert!(
        transport.requests()[1].contains("The server closed before its answer."),
        "{}",
        transport.requests()[1]
    );
    servers.close().await;
}

#[tokio::test]
async fn an_entry_that_cannot_start_fails_and_a_disabled_one_stays_off() {
    let folder = folder("an_entry_that_cannot_start");
    let missing = ServerConfig {
        command: Some("/no/such/program".to_owned()),
        ..test_server(&[])
    };
    let http = ServerConfig {
        command: None,
        url: Some("https://example.test/mcp".to_owned()),
        ..test_server(&[])
    };
    let unset = ServerConfig {
        args: vec!["${UNSET}".to_owned()],
        ..test_server(&[])
    };
    let disabled = ServerConfig {
        enabled: false,
        ..test_server(&[])
    };
    let entries = [
        ("missing", missing),
        ("http", http),
        ("unset", unset),
        ("disabled", disabled),
    ];

    let servers = started(
        entries
            .into_iter()
            .map(|(name, entry)| (name.to_owned(), entry))
            .collect(),
        &folder,
        Arc::default(),
    )
    .await;

    let states = servers.states();
    let ServerState::Failed { error } = &states[0].1 else {
        panic!("{states:?}");
    };
    assert!(error.starts_with("the server did not start: "), "{error}");
    assert_eq!(
        states[1..],
        [
            (
                "http".to_owned(),
                ServerState::Failed {
                    error: "yuke cannot reach an HTTP server yet".to_owned()
                }
            ),
            (
                "unset".to_owned(),
                ServerState::Failed {
                    error: "the variable UNSET has no value and no default".to_owned()
                }
            ),
            ("disabled".to_owned(), ServerState::Disabled),
        ]
    );
    assert!(servers.tools().is_empty());
    servers.close().await;
}
