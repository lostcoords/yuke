//! These types open, use, and close one session of the plugins. Its tools are the tools of yuke and the tools that the
//! `session` exports define. Its hooks are the hooks that the `session` exports add.

use std::borrow::Cow;
use std::error::Error as StdError;
use std::fmt::Display;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use rquickjs::{Ctx, FromJs, Function, IntoJs, Object, Promise, Value};
use tokio::sync::oneshot;
use yuke_agent::{InputDecision, InputHook, PromptSection};
use yuke_ai::{Block, Failure, FinishReason, ProviderKind, ToolCall, ToolResult, answer_text};
use yuke_engine::{
    CancellationToken, Hooks, Replaced, RoundDecision, RoundError, RoundPlan, RoundStart, ToolDecision, chain_text,
};
use yuke_protocol::{
    Input, InputKind, InputSource, InteractionRequest, InteractionResponse, ModelReference, PendingInput,
};

use crate::error::{Error, caught};
use crate::models::{Models, merge_settings};
use crate::native::Operation;
use crate::native::ai::{Round, context_tokens, side_request, tokens};
use crate::plugins::loader;
use crate::runtime::{Caller, Handle};
use crate::tools::{Json, JsonText, MediaFile, Registry, ScriptTool, SessionHost, error_text, store_media};

/// An open session of the plugins. Call [`ScriptSession::close`] to await the cleanups. A drop posts the close and does
/// not wait. The posted close runs only while the runtime thread runs, so close each session before a shutdown.
pub struct ScriptSession {
    caller: Caller,
    host: Arc<dyn SessionHost>,
    /// The open number of the registry. A new open of the same session gets a new number, so a late close of this
    /// handle never reaches it.
    open: u64,
    models: Arc<dyn Models>,
}

impl std::fmt::Debug for ScriptSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ScriptSession")
            .field("session", &self.host.session_id())
            .field("open", &self.open)
            .finish_non_exhaustive()
    }
}

impl Handle {
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
        let model_host = Arc::clone(&host);
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
                    model: caught(
                        &ctx,
                        Function::new(ctx.clone(), move || Json(model_host.model_reference())),
                    )?,
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
            host,
            open,
            models: Arc::clone(&self.models),
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
        Ok(entries
            .into_iter()
            .map(|(id, definition, concurrency)| {
                let tool = ScriptTool {
                    caller: self.caller.clone(),
                    id,
                    open,
                    concurrency,
                    host: Arc::clone(&self.host),
                };
                (definition, tool)
            })
            .collect())
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
            sections: Json(sections.to_vec()),
        };
        let built: Option<Json<Vec<PromptSection>>> =
            run_hook(&self.caller, "startPromptBuild", request, token.clone()).await?;
        Ok(built.map_or_else(|| sections.to_vec(), |Json(built)| built))
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
            retries: AtomicU64::new(0),
            models: Arc::clone(&self.models),
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

/// The engine hooks of one turn of a session. The `s.hook` handlers of the plugins answer them. While the JavaScript
/// thread runs, each hook that they do not handle keeps its default.
pub struct ScriptHooks {
    caller: Caller,
    host: Arc<dyn SessionHost>,
    open: u64,
    token: CancellationToken,
    /// The `continue` answers of the `round.after` hooks in this turn.
    continues: AtomicU64,
    /// The `round.retry` answers that sent the current round again.
    retries: AtomicU64,
    models: Arc<dyn Models>,
}

impl std::fmt::Debug for ScriptHooks {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ScriptHooks")
            .field("open", &self.open)
            .finish_non_exhaustive()
    }
}

impl ScriptHooks {
    /// The natives of a round event for `round`: one copy of the round serves `context` and `sideRequest`.
    fn natives(&self, round: &RoundStart<'_>) -> RoundNatives {
        let round = Round {
            model: round.model.clone(),
            system: round.system.to_owned(),
            tools: round.tools.to_vec(),
            settings: round.settings.clone(),
            session_id: self.host.session_id(),
            context: round.context.to_vec(),
        };
        RoundNatives {
            round: Arc::new(round),
            models: Arc::clone(&self.models),
        }
    }
}

#[async_trait]
impl Hooks for ScriptHooks {
    async fn before_round(&self, round: &RoundStart<'_>) -> Result<RoundPlan, Box<dyn StdError + Send + Sync>> {
        // Each round starts here, so its count of retries starts at zero.
        self.retries.store(0, Ordering::Relaxed);
        let request = RoundBeforeRequest {
            open: self.open,
            window: round.model.context_window,
            input_tokens: round.input_tokens,
            context_tokens: context_tokens(round.context, round.input_tokens),
            blocks: round.context.len(),
            round: self.natives(round),
        };
        let answer: Option<Option<PlannedRound>> =
            run_hook(&self.caller, "startRoundBefore", request, self.token.clone())
                .await
                .map_err(|error| failure_text("round.before", &error))?;
        // A cancel ends the turn, so the driver does not read this plan.
        let Some(Some(planned)) = answer else {
            return Ok(RoundPlan::default());
        };
        Ok(planned.plan(round, &*self.host, "round.before")?)
    }

