//! The tool bridge: a tool that JavaScript defines is an engine [`Tool`] of each session that has it.

use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::convert::Infallible;
use std::fmt;
use std::path::{Path, PathBuf};
use std::pin::pin;
use std::rc::Rc;

use async_trait::async_trait;
use rquickjs::{Ctx, FromJs, Function, IntoJs, Object, Persistent, Value};
use serde::Serialize;
use serde::de::DeserializeOwned;
use tokio::sync::mpsc;
use yuke_engine::{
    CancellationToken, Concurrency, DisplayBlock, MediaStore, Tool, ToolContent, ToolContext, ToolHints,
    check_tool_name,
};

use crate::error::{Error, caught};
use crate::models::Attachment;
use crate::native::{Operation, call};
use crate::processes::Processes;
use crate::runtime::EngineAccess;

/// What the tools of one session need from the consumer. One process can serve sessions of several workspaces at
/// once, so each session gives its own host. Give the same host to every
/// [`Handle::open_session`](crate::Handle::open_session) of a session, also after a reload or a change of its folder:
/// a job holds the host that started it, and reports to that host. The host stores the attachments of the session as a [`MediaStore`], for
/// example an image that a tool read.
#[async_trait(?Send)]
pub trait SessionHost: MediaStore {
    /// The id of the session. A tool gets it as `sessionId`.
    fn session_id(&self) -> yuke_protocol::SessionId;

    /// The parent session.
    fn parent(&self) -> Option<yuke_protocol::SessionId>;

    /// The workspace folder of the session now. Relative paths and commands of the tools start here.
    fn folder(&self) -> PathBuf;

    /// Whether the session closed. A close must set this before it stops the jobs of the session. A job start then fails.
    fn is_closed(&self) -> bool;

    /// A background job of the session started or ended. The call must not wait.
    fn job_changed(&self, job: yuke_protocol::Job);

    /// Accept `input` as an input of the session, as an input of a client is. It starts a turn when the session is
    /// idle, and a running turn takes it after its round. The host reports a failure to the user. A job sends its end
    /// here, and a close and a shutdown wait for the return.
    async fn accept_input(&self, input: yuke_protocol::Input);

    /// Ask the user `request` for `source`, a plugin name, and wait for the answer. A cancel of `cancel`, the close of
    /// the session, and a run without a client answer [`yuke_protocol::InteractionResponse::Canceled`].
    async fn ask(
        &self,
        source: &str,
        request: yuke_protocol::InteractionRequest,
        cancel: CancellationToken,
    ) -> yuke_protocol::InteractionResponse;

    /// Send the request `request` of the plugin `extension` with `data` to the client, and wait for the answer. A drop of
    /// the future cancels the request.
    ///
    /// # Errors
    ///
    /// Returns a [`RequestFailure`] when the client answers an error, when no client can answer, or when the client
    /// disconnects before its answer.
    async fn request(
        &self,
        extension: &str,
        request: String,
        data: serde_json::Value,
    ) -> Result<serde_json::Value, RequestFailure>;

    /// The model of `reference`, with the credential of its provider, for one round that a `round.before` hook plans.
    ///
    /// # Errors
    ///
    /// Returns an error when the catalog has no such model, or when its provider has no credential.
    fn model(
        &self,
        reference: &yuke_protocol::ModelReference,
    ) -> Result<yuke_engine::Model, Box<dyn std::error::Error + Send + Sync>>;

    /// The settings of the session now. A saved change of the settings takes effect at once.
    fn settings(&self) -> yuke_protocol::SessionSettings;
}

/// Why a request of a plugin to the client failed.
#[derive(Debug)]
pub enum RequestFailure {
    /// The client answered with this error.
    Refused(yuke_protocol::ResponseError),
    /// No client can answer, as in `yuke -p`.
    NoClient,
    /// The client disconnected before its answer.
    Disconnected,
}

impl fmt::Display for RequestFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Refused(error) => f.write_str(&error.message),
            Self::NoClient => f.write_str("no client can answer the request"),
            Self::Disconnected => f.write_str("the client disconnected before its answer"),
        }
    }
}

