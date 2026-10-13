//! The tool bridge: a tool that JavaScript defines with `yuke:tools` is an engine [`Tool`].

use std::cell::{Cell, RefCell};
use std::fmt;
use std::path::{Path, PathBuf};
use std::pin::pin;
use std::rc::Rc;
use std::sync::Arc;

use async_trait::async_trait;
use rquickjs::{Constructor, Ctx, FromJs, Function, Object, Persistent, Promise, Value};
use tokio::sync::mpsc;
use yuke_engine::{CancellationToken, Concurrency, Tool, ToolContent, ToolContext};

use crate::error::{Error, caught};
use crate::native::session;
use crate::processes::{JobEnded, Processes, StopOnDrop};
use crate::runtime::Caller;

/// What the tools of one session need from the consumer. One process can serve sessions of several workspaces at
/// once, so each session gives its own host. Give the same host to every [`Runtime::tools`](crate::Runtime::tools)
/// call of a session, also after a reload: the jobs of a session belong to its host.
#[async_trait]
pub trait SessionHost: Send + Sync {
    /// The workspace folder of the session. Relative paths and commands of the tools start here.
    fn folder(&self) -> &Path;

    /// Store the bytes of an attachment of the session, for example an image that a tool read, and return its blob.
    ///
    /// # Errors
    ///
    /// Returns the text of the failure. The model receives it as the error of the tool call.
    async fn put_media(&self, bytes: Vec<u8>) -> Result<yuke_ai::Blob, String>;

    /// A background job of the session ended by itself. Give [`JobEnded::text`] to the session as an input that is not
    /// from the user.
    fn job_ended(&self, ended: JobEnded);
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
}

impl Registry {
    /// Add a tool. A second tool with the same name fails with the text of the failure.
    pub(crate) fn add<'js>(
        &self,
        ctx: &Ctx<'js>,
        definition: yuke_ai::ToolDefinition,
        concurrency: Concurrency,
        start: Function<'js>,
    ) -> Result<(), String> {
        let mut tools = self.tools.borrow_mut();
        if tools.iter().any(|tool| tool.definition.name == definition.name) {
            return Err(format!("a tool with the name '{}' is already defined", definition.name));
        }
        let id = self.last_id.get() + 1;
        self.last_id.set(id);
        tools.push(Registered {
            id,
            definition,
            concurrency,
            start: Persistent::save(ctx, start),
        });
        Ok(())
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
        let Some(folder) = self.host.folder().to_str().map(str::to_owned) else {
            return Err(format!(
                "the workspace folder {} is not UTF-8",
                self.host.folder().display()
            ));
        };
        let id = self.id;
        let processes = Arc::clone(&self.processes);
        let host = Arc::clone(&self.host);
        let arguments = arguments.to_owned();
        let call_id = call_id.to_owned();
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
                // The guard stops the commands of the call when the call ends, and also when the call drops.
                let stop = CancellationToken::new();
                #[expect(
                    unused_variables,
                    reason = "only the drop of the guard matters: it stops the commands"
                )]
                let guard = StopOnDrop(stop.clone());
                let session = caught(&ctx, session::object(&ctx, &processes, &host, &stop))?;
                let started: Object<'_> = caught(&ctx, start.call((arguments, call_id, folder, output, session)))?;
                let promise: Promise<'_> = caught(&ctx, started.get("answer"))?;
                let abort: Function<'_> = caught(&ctx, started.get("abort"))?;

                let mut settled = pin!(promise.into_future::<Answer>());
                tokio::select! {
                    answer = &mut settled => caught(&ctx, answer),
                    () = token.cancelled() => {
                        let reason = caught(&ctx, abort_reason(&ctx))?;
                        caught(&ctx, abort.call::<_, ()>((reason,)))?;
                        // The tool answers what the stopped work did.
                        caught(&ctx, settled.await)
                    }
                }
            })
            .await
            .map_err(|error| error_text(&error))?;
        self.content(answer).await
    }

    /// The engine content of `answer`: its text, and each media file stored through the host.
    async fn content(&self, answer: Answer) -> Result<ToolContent, String> {
        let mut media = Vec::with_capacity(answer.media.len());
        for file in answer.media {
            let path = self.host.folder().join(&file.path);
            let bytes = read_file(path)
                .await
                .map_err(|error| format!("{}: {error}", file.path))?;
            let blob = self.host.put_media(bytes).await?;
            media.push(yuke_ai::Media::new(blob, file.mime));
        }
        Ok(ToolContent {
            text: answer.output,
            media,
        })
    }
}

/// The bytes of the file at `path`. A blocking thread of tokio reads them, so the task of the caller does not wait.
async fn read_file(path: PathBuf) -> std::io::Result<Vec<u8>> {
    tokio::task::spawn_blocking(move || std::fs::read(path))
        .await
        .map_err(std::io::Error::other)?
}

/// The reason of a cancel: a `DOMException` named `AbortError`, as the web gives.
fn abort_reason<'js>(ctx: &Ctx<'js>) -> rquickjs::Result<Value<'js>> {
    let constructor: Constructor<'js> = ctx.globals().get("DOMException")?;
    constructor.construct(("The tool call was cancelled", "AbortError"))
}

/// The text of a failed call for the model: the message of a thrown error.
fn error_text(error: &Error) -> String {
    match error {
        Error::Script(error) if !error.message.is_empty() => error.message.clone(),
        Error::Script(error) => error.name.clone().unwrap_or_else(|| "the tool failed".to_owned()),
        other => other.to_string(),
    }
}

/// The answer of a tool: a string, or `{ output, media }`.
#[derive(Debug)]
struct Answer {
    output: String,
    media: Vec<MediaFile>,
}

/// A file that an answer attaches.
#[derive(Debug)]
struct MediaFile {
    path: String,
    mime: String,
}

impl<'js> FromJs<'js> for Answer {
    fn from_js(_ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        if let Some(text) = value.as_string() {
            return Ok(Self {
                output: text.to_string()?,
                media: Vec::new(),
            });
        }
        let Some(object) = value.as_object() else {
            return Err(rquickjs::Error::new_from_js(
                value.type_name(),
                "a string or { output, media }",
            ));
        };
        Ok(Self {
            output: object.get("output")?,
            media: object.get::<_, Option<Vec<MediaFile>>>("media")?.unwrap_or_default(),
        })
    }
}

impl<'js> FromJs<'js> for MediaFile {
    fn from_js(_ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        let object = Object::from_value(value)?;
        Ok(Self {
            path: object.get("path")?,
            mime: object.get("mime")?,
        })
    }
}
