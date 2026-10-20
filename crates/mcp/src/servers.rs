//! The MCP servers of one session: their connections, their states, and their tools.

use std::collections::HashSet;
use std::path::Path;
use std::process::Stdio;
use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use rmcp::model::{
    CallToolRequest, CallToolRequestParams, CallToolResult, ClientCapabilities, ClientConfig, ClientRequest,
    ContentBlock, Implementation, JsonObject, ProtocolVersion, ResourceContents, ServerResult, Tool as McpToolInfo,
};
use rmcp::service::{PeerRequestOptions, RunningService};
use rmcp::transport::TokioChildProcess;
use rmcp::{Peer, RoleClient, ServiceExt};
use tokio::sync::watch;
use tokio::task::JoinHandle;
use yuke_ai::{Blob, MAX_MEDIA_BYTES, Media, ToolDefinition};
use yuke_engine::{MediaStore, Tool, ToolContent, ToolContext, parse_arguments};

use crate::config::{Launch, ServerConfig};

/// The connection to one running server.
type Client = RunningService<RoleClient, ClientConfig>;
use crate::names::{hashed_name, tool_name};

/// The state of one server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerState {
    /// The server starts.
    Connecting,
    /// The server runs, with this many tools.
    Connected {
        /// The number of its tools.
        tools: usize,
    },
    /// The server did not start, or it stopped.
    Failed {
        /// Why.
        error: String,
    },
    /// The config turns the server off.
    Disabled,
}

/// One server of the session.
struct Slot {
    name: String,
    state: ServerState,
    /// The connection while the server runs.
    client: Option<Client>,
    tools: Vec<McpToolInfo>,
}

/// The MCP servers of one session. Each server starts in the background. A drop stops each server.
pub struct Servers {
    slots: Arc<Mutex<Vec<Slot>>>,
    /// The number of servers that still start.
    starting: watch::Receiver<usize>,
    media: Arc<dyn MediaStore>,
    tasks: Vec<JoinHandle<()>>,
}

impl std::fmt::Debug for Servers {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Servers")
            .field("states", &self.states())
            .finish_non_exhaustive()
    }
}

impl Servers {
    /// Start each server of `servers` in the background. `variable` gives the values of the variables of the config.
    /// A stdio server without its own folder runs in `folder`. `media` stores the attachments of the results.
    pub fn start(
        servers: Vec<(String, ServerConfig)>,
        variable: &dyn Fn(&str) -> Option<String>,
        folder: &Path,
        media: Arc<dyn MediaStore>,
    ) -> Servers {
        let mut slots = Vec::new();
        let mut launches = Vec::new();
        for (index, (name, config)) in servers.into_iter().enumerate() {
            let launch = config.enabled.then(|| config.launch(variable));
            let state = match launch {
                None => ServerState::Disabled,
                Some(Ok(Launch {
                    command,
                    args,
                    env,
                    cwd,
                })) => {
                    let mut process = tokio::process::Command::new(command);
                    process
                        .args(args)
                        .envs(env)
                        .current_dir(folder.join(cwd.unwrap_or_default()));
                    launches.push((index, process));
                    ServerState::Connecting
                }
                Some(Err(error)) => ServerState::Failed {
                    error: error.to_string(),
                },
            };
            slots.push(Slot {
                name,
                state,
                client: None,
                tools: Vec::new(),
            });
        }
        let slots = Arc::new(Mutex::new(slots));
        let (count, starting) = watch::channel(launches.len());
        let count = Arc::new(count);
        let tasks = launches
            .into_iter()
            .map(|(index, process)| {
                let (slots, count) = (Arc::clone(&slots), Arc::clone(&count));
                tokio::spawn(async move {
                    let connected = connect(process).await;
                    let mut slots = lock(&slots);
                    let slot = &mut slots[index];
                    match connected {
                        Ok((client, tools)) => {
                            slot.state = ServerState::Connected { tools: tools.len() };
                            slot.client = Some(client);
                            slot.tools = tools;
                        }
                        Err(error) => slot.state = ServerState::Failed { error },
                    }
                    count.send_modify(|starting| *starting -= 1);
                })
            })
            .collect();
        Servers {
            slots,
            starting,
            media,
            tasks,
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

    /// The name and the state of each server, in config order.
    pub fn states(&self) -> Vec<(String, ServerState)> {
        let mut slots = lock(&self.slots);
        mark_stopped(&mut slots);
        slots
            .iter()
            .map(|slot| (slot.name.clone(), slot.state.clone()))
            .collect()
    }

    /// The tools of the running servers, each deferred, with its definition. A tool whose name an earlier tool has gets
    /// the name with the hash.
    pub fn tools(&self) -> Vec<(ToolDefinition, McpTool)> {
        let mut slots = lock(&self.slots);
        mark_stopped(&mut slots);
        let mut names = HashSet::new();
        let mut tools = Vec::new();
        for slot in slots.iter() {
            let Some(client) = &slot.client else {
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
                    peer: client.peer().clone(),
                    name: info.name.to_string(),
                    media: Arc::clone(&self.media),
                };
                tools.push((definition, tool));
            }
        }
        tools
    }

    /// Stop each server, and wait for its end.
    pub async fn close(mut self) {
        for task in &self.tasks {
            task.abort();
        }
        // The end of a task drops its start, so the program of an unfinished start has stopped too.
        for task in self.tasks.drain(..) {
            match task.await {
                Ok(()) | Err(_) => {}
            }
        }
        let clients: Vec<_> = lock(&self.slots)
            .iter_mut()
            .filter_map(|slot| slot.client.take())
            .collect();
        for client in clients {
            match client.cancel().await {
                // A failed service task has stopped its server already.
                Ok(_) | Err(_) => {}
            }
        }
    }
}

impl Drop for Servers {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

/// Mark each server whose connection closed as failed, and drop its tools.
fn mark_stopped(slots: &mut [Slot]) {
    for slot in slots {
        // The service loop drops its receiver when the server ends, also without a cancel.
        let closed = |client: &Client| client.is_closed() || client.peer().is_transport_closed();
        if slot.client.as_ref().is_some_and(closed) {
            slot.client = None;
            slot.tools.clear();
            slot.state = ServerState::Failed {
                error: "the server stopped".to_owned(),
            };
        }
    }
}

/// Start the program of `process`, agree on the protocol, and list its tools.
async fn connect(process: tokio::process::Command) -> Result<(Client, Vec<McpToolInfo>), String> {
    // The log of a server is no message; a later version can keep its last lines for a failure.
    let (transport, _stderr) = TokioChildProcess::builder(process)
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("the server did not start: {error}"))?;
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