impl std::error::Error for RequestFailure {}

/// The state of the engine task: the tools that the JavaScript defined, the open sessions, and the processes that
/// the calls start.
pub(crate) struct Registry {
    pub(crate) processes: Rc<Processes>,
    tools: RefCell<Vec<Registered>>,
    last_id: Cell<u64>,
    /// The open number of each open session.
    opens: RefCell<HashSet<u64>>,
    last_open: Cell<u64>,
}

/// The plugin and open session of a tool change. A built-in has no owner.
#[derive(Debug, FromJs)]
pub(crate) struct ToolOwner {
    pub(crate) open: u64,
    pub(crate) plugin: String,
}

/// A definition or name removal in registration order.
struct Registered {
    id: u64,
    owner: Option<ToolOwner>,
    change: ToolChange,
}

impl Registered {
    fn visible_in(&self, open: u64) -> bool {
        self.owner.as_ref().is_none_or(|owner| owner.open == open)
    }
}

/// One tool definition or name removal.
pub(crate) enum ToolChange {
    Define {
        definition: yuke_ai::ToolDefinition,
        concurrency: Concurrency,
        hints: ToolHints,
        start: Persistent<Function<'static>>,
    },
    Remove {
        name: String,
    },
}

impl ToolChange {
    fn name(&self) -> &str {
        match self {
            Self::Define { definition, .. } => &definition.name,
            Self::Remove { name } => name,
        }
    }
}

/// The id of a tool change and the plugin whose definition it replaces.
#[derive(IntoJs)]
pub(crate) struct Registration {
    pub(crate) id: u64,
    replaced: Option<String>,
}

impl Registry {
    pub(crate) fn new(processes: Rc<Processes>) -> Self {
        Self {
            processes,
            tools: RefCell::default(),
            last_id: Cell::default(),
            opens: RefCell::default(),
            last_open: Cell::default(),
        }
    }
    /// Add a tool change. An invalid name, a reserved name, or a closed session fails with its error text.
    pub(crate) fn add(&self, owner: Option<ToolOwner>, change: ToolChange) -> Result<Registration, String> {
        check_tool_name(change.name()).map_err(|error| error.to_string())?;
        if owner
            .as_ref()
            .is_some_and(|owner| !self.opens.borrow().contains(&owner.open))
        {
            return Err("the session is closed".to_owned());
        }
        let mut tools = self.tools.borrow_mut();
        let replaced = if matches!(change, ToolChange::Define { .. }) {
            owner.as_ref().and_then(|owner| {
                tools
                    .iter()
                    .rev()
                    .find(|tool| tool.visible_in(owner.open) && tool.change.name() == change.name())
                    .filter(|tool| matches!(tool.change, ToolChange::Define { .. }))
                    .and_then(|tool| tool.owner.as_ref())
                    .filter(|previous| previous.plugin != owner.plugin)
                    .map(|previous| previous.plugin.clone())
            })
        } else {
            None
        };
        let id = self.last_id.get() + 1;
        self.last_id.set(id);
        tools.push(Registered { id, owner, change });
        Ok(Registration { id, replaced })
    }

    /// Remove the tool changes of `ids`.
    pub(crate) fn remove(&self, ids: &[u64]) {
        self.tools.borrow_mut().retain(|tool| !ids.contains(&tool.id));
    }

    /// Open a session, and return its open number. Each open gets a new number, so an old handle never reaches a new
    /// open of the same session.
    pub(crate) fn open(&self) -> u64 {
        let open = self.last_open.get() + 1;
        self.last_open.set(open);
        self.opens.borrow_mut().insert(open);
        open
    }

    /// Close the open session `open`, and remove its tools.
    pub(crate) fn close(&self, open: u64) {
        self.opens.borrow_mut().remove(&open);
        self.tools
            .borrow_mut()
            .retain(|tool| tool.owner.as_ref().is_none_or(|owner| owner.open != open));
    }

