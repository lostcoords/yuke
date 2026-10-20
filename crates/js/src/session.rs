//! These types open, use, and close one session of the plugins. Its tools are the tools of yuke and the tools that the
//! `session` exports define. Its hooks are the hooks that the `session` exports add.

use std::error::Error as StdError;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use rquickjs::{Ctx, FromJs, Function, IntoJs, Object, Promise, Value};
use tokio::sync::oneshot;
use yuke_agent::PromptSection;
use yuke_ai::{Block, FinishReason, ToolCall, ToolResult, answer_text};
use yuke_engine::{CancellationToken, Hooks, RoundDecision, ToolDecision};
use yuke_protocol::{Input, InteractionRequest, InteractionResponse};

use crate::Runtime;
use crate::error::{Error, ErrorClass, caught, throw};
use crate::native::Operation;
use crate::plugins::loader;
use crate::processes::Processes;
use crate::runtime::Caller;
use crate::tools::{self, JsonText, MediaFile, Registry, ScriptTool, SessionHost, error_text, store_media};

/// An open session of the plugins. Call [`ScriptSession::close`] to await the cleanups. A drop posts the close and does
/// not wait. The posted close runs only while the runtime thread runs, so close each session before a shutdown.
pub struct ScriptSession {
    caller: Caller,
    processes: Arc<Processes>,
    host: Arc<dyn SessionHost>,
    /// The open number of the registry. A new open of the same session gets a new number, so a late close of this
    /// handle never reaches it.
    open: u64,
}

impl std::fmt::Debug for ScriptSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ScriptSession")
            .field("session", &self.host.session_id())
            .field("open", &self.open)
            .finish_non_exhaustive()
    }
}

impl Runtime {
    /// Open the session of `host`: start `session(s)` of each loaded plugin. The open does not wait for them;
    /// [`ScriptSession::tools`] does. Keep `host` for the whole session: its jobs belong to it.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Folder`] when the folder of `host` is not UTF-8, and [`Error::Stopped`] when the thread has
    /// ended.
    pub async fn open_session(&self, host: Arc<dyn SessionHost>) -> Result<ScriptSession, Error> {
        let folder = host.folder();
        let folder = folder.to_str().ok_or_else(|| Error::Folder(folder.clone()))?.to_owned();
        let session_id = host.session_id().to_string();
        let ask_host = Arc::clone(&host);
        let open = self
            .caller
            .run(async move |ctx: Ctx<'_>, registry: Rc<Registry>| {
                let open_session: Function<'_> = caught(&ctx, loader(&ctx).await?.get("openSession"))?;
                let open = registry.open();
                let request = OpenRequest {
                    open,
                    session_id,
                    folder,
                    ask: caught(&ctx, ask_function(&ctx, ask_host))?,
                };
                if let Err(error) = caught(&ctx, open_session.call::<_, ()>((request,))) {
                    registry.close(open);
                    return Err(error);
                }
                Ok(open)
            })
            .await?;
        Ok(ScriptSession {
            caller: self.caller.clone(),
            processes: Arc::clone(&self.processes),
            host,
            open,
        })
    }
}

