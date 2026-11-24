//! These tests run the MCP test server of this crate: its start, its tools in a turn, a cancel, and the entries that
//! do not start.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use tokio::io::AsyncBufReadExt;
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

#[async_trait(?Send)]
impl MediaStore for Recorded {
    async fn put_media(&self, bytes: Vec<u8>) -> Result<Blob, Box<dyn std::error::Error + Send + Sync>> {
        let blob = Blob {
            digest: yuke_ai::Digest([7; 32]),
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
        folder: None,
        url: None,
        headers: std::collections::BTreeMap::new(),
        oauth: None,
        enabled: true,
    }
}

/// The test server over HTTP with `env`, and its entry with the header `X-Api-Key: ${SET}`. The drop of the child
/// stops the server.
async fn http_server(env: &[(&str, &str)]) -> (ServerConfig, tokio::process::Child) {
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_yuke-mcp-test-server"))
        .arg("--http")
        .envs(env.iter().copied())
        .stdout(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut port = String::new();
    tokio::io::BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut port)
        .await
        .unwrap();
    let entry = ServerConfig {
        command: None,
        url: Some(format!("http://127.0.0.1:{}/mcp", port.trim())),
        headers: [("X-Api-Key".to_owned(), "${SET}".to_owned())].into(),
        ..test_server(&[])
    };
    (entry, child)
}

/// The entry of the test server over stdio and over HTTP, each with `env`, and the child of the HTTP server.
async fn both_servers(env: &[(&str, &str)]) -> ([(&'static str, ServerConfig); 2], tokio::process::Child) {
    let (remote, child) = http_server(env).await;
    ([("stdio", test_server(env)), ("http", remote)], child)
}

/// A client for the requests of the remote servers.
fn http() -> Arc<yuke_http::Client> {
    Arc::new(yuke_http::Client::new(yuke_http::http::HeaderValue::from_static(
        "yuke-test",
    )))
}

/// A new empty folder for the test `name`.
fn folder(name: &str) -> PathBuf {
    yuke_testing::folder("mcp", name)
}

/// Keeps each change of a server state.
type Changes = Rc<RefCell<Vec<McpServer>>>;

/// The servers of `entries`, after each start ended, and the changes of their states.
async fn started(entries: Vec<(String, ServerConfig)>, folder: &Path, media: Rc<Recorded>) -> (Servers, Changes) {
    started_with(entries, Vec::new(), false, folder, media).await
}

/// The user servers of `user` and the project servers of `project` with the trust `trusted`, after each start ended.
async fn started_with(
    user: Vec<(String, ServerConfig)>,
    project: Vec<(String, ServerConfig)>,
    trusted: bool,
    folder: &Path,
    media: Rc<Recorded>,
) -> (Servers, Changes) {
    let variable = |name: &str| (name == "SET").then(|| "set".to_owned());
    let changes = Changes::default();
    let kept = Rc::clone(&changes);
    let on_change = Rc::new(move |server| kept.borrow_mut().push(server));
    let trust = async move { trusted };
    let data = folder.join("data");
    let servers = Servers::start(
        &user,
        &project,
        trust,
        &variable,
        folder,
        &data,
        media,
        http(),
        on_change,
    );
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

#[tokio::test(flavor = "local")]
async fn a_server_starts_and_gives_its_tools_deferred_with_their_names_and_schemas() {
    let folder = folder("a_server_starts");
    let log = folder.join("log");
    let entry = test_server(&[("MCP_TEST_LOG", log.to_str().unwrap())]);
    let (servers, changes) = started(vec![("test".to_owned(), entry)], &folder, Rc::default()).await;

    let tools = servers.tools();

    assert_eq!(
        servers.states(),
        [server("test", McpServerState::Connected { tools: tools.len() })]
    );
    // The newest version with `initialize`, which each server of this era speaks.
    assert_eq!(std::fs::read_to_string(&log).unwrap(), "initialize \"2025-11-25\"\n");
    assert_eq!(*changes.borrow_mut(), servers.states());
    let tool = |name: &str| {
        tools
            .iter()
            .find(|(definition, _)| definition.name == name)
            .unwrap_or_else(|| panic!("the server gives no tool {name}"))
    };
    // A tool title, else an annotation title, is the title of the head line.
    assert_eq!(tool("mcp__test__echo").1.hints().title, Some("Echo".to_owned()));
    assert_eq!(tool("mcp__test__picture").1.hints().title, Some("Picture".to_owned()));
    assert_eq!(tool("mcp__test__fail").1.hints().title, None);
    let (echo, _) = tool("mcp__test__echo");
    assert!(echo.defer_loading);
    assert_eq!(echo.description, "Echo the text.");
    assert_eq!(
        echo.input_schema,
        r#"{"properties":{"text":{"type":"string"}},"type":"object"}"#
    );
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_remote_server_gets_its_headers_on_each_request_and_the_end_of_its_session_at_the_close() {
    let folder = folder("a_remote_server_gets_its_headers");
    let log = folder.join("log");
    let (entry, _child) = http_server(&[("MCP_TEST_LOG", log.to_str().unwrap())]).await;
    let (servers, _changes) = started(vec![("remote".to_owned(), entry)], &folder, Rc::default()).await;

    let connected = servers.states();
    servers.close().await;

    assert_eq!(connected, [server("remote", McpServerState::Connected { tools: 6 })]);
    let lines = std::fs::read_to_string(&log).unwrap();
    // `initialize`, `notifications/initialized`, and `tools/list` each carry the header.
    assert_eq!(
        lines.lines().collect::<Vec<_>>(),
        [
            "key set",
            "initialize \"2025-11-25\"",
            "key set",
            "key set",
            "delete s1 set"
        ]
    );
}

#[tokio::test(flavor = "local")]
async fn a_remote_server_that_refuses_the_key_fails_with_its_status_and_its_text() {
    let folder = folder("a_remote_server_that_refuses_the_key");
    let (entry, _child) = http_server(&[]).await;
    let denied = ServerConfig {
        headers: [("X-Api-Key".to_owned(), "deny".to_owned())].into(),
        ..entry
    };

    let (servers, _changes) = started(vec![("remote".to_owned(), denied)], &folder, Rc::default()).await;

    let states = servers.states();
    let McpServerState::Failed { error } = &states[0].state else {
        panic!("{states:?}");
    };
    assert!(error.starts_with("the server did not initialize: "), "{error}");
    assert!(error.contains("HTTP 401 Unauthorized: no access"), "{error}");
}

#[tokio::test(flavor = "local")]
async fn the_model_reads_the_text_the_image_the_error_and_the_structure_of_the_results() {
    let folder = folder("the_model_reads_the_results");
    let (entries, _child) = both_servers(&[]).await;
    for (transport_name, entry) in entries {
        let media = Rc::new(Recorded::default());
        let (servers, _changes) = started(vec![("test".to_owned(), entry)], &folder, Rc::clone(&media)).await;
        let toolset = toolset(&servers);
        let transport = ScriptedTransport::new([
            tool_reply(&[
                ("c1", "mcp__test__echo", r#"{"text":"hello"}"#),
                ("c2", "mcp__test__picture", "{}"),
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
        for text in ["hello", "a picture", "it broke", r#"{\"answer\":42}"#] {
            assert!(request.contains(text), "{transport_name}, {text}: {request}");
        }
        assert_eq!(*media.0.lock().unwrap(), [STANDARD.decode(PIXEL).unwrap()]);
        servers.close().await;
    }
}

#[tokio::test(flavor = "local")]
async fn a_cancel_of_a_call_sends_the_cancel_to_the_server() {
    let folder = folder("a_cancel_of_a_call");
    let log = folder.join("log");
    let (entries, _child) = both_servers(&[("MCP_TEST_LOG", log.to_str().unwrap())]).await;
    for (transport_name, entry) in entries {
        _ = std::fs::remove_file(&log);
        cancel_reaches(entry, &folder, &log).await;
        let lines = std::fs::read_to_string(&log).unwrap();
        assert!(lines.contains("cancelled "), "{transport_name}: {lines}");
    }
}

/// Cancel a call of the `wait` tool of `entry`, and wait until the server writes the cancel to `log`.
async fn cancel_reaches(entry: ServerConfig, folder: &Path, log: &Path) {
    let (servers, _changes) = started(vec![("test".to_owned(), entry)], folder, Rc::default()).await;
    let toolset = toolset(&servers);
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "mcp__test__wait", "{}")]), text_reply("done")]);
    let model = model_of(native_target());
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);
    let token = CancellationToken::new();
    let cancel = token.clone();
    let received = async {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let lines = std::fs::read_to_string(log).unwrap();
            if lines.lines().any(|line| line.starts_with("call ")) {
                cancel.cancel();
            }
            if lines.lines().any(|line| line.starts_with("cancelled ")) {
                assert!(lines.lines().any(|line| line.starts_with("call ")), "{lines}");
                break;
            }
            assert!(Instant::now() < deadline, "the server got no call or cancel: {lines}");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };

    let mut context = Vec::new();
    let turn = driver
        .turn(&mut context, vec![Block::user_text("go")])
        .cancellation_token(token);
    let (result, ()) = tokio::join!(turn.run(), received);
    result.unwrap();

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

#[tokio::test(flavor = "local")]
async fn two_servers_with_one_valid_name_both_keep_their_tools() {
    let folder = folder("two_servers_with_one_valid_name");
    let entries = vec![
        ("a b".to_owned(), test_server(&[])),
        ("a_b".to_owned(), test_server(&[])),
    ];
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;

    let tools = servers.tools();

    let names: Vec<_> = tools.iter().map(|(definition, _)| definition.name.clone()).collect();
    assert_eq!(names.len(), 12);
    assert_eq!(names[0], "mcp__a_b__echo");
    assert!(
        names[6].starts_with("mcp__a_b__echo_") && names[6].len() == 23,
        "{names:?}"
    );
    servers.close().await;
}

#[tokio::test(flavor = "local")]
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
    let (changed, mut changes) = tokio::sync::mpsc::unbounded_channel();
    let servers = Servers::start(
        &[("test".to_owned(), wrapper)],
        &[],
        async { false },
        &|_| None,
        &folder,
        &folder,
        Rc::new(Recorded::default()),
        http(),
        Rc::new(move |server| changed.send(server).unwrap()),
    );
    tokio::time::timeout(Duration::from_secs(10), servers.ready())
        .await
        .unwrap();
    assert_eq!(
        changes.recv().await,
        Some(server("test", McpServerState::Connected { tools: 6 }))
    );
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
    let changed = tokio::time::timeout(Duration::from_secs(5), changes.recv())
        .await
        .unwrap();
    assert_eq!(changed, Some(stopped.clone()));
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

#[tokio::test(flavor = "local")]
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

    let (servers, _) = started(vec![("failing".to_owned(), failing)], &folder, Rc::default()).await;

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

#[tokio::test(flavor = "local")]
async fn a_close_stops_a_server_that_never_answers_its_start() {
    let folder = folder("a_close_stops_a_server_that_never_answers");
    // `sleep` reads nothing, so the start waits for `initialize` forever.
    let silent = ServerConfig {
        command: Some("sleep".to_owned()),
        args: vec!["30".to_owned()],
        ..test_server(&[])
    };
    let on_change = Rc::new(|_| {});
    let servers = Servers::start(
        &[("silent".to_owned(), silent)],
        &[],
        async { false },
        &|_| None,
        &folder,
        &folder,
        Rc::new(Recorded::default()),
        http(),
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

#[tokio::test(flavor = "local")]
async fn a_close_stops_the_children_of_a_server_that_outlives_its_input() {
    let folder = folder("a_close_stops_the_children");
    let (servers, _) = started(
        vec![("wrapped".to_owned(), wrapped_server(&folder))],
        &folder,
        Rc::default(),
    )
    .await;

    // The close waits for the server, then kills it.
    tokio::time::timeout(Duration::from_secs(10), servers.close())
        .await
        .unwrap();

    child_stops(&folder).await;
}

#[tokio::test(flavor = "local")]
async fn a_drop_stops_the_children_of_a_server() {
    let folder = folder("a_drop_stops_the_children");
    let (servers, _) = started(
        vec![("wrapped".to_owned(), wrapped_server(&folder))],
        &folder,
        Rc::default(),
    )
    .await;

    drop(servers);

    child_stops(&folder).await;
}

#[tokio::test(flavor = "local")]
async fn a_project_server_replaces_a_user_server_and_starts_only_when_trusted() {
    let folder = folder("a_project_server_replaces_a_user_server");
    let user = vec![
        ("test".to_owned(), test_server(&[])),
        ("mine".to_owned(), test_server(&[])),
    ];
    let project = vec![("test".to_owned(), test_server(&[]))];

    let (trusted, changes) = started_with(user.clone(), project.clone(), true, &folder, Rc::default()).await;
    let (refused, refused_changes) = started_with(user, project, false, &folder, Rc::default()).await;

    let connected = McpServerState::Connected { tools: 6 };
    assert_eq!(
        trusted.states(),
        [
            server("mine", connected.clone()),
            project_server("test", connected.clone())
        ]
    );
    assert!(
        changes
            .borrow_mut()
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
            .borrow_mut()
            .iter()
            .all(|change| change.source == McpServerSource::User)
    );
    trusted.close().await;
    refused.close().await;
}

#[tokio::test]
async fn the_trust_runs_only_when_a_project_server_can_start() {
    let folder = folder("the_trust_runs_only_when_a_project_server_can_start");
    let asked = Rc::new(std::cell::Cell::new(false));
    let marked = Rc::clone(&asked);
    let trust = async move {
        marked.set(true);
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
        &folder,
        Rc::new(Recorded::default()),
        http(),
        Rc::new(|_| {}),
    );
    servers.ready().await;

    assert!(!asked.get());
    assert_eq!(servers.states(), [project_server("off", McpServerState::Disabled)]);
}

#[tokio::test(flavor = "local")]
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
        &folder,
        Rc::new(Recorded::default()),
        http(),
        Rc::new(|_| {}),
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

#[tokio::test(flavor = "local")]
async fn an_entry_that_cannot_start_fails_and_a_disabled_one_stays_off() {
    let folder = folder("an_entry_that_cannot_start");
    let missing = ServerConfig {
        command: Some("/no/such/program".to_owned()),
        ..test_server(&[])
    };
    let remote = ServerConfig {
        command: None,
        url: Some("https://example.test/mcp".to_owned()),
        headers: [("bad name".to_owned(), "x".to_owned())].into(),
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
        ("http", remote),
        ("unset", unset),
        ("disabled", disabled),
    ];

    let (servers, changes) = started(
        entries
            .into_iter()
            .map(|(name, entry)| (name.to_owned(), entry))
            .collect(),
        &folder,
        Rc::default(),
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
                    error: "bad name is not a header name".to_owned()
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
    assert_eq!(changes.borrow_mut().len(), 1);
    servers.close().await;
}

// The tests of the OAuth login run the fake authorization server of the test server. The test plays the browser: it
// opens the page of the login, and it follows the redirect to the loopback listener of the client.

/// The client id document of yuke, which the fake server takes with the option `cimd`.
const CLIENT_METADATA: &str = "https://yuke.sh/oauth/client.json";

/// The test server over HTTP with the OAuth options `options`, and its entry named `test` without headers.
async fn oauth_server(
    options: &str,
    log: &Path,
    env: &[(&str, &str)],
) -> (Vec<(String, ServerConfig)>, tokio::process::Child) {
    let mut variables = vec![("MCP_TEST_OAUTH", options), ("MCP_TEST_LOG", log.to_str().unwrap())];
    variables.extend_from_slice(env);
    let (entry, child) = http_server(&variables).await;
    let entry = ServerConfig {
        headers: std::collections::BTreeMap::new(),
        ..entry
    };
    (vec![("test".to_owned(), entry)], child)
}

/// Send a request to `url`, and give the status, the headers, and the body.
async fn fetch(
    method: yuke_http::http::Method,
    url: &str,
) -> (yuke_http::http::StatusCode, yuke_http::http::HeaderMap, String) {
    let mut response = http().send(yuke_http::Request::new(method, url)).await.unwrap();
    let mut body = Vec::new();
    while let Some(chunk) = response.body.chunk().await {
        body.extend_from_slice(&chunk.unwrap());
    }
    (response.status, response.headers, String::from_utf8(body).unwrap())
}

/// What the user does on the page `url` of the login: the authorization server redirects the browser to the client.
/// Gives the address of the redirect.
async fn approve(url: &str) -> String {
    let (status, headers, body) = fetch(yuke_http::http::Method::GET, url).await;
    assert_eq!(status, 302, "{body}");
    headers[yuke_http::http::header::LOCATION].to_str().unwrap().to_owned()
}

/// The browser opens `location`, and the listener of the client answers.
async fn visit(location: &str) -> (u16, String) {
    let (status, _, body) = fetch(yuke_http::http::Method::GET, location).await;
    (status.as_u16(), body)
}

/// Log in the server `test` as the user does, and wait until it connects again.
async fn log_in(servers: &Servers) {
    let (login, outcome) = servers.login("test").await.unwrap();
    let location = approve(login.url()).await;
    let (result, page) = tokio::join!(outcome, visit(&location));
    result.unwrap();
    assert_eq!(page.0, 200, "{}", page.1);
    tokio::time::timeout(Duration::from_secs(10), servers.ready())
        .await
        .unwrap();
}

/// The lines of the log that the authorization server and the bearer check write.
fn oauth_lines(log: &Path) -> Vec<String> {
    let text = std::fs::read_to_string(log).unwrap_or_default();
    let kinds = ["authorize ", "register ", "token ", "bearer ", "refused "];
    text.lines()
        .filter(|line| kinds.iter().any(|kind| line.starts_with(kind)))
        .map(str::to_owned)
        .collect()
}

/// The lines of the log from the first line that starts with `prefix`.
fn lines_from(log: &Path, prefix: &str) -> Vec<String> {
    let lines = oauth_lines(log);
    lines.into_iter().skip_while(|line| !line.starts_with(prefix)).collect()
}

/// Wait until the server `test` is in the state `expected`.
async fn wait_for_state(servers: &Servers, expected: McpServerState) {
    let reached = async {
        while state_of(servers) != expected {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(Duration::from_secs(5), reached).await.unwrap();
}

/// Send the control request `path` to the fake authorization server of `entries`.
async fn control(entries: &[(String, ServerConfig)], path: &str) {
    let origin = entries[0].1.url.clone().unwrap().replace("/mcp", "");
    fetch(yuke_http::http::Method::POST, &format!("{origin}/test/{path}")).await;
}

/// The text of the file with the stored logins.
fn stored_logins(folder: &Path) -> serde_json::Value {
    serde_json::from_str(&std::fs::read_to_string(folder.join("data/mcp-auth.json")).unwrap()).unwrap()
}

/// The result text of a call of the `echo` tool of the server `test`.
async fn call_echo(servers: &Servers) -> String {
    let toolset = toolset(servers);
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "mcp__test__echo", r#"{"text":"hello"}"#)]),
        text_reply("done"),
    ]);
    let model = model_of(native_target());
    let driver = Driver::new(&transport, &model, &NoWait).toolset(&toolset);
    let mut context = Vec::new();
    driver
        .turn(&mut context, vec![Block::user_text("go")])
        .run()
        .await
        .unwrap();
    context
        .iter()
        .filter_map(|block| match block {
            Block::ToolResult(result) => Some(result.content.as_str()),
            _ => None,
        })
        .collect()
}

fn state_of(servers: &Servers) -> McpServerState {
    servers.states().remove(0).state
}

#[tokio::test(flavor = "local")]
async fn a_server_that_needs_a_login_waits_in_needs_login_and_a_login_over_the_loopback_connects_it() {
    let folder = folder("a_login_over_the_loopback");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd,dcr", &log, &[]).await;
    let (servers, changes) = started(entries, &folder, Rc::default()).await;
    let waiting = servers.states();

    log_in(&servers).await;

    assert_eq!(waiting, [server("test", McpServerState::NeedsLogin)]);
    assert_eq!(state_of(&servers), McpServerState::Connected { tools: 6 });
    let kinds: Vec<_> = changes.borrow().iter().map(|server| server.state.clone()).collect();
    assert_eq!(
        kinds,
        [
            McpServerState::NeedsLogin,
            McpServerState::Connecting,
            McpServerState::Connected { tools: 6 }
        ]
    );
    // The start has no token. The authorization server checks the PKCE verifier at the token request. The client id
    // document wins over the registration, and the scope is the one of the challenge. After the login, `initialize`,
    // `notifications/initialized`, and `tools/list` carry the token.
    assert_eq!(
        oauth_lines(&log),
        [
            "refused ".to_owned(),
            format!("authorize client={CLIENT_METADATA} scope=files:read"),
            "token authorization_code".to_owned(),
            "bearer access-1".to_owned(),
            "bearer access-1".to_owned(),
            "bearer access-1".to_owned(),
        ]
    );
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_login_completes_with_the_pasted_address_of_the_redirect() {
    let folder = folder("a_login_with_the_pasted_address");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd", &log, &[]).await;
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;

    let (login, outcome) = servers.login("test").await.unwrap();
    let location = approve(login.url()).await;
    login.complete(&location).unwrap();
    outcome.await.unwrap();
    servers.ready().await;

    assert_eq!(state_of(&servers), McpServerState::Connected { tools: 6 });
    servers.close().await;
}

/// The address `location` with the value of `name` replaced by `value`.
fn with_parameter(location: &str, name: &str, value: &str) -> String {
    let (base, query) = location.split_once('?').unwrap();
    let query: Vec<_> = query
        .split('&')
        .map(|pair| match pair.split_once('=') {
            Some((key, _)) if key == name => format!("{name}={value}"),
            _ => pair.to_owned(),
        })
        .collect();
    format!("{base}?{}", query.join("&"))
}

#[tokio::test(flavor = "local")]
async fn a_redirect_with_another_state_is_refused_and_the_login_goes_on_to_wait() {
    let folder = folder("a_redirect_with_another_state");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd", &log, &[]).await;
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;
    let (login, outcome) = servers.login("test").await.unwrap();
    let location = approve(login.url()).await;
    let forged = with_parameter(&location, "state", "forged");

    let pasted = login.complete(&forged);
    let (result, page) = tokio::join!(outcome, async {
        let page = visit(&forged).await;
        // The right redirect still logs in.
        login.complete(&location).unwrap();
        page
    });

    assert_eq!(
        pasted,
        Err("the state of the redirect is not the state of this login".to_owned())
    );
    assert_eq!(page.0, 400);
    result.unwrap();
    servers.ready().await;
    assert_eq!(state_of(&servers), McpServerState::Connected { tools: 6 });
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_redirect_with_another_issuer_is_refused_when_the_server_names_its_issuer() {
    let folder = folder("a_redirect_with_another_issuer");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd,iss", &log, &[]).await;
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;
    let (login, outcome) = servers.login("test").await.unwrap();
    let location = approve(login.url()).await;

    let forged = login.complete(&with_parameter(&location, "iss", "https%3A%2F%2Fevil.test"));
    login.complete(&location).unwrap();
    outcome.await.unwrap();

    assert_eq!(
        forged,
        Err("the issuer of the redirect is not the issuer of the server".to_owned())
    );
    servers.ready().await;
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_login_that_the_user_denies_ends_with_the_error_of_the_authorization_server() {
    let folder = folder("a_login_that_the_user_denies");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd", &log, &[]).await;
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;
    let (login, outcome) = servers.login("test").await.unwrap();
    let location = approve(login.url()).await;
    let denied = with_parameter(&location, "code", "x").replace("code=x", "error=access_denied");

    login.complete(&denied).unwrap();
    let result = outcome.await;

    assert_eq!(
        result,
        Err("the authorization server refused the login: access_denied".to_owned())
    );
    assert_eq!(state_of(&servers), McpServerState::NeedsLogin);
}

#[tokio::test(flavor = "local")]
async fn two_logins_of_one_server_connect_it_once() {
    let folder = folder("two_logins_of_one_server");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd", &log, &[]).await;
    let (servers, changes) = started(entries, &folder, Rc::default()).await;
    let (first, first_outcome) = servers.login("test").await.unwrap();
    let (second, second_outcome) = servers.login("test").await.unwrap();
    first.complete(&approve(first.url()).await).unwrap();
    second.complete(&approve(second.url()).await).unwrap();

    let (first_result, second_result) = tokio::join!(first_outcome, second_outcome);
    servers.ready().await;

    assert_eq!((first_result, second_result), (Ok(()), Ok(())));
    let kinds: Vec<_> = changes.borrow().iter().map(|server| server.state.clone()).collect();
    assert_eq!(
        kinds,
        [
            McpServerState::NeedsLogin,
            McpServerState::Connecting,
            McpServerState::Connected { tools: 6 }
        ]
    );
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_cancelled_login_ends_with_an_error_and_the_server_still_needs_a_login() {
    let folder = folder("a_cancelled_login");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd", &log, &[]).await;
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;
    let (login, outcome) = servers.login("test").await.unwrap();

    login.cancel();
    let result = outcome.await;

    assert_eq!(result, Err("the login was cancelled".to_owned()));
    assert_eq!(state_of(&servers), McpServerState::NeedsLogin);
    assert_eq!(
        servers.login("other").await.err().as_deref(),
        Some("there is no server other")
    );
}

#[tokio::test(flavor = "local")]
async fn a_server_that_needs_no_login_refuses_a_login_and_a_logout_needs_a_remote_server() {
    let folder = folder("a_server_that_needs_no_login");
    let (remote, _child) = http_server(&[]).await;
    let entries = vec![("remote".to_owned(), remote), ("local".to_owned(), test_server(&[]))];
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;

    let login = servers.login("remote").await.err();
    let logout = servers.logout("local").await;

    assert_eq!(login.as_deref(), Some("the server remote does not need a login"));
    assert_eq!(logout, Err("local is not a remote server".to_owned()));
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_login_is_refused_when_the_authorization_server_lacks_pkce_with_s256() {
    let folder = folder("a_login_without_pkce");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd,nopkce", &log, &[]).await;
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;

    let result = servers.login("test").await.err();

    let error = result.unwrap();
    assert!(error.ends_with("does not support PKCE with S256"), "{error}");
    assert!(oauth_lines(&log).iter().all(|line| !line.starts_with("authorize")));
}

#[tokio::test(flavor = "local")]
async fn a_login_is_refused_when_an_endpoint_of_the_authorization_server_uses_http_on_another_computer() {
    let folder = folder("a_login_with_a_plaintext_endpoint");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd,plaintext", &log, &[]).await;
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;

    let error = servers.login("test").await.err().unwrap();

    assert!(
        error.ends_with("names http://auth.example.test/token, which does not use HTTPS"),
        "{error}"
    );
    assert!(oauth_lines(&log).iter().all(|line| !line.starts_with("authorize")));
}

#[tokio::test(flavor = "local")]
async fn a_login_without_a_client_id_source_asks_for_the_client_id_of_the_config() {
    let folder = folder("a_login_without_a_client_id_source");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("", &log, &[]).await;
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;

    let error = servers.login("test").await.err().unwrap();

    assert!(
        error.ends_with("set oauth.clientId in the entry of the server"),
        "{error}"
    );
}

#[tokio::test(flavor = "local")]
async fn the_client_id_of_the_config_wins_and_the_redirect_uses_the_port_of_the_config() {
    let folder = folder("the_client_id_of_the_config_wins");
    let log = folder.join("log");
    let (mut entries, _child) = oauth_server("cimd,dcr", &log, &[]).await;
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    entries[0].1.oauth = Some(yuke_mcp::OAuthConfig {
        client_id: Some("preregistered".to_owned()),
        callback_port: Some(port),
    });
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;

    let (login, outcome) = servers.login("test").await.unwrap();
    let location = approve(login.url()).await;
    let (result, _page) = tokio::join!(outcome, visit(&location));
    result.unwrap();
    servers.ready().await;

    assert!(
        location.starts_with(&format!("http://127.0.0.1:{port}/callback?")),
        "{location}"
    );
    assert_eq!(
        lines_from(&log, "authorize")[..2],
        [
            "authorize client=preregistered scope=files:read",
            "token authorization_code"
        ]
    );
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn the_metadata_is_found_at_the_well_known_urls_and_the_scope_falls_back_to_the_supported_scopes() {
    let folder = folder("the_metadata_at_the_well_known_urls");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd,bare,oidc", &log, &[]).await;
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;
    assert_eq!(state_of(&servers), McpServerState::NeedsLogin);

    log_in(&servers).await;

    assert_eq!(
        lines_from(&log, "authorize")[0],
        format!("authorize client={CLIENT_METADATA} scope=a b")
    );
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_server_without_a_client_id_document_registers_yuke_and_logs_in_with_the_new_client() {
    let folder = folder("a_server_without_a_client_id_document");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("dcr", &log, &[]).await;
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;

    log_in(&servers).await;

    let lines = lines_from(&log, "register");
    assert!(lines[0].starts_with("register http://127.0.0.1:"), "{lines:?}");
    assert!(lines[0].ends_with("/callback"), "{lines:?}");
    assert_eq!(lines[1], "authorize client=client-1 scope=files:read");
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_stored_login_serves_the_next_session_and_its_file_is_private() {
    let folder = folder("a_stored_login_serves_the_next_session");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd", &log, &[]).await;
    let (servers, _changes) = started(entries.clone(), &folder, Rc::default()).await;
    log_in(&servers).await;
    servers.close().await;

    let (servers, _changes) = started(entries, &folder, Rc::default()).await;

    assert_eq!(state_of(&servers), McpServerState::Connected { tools: 6 });
    let lines = oauth_lines(&log);
    assert_eq!(
        lines.iter().filter(|line| line.starts_with("authorize ")).count(),
        1,
        "{lines:?}"
    );
    let file = folder.join("data/mcp-auth.json");
    assert_eq!(
        std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(&file).unwrap().permissions()) & 0o777,
        0o600
    );
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_logout_removes_the_login_and_stops_the_server_until_a_login() {
    let folder = folder("a_logout_removes_the_login");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd", &log, &[]).await;
    let (servers, _changes) = started(entries.clone(), &folder, Rc::default()).await;
    log_in(&servers).await;

    servers.logout("test").await.unwrap();

    wait_for_state(&servers, McpServerState::NeedsLogin).await;
    assert!(servers.tools().is_empty());
    assert_eq!(stored_logins(&folder), serde_json::json!({}));
    servers.close().await;
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;
    assert_eq!(state_of(&servers), McpServerState::NeedsLogin);
}

#[tokio::test(flavor = "local")]
async fn a_server_that_has_no_login_to_remove_keeps_running_at_a_logout() {
    let folder = folder("a_logout_without_a_login");
    let (remote, _child) = http_server(&[]).await;
    let (servers, _changes) = started(vec![("test".to_owned(), remote)], &folder, Rc::default()).await;

    servers.logout("test").await.unwrap();

    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(state_of(&servers), McpServerState::Connected { tools: 6 });
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_token_that_the_server_rejects_refreshes_once_and_the_call_succeeds() {
    let folder = folder("a_token_that_the_server_rejects");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd", &log, &[]).await;
    let (servers, _changes) = started(entries.clone(), &folder, Rc::default()).await;
    log_in(&servers).await;
    control(&entries, "expire").await;

    let echoed = call_echo(&servers).await;

    assert_eq!(echoed, "hello");
    assert_eq!(
        lines_from(&log, "refused access"),
        ["refused access-1", "token refresh_token", "bearer access-2"]
    );
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_token_that_ends_within_the_margin_refreshes_before_the_request() {
    let folder = folder("a_token_that_ends_within_the_margin");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd", &log, &[("MCP_TEST_EXPIRES_IN", "30")]).await;
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;

    log_in(&servers).await;

    // Each new token lasts less than the margin, so each request refreshes first, and the server never refuses one.
    let lines = oauth_lines(&log);
    assert!(
        lines
            .iter()
            .all(|line| !line.starts_with("refused ") || line == "refused "),
        "{lines:?}"
    );
    let refreshes = lines.iter().filter(|line| *line == "token refresh_token").count();
    assert_eq!(refreshes, 3, "{lines:?}");
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_login_that_cannot_refresh_is_removed_and_the_server_needs_a_login_again() {
    let folder = folder("a_login_that_cannot_refresh");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd", &log, &[]).await;
    let (servers, _changes) = started(entries.clone(), &folder, Rc::default()).await;
    log_in(&servers).await;
    servers.close().await;
    control(&entries, "revoke").await;

    let (servers, _changes) = started(entries, &folder, Rc::default()).await;

    assert_eq!(state_of(&servers), McpServerState::NeedsLogin);
    assert_eq!(stored_logins(&folder), serde_json::json!({}));
}

#[tokio::test(flavor = "local")]
async fn a_login_that_the_server_ends_during_the_session_moves_it_to_needs_login_and_a_login_connects_it_again() {
    let folder = folder("a_login_that_the_server_ends");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd", &log, &[]).await;
    let (servers, _changes) = started(entries.clone(), &folder, Rc::default()).await;
    log_in(&servers).await;
    control(&entries, "revoke").await;

    let failed = call_echo(&servers).await;

    assert_ne!(failed, "hello");
    wait_for_state(&servers, McpServerState::NeedsLogin).await;
    assert!(servers.tools().is_empty());
    log_in(&servers).await;
    assert_eq!(state_of(&servers), McpServerState::Connected { tools: 6 });
    assert_eq!(call_echo(&servers).await, "hello");
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_refresh_that_fails_for_now_keeps_the_login_and_a_token_that_still_lives_serves_the_call() {
    let folder = folder("a_refresh_that_fails_for_now");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd", &log, &[("MCP_TEST_EXPIRES_IN", "30")]).await;
    let (servers, _changes) = started(entries.clone(), &folder, Rc::default()).await;
    log_in(&servers).await;
    control(&entries, "token-down").await;

    let echoed = call_echo(&servers).await;

    // The token ends within the margin, but it did not end yet.
    assert_eq!(echoed, "hello");
    assert_eq!(stored_logins(&folder).as_object().unwrap().len(), 1);
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_refresh_whose_request_never_left_keeps_the_login() {
    let folder = folder("a_refresh_that_never_left");
    let log = folder.join("log");
    let (entries, mut child) = oauth_server("cimd", &log, &[("MCP_TEST_EXPIRES_IN", "30")]).await;
    let (servers, _changes) = started(entries.clone(), &folder, Rc::default()).await;
    log_in(&servers).await;
    servers.close().await;
    child.kill().await.unwrap();

    let (servers, _changes) = started(entries, &folder, Rc::default()).await;

    let McpServerState::Failed { .. } = state_of(&servers) else {
        panic!("{:?}", servers.states());
    };
    assert_eq!(stored_logins(&folder).as_object().unwrap().len(), 1);
}

#[tokio::test(flavor = "local")]
async fn a_refresh_answer_without_a_new_refresh_token_keeps_the_old_one() {
    let folder = folder("a_refresh_answer_without_a_new_token");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd,norotate", &log, &[]).await;
    let (servers, _changes) = started(entries.clone(), &folder, Rc::default()).await;
    log_in(&servers).await;

    control(&entries, "expire").await;
    let first = call_echo(&servers).await;
    control(&entries, "expire").await;
    let second = call_echo(&servers).await;

    assert_eq!((first.as_str(), second.as_str()), ("hello", "hello"));
    let refreshes = oauth_lines(&log)
        .iter()
        .filter(|line| *line == "token refresh_token")
        .count();
    assert_eq!(refreshes, 2);
    servers.close().await;
}

#[tokio::test(flavor = "local")]
async fn a_request_to_another_path_of_the_listener_gets_404_and_the_login_goes_on() {
    let folder = folder("a_request_to_another_path");
    let log = folder.join("log");
    let (entries, _child) = oauth_server("cimd", &log, &[]).await;
    let (servers, _changes) = started(entries, &folder, Rc::default()).await;
    let (login, outcome) = servers.login("test").await.unwrap();
    let location = approve(login.url()).await;
    let origin = location.split("/callback").next().unwrap().to_owned();

    let (result, (stray, page)) = tokio::join!(outcome, async {
        let stray = visit(&format!("{origin}/favicon.ico")).await;
        (stray, visit(&location).await)
    });

    assert_eq!((stray.0, page.0), (404, 200));
    result.unwrap();
    servers.ready().await;
    servers.close().await;
}
