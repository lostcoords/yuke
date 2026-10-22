//! The tool bridge: a tool that JavaScript defines is an engine [`Tool`] of each session that has it.

use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::fmt;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::pin::pin;
use std::rc::Rc;
use std::sync::Arc;

use async_trait::async_trait;
use rquickjs::{Ctx, FromJs, Function, IntoJs, Object, Persistent, Value};
use serde::Serialize;
use serde::de::DeserializeOwned;
use tokio::sync::mpsc;
use yuke_ai::MAX_MEDIA_BYTES;
use yuke_engine::{CancellationToken, Concurrency, MediaStore, Tool, ToolContent, ToolContext, check_tool_name};

use crate::error::{Error, caught};
use crate::native::{Operation, call};
use crate::processes::Processes;
use crate::runtime::Caller;

/// What the tools of one session need from the consumer. One process can serve sessions of several workspaces at
/// once, so each session gives its own host. Give the same host to every
/// [`Runtime::open_session`](crate::Runtime::open_session) of a session, also after a reload or a change of its folder:
/// the jobs of a session belong to its host. The host stores the attachments of the session as a [`MediaStore`], for
/// example an image that a tool read.
#[async_trait]
pub trait SessionHost: MediaStore {
    /// The id of the session. A tool gets it as `sessionId`.
    fn session_id(&self) -> yuke_protocol::SessionId;

    /// The workspace folder of the session now. Relative paths and commands of the tools start here.
    fn folder(&self) -> PathBuf;

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
}

/// The tools that the JavaScript defined, and the open sessions, on the JavaScript thread.
#[derive(Debug, Default)]
pub(crate) struct Registry {
    tools: RefCell<Vec<Registered>>,
    last_id: Cell<u64>,
    /// The open number of each open session.
    opens: RefCell<HashSet<u64>>,
    last_open: Cell<u64>,
}

/// One defined tool.
#[derive(Debug)]
struct Registered {
    id: u64,
    /// The open session of the tool, or `None` for a tool of every session.
    open: Option<u64>,
    definition: yuke_ai::ToolDefinition,
    concurrency: Concurrency,
    /// The JavaScript function that starts a call.
    start: Persistent<Function<'static>>,
}

impl Registry {
    /// Add a tool to the open session `open`, or to every session when `open` is `None`, and return its id. A reserved
    /// name, a name that the session already has, or a closed session fails with the text of the failure.
    pub(crate) fn add<'js>(
        &self,
        ctx: &Ctx<'js>,
        definition: yuke_ai::ToolDefinition,
        concurrency: Concurrency,
        start: Function<'js>,
        open: Option<u64>,
    ) -> Result<u64, String> {
        check_tool_name(&definition.name).map_err(|error| error.to_string())?;
        if open.is_some_and(|open| !self.opens.borrow().contains(&open)) {
            return Err("the session is closed".to_owned());
        }
        let mut tools = self.tools.borrow_mut();
        // A tool of every session meets the tools of each session.
        let clash = tools.iter().any(|tool| {
            tool.definition.name == definition.name && (tool.open.is_none() || open.is_none() || tool.open == open)
        });
        if clash {
            return Err(format!(
                "the session already has a tool with the name '{}'",
                definition.name
            ));
        }
        let id = self.last_id.get() + 1;
        self.last_id.set(id);
        tools.push(Registered {
            id,
            open,
            definition,
            concurrency,
            start: Persistent::save(ctx, start),
        });
        Ok(id)
    }

    /// Remove the tools of `ids`.
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
        self.tools.borrow_mut().retain(|tool| tool.open != Some(open));
    }

    /// The id, the definition, and the concurrency of each tool of the open session `open`, in the order of their
    /// definition. A closed session has no tools.
    pub(crate) fn entries(&self, open: u64) -> Vec<(u64, yuke_ai::ToolDefinition, Concurrency)> {
        if !self.opens.borrow().contains(&open) {
            return Vec::new();
        }
        self.tools
            .borrow()
            .iter()
            .filter(|tool| tool.open.is_none_or(|own| own == open))
            .map(|tool| (tool.id, tool.definition.clone(), tool.concurrency))
            .collect()
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
            .map(|tool| tool.start.clone())
            .ok_or_else(|| failure("the tool is no longer defined"))?;
        caught(ctx, start.restore(ctx))
    }

    /// Drop each saved function. The thread calls this before it drops the runtime, because a saved value that
    /// outlives the runtime aborts the process.
    pub(crate) fn clear(&self) {
        self.tools.borrow_mut().clear();
    }
}

/// The definitions of `entries` of the open session `open`, each with its engine tool for the session of `host`.
pub(crate) fn script_tools(
    caller: &Caller,
    processes: &Arc<Processes>,
    host: &Arc<dyn SessionHost>,
    open: u64,
    entries: Vec<(u64, yuke_ai::ToolDefinition, Concurrency)>,
) -> Vec<(yuke_ai::ToolDefinition, ScriptTool)> {
    entries
        .into_iter()
        .map(|(id, definition, concurrency)| {
            let tool = ScriptTool {
                caller: caller.clone(),
                id,
                open,
                concurrency,
                processes: Arc::clone(processes),
                host: Arc::clone(host),
            };
            (definition, tool)
        })
        .collect()
}