    /// The effective tools of the open session `open`, in registration order. A closed session has no tools.
    pub(crate) fn entries(&self, open: u64) -> Vec<Entry> {
        if !self.opens.borrow().contains(&open) {
            return Vec::new();
        }
        let tools = self.tools.borrow();
        let mut names = HashSet::new();
        let mut entries: Vec<_> = tools
            .iter()
            .rev()
            .filter(|tool| tool.visible_in(open) && names.insert(tool.change.name()))
            .filter_map(|tool| match &tool.change {
                ToolChange::Define {
                    definition,
                    concurrency,
                    hints,
                    ..
                } => Some(Entry {
                    id: tool.id,
                    definition: definition.clone(),
                    concurrency: *concurrency,
                    hints: hints.clone(),
                }),
                ToolChange::Remove { .. } => None,
            })
            .collect();
        entries.reverse();
        entries
    }

    /// The start function of the tool `id` of the open session `open`. The borrow ends before the caller runs
    /// JavaScript, which can define a tool.
    fn start<'js>(&self, ctx: &Ctx<'js>, open: u64, id: u64) -> Result<Function<'js>, Error> {
        let failure = |message: &str| {
            Error::Script(crate::ScriptError {
                name: None,
                message: message.to_owned(),
                stack: None,
            })
        };
        if !self.opens.borrow().contains(&open) {
            return Err(failure("the session is closed"));
        }
        let start = self
            .tools
            .borrow()
            .iter()
            .find(|tool| tool.id == id)
            .and_then(|tool| match &tool.change {
                ToolChange::Define { start, .. } => Some(start.clone()),
                ToolChange::Remove { .. } => None,
            })
            .ok_or_else(|| failure("the tool is no longer defined"))?;
        caught(ctx, start.restore(ctx))
    }

    /// Drop each saved function. The engine calls this before it drops the runtime, because a saved value that
    /// outlives the runtime aborts the process.
    pub(crate) fn clear(&self) {
        self.tools.borrow_mut().clear();
    }
}

/// One tool of an open session: its id, its definition, how its calls run, and how a chat shows them.
pub(crate) struct Entry {
    pub(crate) id: u64,
    pub(crate) definition: yuke_ai::ToolDefinition,
    pub(crate) concurrency: Concurrency,
    pub(crate) hints: ToolHints,
}

/// A tool that the JavaScript defined, for one session. Each call runs on the engine task.
#[derive(Clone)]
pub struct ScriptTool {
    pub(crate) access: EngineAccess,
    pub(crate) id: u64,
    pub(crate) open: u64,
    pub(crate) concurrency: Concurrency,
    pub(crate) hints: ToolHints,
    pub(crate) host: Rc<dyn SessionHost>,
}

impl fmt::Debug for ScriptTool {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ScriptTool")
            .field("id", &self.id)
            .field("concurrency", &self.concurrency)
            .field("folder", &self.host.folder())
            .finish_non_exhaustive()
    }
}

#[async_trait(?Send)]
impl Tool for ScriptTool {
    fn concurrency(&self) -> Concurrency {
        self.concurrency
    }

    fn hints(&self) -> ToolHints {
        self.hints.clone()
    }

    async fn call(
        &self,
        arguments: &str,
        context: &ToolContext<'_>,
    ) -> Result<ToolContent, Box<dyn std::error::Error + Send + Sync>> {
        let (output, texts) = mpsc::unbounded_channel();
        let answer = self.answer(
            arguments,
            context.call_id(),
            context.cancellation_token().clone(),
            output,
        );
        let Ok(content) = forward(answer, texts, |text| {
            context.output(text);
            Ok::<_, Infallible>(())
        })
        .await;
        content
    }
}