impl ScriptSession {
    /// Wait until `session(s)` of each plugin settles, then return the tools of the session, each with its definition:
    /// the tools of yuke and the tools that the plugins defined. A closed session has no tools. A drop of the wait leaves
    /// the plugins running.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Stopped`] when the thread has ended.
    pub async fn tools(&self) -> Result<Vec<(yuke_ai::ToolDefinition, ScriptTool)>, Error> {
        let open = self.open;
        let entries = self
            .caller
            .run(async move |ctx: Ctx<'_>, registry: Rc<Registry>| {
                let ready: Function<'_> = caught(&ctx, loader(&ctx).await?.get("ready"))?;
                let promise: Promise<'_> = caught(&ctx, ready.call((open,)))?;
                caught(&ctx, promise.into_future::<()>().await)?;
                Ok(registry.entries(open))
            })
            .await?;
        Ok(tools::script_tools(
            &self.caller,
            &self.processes,
            &self.host,
            open,
            entries,
        ))
    }

    /// Run the `prompt.build` handlers of the plugins on `sections`, after `session(s)` of each plugin settles. Each
    /// handler gets the sections of the answer before it. When `token` is cancelled, the call aborts the signal of the
    /// build and returns `sections` at once. A closed session also returns `sections`.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Script`] when a handler throws or gives an answer that is not valid. Returns
    /// [`Error::Stopped`] when the thread has ended.
    pub async fn build_prompt(
        &self,
        sections: &[PromptSection],
        token: &CancellationToken,
    ) -> Result<Vec<PromptSection>, Error> {
        let request = PromptBuildRequest {
            open: self.open,
            sections: sections
                .iter()
                .map(|section| Section {
                    key: section.key.clone(),
                    text: section.text.clone(),
                })
                .collect(),
        };
        let built: Option<Vec<Section>> = run_hook(&self.caller, "startPromptBuild", request, token.clone()).await?;
        Ok(built.map_or_else(
            || sections.to_vec(),
            |built| {
                built
                    .into_iter()
                    .map(|Section { key, text }| PromptSection { key, text })
                    .collect()
            },
        ))
    }

    /// The engine hooks of one turn of the session. The plugins answer them. When `token` is cancelled, each hook
    /// aborts its signal.
    pub fn hooks(&self, token: CancellationToken) -> ScriptHooks {
        ScriptHooks {
            caller: self.caller.clone(),
            host: Arc::clone(&self.host),
            open: self.open,
            token,
            continues: AtomicU64::new(0),
        }
    }

    /// Close the session: its tools stop at once, each signal of its plugins aborts, and the close waits for each
    /// cleanup. A second close, and the drop after a close, do nothing.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Stopped`] when the thread has ended, which also ends the plugins.
    pub async fn close(&self) -> Result<(), Error> {
        let open = self.open;
        self.caller
            .run(async move |ctx: Ctx<'_>, registry: Rc<Registry>| close(&ctx, &registry, open).await)
            .await
    }
}

impl Drop for ScriptSession {
    fn drop(&mut self) {
        let open = self.open;
        let posted = self.caller.post(async move |ctx: Ctx<'_>, registry: Rc<Registry>| {
            if close(&ctx, &registry, open).await.is_err() {
                // Only the end of the engine fails the close, and that end drops the plugins too.
            }
        });
        if posted.is_err() {
            // The thread has ended, so no plugin of the session runs.
        }
    }
}

/// The engine hooks of one turn of a session. The `s.hook` handlers of the plugins answer them, and each hook that
/// they do not handle keeps its default.
pub struct ScriptHooks {
    caller: Caller,
    host: Arc<dyn SessionHost>,
    open: u64,
    token: CancellationToken,
    /// The `continue` answers of the `round.after` hooks in this turn.
    continues: AtomicU64,
}

