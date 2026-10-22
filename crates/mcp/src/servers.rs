//! The MCP servers of one session: their connections, their states, and their tools.

use std::collections::{HashSet, VecDeque};
use std::path::Path;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use process_wrap::tokio::{CommandWrap, ProcessSession};
use rmcp::model::{
    CallToolRequest, CallToolRequestParams, CallToolResult, ClientCapabilities, ClientConfig, ClientRequest,
    ContentBlock, Implementation, JsonObject, ProtocolVersion, ResourceContents, ServerResult, Tool as McpToolInfo,
};
use rmcp::service::{PeerRequestOptions, RunningService, RunningServiceCancellationToken};
use rmcp::transport::TokioChildProcess;
use rmcp::{Peer, RoleClient, ServiceExt};
use rustix::process::{Pid, Signal, kill_process_group};
use tokio::io::AsyncReadExt;
use tokio::process::ChildStderr;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use yuke_ai::{Blob, MAX_MEDIA_BYTES, Media, ToolDefinition};
use yuke_engine::{MediaStore, Tool, ToolContent, ToolContext, parse_arguments};
use yuke_protocol::{McpServer, McpServerSource, McpServerState};

use crate::config::ServerConfig;
use crate::names::{hashed_name, tool_name};

/// The connection to one running server.
type Client = RunningService<RoleClient, ClientConfig>;

/// The number of the last stderr lines of a server that its failure shows.
const LOG_LINES: usize = 20;

/// The longest stderr line of a server that its failure shows, in bytes. A longer line is cut.
const LOG_LINE_BYTES: usize = 500;

/// Receives each change of the state of a server. It must not wait, and it must not call the [`Servers`].
pub type OnChange = Arc<dyn Fn(McpServer) + Send + Sync>;

/// One server of the session.
struct Slot {
    name: String,
    source: McpServerSource,
    state: McpServerState,
    /// The connection while the server runs.
    peer: Option<Peer<RoleClient>>,
    /// Stops the connection while the server runs.
    stop: Option<RunningServiceCancellationToken>,
    tools: Vec<McpToolInfo>,
}

/// What the servers and their tasks share.
struct Shared {
    slots: Mutex<Vec<Slot>>,
    on_change: OnChange,
    /// After a close, a stop is no news and no gated server starts.
    closed: AtomicBool,
    /// The task of each started server by the index of its slot, and the task of the trust without one. A close takes
    /// them under this lock, so the trust task starts no server after the close.
    tasks: Mutex<Vec<(Option<usize>, JoinHandle<()>)>>,
}

impl Slot {
    fn server(&self) -> McpServer {
        McpServer {
            name: self.name.clone(),
            source: self.source,
            state: self.state.clone(),
        }
    }
}

impl Shared {
    /// Change the slot `index` with `change`, and report its new state after the lock.
    fn update(&self, index: usize, change: impl FnOnce(&mut Slot)) {
        let server = {
            let mut slots = lock(&self.slots);
            let slot = &mut slots[index];
            change(slot);
            slot.server()
        };
        if !self.closed.load(Ordering::Acquire) {
            (self.on_change)(server);
        }
    }
}

/// The MCP servers of one session. Each server starts in the background, and its task holds its connection until the
/// server ends. A drop stops each server.
pub struct Servers {
    shared: Arc<Shared>,
    /// The number of servers that still start or wait for the trust.
    starting: watch::Receiver<usize>,
    media: Arc<dyn MediaStore>,
}

impl std::fmt::Debug for Servers {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Servers")
            .field("states", &self.states())
            .finish_non_exhaustive()
    }
}