/// Await `answer`, and give each text of `texts` to `show` in order. A text that the work sends after its answer has no
/// reader. A failure of `show` ends the wait with that failure, and the drop of `answer` stops the work.
pub(crate) async fn forward<T, E>(
    answer: impl Future<Output = T>,
    mut texts: mpsc::UnboundedReceiver<String>,
    mut show: impl FnMut(&str) -> Result<(), E>,
) -> Result<T, E> {
    let mut answer = pin!(answer);
    let result = loop {
        tokio::select! {
            // A text before the answer shows before it.
            biased;
            Some(text) = texts.recv() => show(&text)?,
            result = &mut answer => break result,
        }
    };
    // The answer can overtake the last texts.
    while let Ok(text) = texts.try_recv() {
        show(&text)?;
    }
    Ok(result)
}

impl ScriptTool {
    /// Run one call. Each text of `context.output` goes to `output`. A cancel of `token` aborts the signal of the
    /// call, and the call still answers.
    pub(crate) async fn answer(
        &self,
        arguments: &str,
        call_id: &str,
        token: CancellationToken,
        output: mpsc::UnboundedSender<String>,
    ) -> Result<ToolContent, Box<dyn std::error::Error + Send + Sync>> {
        // One folder for the whole call: the context, the commands, and the media paths of the answer.
        let folder = self.host.folder();
        let Some(folder_text) = folder.to_str().map(str::to_owned) else {
            return Err(Error::Folder(folder).into());
        };
        let (id, open) = (self.id, self.open);
        let host = Rc::clone(&self.host);
        let session_folder = folder.clone();
        let arguments = arguments.to_owned();
        let call_id = call_id.to_owned();
        let session_id = self.host.session_id().to_string();
        let answer = self
            .access
            .run(async move |ctx: Ctx<'_>, registry: Rc<Registry>| {
                let start = registry.start(&ctx, open, id)?;
                let output = caught(
                    &ctx,
                    Function::new(ctx.clone(), move |text: String| {
                        if output.send(text).is_err() {
                            // The call has answered, so a late text has no reader.
                        }
                    }),
                )?;
                // A cancel of the call stops its commands. The guard also stops them when the call ends or drops.
                let stop = token.child_token();
                let _guard = stop.clone().drop_guard();
                let call = caught(
                    &ctx,
                    call::object(&ctx, &registry.processes, &host, session_folder, &stop),
                )?;
                let request = CallRequest {
                    arguments: JsonText(arguments),
                    session_id,
                    call_id,
                    folder: folder_text,
                    output,
                    call,
                };
                let Operation { promise, cancel } = caught(&ctx, start.call((request,)))?;

                let mut settled = pin!(promise.into_future::<Answer>());
                tokio::select! {
                    answer = &mut settled => caught(&ctx, answer),
                    () = token.cancelled() => {
                        caught(&ctx, cancel.call::<_, ()>(()))?;
                        // The tool answers what the stopped work did.
                        caught(&ctx, settled.await)
                    }
                }
            })
            .await
            .map_err(|error| -> Box<dyn std::error::Error + Send + Sync> {
                match error {
                    Error::Script(error) => error_text(&error).into(),
                    other => other.into(),
                }
            })?;
        self.content(answer, &folder).await
    }

    /// The engine content of the result `answer`: its text, its error flag, and each media item stored through the
    /// host. A relative media path starts in `folder`.
    async fn content(
        &self,
        answer: Answer,
        folder: &Path,
    ) -> Result<ToolContent, Box<dyn std::error::Error + Send + Sync>> {
        Ok(ToolContent {
            text: answer.text,
            media: store_media(&*self.host, answer.media, folder).await?,
            is_error: answer.is_error,
            display: answer.display.0,
        })
    }
}

/// Store each media item of `files` through `host`, and return the items in order. A relative path starts in `folder`.
pub(crate) async fn store_media(
    host: &dyn SessionHost,
    files: Vec<MediaFile>,
    folder: &Path,
) -> Result<Vec<yuke_ai::Media>, Box<dyn std::error::Error + Send + Sync>> {
    // Each read comes before the first store, so a failed read leaves no blob without a reference.
    let read = read_media(files, folder).await?;
    let mut media = Vec::with_capacity(read.len());
    for attachment in read {
        let blob = host.put_media(attachment.bytes).await?;
        media.push(yuke_ai::Media::new(blob, attachment.mime_type));
    }
    Ok(media)
}

