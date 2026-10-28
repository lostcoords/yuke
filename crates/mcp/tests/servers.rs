//! These tests run the MCP test server of this crate: its start, its tools in a turn, a cancel, and the entries that
//! do not start.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use yuke_ai::scripted::{ScriptedTransport, text_reply, tool_reply};
use yuke_ai::{Blob, Block, Target};
use yuke_engine::NoWait;
use yuke_engine::{CancellationToken, Driver, MediaStore, Tool, Toolset};
use yuke_mcp::{ServerConfig, Servers};
use yuke_protocol::{McpServer, McpServerSource, McpServerState};
use yuke_testing::{model_of, target};

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

/// Keeps each change of a server state.
type Changes = Arc<Mutex<Vec<McpServer>>>;

/// The servers of `entries`, after each start ended, and the changes of their states.
async fn started(entries: Vec<(String, ServerConfig)>, folder: &Path, media: Arc<Recorded>) -> (Servers, Changes) {
    started_with(entries, Vec::new(), false, folder, media).await
}

/// The user servers of `user` and the project servers of `project` with the trust `trusted`, after each start ended.
async fn started_with(
    user: Vec<(String, ServerConfig)>,
    project: Vec<(String, ServerConfig)>,
    trusted: bool,
    folder: &Path,
    media: Arc<Recorded>,
) -> (Servers, Changes) {
    let variable = |name: &str| (name == "SET").then(|| "set".to_owned());
    let changes = Changes::default();
    let kept = Arc::clone(&changes);
    let on_change = Arc::new(move |server| kept.lock().unwrap().push(server));
    let trust = async move { trusted };
    let servers = Servers::start(&user, &project, trust, &variable, folder, media, on_change);
    tokio::time::timeout(Duration::from_secs(10), servers.ready())
        .await
        .unwrap();
    (servers, changes)
}

fn server(name: &str, state: McpServerState) -> McpServer {
    McpServer {
        name: name.to_owned(),
        source: McpServerSource::User,
        state,
    }
}

