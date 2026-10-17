//! The tool bridge: a tool that JavaScript defines with `yuke:tools` is an engine [`Tool`].

use std::cell::{Cell, RefCell};
use std::fmt;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::pin::pin;
use std::rc::Rc;
use std::sync::Arc;

use async_trait::async_trait;
use rquickjs::{Ctx, FromJs, Function, Object, Persistent, Promise, Value};
use tokio::sync::mpsc;
use yuke_engine::{
    CancellationToken, Concurrency, Tool, ToolContent, ToolContext, ToolNameError, is_reserved_tool_name,
};

use crate::error::{Error, caught};
use crate::native::session;
use crate::processes::{JobEnded, Processes};
use crate::runtime::Caller;

/// What the tools of one session need from the consumer. One process can serve sessions of several workspaces at
/// once, so each session gives its own host. Give the same host to every [`Runtime::tools`](crate::Runtime::tools)
/// call of a session, also after a reload or a change of its folder: the jobs of a session belong to its host.
#[async_trait]
pub trait SessionHost: Send + Sync {
    /// The id of the session. A tool gets it as `sessionId`.
    fn session_id(&self) -> yuke_protocol::SessionId;

    /// The workspace folder of the session now. Relative paths and commands of the tools start here.
    fn folder(&self) -> PathBuf;

    /// Store the bytes of an attachment of the session, for example an image that a tool read, and return its blob.
    ///
    /// # Errors
    ///
    /// Returns the text of the failure. The model receives it as the error of the tool call.
    async fn put_media(&self, bytes: Vec<u8>) -> Result<yuke_ai::Blob, String>;

    /// A background job of the session started or ended. The call must not wait.
    fn job_changed(&self, job: yuke_protocol::Job);

    /// A background job of the session ended by itself. Give [`JobEnded::text`] to the session as an input that is not
    /// from the user. A close and a shutdown wait for the return.
    async fn job_ended(&self, ended: JobEnded);
}

/// The tools that the JavaScript defined, on the JavaScript thread.
#[derive(Debug, Default)]
pub(crate) struct Registry {
    tools: RefCell<Vec<Registered>>,
    last_id: Cell<u64>,
}

/// One defined tool.
#[derive(Debug)]
struct Registered {
    id: u64,
    definition: yuke_ai::ToolDefinition,
    concurrency: Concurrency,
    /// The JavaScript function that starts a call.
    start: Persistent<Function<'static>>,
    /// The plugin that defined the tool, or `None` for yuke itself.
    owner: Option<String>,
}

impl Registry {
    /// Add a tool of `owner`, a plugin, or of yuke itself. A name that the engine reserves, or a second tool with the
    /// same name, fails with the text of the failure.
    pub(crate) fn add<'js>(
        &self,
        ctx: &Ctx<'js>,
        definition: yuke_ai::ToolDefinition,
        concurrency: Concurrency,
        start: Function<'js>,
        owner: Option<String>,
    ) -> Result<(), String> {
        if is_reserved_tool_name(&definition.name) {
            return Err(ToolNameError::Reserved(definition.name).to_string());
        }
        let mut tools = self.tools.borrow_mut();
        if let Some(other) = tools.iter().find(|tool| tool.definition.name == definition.name) {
            let by = other
                .owner
                .as_ref()
                .map_or_else(|| "yuke".to_owned(), |owner| format!("plugin {owner}"));
            return Err(format!(
                "{by} already defines a tool with the name '{}'",
                definition.name
            ));
        }
        let id = self.last_id.get() + 1;
        self.last_id.set(id);
        tools.push(Registered {
            id,
            definition,
            concurrency,
            start: Persistent::save(ctx, start),
            owner,
        });
        Ok(())
    }

    /// Remove each tool of the plugin `owner`.
    pub(crate) fn remove_owner(&self, owner: &str) {
        self.tools
            .borrow_mut()
            .retain(|tool| tool.owner.as_deref() != Some(owner));
    }

    /// The id, the definition, and the concurrency of each tool, in the order of their definition.
    fn entries(&self) -> Vec<(u64, yuke_ai::ToolDefinition, Concurrency)> {
        self.tools
            .borrow()
            .iter()
            .map(|tool| (tool.id, tool.definition.clone(), tool.concurrency))
            .collect()
    }

    /// The start function of the tool `id`. The borrow ends before the caller runs JavaScript, which can define a tool.
    fn start<'js>(&self, ctx: &Ctx<'js>, id: u64) -> Option<rquickjs::Result<Function<'js>>> {
        let start = self
            .tools
            .borrow()
            .iter()
            .find(|tool| tool.id == id)
            .map(|tool| tool.start.clone());
        start.map(|start| start.restore(ctx))
    }

    /// Drop each saved function. The thread calls this before it drops the runtime, because a saved value that
    /// outlives the runtime aborts the process.
    pub(crate) fn clear(&self) {
        self.tools.borrow_mut().clear();
    }
}