impl std::fmt::Debug for ScriptHooks {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ScriptHooks")
            .field("open", &self.open)
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl Hooks for ScriptHooks {
    async fn after_round(
        &self,
        context: &[Block],
        finish_reason: Option<FinishReason>,
    ) -> Result<RoundDecision, Box<dyn StdError + Send + Sync>> {
        let request = RoundAfterRequest {
            open: self.open,
            text: answer_text(context),
            finish_reason: finish_reason.map(FinishReason::as_str),
            continues: self.continues.load(Ordering::Relaxed),
        };
        let answer: Option<Option<RoundAnswer>> =
            run_hook(&self.caller, "startRoundAfter", request, self.token.clone())
                .await
                .map_err(|error| failure_text("round.after", &error))?;
        Ok(match answer {
            Some(Some(RoundAnswer::Stop)) => RoundDecision::Stop,
            Some(Some(RoundAnswer::Continue { plugin, text })) => {
                self.continues.fetch_add(1, Ordering::Relaxed);
                // The request is a notification of the plugin, so the user sees who sent it. The turn takes the
                // input of the session after this round, together with an input of the user.
                self.host.accept_input(Input::notification(&plugin, &text, &text)).await;
                RoundDecision::Proceed
            }
            // A cancel ends the turn, so the driver does not read this answer.
            Some(None) | None => RoundDecision::Proceed,
        })
    }

    async fn before_tool(&self, call: &ToolCall) -> ToolDecision {
        let request = ToolBeforeRequest {
            open: self.open,
            call: HookCall::of(call),
        };
        let answer: Result<Option<Option<String>>, Error> =
            run_hook(&self.caller, "startToolBefore", request, self.token.clone()).await;
        match answer {
            Ok(Some(Some(reason))) => ToolDecision::Block(reason),
            // A cancel stops the turn, so the driver does not start the call.
            Ok(Some(None) | None) => ToolDecision::Run,
            // A failed check never lets a call run.
            Err(error) => ToolDecision::Block(failure_text("tool.before", &error)),
        }
    }

    async fn after_tool(&self, call: &ToolCall, result: &ToolResult) -> Option<ToolResult> {
        let request = ToolAfterRequest {
            open: self.open,
            call: HookCall::of(call),
            result: HookResult {
                text: result.content.clone(),
                is_error: result.is_error,
                media: result
                    .media
                    .iter()
                    .map(|item| HookMedia {
                        mime_type: item.mime.clone(),
                        size: item.blob.len,
                    })
                    .collect(),
            },
        };
        let answer: Result<Option<Option<ChangedResult>>, Error> =
            run_hook(&self.caller, "startToolAfter", request, self.token.clone()).await;
        let changed = match answer {
            Ok(Some(Some(changed))) => self.changed(result, changed).await,
            Ok(Some(None) | None) => return None,
            Err(error) => Err(failure_text("tool.after", &error)),
        };
        // A failed hook never shows the original result.
        Some(changed.unwrap_or_else(|text| ToolResult {
            call_id: result.call_id.clone(),
            content: text,
            is_error: true,
            media: Vec::new(),
            loaded: result.loaded.clone(),
        }))
    }
}

impl ScriptHooks {
    /// `result` after the `tool.after` handlers. The text and `is_error` come from `changed`. Each media item is an
    /// item of `result`, or a new item that the host stores. The `loaded` tools of `result` stay.
    async fn changed(&self, result: &ToolResult, changed: ChangedResult) -> Result<ToolResult, String> {
        // Each item is a kept item, or `None` for the next new item.
        let mut order = Vec::with_capacity(changed.media.len());
        let mut files = Vec::new();
        for item in changed.media {
            match item {
                ChangedMedia::Kept(index) => order.push(Some(result.media.get(index).cloned().ok_or_else(|| {
                    format!("the tool.after hooks kept media item {index}, which the result does not have")
                })?)),
                ChangedMedia::New(file) => {
                    files.push(file);
                    order.push(None);
                }
            }
        }
        let mut stored = store_media(&*self.host, files, &self.host.folder())
            .await
            .map_err(|error| format!("the tool.after hooks failed: {error}"))?
            .into_iter();
        Ok(ToolResult {
            call_id: result.call_id.clone(),
            content: changed.text,
            is_error: changed.is_error,
            media: order
                .into_iter()
                .filter_map(|kept| kept.or_else(|| stored.next()))
                .collect(),
            loaded: result.loaded.clone(),
        })
    }
}

/// What `openSession` gets.
#[derive(IntoJs)]
#[qjs(rename_all = "camelCase")]
struct OpenRequest<'js> {
    open: u64,
    session_id: String,
    folder: String,
    /// The native `ask(source, question)` of the session.
    ask: Function<'js>,
}

/// A question as the session context gives it to the native `ask`.
#[derive(FromJs)]
struct Question {
    kind: String,
    title: String,
    message: Option<String>,
    options: Option<Vec<String>>,
    placeholder: Option<String>,
    secret: Option<bool>,
}