    async fn retry_round(
        &self,
        round: &RoundStart<'_>,
        failure: &RoundError,
    ) -> Result<Option<RoundPlan>, Box<dyn StdError + Send + Sync>> {
        // A failure of yuke itself has no kind for a plugin, so it ends the turn as without a handler.
        let Some(kind) = failure_kind(failure) else {
            return Ok(None);
        };
        let request = RoundRetryRequest {
            open: self.open,
            failure: RoundFailure {
                kind,
                message: chain_text(failure),
            },
            retries: self.retries.load(Ordering::Relaxed),
            window: round.model.context_window,
            input_tokens: round.input_tokens,
            context_tokens: context_tokens(round.context, round.input_tokens),
            blocks: round.context.len(),
            round: self.natives(round),
        };
        let answer: Option<Option<PlannedRound>> =
            run_hook(&self.caller, "startRoundRetry", request, self.token.clone())
                .await
                .map_err(|error| failure_text("round.retry", &error))?;
        // No answer ends the turn with the failure. A cancel ends the turn, so the driver does not read the plan.
        let Some(Some(planned)) = answer else {
            return Ok(None);
        };
        let plan = planned.plan(round, &*self.host, "round.retry")?;
        self.retries.fetch_add(1, Ordering::Relaxed);
        Ok(Some(plan))
    }

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

/// One item of a list that hooks answer: an item that stays, or a new media item that the host stores.
enum Answered<T> {
    Kept(T),
    New(MediaFile),
}

impl ScriptHooks {
    /// The items of `answered` in order. The host stores each new media item, and `item` makes it an item. A failed read
    /// or store fails with a text that names `point`.
    async fn stored<T>(
        &self,
        point: &str,
        answered: Vec<Answered<T>>,
        item: impl Fn(yuke_ai::Media) -> T,
    ) -> Result<Vec<T>, String> {
        // Each entry is a kept item, or `None` for the next new item.
        let mut order = Vec::with_capacity(answered.len());
        let mut files = Vec::new();
        for answer in answered {
            match answer {
                Answered::Kept(kept) => order.push(Some(kept)),
                Answered::New(file) => {
                    files.push(file);
                    order.push(None);
                }
            }
        }
        let mut stored = store_media(&*self.host, files, &self.host.folder())
            .await
            .map_err(|error| format!("the {point} hooks failed: {error}"))?
            .into_iter();
        Ok(order
            .into_iter()
            .filter_map(|kept| kept.or_else(|| stored.next().map(&item)))
            .collect())
    }

    /// `result` after the `tool.after` handlers. The text and `is_error` come from `changed`. Each media item is an
    /// item of `result`, or a new item that the host stores. The `loaded` tools of `result` stay.
    async fn changed(&self, result: &ToolResult, changed: ChangedResult) -> Result<ToolResult, String> {
        let mut answered = Vec::with_capacity(changed.media.len());
        for item in changed.media {
            answered.push(match item {
                ChangedMedia::Kept(index) => Answered::Kept(result.media.get(index).cloned().ok_or_else(|| {
                    format!("the tool.after hooks kept media item {index}, which the result does not have")
                })?),
                ChangedMedia::New(file) => Answered::New(file),
            });
        }
        Ok(ToolResult {
            call_id: result.call_id.clone(),
            content: changed.text,
            is_error: changed.is_error,
            media: self.stored("tool.after", answered, |media| media).await?,
            loaded: result.loaded.clone(),
        })
    }
}

#[async_trait]
impl InputHook for ScriptHooks {
    async fn before_input(&self, input: &PendingInput) -> Result<InputDecision, Box<dyn StdError + Send + Sync>> {
        let request = InputBeforeRequest {
            open: self.open,
            session_id: self.host.session_id().to_string(),
            source: Json(input.input.source().clone()),
            kind: Json(input.input.kind()),
            blocks: Json(input.input.model_content().to_vec()),
        };
        let answer: Option<Option<PlannedInput>> =
            run_hook(&self.caller, "startInputBefore", request, self.token.clone())
                .await
                .map_err(|error| failure_text("input.before", &error))?;
        // A cancel ends the turn, so the input stays pending as it is.
        let Some(Some(planned)) = answer else {
            return Ok(InputDecision::Keep);
        };
        let Some(items) = planned.blocks else {
            return Ok(InputDecision::Remove);
        };
        let answered = items
            .into_iter()
            .map(|item| match item {
                InputItem::Block(Json(block)) => Answered::Kept(block),
                InputItem::New(file) => Answered::New(file),
            })
            .collect();
        Ok(InputDecision::Replace(
            self.stored("input.before", answered, Block::Media).await?,
        ))
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
    /// The native `model()` of the session, which gives the model that the settings name now.
    model: Function<'js>,
}

/// The native `ask(source, question)` of the session of `host`. It answers an operation whose promise gives the answer:
/// a boolean for a confirm, a text for a select and an input, and `undefined` without an answer. Its cancel ends the
/// question.
fn ask_function<'js>(ctx: &Ctx<'js>, host: Arc<dyn SessionHost>) -> rquickjs::Result<Function<'js>> {
    Function::new(
        ctx.clone(),
        move |ctx: Ctx<'js>,
              source: String,
              Json(request): Json<InteractionRequest>|
              -> rquickjs::Result<Operation<'js>> {
            let host = Arc::clone(&host);
            Operation::start(&ctx, move |ctx, stop| async move {
                match host.ask(&source, request, stop).await {
                    InteractionResponse::Confirm { value } => value.into_js(&ctx),
                    InteractionResponse::Select { value } | InteractionResponse::Input { value } => value.into_js(&ctx),
                    InteractionResponse::Canceled => Ok(Value::new_undefined(ctx.clone())),
                }
            })
        },
    )
}