/// The definitions of the tools, each with its engine tool for the session of `host`.
pub(crate) async fn tools(
    caller: &Caller,
    processes: &Arc<Processes>,
    host: Arc<dyn SessionHost>,
) -> Result<Vec<(yuke_ai::ToolDefinition, ScriptTool)>, Error> {
    let entries = caller
        .run(async |_ctx: Ctx<'_>, registry: Rc<Registry>| Ok(registry.entries()))
        .await?;
    Ok(entries
        .into_iter()
        .map(|(id, definition, concurrency)| {
            let tool = ScriptTool {
                caller: caller.clone(),
                id,
                concurrency,
                processes: Arc::clone(processes),
                host: Arc::clone(&host),
            };
            (definition, tool)
        })
        .collect())
}

/// A tool that the JavaScript defined, for one session. Each call runs on the JavaScript thread.
#[derive(Clone)]
pub struct ScriptTool {
    caller: Caller,
    id: u64,
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
        let id = self.id;
        let processes = Arc::clone(&self.processes);
        let host = Arc::clone(&self.host);
        let session_folder = folder.clone();
        let arguments = arguments.to_owned();
        let call_id = call_id.to_owned();
        let session_id = self.host.session_id().to_string();
        let answer = self
            .caller
            .run(async move |ctx: Ctx<'_>, registry: Rc<Registry>| {
                let Some(start) = registry.start(&ctx, id) else {
                    return Err(Error::Script(crate::ScriptError {
                        name: None,
                        message: "the tool is no longer defined".to_owned(),
                        stack: None,
                    }));
                };
                let start = caught(&ctx, start)?;
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
                let session = caught(&ctx, session::object(&ctx, &processes, &host, session_folder, &stop))?;
                let metadata = caught(&ctx, crate::native::internal_record(&ctx))?;
                caught(&ctx, metadata.set("sessionId", session_id))?;
                caught(&ctx, metadata.set("callId", call_id))?;
                caught(&ctx, metadata.set("folder", folder_text))?;
                let started: Object<'_> = caught(&ctx, start.call((arguments, metadata, output, session)))?;
                let promise: Promise<'_> = caught(&ctx, started.get("answer"))?;
                let abort: Function<'_> = caught(&ctx, started.get("abort"))?;

                let mut settled = pin!(promise.into_future::<Answer>());
                tokio::select! {
                    answer = &mut settled => caught(&ctx, answer),
                    () = token.cancelled() => {
                        caught(&ctx, abort.call::<_, ()>(()))?;
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
        // Each read comes before the first store, so a failed read leaves no blob without a reference.
        let mut files = Vec::with_capacity(answer.media.len());
        for file in answer.media {
            let bytes = match file.source {
                Source::Path(path) => read_file(folder.join(&path))
                    .await
                    .map_err(|error| format!("{path}: {error}"))?,
                Source::Bytes(bytes) if bytes.len() as u64 > MAX_MEDIA_BYTES => return Err(too_large()),
                Source::Bytes(bytes) => bytes,
            };
            files.push((bytes, file.mime_type));
        }
        let mut media = Vec::with_capacity(files.len());
        for (bytes, mime_type) in files {
            let blob = self.host.put_media(bytes).await?;
            media.push(yuke_ai::Media::new(blob, mime_type));
        }
        Ok(ToolContent {
            text: answer.text,
            media,
            is_error: answer.is_error,
        })
    }
}

/// The largest media item of each provider, from a file or from bytes: 5 MiB as base64. Anthropic on Bedrock and
/// Google Cloud, which OpenRouter can use, has this limit per image.
const MAX_MEDIA_BYTES: u64 = 5 * 1024 * 1024 / 4 * 3;

/// The bytes of the file at `path`, at most [`MAX_MEDIA_BYTES`]. A blocking thread of tokio reads them, so the task of
/// the caller does not wait.
async fn read_file(path: PathBuf) -> std::io::Result<Vec<u8>> {
    tokio::task::spawn_blocking(move || {
        let mut bytes = Vec::new();
        // A provider refuses a larger file in each later request, so the session could not go on.
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
fn error_text(error: &Error) -> String {
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

/// The checked result of a call: `{ text, isError, media }`.
#[derive(Debug)]
struct Answer {
    text: String,
    is_error: bool,
    media: Vec<MediaFile>,
}

/// A media item of a result.
#[derive(Debug)]
struct MediaFile {
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

impl<'js> FromJs<'js> for Answer {
    fn from_js(_ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        let object = Object::from_value(value)?;
        Ok(Self {
            text: object.get("text")?,
            is_error: object.get("isError")?,
            media: object.get("media")?,
        })
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