fn project_server(name: &str, state: McpServerState) -> McpServer {
    McpServer {
        source: McpServerSource::Project,
        ..server(name, state)
    }
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
    let (servers, changes) = started(vec![("test".to_owned(), entry)], &folder, Arc::default()).await;

    let tools = servers.tools();

    assert_eq!(
        servers.states(),
        [server("test", McpServerState::Connected { tools: 7 })]
    );
    // The newest version with `initialize`, which each server of this era speaks.
    assert_eq!(std::fs::read_to_string(&log).unwrap(), "initialize \"2025-11-25\"\n");
    assert_eq!(*changes.lock().unwrap(), servers.states());
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
    // A tool title, else an annotation title, is the title of the summary line.
    let titles: Vec<_> = tools.iter().take(3).map(|(_, tool)| tool.hints().title).collect();
    assert_eq!(titles, [Some("Echo".to_owned()), Some("Picture".to_owned()), None]);
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
    let (servers, _changes) = started(vec![("test".to_owned(), test_server(&[]))], &folder, Arc::clone(&media)).await;
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
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    driver
        .turn(&mut Vec::new(), vec![Block::user_text("go")])
        .blobs(&*media)
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
    let (servers, _changes) = started(vec![("test".to_owned(), entry)], &folder, Arc::default()).await;
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
    let (servers, _changes) = started(entries, &folder, Arc::default()).await;

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
async fn a_server_that_exits_fails_with_its_last_stderr_line_loses_its_tools_and_stops_its_children() {
    let folder = folder("a_server_that_exits");
    // The child keeps the stderr of the server open after the server ends.
    let script = r#"sleep 30 >/dev/null & echo $! > "$1"; exec "$2""#;
    let wrapper = ServerConfig {
        command: Some("sh".to_owned()),
        args: vec![
            "-c".to_owned(),
            script.to_owned(),
            "sh".to_owned(),
            folder.join("child.pid").display().to_string(),
            env!("CARGO_BIN_EXE_yuke-mcp-test-server").to_owned(),
        ],
        ..test_server(&[])
    };
    let (servers, changes) = started(vec![("test".to_owned(), wrapper)], &folder, Arc::default()).await;
    let toolset = toolset(&servers);
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "mcp__test__exit", "{}")]), text_reply("done")]);
    let model = model_of(native_target());
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);

    driver
        .turn(&mut Vec::new(), vec![Block::user_text("go")])
        .run()
        .await
        .unwrap();

    let stopped = server(
        "test",
        McpServerState::Failed {
            error: "the server stopped\nexit".to_owned(),
        },
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while changes.lock().unwrap().last() != Some(&stopped) {
        assert!(Instant::now() < deadline, "{:?}", changes.lock().unwrap());
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(servers.states(), [stopped]);
    assert!(servers.tools().is_empty());
    assert!(
        transport.requests()[1].contains("The server closed before its answer."),
        "{}",
        transport.requests()[1]
    );
    child_stops(&folder).await;
    servers.close().await;
}

#[tokio::test]
async fn a_failed_start_shows_the_last_twenty_stderr_lines_and_stops_the_children() {
    let folder = folder("a_failed_start_shows_the_last_lines");
    // 25 lines, a blank one, and a child that keeps the stderr open after the server ends.
    let script = r#"i=1; while [ $i -le 25 ]; do echo "line $i" >&2; i=$((i + 1)); done; echo >&2
        sleep 30 >/dev/null & echo $! > "$1"; exit 1"#;
    let failing = ServerConfig {
        command: Some("sh".to_owned()),
        args: vec![
            "-c".to_owned(),
            script.to_owned(),
            "sh".to_owned(),
            folder.join("child.pid").display().to_string(),
        ],
        ..test_server(&[])
    };

    let (servers, _) = started(vec![("failing".to_owned(), failing)], &folder, Arc::default()).await;

    let states = servers.states();
    let [
        McpServer {
            state: McpServerState::Failed { error },
            ..
        },
    ] = states.as_slice()
    else {
        panic!("{states:?}");
    };
    let (head, log) = error.split_once('\n').unwrap();
    assert!(head.starts_with("the server did not initialize"), "{head}");
    let expected: Vec<String> = (6..=25).map(|line| format!("line {line}")).collect();
    assert_eq!(log, expected.join("\n"));
    child_stops(&folder).await;
}

#[tokio::test]
async fn a_close_stops_a_server_that_never_answers_its_start() {
    let folder = folder("a_close_stops_a_server_that_never_answers");
    // `sleep` reads nothing, so the start waits for `initialize` forever.
    let silent = ServerConfig {
        command: Some("sleep".to_owned()),
        args: vec!["30".to_owned()],
        ..test_server(&[])
    };
    let on_change = Arc::new(|_| {});
    let servers = Servers::start(
        &[("silent".to_owned(), silent)],
        &[],
        async { false },
        &|_| None,
        &folder,
        Arc::new(Recorded::default()),
        on_change,
    );

    let waited = tokio::time::timeout(Duration::from_millis(200), servers.ready()).await;
    tokio::time::timeout(Duration::from_secs(5), servers.close())
        .await
        .unwrap();

    assert!(waited.is_err(), "the start ended");
    assert_eq!(servers.states(), [server("silent", McpServerState::Connecting)]);
}

/// A server behind a shell that starts a child and waits for it after the server ends, so the server outlives its
/// input. The file `child.pid` in `folder` gets the id of the child.
fn wrapped_server(folder: &Path) -> ServerConfig {
    let script = r#"sleep 30 </dev/null >/dev/null 2>&1 & echo $! > "$1"; "$2"; wait"#;
    ServerConfig {
        command: Some("sh".to_owned()),
        args: vec![
            "-c".to_owned(),
            script.to_owned(),
            "sh".to_owned(),
            folder.join("child.pid").display().to_string(),
            env!("CARGO_BIN_EXE_yuke-mcp-test-server").to_owned(),
        ],
        ..test_server(&[])
    }
}

/// Wait until the child of [`wrapped_server`] in `folder` no longer exists.
async fn child_stops(folder: &Path) {
    let child = std::fs::read_to_string(folder.join("child.pid")).unwrap();
    let child = child.trim();
    let deadline = Instant::now() + Duration::from_secs(10);
    while std::process::Command::new("kill")
        .args(["-0", child])
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success()
    {
        assert!(Instant::now() < deadline, "the child {child} runs");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn a_close_stops_the_children_of_a_server_that_outlives_its_input() {
    let folder = folder("a_close_stops_the_children");
    let (servers, _) = started(
        vec![("wrapped".to_owned(), wrapped_server(&folder))],
        &folder,
        Arc::default(),
    )
    .await;

    // The close waits for the server, then kills it.
    tokio::time::timeout(Duration::from_secs(10), servers.close())
        .await
        .unwrap();

    child_stops(&folder).await;
}

#[tokio::test]
async fn a_drop_stops_the_children_of_a_server() {
    let folder = folder("a_drop_stops_the_children");
    let (servers, _) = started(
        vec![("wrapped".to_owned(), wrapped_server(&folder))],
        &folder,
        Arc::default(),
    )
    .await;

    drop(servers);

    child_stops(&folder).await;
}

#[tokio::test]
async fn a_project_server_replaces_a_user_server_and_starts_only_when_trusted() {
    let folder = folder("a_project_server_replaces_a_user_server");
    let user = vec![
        ("test".to_owned(), test_server(&[])),
        ("mine".to_owned(), test_server(&[])),
    ];
    let project = vec![("test".to_owned(), test_server(&[]))];

    let (trusted, changes) = started_with(user.clone(), project.clone(), true, &folder, Arc::default()).await;
    let (refused, refused_changes) = started_with(user, project, false, &folder, Arc::default()).await;

    let connected = McpServerState::Connected { tools: 7 };
    assert_eq!(
        trusted.states(),
        [
            server("mine", connected.clone()),
            project_server("test", connected.clone())
        ]
    );
    assert!(
        changes
            .lock()
            .unwrap()
            .contains(&project_server("test", McpServerState::Connecting))
    );
    assert_eq!(
        refused.states(),
        [
            server("mine", connected),
            project_server("test", McpServerState::Untrusted)
        ]
    );
    assert!(
        refused_changes
            .lock()
            .unwrap()
            .iter()
            .all(|change| change.source == McpServerSource::User)
    );
    trusted.close().await;
    refused.close().await;
}

#[tokio::test]
async fn the_trust_runs_only_when_a_project_server_can_start() {
    let folder = folder("the_trust_runs_only_when_a_project_server_can_start");
    let asked = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let marked = Arc::clone(&asked);
    let trust = async move {
        marked.store(true, std::sync::atomic::Ordering::SeqCst);
        true
    };
    let disabled = ServerConfig {
        enabled: false,
        ..test_server(&[])
    };

    let servers = Servers::start(
        &[],
        &[("off".to_owned(), disabled)],
        trust,
        &|_| None,
        &folder,
        Arc::new(Recorded::default()),
        Arc::new(|_| {}),
    );
    servers.ready().await;

    assert!(!asked.load(std::sync::atomic::Ordering::SeqCst));
    assert_eq!(servers.states(), [project_server("off", McpServerState::Disabled)]);
}

#[tokio::test]
async fn a_close_during_the_trust_starts_no_project_server() {
    let folder = folder("a_close_during_the_trust");
    let (answer, answered) = tokio::sync::oneshot::channel::<bool>();
    let trust = async move { answered.await.unwrap_or(false) };
    let servers = Servers::start(
        &[],
        &[("proj".to_owned(), test_server(&[]))],
        trust,
        &|_| None,
        &folder,
        Arc::new(Recorded::default()),
        Arc::new(|_| {}),
    );

    tokio::time::timeout(Duration::from_secs(5), servers.close())
        .await
        .unwrap();
    // The trust task ended with the close, so the answer finds no receiver.
    let late = answer.send(true);

    assert!(late.is_err());
    assert_eq!(servers.states(), [project_server("proj", McpServerState::Untrusted)]);
    assert!(servers.tools().is_empty());
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

    let (servers, changes) = started(
        entries
            .into_iter()
            .map(|(name, entry)| (name.to_owned(), entry))
            .collect(),
        &folder,
        Arc::default(),
    )
    .await;

    let states = servers.states();
    let McpServerState::Failed { error } = &states[0].state else {
        panic!("{states:?}");
    };
    assert!(error.starts_with("the server did not start: "), "{error}");
    assert_eq!(
        states[1..],
        [
            server(
                "http",
                McpServerState::Failed {
                    error: "yuke cannot reach an HTTP server yet".to_owned()
                }
            ),
            server(
                "unset",
                McpServerState::Failed {
                    error: "the variable UNSET has no value and no default".to_owned()
                }
            ),
            server("disabled", McpServerState::Disabled),
        ]
    );
    assert!(servers.tools().is_empty());
    // Only the end of a start is a change, so the entries that never start send none.
    assert_eq!(changes.lock().unwrap().len(), 1);
    servers.close().await;
}