impl Question {
    fn request(self) -> Option<InteractionRequest> {
        let Question {
            kind,
            title,
            message,
            options,
            placeholder,
            secret,
        } = self;
        Some(match kind.as_str() {
            "confirm" => InteractionRequest::Confirm {
                title,
                message: message.unwrap_or_default(),
            },
            "select" => InteractionRequest::Select {
                title,
                options: options?,
            },
            "input" => InteractionRequest::Input {
                title,
                placeholder,
                secret: secret.unwrap_or(false),
            },
            _ => return None,
        })
    }
}

/// The native `ask(source, question)` of the session of `host`. It answers an operation whose promise gives the answer:
/// a boolean for a confirm, a text for a select and an input, and `undefined` without an answer. Its cancel ends the
/// question.
fn ask_function<'js>(ctx: &Ctx<'js>, host: Arc<dyn SessionHost>) -> rquickjs::Result<Function<'js>> {
    Function::new(
        ctx.clone(),
        move |ctx: Ctx<'js>, source: String, question: Question| -> rquickjs::Result<Operation<'js>> {
            let Some(request) = question.request() else {
                return Err(throw(
                    &ctx,
                    ErrorClass::TypeError,
                    "ask: the question has no known kind",
                ));
            };
            let (host, stop) = (Arc::clone(&host), CancellationToken::new());
            let (settle, waiting) = (ctx.clone(), stop.clone());
            let promise = Promise::wrap_future(&ctx, async move {
                match host.ask(&source, request, waiting).await {
                    InteractionResponse::Confirm { value } => value.into_js(&settle),
                    InteractionResponse::Select { value } | InteractionResponse::Input { value } => {
                        value.into_js(&settle)
                    }
                    InteractionResponse::Canceled => Ok(Value::new_undefined(settle.clone())),
                }
            })?;
            let cancel = Function::new(ctx.clone(), move || stop.cancel())?;
            Ok(Operation { promise, cancel })
        },
    )
}

/// What `startPromptBuild` gets.
#[derive(IntoJs)]
struct PromptBuildRequest {
    open: u64,
    sections: Vec<Section>,
}

/// One system prompt section, in both directions.
#[derive(IntoJs, FromJs)]
struct Section {
    key: String,
    text: String,
}

/// What `startToolBefore` gets.
#[derive(IntoJs)]
struct ToolBeforeRequest {
    open: u64,
    call: HookCall,
}

/// What `startToolAfter` gets.
#[derive(IntoJs)]
struct ToolAfterRequest {
    open: u64,
    call: HookCall,
    result: HookResult,
}

/// One tool call of the model. The arguments cross as their parsed JSON.
#[derive(IntoJs)]
struct HookCall {
    id: String,
    name: String,
    arguments: JsonText,
}

impl HookCall {
    fn of(call: &ToolCall) -> Self {
        Self {
            id: call.call_id.clone(),
            name: call.name.clone(),
            arguments: JsonText(call.arguments.clone()),
        }
    }
}

/// The result of one tool call before the `tool.after` handlers.
#[derive(IntoJs)]
#[qjs(rename_all = "camelCase")]
struct HookResult {
    text: String,
    is_error: bool,
    media: Vec<HookMedia>,
}

/// A media item of a result: its media type and the size of its bytes.
#[derive(IntoJs)]
#[qjs(rename_all = "camelCase")]
struct HookMedia {
    mime_type: String,
    size: usize,
}

/// What `startRoundAfter` gets.
#[derive(IntoJs)]
#[qjs(rename_all = "camelCase")]
struct RoundAfterRequest {
    open: u64,
    text: String,
    finish_reason: Option<&'static str>,
    continues: u64,
}

/// The answer of the `round.after` handlers: `{ stop: true }`, or `{ continue, plugin }`.
#[derive(Debug)]
enum RoundAnswer {
    Stop,
    /// The text of the request, and the plugin that sent it.
    Continue {
        plugin: String,
        text: String,
    },
}