/// A tool that the JavaScript defined, for one session. Each call runs on the JavaScript thread.
#[derive(Clone)]
pub struct ScriptTool {
    caller: Caller,
    id: u64,
    open: u64,
    concurrency: Concurrency,
    processes: Arc<Processes>,
    host: Arc<dyn SessionHost>,
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

#[async_trait]
impl Tool for ScriptTool {
    fn concurrency(&self) -> Concurrency {
        self.concurrency
    }

    async fn call(&self, arguments: &str, context: &ToolContext<'_>) -> Result<ToolContent, String> {
        let (output, texts) = mpsc::unbounded_channel();
        let answer = self.answer(
            arguments,
            context.call_id(),
            context.cancellation_token().clone(),
            output,
        );
        forward(answer, texts, |text| context.output(text)).await
    }
}

/// Await `answer`, and give each text of `texts` to `show` in order. A text that the tool sends after its answer has no
/// reader.
pub(crate) async fn forward<T>(
    answer: impl Future<Output = T>,
    mut texts: mpsc::UnboundedReceiver<String>,
    show: impl Fn(&str),
) -> T {
    let mut answer = pin!(answer);
    let result = loop {
        tokio::select! {
            // A text before the answer shows before it.
            biased;
            Some(text) = texts.recv() => show(&text),
            result = &mut answer => break result,
        }
    };
    // The answer can overtake the last texts.
    while let Ok(text) = texts.try_recv() {
        show(&text);
    }
    result
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
    ) -> Result<ToolContent, String> {
        // One folder for the whole call: the context, the commands, and the media paths of the answer.
        let folder = self.host.folder();
        let Some(folder_text) = folder.to_str().map(str::to_owned) else {
            return Err(format!("the workspace folder {} is not UTF-8", folder.display()));
        };
        let (id, open) = (self.id, self.open);
        let processes = Arc::clone(&self.processes);
        let host = Arc::clone(&self.host);
        let session_folder = folder.clone();
        let arguments = arguments.to_owned();
        let call_id = call_id.to_owned();
        let session_id = self.host.session_id().to_string();
        let answer = self
            .caller
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
                let call = caught(&ctx, call::object(&ctx, &processes, &host, session_folder, &stop))?;
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
            .map_err(|error| error_text(&error))?;
        self.content(answer, &folder).await
    }

    /// The engine content of the result `answer`: its text, its error flag, and each media item stored through the
    /// host. A relative media path starts in `folder`.
    async fn content(&self, answer: Answer, folder: &Path) -> Result<ToolContent, String> {
        Ok(ToolContent {
            text: answer.text,
            media: store_media(&*self.host, answer.media, folder).await?,
            is_error: answer.is_error,
        })
    }
}

/// Store each media item of `files` through `host`, and return the items in order. A relative path starts in `folder`.
pub(crate) async fn store_media(
    host: &dyn SessionHost,
    files: Vec<MediaFile>,
    folder: &Path,
) -> Result<Vec<yuke_ai::Media>, String> {
    // Each read comes before the first store, so a failed read leaves no blob without a reference.
    let mut read = Vec::with_capacity(files.len());
    for file in files {
        let bytes = match file.source {
            Source::Path(path) => read_file(folder.join(&path))
                .await
                .map_err(|error| format!("{path}: {error}"))?,
            Source::Bytes(bytes) if bytes.len() as u64 > MAX_MEDIA_BYTES => return Err(too_large()),
            Source::Bytes(bytes) => bytes,
        };
        read.push((bytes, file.mime_type));
    }
    let mut media = Vec::with_capacity(read.len());
    for (bytes, mime_type) in read {
        let blob = host.put_media(bytes).await?;
        media.push(yuke_ai::Media::new(blob, mime_type));
    }
    Ok(media)
}

/// The bytes of the file at `path`, at most [`MAX_MEDIA_BYTES`]. A blocking thread of tokio reads them, so the task of
/// the caller does not wait.
async fn read_file(path: PathBuf) -> std::io::Result<Vec<u8>> {
    tokio::task::spawn_blocking(move || {
        let mut bytes = Vec::new();
        std::fs::File::open(path)?
            .take(MAX_MEDIA_BYTES + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_MEDIA_BYTES {
            return Err(std::io::Error::new(std::io::ErrorKind::FileTooLarge, too_large()));
        }
        Ok(bytes)
    })
    .await
    .map_err(std::io::Error::other)?
}

/// The text of a failed call for the model: the message of a thrown error.
pub(crate) fn error_text(error: &Error) -> String {
    match error {
        Error::Script(error) if !error.message.is_empty() => error.message.clone(),
        Error::Script(error) => error.name.clone().unwrap_or_else(|| "the tool failed".to_owned()),
        other => other.to_string(),
    }
}

/// The error text of a media item over [`MAX_MEDIA_BYTES`].
fn too_large() -> String {
    format!("the media is larger than the limit of {MAX_MEDIA_BYTES} bytes")
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