/// The bytes and the media type of each item of `files`, in order. A relative path starts in `folder`.
pub(crate) async fn read_media(files: Vec<MediaFile>, folder: &Path) -> Result<Vec<Attachment>, String> {
    let mut read = Vec::with_capacity(files.len());
    for file in files {
        let bytes = match file.source {
            Source::Path(path) => tokio::task::spawn_blocking({
                let path = folder.join(&path);
                move || std::fs::read(path)
            })
            .await
            .map_err(|error| format!("{path}: {error}"))?
            .map_err(|error| format!("{path}: {error}"))?,
            Source::Bytes(bytes) => bytes,
        };
        read.push(Attachment {
            bytes,
            mime_type: file.mime_type,
        });
    }
    Ok(read)
}

/// The text of a failed call for the model: the message of a thrown error.
pub(crate) fn error_text(error: &crate::ScriptError) -> String {
    if error.message.is_empty() {
        error.name.clone().unwrap_or_else(|| "the tool failed".to_owned())
    } else {
        error.message.clone()
    }
}

/// What the start function of a tool gets for one call.
#[derive(IntoJs)]
#[qjs(rename_all = "camelCase")]
struct CallRequest<'js> {
    arguments: JsonText,
    session_id: String,
    call_id: String,
    /// The workspace folder of the session at the start of the call.
    folder: String,
    /// Sends one text of the call to the consumer.
    output: Function<'js>,
    /// The natives that need the session or the life of the call.
    call: Object<'js>,
}

/// The JSON text of a value, which crosses to JavaScript as the parsed value.
pub(crate) struct JsonText(pub(crate) String);

impl<'js> IntoJs<'js> for JsonText {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<Value<'js>> {
        ctx.json_parse(self.0)
    }
}

/// A value that crosses to JavaScript and back as its serde JSON, so a type of another crate needs no copy here.
#[derive(Debug)]
pub(crate) struct Json<T>(pub(crate) T);

impl<'js, T: Serialize> IntoJs<'js> for Json<T> {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<Value<'js>> {
        let text = serde_json::to_string(&self.0)
            .map_err(|error| rquickjs::Error::new_into_js_message("value", "JSON", error.to_string()))?;
        ctx.json_parse(text)
    }
}

impl<'js, T: DeserializeOwned> FromJs<'js> for Json<T> {
    fn from_js(ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        let text = ctx
            .json_stringify(value)?
            .ok_or_else(|| rquickjs::Error::new_from_js("undefined", "JSON"))?
            .to_string()?;
        serde_json::from_str(&text)
            .map(Json)
            .map_err(|error| rquickjs::Error::new_from_js_message("JSON", "value", error.to_string()))
    }
}

/// The checked result of a call.
#[derive(Debug, FromJs)]
#[qjs(rename_all = "camelCase")]
struct Answer {
    text: String,
    is_error: bool,
    media: Vec<MediaFile>,
    display: Json<Vec<DisplayBlock>>,
}

/// A media item of a result.
#[derive(Debug)]
pub(crate) struct MediaFile {
    mime_type: String,
    source: Source,
}

/// Where the bytes of a media file come from.
#[derive(Debug)]
enum Source {
    /// A file. A relative path starts in the folder of the call.
    Path(String),
    /// The bytes that the tool gave.
    Bytes(Vec<u8>),
}

impl MediaFile {
    /// The path of the file, or `None` for bytes.
    pub(crate) fn path(&self) -> Option<&str> {
        match &self.source {
            Source::Path(path) => Some(path),
            Source::Bytes(_) => None,
        }
    }
}

impl<'js> FromJs<'js> for MediaFile {
    fn from_js(_ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        let object = Object::from_value(value)?;
        let source = match object.get::<_, Option<String>>("path")? {
            Some(path) => Source::Path(path),
            None => Source::Bytes(crate::bytes::copy(&object.get("bytes")?)?),
        };
        Ok(Self {
            mime_type: object.get("mimeType")?,
            source,
        })
    }
}