impl Servers {
    /// Start each server of `user` in the background. Each server of `project` replaces a user server of its name, and
    /// waits in [`McpServerState::Untrusted`] until `trust` answers; a `true` starts it. `trust` runs only when a
    /// project server can start. `variable` gives the values of the variables of the config. A server without its own
    /// folder runs in `folder`. `media` stores the attachments of the results. `on_change` gets each later state of a
    /// server: the end of its start, the start after the trust, and its stop.
    pub fn start(
        user: &[(String, ServerConfig)],
        project: &[(String, ServerConfig)],
        trust: impl Future<Output = bool> + Send + 'static,
        variable: &dyn Fn(&str) -> Option<String>,
        folder: &Path,
        media: Arc<dyn MediaStore>,
        on_change: OnChange,
    ) -> Servers {
        let overridden: HashSet<&str> = project.iter().map(|(name, _)| name.as_str()).collect();
        let user = user.iter().filter(|(name, _)| !overridden.contains(name.as_str()));
        let entries = user
            .map(|entry| (McpServerSource::User, entry))
            .chain(project.iter().map(|entry| (McpServerSource::Project, entry)));
        let mut slots = Vec::new();
        let (mut launches, mut gated) = (Vec::new(), Vec::new());
        for (index, (source, (name, config))) in entries.enumerate() {
            let state = match config.enabled.then(|| config.command(variable, folder)) {
                None => McpServerState::Disabled,
                Some(Ok(process)) => match source {
                    McpServerSource::User => {
                        launches.push((index, process));
                        McpServerState::Connecting
                    }
                    McpServerSource::Project => {
                        gated.push((index, process));
                        McpServerState::Untrusted
                    }
                },
                Some(Err(error)) => McpServerState::Failed { error },
            };
            slots.push(Slot {
                name: name.clone(),
                source,
                state,
                peer: None,
                stop: None,
                tools: Vec::new(),
            });
        }
        let shared = Arc::new(Shared {
            slots: Mutex::new(slots),
            on_change,
            closed: AtomicBool::new(false),
            tasks: Mutex::default(),
        });
        let (count, starting) = watch::channel(launches.len() + gated.len());
        let count = Arc::new(count);
        let mut tasks = lock(&shared.tasks);
        for (index, process) in launches {
            let (task_shared, count) = (Arc::clone(&shared), Arc::clone(&count));
            tasks.push((Some(index), tokio::spawn(run(index, process, task_shared, count))));
        }
        if !gated.is_empty() {
            let (task_shared, count) = (Arc::clone(&shared), Arc::clone(&count));
            tasks.push((None, tokio::spawn(start_trusted(gated, trust, task_shared, count))));
        }
        drop(tasks);
        Servers {
            shared,
            starting,
            media,
        }
    }

    /// Wait until no server starts.
    pub async fn ready(&self) {
        let mut starting = self.starting.clone();
        match starting.wait_for(|starting| *starting == 0).await {
            // The tasks hold the sender, so its drop means that each task ended and no server starts.
            Ok(_) | Err(_) => {}
        }
    }

    /// Each server and its state, in config order.
    pub fn states(&self) -> Vec<McpServer> {
        lock(&self.shared.slots).iter().map(Slot::server).collect()
    }

    /// The tools of the running servers, each deferred, with its definition. A tool whose name an earlier tool has gets
    /// the name with the hash.
    pub fn tools(&self) -> Vec<(ToolDefinition, McpTool)> {
        let slots = lock(&self.shared.slots);
        let mut names = HashSet::new();
        let mut tools = Vec::new();
        for slot in slots.iter() {
            let Some(peer) = &slot.peer else {
                continue;
            };
            for info in &slot.tools {
                let mut name = tool_name(&slot.name, &info.name);
                if names.contains(&name) {
                    name = hashed_name(&slot.name, &info.name);
                }
                // Two raw names with one hash are too rare to name a third way.
                if !names.insert(name.clone()) {
                    continue;
                }
                let definition = ToolDefinition {
                    name,
                    description: info.description.as_deref().unwrap_or_default().to_owned(),
                    input_schema: serde_json::Value::Object((*info.input_schema).clone()).to_string(),
                    defer_loading: false,
                }
                .deferred();
                let tool = McpTool {
                    peer: peer.clone(),
                    name: info.name.to_string(),
                    media: Arc::clone(&self.media),
                };
                tools.push((definition, tool));
            }
        }
        tools
    }

    /// Stop each server, and wait for its end. A running server closes its connection, and a server that still starts
    /// stops its start.
    pub async fn close(&self) {
        let tasks = {
            let mut tasks = lock(&self.shared.tasks);
            self.shared.closed.store(true, Ordering::Release);
            std::mem::take(&mut *tasks)
        };
        let mut stops: Vec<_> = lock(&self.shared.slots)
            .iter_mut()
            .map(|slot| slot.stop.take())
            .collect();
        for (index, task) in tasks {
            match index.and_then(|index| stops.get_mut(index)).and_then(Option::take) {
                // The task ends after the cleanup of the connection.
                Some(stop) => stop.cancel(),
                None => task.abort(),
            }
            match task.await {
                // An aborted start dropped its program, and a cancelled connection closed it.
                Ok(()) | Err(_) => {}
            }
        }
    }
}

impl Drop for Servers {
    fn drop(&mut self) {
        for (_, task) in lock(&self.shared.tasks).iter() {
            task.abort();
        }
    }
}