/// What `startPromptBuild` gets.
#[derive(IntoJs)]
struct PromptBuildRequest {
    open: u64,
    sections: Json<Vec<PromptSection>>,
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

/// What `startRoundRetry` gets: the facts of `startRoundBefore`, and why the round failed.
#[derive(IntoJs)]
#[qjs(rename_all = "camelCase")]
struct RoundRetryRequest {
    open: u64,
    failure: RoundFailure,
    retries: u64,
    window: Option<u64>,
    input_tokens: Option<u64>,
    /// The estimate of [`context_tokens`] for the context before the round.
    context_tokens: u64,
    blocks: usize,
    round: RoundNatives,
}

/// Why a round failed, for `round.retry`.
#[derive(IntoJs)]
struct RoundFailure {
    kind: &'static str,
    message: String,
}

/// The `kind` of `failure` for `round.retry`, or `None` for a failure of yuke itself.
fn failure_kind(failure: &RoundError) -> Option<&'static str> {
    Some(match failure {
        RoundError::Credential(_) => "credential",
        RoundError::Model(yuke_ai::Error::Encode(_)) => "encode",
        RoundError::Model(yuke_ai::Error::Attempt(attempt)) => match attempt.cause {
            Failure::Provider(kind) => match kind {
                ProviderKind::ContextOverflow => "context_overflow",
                ProviderKind::RateLimited => "rate_limited",
                ProviderKind::RateLimitUnknown => "rate_limit_unknown",
                ProviderKind::QuotaExhausted => "quota_exhausted",
                ProviderKind::ServerError => "server_error",
                ProviderKind::Timeout => "timeout",
                ProviderKind::Conflict => "conflict",
                ProviderKind::AuthFailed => "auth_failed",
                ProviderKind::PermissionDenied => "permission_denied",
                ProviderKind::BadStatus => "bad_status",
                ProviderKind::ProviderFailed => "provider_failed",
            },
            Failure::Transport(_) => "transport",
            Failure::Protocol => "protocol",
            Failure::ResponseTooLarge => "response_too_large",
            Failure::IncompleteStream => "incomplete_stream",
        },
        RoundError::Hook { .. } | RoundError::Inbox(_) => return None,
    })
}

/// What `startRoundBefore` gets.
#[derive(IntoJs)]
#[qjs(rename_all = "camelCase")]
struct RoundBeforeRequest {
    open: u64,
    window: Option<u64>,
    input_tokens: Option<u64>,
    /// The estimate of [`context_tokens`] for the context before the round.
    context_tokens: u64,
    blocks: usize,
    round: RoundNatives,
}

/// A copy of the round. `round.before` and `round.retry` make it, also without a handler. It crosses to JavaScript as
/// the functions `context`, `tokens`, and `sideRequest`. `context` converts the blocks at each call, so a round without
/// a call converts nothing.
struct RoundNatives {
    round: Arc<Round>,
    models: Arc<dyn Models>,
}

impl<'js> IntoJs<'js> for RoundNatives {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<Value<'js>> {
        let object = Object::new(ctx.clone())?;
        object.set("sideRequest", side_request(ctx, Arc::clone(&self.round), self.models)?)?;
        object.set("tokens", tokens(ctx, Arc::clone(&self.round))?)?;
        let round = self.round;
        object.set(
            "context",
            Function::new(ctx.clone(), move || Json(round.context.clone()))?,
        )?;
        object.into_js(ctx)
    }
}

