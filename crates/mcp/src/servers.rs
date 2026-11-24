//! The MCP servers of one session: their connections, their states, and their tools.

use std::cell::Cell;
use std::cell::RefCell;
use std::collections::{HashSet, VecDeque};
use std::path::Path;
use std::process::Stdio;
use std::rc::Rc;
use std::sync::Arc;

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD_PAD_INDIFFERENT;
use process_wrap::tokio::{CommandWrap, ProcessSession};
use rmcp::model::{
    CallToolRequest, CallToolRequestParams, CallToolResult, ClientCapabilities, ClientConfig, ClientRequest,
    ContentBlock, Implementation, JsonObject, ProtocolVersion, ResourceContents, ServerResult, Tool as McpToolInfo,
};
use rmcp::service::{PeerRequestOptions, RunningService, RunningServiceCancellationToken};
use rmcp::transport::streamable_http_client::StreamableHttpClientTransportConfig;
use rmcp::transport::{IntoTransport, StreamableHttpClientTransport, TokioChildProcess};
use rmcp::{Peer, RoleClient, ServiceExt};
use rustix::process::{Pid, Signal, kill_process_group};
use tokio::io::AsyncReadExt;
use tokio::process::{ChildStderr, Command};
use tokio::sync::watch;
use tokio::task::JoinHandle;
use yuke_ai::{Blob, Media, ToolDefinition};
use yuke_engine::{MediaStore, Tool, ToolContent, ToolContext, ToolHints, parse_arguments};
use yuke_http::http::header::AUTHORIZATION;
use yuke_protocol::{McpServer, McpServerSource, McpServerState};

use crate::config::{Launch, Remote, ServerConfig};
use crate::http::HttpClient;
use crate::names::{hashed_name, tool_name};
use crate::oauth::{Auth, PendingLogin};

/// The connection to one running server.
type Client = RunningService<RoleClient, ClientConfig>;

/// The number of the last stderr lines of a server that its failure shows.
const LOG_LINES: usize = 20;

/// The longest stderr line of a server that its failure shows, in bytes. A longer line is cut.
const LOG_LINE_BYTES: usize = 500;

/// Receives each change of the state of a server. It must not wait, and it must not call the [`Servers`].
pub type OnChange = Rc<dyn Fn(McpServer)>;

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
    /// The connection of a remote server, to connect again after its login.
    remote: Option<Remote>,
    /// The login of a remote server.
    auth: Option<Arc<Auth>>,
}

/// What the servers and their tasks share.
struct Shared {
    slots: RefCell<Vec<Slot>>,
    http: Arc<yuke_http::Client>,
    on_change: OnChange,
    /// The number of servers that still start or wait for the trust.
    starting: watch::Sender<usize>,
    /// After a close, a stop is no news and no gated server starts.
    closed: Cell<bool>,
    /// The task of each started server, by its slot index. The trust task has no index.
    tasks: RefCell<Vec<(Option<usize>, JoinHandle<()>)>>,
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
    /// Change the slot `index` with `change`, and report its new state after the borrow ends.
    fn update(&self, index: usize, change: impl FnOnce(&mut Slot)) {
        let server = {
            let mut slots = self.slots.borrow_mut();
            let slot = &mut slots[index];
            change(slot);
            slot.server()
        };
        if !self.closed.get() {
            (self.on_change)(server);
        }
    }
}