/// Wait for `trust`, then start each server of `gated` when it is `true`. A server that does not start stays untrusted.
async fn start_trusted(
    gated: Vec<(usize, tokio::process::Command)>,
    trust: impl Future<Output = bool>,
    shared: Arc<Shared>,
    count: Arc<watch::Sender<usize>>,
) {
    let trusted = trust.await;
    for (index, process) in gated {
        let mut tasks = lock(&shared.tasks);
        if !trusted || shared.closed.load(Ordering::Acquire) {
            count.send_modify(|starting| *starting -= 1);
            continue;
        }
        shared.update(index, |slot| slot.state = McpServerState::Connecting);
        let (task_shared, count) = (Arc::clone(&shared), Arc::clone(&count));
        tasks.push((Some(index), tokio::spawn(run(index, process, task_shared, count))));
    }
}

/// Start the server of the slot `index` with `process`, and hold its connection until the server ends.
async fn run(index: usize, process: tokio::process::Command, shared: Arc<Shared>, count: Arc<watch::Sender<usize>>) {
    let connected = connect(process).await;
    let connection = match connected {
        Ok((client, tools, program)) => {
            shared.update(index, |slot| {
                slot.state = McpServerState::Connected { tools: tools.len() };
                slot.peer = Some(client.peer().clone());
                slot.stop = Some(client.cancellation_token());
                slot.tools = tools;
            });
            Some((client, program))
        }
        Err(error) => {
            shared.update(index, |slot| slot.state = McpServerState::Failed { error });
            None
        }
    };
    count.send_modify(|starting| *starting -= 1);
    let Some((client, program)) = connection else {
        return;
    };
    // The connection ends when the server ends or a close cancels it.
    match client.waiting().await {
        Ok(_) | Err(_) => {}
    }
    let log = program.end().await;
    shared.update(index, |slot| {
        slot.peer = None;
        slot.stop = None;
        slot.tools.clear();
        slot.state = McpServerState::Failed {
            error: with_log("the server stopped".to_owned(), &log),
        };
    });
}

/// Start the program of `process`, agree on the protocol, and list its tools. The error of a failed start holds the
/// last stderr lines of the program.
async fn connect(process: tokio::process::Command) -> Result<(Client, Vec<McpToolInfo>, Program), String> {
    // A wrapper such as `npx` starts the real server as its child. In a session of its own, a kill of the server stops
    // the whole group.
    let mut process = CommandWrap::from(process);
    process.wrap(ProcessSession);
    let (transport, stderr) = TokioChildProcess::builder(process)
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("the server did not start: {error}"))?;
    let program = Program {
        // In a session of its own, the server leads its group.
        group: transport.id().and_then(|id| Pid::from_raw(i32::try_from(id).ok()?)),
        log: stderr.map(|stderr| tokio::spawn(read_log(stderr))),
    };
    match agree(transport).await {
        Ok((client, tools)) => Ok((client, tools, program)),
        Err(error) => Err(with_log(error, &program.end().await)),
    }
}

/// Agree on the protocol with the server of `transport`, and list its tools.
async fn agree(transport: TokioChildProcess) -> Result<(Client, Vec<McpToolInfo>), String> {
    // Each server of this era speaks `initialize`. A version without it needs the newer requests that yuke lacks yet.
    let config = ClientConfig::new(
        ClientCapabilities::default(),
        Implementation::new("yuke", env!("CARGO_PKG_VERSION")),
    )
    .with_protocol_version(ProtocolVersion::LATEST_WITH_INITIALIZE);
    let client = config
        .serve(transport)
        .await
        .map_err(|error| format!("the server did not initialize: {error}"))?;
    let tools = client
        .list_all_tools()
        .await
        .map_err(|error| format!("the server did not list its tools: {error}"))?;
    Ok((client, tools))
}

/// The program of a server: its process group and the reader of its stderr.
struct Program {
    group: Option<Pid>,
    log: Option<JoinHandle<String>>,
}

impl Program {
    /// Kill each process that remains in the group, and give the last lines of the stderr. A child that outlives the
    /// server holds the stderr open, so the kill comes first.
    async fn end(self) -> String {
        if let Some(group) = self.group
            && kill_process_group(group, Signal::KILL).is_err()
        {
            // An empty group has nothing to kill, and macOS can refuse the kill of a group that empties.
        }
        match self.log {
            Some(log) => log.await.unwrap_or_default(),
            None => String::new(),
        }
    }
}