/// The plan of the `round.before` handlers. Each part names the plugin of its last change.
#[derive(FromJs)]
struct PlannedRound {
    replace: Option<PlannedReplace>,
    model: Option<PlannedModel>,
    settings: Option<PlannedSettings>,
}

#[derive(FromJs)]
struct PlannedReplace {
    plugin: String,
    head: Json<serde_json::Value>,
    keep: usize,
}

#[derive(FromJs)]
struct PlannedModel {
    plugin: String,
    provider: String,
    model: String,
}

#[derive(FromJs)]
struct PlannedSettings {
    plugin: String,
    changes: Json<serde_json::Map<String, serde_json::Value>>,
}

impl PlannedRound {
    /// The plan of the engine for `round`, from the handlers of `point`. Each failure names its plugin: a head that is
    /// not a list of blocks, a replacement with a result without its call, a model that `host` does not know, or settings
    /// of another shape.
    fn plan(self, round: &RoundStart<'_>, host: &dyn SessionHost, point: &str) -> Result<RoundPlan, String> {
        let failed = |plugin: &str, error: &dyn Display| format!("{point} of plugin {plugin} failed: {error}");
        let replace = match self.replace {
            Some(PlannedReplace { plugin, head, keep }) => {
                let head: Vec<Block> = serde_json::from_value(head.0)
                    .map_err(|error| failed(&plugin, &format!("the head is not a list of blocks: {error}")))?;
                let replaced = Replaced {
                    head: Cow::Owned(head),
                    keep,
                };
                replaced.check(round.context).map_err(|error| failed(&plugin, &error))?;
                Some(replaced)
            }
            None => None,
        };
        let model = match self.model {
            Some(PlannedModel {
                plugin,
                provider,
                model,
            }) => {
                let reference = ModelReference { provider, model };
                Some(host.model(&reference).map_err(|error| failed(&plugin, &error))?)
            }
            None => None,
        };
        let settings = match self.settings {
            Some(PlannedSettings { plugin, changes }) => {
                Some(merge_settings(round.settings, changes.0).map_err(|error| failed(&plugin, &error))?)
            }
            None => None,
        };
        Ok(RoundPlan {
            replace,
            model,
            settings,
        })
    }
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

/// What `startInputBefore` gets.
#[derive(IntoJs)]
#[qjs(rename_all = "camelCase")]
struct InputBeforeRequest {
    open: u64,
    session_id: String,
    source: Json<InputSource>,
    kind: Json<InputKind>,
    /// The blocks that the model reads.
    blocks: Json<Vec<Block>>,
}

/// The plan of the `input.before` handlers: the new blocks of the input, or no blocks for a removal.
#[derive(FromJs)]
struct PlannedInput {
    blocks: Option<Vec<InputItem>>,
}

/// One item of the new blocks of an input.
enum InputItem {
    /// A block, also a media block that the session holds. It crosses as its JSON.
    Block(Json<Block>),
    /// A new media item: a `ToolMedia`, with a `mimeType`.
    New(MediaFile),
}

impl<'js> FromJs<'js> for InputItem {
    fn from_js(ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        let media = value
            .as_object()
            .is_some_and(|object| object.contains_key("mimeType").unwrap_or(false));
        if media {
            MediaFile::from_js(ctx, value).map(Self::New)
        } else {
            Json::from_js(ctx, value).map(Self::Block)
        }
    }
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
        let answer = async {
            let function: Function<'_> = caught(&ctx, loader(&ctx).await?.get(start))?;
            let Operation { promise, cancel } = caught(&ctx, function.call((request,)))?;
            tokio::select! {
                answer = promise.into_future::<T>() => caught(&ctx, answer).map(Some),
                () = token.cancelled() => {
                    caught(&ctx, cancel.call::<_, ()>(()))?;
                    Ok(None)
                }
            }
        };
        if reply.send(answer.await).is_err() {
            // The caller has left, and the run has ended.
        }
    })?;
    answer.await.map_err(|_| Error::Stopped)?
}

/// Close the open session `open` on the JavaScript thread: remove its tools, then await `closeSession`.
async fn close(ctx: &Ctx<'_>, registry: &Registry, open: u64) -> Result<(), Error> {
    let close_session: Function<'_> = caught(ctx, loader(ctx).await?.get("closeSession"))?;
    // No await comes between the two steps, so a dropped close cannot remove the tools without the close of the plugins.
    registry.close(open);
    let promise: Promise<'_> = caught(ctx, close_session.call((open,)))?;
    caught(ctx, promise.into_future::<()>().await)
}