/// The MCP servers of one session. Each server starts in the background, and its task holds its connection until the
/// server ends. A drop stops each server.
pub struct Servers {
    shared: Rc<Shared>,
    media: Rc<dyn MediaStore>,
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
    /// folder runs in `folder`. `media` stores the attachments of the results. `http` sends the requests of the remote
    /// servers, and `data` is the folder of their stored logins. `on_change` gets each later state of a server: the end
    /// of its start, the start after the trust, and its stop.
    ///
    /// # Panics
    ///
    /// Panics outside a tokio local runtime or local task set when a server can start.
    #[expect(
        clippy::too_many_arguments,
        reason = "each argument is an independent input of the start"
    )]
    pub fn start(
        user: &[(String, ServerConfig)],
        project: &[(String, ServerConfig)],
        trust: impl Future<Output = bool> + 'static,
        variable: &dyn Fn(&str) -> Option<String>,
        folder: &Path,
        data: &Path,
        media: Rc<dyn MediaStore>,
        http: Arc<yuke_http::Client>,
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
            let (mut remote, mut auth) = (None, None);
            let state = match config.enabled.then(|| config.launch(variable, folder)) {
                None => McpServerState::Disabled,
                Some(Ok(launch)) => {
                    if let Launch::Remote(launch) = &launch {
                        auth = Some(Arc::new(Auth::new(Arc::clone(&http), data, launch)));
                        remote = Some(launch.clone());
                    }
                    match source {
                        McpServerSource::User => {
                            launches.push((index, launch));
                            McpServerState::Connecting
                        }
                        McpServerSource::Project => {
                            gated.push((index, launch));
                            McpServerState::Untrusted
                        }
                    }
                }
                Some(Err(error)) => McpServerState::Failed { error },
            };
            slots.push(Slot {
                name: name.clone(),
                source,
                state,
                peer: None,
                stop: None,
                tools: Vec::new(),
                remote,
                auth,
            });
        }
        let shared = Rc::new(Shared {
            slots: RefCell::new(slots),
            http,
            on_change,
            starting: watch::channel(launches.len() + gated.len()).0,
            closed: Cell::new(false),
            tasks: RefCell::default(),
        });
        let mut tasks = shared.tasks.borrow_mut();
        for (index, launch) in launches {
            tasks.push((
                Some(index),
                tokio::task::spawn_local(run(index, launch, Rc::clone(&shared))),
            ));
        }
        if !gated.is_empty() {
            tasks.push((
                None,
                tokio::task::spawn_local(start_trusted(gated, trust, Rc::clone(&shared))),
            ));
        }
        drop(tasks);
        Servers { shared, media }
    }

    /// Wait until no server starts.
    pub async fn ready(&self) {
        let mut starting = self.shared.starting.subscribe();
        _ = starting.wait_for(|starting| *starting == 0).await;
    }

    /// Start the login of the server `name`, which is in the state [`McpServerState::NeedsLogin`]. The user opens the
    /// [`PendingLogin::url`]. The future ends when the login ends. After a success, the server connects again: its
    /// state changes to `Connecting`, and then to `Connected` or `Failed`. A drop of the future ends the login.
    ///
    /// # Errors
    ///
    /// Returns why the login cannot start: the server does not exist or does not need a login, or its OAuth metadata
    /// does not allow a login.
    ///
    /// # Panics
    ///
    /// Panics when the future runs outside a tokio local runtime or local task set.
    pub async fn login(
        &self,
        name: &str,
    ) -> Result<(PendingLogin, impl Future<Output = Result<(), String>> + use<>), String> {
        let (index, auth) = {
            let slots = self.shared.slots.borrow();
            let Some((index, slot)) = slots.iter().enumerate().find(|(_, slot)| slot.name == name) else {
                return Err(format!("there is no server {name}"));
            };
            match (&slot.auth, &slot.state) {
                (Some(auth), McpServerState::NeedsLogin) => (index, Arc::clone(auth)),
                _ => return Err(format!("the server {name} does not need a login")),
            }
        };
        let (login, outcome) = auth.login().await?;
        let shared = Rc::clone(&self.shared);
        let outcome = async move {
            outcome.await?;
            reconnect(&shared, index);
            Ok(())
        };
        Ok((login, outcome))
    }

    /// Remove the stored login of the remote server `name`. A server that had a login stops, and it needs a login
    /// again.
    ///
    /// # Errors
    ///
    /// Returns an error when the server is not a remote server, or when the stored logins do not read or write.
    pub async fn logout(&self, name: &str) -> Result<(), String> {
        let auth = {
            let slots = self.shared.slots.borrow();
            slots
                .iter()
                .find(|slot| slot.name == name)
                .and_then(|slot| slot.auth.clone())
        };
        auth.ok_or_else(|| format!("{name} is not a remote server"))?
            .logout()
            .await
    }

    /// Each server and its state, in config order.
    pub fn states(&self) -> Vec<McpServer> {
        self.shared.slots.borrow().iter().map(Slot::server).collect()
    }

    /// The tools of the running servers, each deferred, with its definition. A tool whose name an earlier tool has gets
    /// the name with the hash.
    pub fn tools(&self) -> Vec<(ToolDefinition, McpTool)> {
        let slots = self.shared.slots.borrow();
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
                    // MCP has no subject or preview hint, so only the title is set, and the preview stays `head`.
                    title: info.title.clone().or_else(|| {
                        info.annotations
                            .as_ref()
                            .and_then(|annotations| annotations.title.clone())
                    }),
                    media: Rc::clone(&self.media),
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
            let mut tasks = self.shared.tasks.borrow_mut();
            self.shared.closed.set(true);
            std::mem::take(&mut *tasks)
        };
        let mut stops: Vec<_> = self
            .shared
            .slots
            .borrow_mut()
            .iter_mut()
            .map(|slot| slot.stop.take())
            .collect();
        for (index, task) in tasks {
            match index.and_then(|index| stops.get_mut(index)).and_then(Option::take) {
                // The task ends after the cleanup of the connection.
                Some(stop) => stop.cancel(),
                None => task.abort(),
            }
            // An aborted start dropped its program, and a cancelled connection closed it.
            _ = task.await;
        }
        // An aborted start never ended its count.
        self.shared.starting.send_replace(0);
    }
}