/// Read `stderr` to its end, and give its last [`LOG_LINES`] lines that are not blank, each cut to
/// [`LOG_LINE_BYTES`]. The read never stops early, so the pipe never fills and the server never blocks.
async fn read_log(mut stderr: ChildStderr) -> String {
    let mut lines = VecDeque::new();
    let mut line = Vec::new();
    let mut chunk = [0; 4096];
    // A read error ends the log as its end does.
    while let Ok(read @ 1..) = stderr.read(&mut chunk).await {
        for &byte in &chunk[..read] {
            if byte == b'\n' {
                keep_line(&mut lines, std::mem::take(&mut line));
            } else if line.len() < LOG_LINE_BYTES {
                line.push(byte);
            }
        }
    }
    keep_line(&mut lines, line);
    lines
        .iter()
        .map(|line| String::from_utf8_lossy(line))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Add `line` to the last `lines` when it is not blank.
fn keep_line(lines: &mut VecDeque<Vec<u8>>, line: Vec<u8>) {
    if line.trim_ascii().is_empty() {
        return;
    }
    if lines.len() == LOG_LINES {
        lines.pop_front();
    }
    lines.push_back(line);
}

/// `error` with the last stderr lines of its server, when the server wrote any.
fn with_log(error: String, log: &str) -> String {
    if log.is_empty() {
        error
    } else {
        format!("{error}\n{log}")
    }
}

/// One tool of a server, for the engine. A cancel of a call sends `notifications/cancelled` to the server.
pub struct McpTool {
    peer: Peer<RoleClient>,
    /// The name of the tool on its server.
    name: String,
    media: Arc<dyn MediaStore>,
}

impl std::fmt::Debug for McpTool {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("McpTool")
            .field("name", &self.name)
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl Tool for McpTool {
    async fn call(&self, arguments: &str, context: &ToolContext<'_>) -> Result<ToolContent, String> {
        let arguments: JsonObject = parse_arguments(arguments)?;
        let params = CallToolRequestParams::new(self.name.clone()).with_arguments(arguments);
        let request = ClientRequest::CallToolRequest(CallToolRequest::new(params));
        let mut handle = self
            .peer
            .send_cancellable_request(request, PeerRequestOptions::no_options())
            .await
            .map_err(|error| format!("The server failed: {error}"))?;
        let answer = tokio::select! {
            answer = &mut handle.rx => answer,
            () = context.cancellation_token().cancelled() => {
                let mut text = "The user cancelled the call.".to_owned();
                if let Err(error) = handle.cancel(Some("the user cancelled the turn".to_owned())).await {
                    text = format!("{text} The server did not get the cancel: {error}");
                }
                return Ok(ToolContent { text, media: Vec::new(), is_error: true });
            }
        };
        match answer {
            Ok(Ok(ServerResult::CallToolResult(result))) => Ok(content(result, &*self.media).await),
            Ok(Ok(_)) => Err("The server answered with another kind of result.".to_owned()),
            Ok(Err(error)) => Err(format!("The server failed: {error}")),
            Err(_) => Err("The server closed before its answer.".to_owned()),
        }
    }
}

/// The result of a call as the model reads it: the texts, the images as attachments, and a line for each other block.
/// The structured content becomes the text when the result has no text.
async fn content(result: CallToolResult, media: &dyn MediaStore) -> ToolContent {
    let mut texts = Vec::new();
    let mut attachments = Vec::new();
    for block in result.content {
        match block {
            ContentBlock::Text(text) => texts.push(text.text),
            ContentBlock::Image(image) => match image_of(&image.data, media).await {
                Ok(blob) => attachments.push(Media::new(blob, image.mime_type)),
                Err(error) => texts.push(format!("[an image of type {} was lost: {error}]", image.mime_type)),
            },
            ContentBlock::Audio(audio) => texts.push(format!("[audio of type {}]", audio.mime_type)),
            ContentBlock::Resource(resource) => texts.push(match resource.resource {
                ResourceContents::TextResourceContents { text, .. } => text,
                ResourceContents::BlobResourceContents { uri, mime_type, .. } => {
                    format!("[resource {uri} of type {}]", mime_type.unwrap_or_default())
                }
                _ => "[a resource of a kind that yuke does not know]".to_owned(),
            }),
            ContentBlock::ResourceLink(link) => texts.push(format!("[resource link {} ({})]", link.uri, link.name)),
            _ => texts.push("[content of a kind that yuke does not know]".to_owned()),
        }
    }
    if texts.is_empty()
        && let Some(structured) = result.structured_content
    {
        texts.push(structured.to_string());
    }
    ToolContent {
        text: texts.join("\n"),
        media: attachments,
        is_error: result.is_error == Some(true),
    }
}

/// Store the base64 image `data`.
async fn image_of(data: &str, media: &dyn MediaStore) -> Result<Blob, String> {
    let bytes = yuke_ai::decode_base64(data.as_bytes()).ok_or("its data is not base64")?;
    if bytes.len() as u64 > MAX_MEDIA_BYTES {
        return Err(format!("it is larger than the limit of {MAX_MEDIA_BYTES} bytes"));
    }
    media.put_media(bytes).await
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    // A panic of another holder leaves the slots valid.
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