impl<'js> FromJs<'js> for RoundAnswer {
    fn from_js(_ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        let object = Object::from_value(value)?;
        Ok(match object.get::<_, Option<String>>("continue")? {
            Some(text) => Self::Continue {
                plugin: object.get("plugin")?,
                text,
            },
            None => Self::Stop,
        })
    }
}

/// The result after the `tool.after` handlers.
#[derive(Debug, FromJs)]
#[qjs(rename_all = "camelCase")]
struct ChangedResult {
    text: String,
    is_error: bool,
    media: Vec<ChangedMedia>,
}

/// A media item of a changed result.
#[derive(Debug)]
enum ChangedMedia {
    /// The item of the original result at this index. It crosses as a number.
    Kept(usize),
    /// A new item of an answer.
    New(MediaFile),
}

impl<'js> FromJs<'js> for ChangedMedia {
    fn from_js(ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        if value.is_number() {
            usize::from_js(ctx, value).map(Self::Kept)
        } else {
            MediaFile::from_js(ctx, value).map(Self::New)
        }
    }
}

/// The text of a failed run of the `point` hooks. The message of a failed handler names the point and its plugin.
fn failure_text(point: &str, error: &Error) -> String {
    match error {
        Error::Script(_) => error_text(error),
        other => format!("the {point} hooks failed: {other}"),
    }
}

/// Call the loader function `start` with `request` on the JavaScript thread, and return the answer of the run that it
/// starts. When `token` is cancelled, the run aborts its signal, and the call returns `None`.
async fn run_hook<R, T>(
    caller: &Caller,
    start: &'static str,
    request: R,
    token: CancellationToken,
) -> Result<Option<T>, Error>
where
    R: for<'js> IntoJs<'js> + Send + 'static,
    T: for<'js> FromJs<'js> + Send + 'static,
{
    // A driver drops a hook future at a cancel. A posted run goes on after that drop, so the cancel still reaches it.
    let (reply, answer) = oneshot::channel();
    caller.post(async move |ctx: Ctx<'_>, _: Rc<Registry>| {
        let answer = start_and_settle(&ctx, start, request, &token).await;
        if reply.send(answer).is_err() {
            // The caller has left, and the run has ended.
        }
    })?;
    answer.await.map_err(|_| Error::Stopped)?
}

/// Start the run of the loader function `start` with `request`, and await its answer. When `token` is cancelled, the run
/// aborts its signal, and the call returns `None` at once.
async fn start_and_settle<'js, R: IntoJs<'js>, T: FromJs<'js>>(
    ctx: &Ctx<'js>,
    start: &str,
    request: R,
    token: &CancellationToken,
) -> Result<Option<T>, Error> {
    let function: Function<'js> = caught(ctx, loader(ctx).await?.get(start))?;
    let started: Object<'js> = caught(ctx, function.call((request,)))?;
    let promise: Promise<'js> = caught(ctx, started.get("answer"))?;
    let abort: Function<'js> = caught(ctx, started.get("abort"))?;
    tokio::select! {
        answer = promise.into_future::<T>() => caught(ctx, answer).map(Some),
        () = token.cancelled() => {
            caught(ctx, abort.call::<_, ()>(()))?;
            Ok(None)
        }
    }
}

/// Close the open session `open` on the JavaScript thread: remove its tools, then await `closeSession`.
async fn close(ctx: &Ctx<'_>, registry: &Registry, open: u64) -> Result<(), Error> {
    let close_session: Function<'_> = caught(ctx, loader(ctx).await?.get("closeSession"))?;
    // No await comes between the two steps, so a dropped close cannot remove the tools without the close of the plugins.
    registry.close(open);
    let promise: Promise<'_> = caught(ctx, close_session.call((open,)))?;
    caught(ctx, promise.into_future::<()>().await)
}