impl Drop for Servers {
    fn drop(&mut self) {
        for (_, task) in self.shared.tasks.borrow().iter() {
            task.abort();
        }
    }
}

/// Wait for `trust`, then start each server of `gated` when it is `true`. A server that does not start stays untrusted.
async fn start_trusted(gated: Vec<(usize, Launch)>, trust: impl Future<Output = bool>, shared: Rc<Shared>) {
    let trusted = trust.await;
    for (index, launch) in gated {
        if !trusted || shared.closed.get() {
            shared.starting.send_modify(|starting| *starting -= 1);
            continue;
        }
        shared.update(index, |slot| slot.state = McpServerState::Connecting);
        let task = tokio::task::spawn_local(run(index, launch, Rc::clone(&shared)));
        shared.tasks.borrow_mut().push((Some(index), task));
    }
}

/// Start the server of the slot `index` again after its login.
fn reconnect(shared: &Rc<Shared>, index: usize) {
    let remote = {
        let slots = shared.slots.borrow();
        let slot = &slots[index];
        // A second login of the same server finds the state changed already.
        match &slot.remote {
            Some(remote) if slot.state == McpServerState::NeedsLogin && !shared.closed.get() => remote.clone(),
            _ => return,
        }
    };
    shared.starting.send_modify(|starting| *starting += 1);
    shared.update(index, |slot| slot.state = McpServerState::Connecting);
    let task = tokio::task::spawn_local(run(index, Launch::Remote(remote), Rc::clone(shared)));
    let mut tasks = shared.tasks.borrow_mut();
    // The task of the failed start ended, and `close` needs the new task at the index.
    tasks.retain(|(task_index, _)| *task_index != Some(index));
    tasks.push((Some(index), task));
}

/// Start the server of the slot `index` with `launch`, and hold its connection until the server ends.
async fn run(index: usize, launch: Launch, shared: Rc<Shared>) {
    let auth = shared.slots.borrow()[index].auth.clone();
    let connected = match launch {
        Launch::Process(process) => connect(process).await.map_err(|error| McpServerState::Failed { error }),
        Launch::Remote(remote) => connect_remote(remote, auth.clone(), &shared)
            .await
            .map(|(client, tools)| {
                // A remote server has no process and no stderr.
                (client, tools, Program { group: None, log: None })
            }),
    };
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
        Err(state) => {
            shared.update(index, |slot| slot.state = state);
            None
        }
    };
    shared.starting.send_modify(|starting| *starting -= 1);
    let Some((client, program)) = connection else {
        return;
    };
    // The connection ends when the server ends, when a close cancels it, or when the server needs a login again.
    let stop = client.cancellation_token();
    let mut waiting = std::pin::pin!(client.waiting());
    let login_lost = async {
        match &auth {
            Some(auth) => auth.wait_for_needs_login().await,
            None => std::future::pending().await,
        }
    };
    let needs_login = tokio::select! {
        _ = &mut waiting => false,
        () = login_lost => {
            stop.cancel();
            _ = waiting.await;
            true
        }
    };
    let log = program.end().await;
    shared.update(index, |slot| {
        slot.peer = None;
        slot.stop = None;
        slot.tools.clear();
        slot.state = if needs_login {
            McpServerState::NeedsLogin
        } else {
            McpServerState::Failed {
                error: with_log("the server stopped".to_owned(), &log),
            }
        };
    });
}

/// Connect to the URL of `remote`. Then agree on the protocol, and list the tools. A server that needs a login ends
/// in [`McpServerState::NeedsLogin`].
async fn connect_remote(
    remote: Remote,
    auth: Option<Arc<Auth>>,
    shared: &Shared,
) -> Result<(Client, Vec<McpToolInfo>), McpServerState> {
    // A static `authorization` header of the config replaces the OAuth login.
    let auth = auth.filter(|_| !remote.headers.contains_key(&AUTHORIZATION));
    if let Some(auth) = &auth {
        auth.set_needs_login(false);
    }
    let http = HttpClient {
        client: Arc::clone(&shared.http),
        auth: auth.clone(),
    };
    let config = StreamableHttpClientTransportConfig::with_uri(remote.url).custom_headers(remote.headers);
    agree(StreamableHttpClientTransport::with_client(http, config))
        .await
        .map_err(|error| {
            if auth.is_some_and(|auth| auth.needs_login()) {
                McpServerState::NeedsLogin
            } else {
                McpServerState::Failed { error }
            }
        })
}

/// Start the program `process`. Then agree on the protocol, and list the tools. The error of a failed start holds the
/// last stderr lines of the program.
async fn connect(process: Command) -> Result<(Client, Vec<McpToolInfo>, Program), String> {
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
async fn agree<E, A>(transport: impl IntoTransport<RoleClient, E, A>) -> Result<(Client, Vec<McpToolInfo>), String>
where
    E: std::error::Error + Send + Sync + 'static,
{
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
    /// The title of the tool for a person, from the tool or from its annotations.
    title: Option<String>,
    media: Rc<dyn MediaStore>,
}

impl std::fmt::Debug for McpTool {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("McpTool")
            .field("name", &self.name)
            .finish_non_exhaustive()
    }
}

#[async_trait(?Send)]
impl Tool for McpTool {
    fn hints(&self) -> ToolHints {
        ToolHints {
            title: self.title.clone(),
            ..ToolHints::default()
        }
    }

    async fn call(
        &self,
        arguments: &str,
        context: &ToolContext<'_>,
    ) -> Result<ToolContent, Box<dyn std::error::Error + Send + Sync>> {
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
                return Ok(ToolContent {
                    text,
                    is_error: true,
                    ..ToolContent::default()
                });
            }
        };
        match answer {
            Ok(Ok(ServerResult::CallToolResult(result))) => Ok(content(result, &*self.media).await),
            Ok(Ok(_)) => Err("The server answered with another kind of result.".into()),
            Ok(Err(error)) => Err(format!("The server failed: {error}").into()),
            Err(_) => Err("The server closed before its answer.".into()),
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
                Err(error) => texts.push(format!(
                    "[an image of type {} was lost: {}]",
                    image.mime_type,
                    yuke_engine::chain_text(error.as_ref())
                )),
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
        display: Vec::new(),
    }
}

/// Store the base64 image `data`. The padding is optional.
async fn image_of(data: &str, media: &dyn MediaStore) -> Result<Blob, Box<dyn std::error::Error + Send + Sync>> {
    let bytes = STANDARD_PAD_INDIFFERENT
        .decode(data)
        .map_err(|_| "its data is not base64")?;
    media.put_media(bytes).await
}
