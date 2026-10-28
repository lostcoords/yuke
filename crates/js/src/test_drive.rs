//! The drivers of `run` and `call` in `yuke:test`. A driver runs one hook point or one tool of a session from plain
//! data. It uses the real hooks and tools, so each point keeps the conversions and the checks of a turn.

use std::convert::Infallible;
use std::sync::atomic::{AtomicU64, Ordering};

use rquickjs::{Array, Ctx, FromJs, IntoJs, Object, TypedArray, Value};
use serde_json::json;
use tokio::sync::mpsc;
use yuke_agent::{InputDecision, InputHook, PromptSection};
use yuke_ai::{
    AttemptError, AttemptInfo, Block, Failure, FinishReason, Media, ProviderKind, Settings, ToolCall, ToolDefinition,
    ToolResult,
};
use yuke_engine::{CancellationToken, Hooks, Model, RoundDecision, RoundError, RoundPlan, RoundStart, ToolDecision};
use yuke_protocol::{Input, InputId, InputKind, InputSource, PendingInput, SessionId};

use crate::ScriptSession;
use crate::test_host::TestHost;
use crate::test_runner::TestError;
use crate::tools::{Json, MediaFile, forward, store_media};

/// The calls of `call` so far, for the id of the next call.
static CALLS: AtomicU64 = AtomicU64::new(0);

/// The field `name` of `object`. A missing field is `undefined`, which an `Option` reads as `None`.
fn field<'js, T: FromJs<'js>>(object: &Object<'js>, name: &str) -> rquickjs::Result<T> {
    object.get(name)
}

/// The tool call of an event: `{ callId, name, arguments }`, with the arguments as their JSON.
#[derive(FromJs)]
#[qjs(rename_all = "camelCase")]
struct EventCall {
    call_id: String,
    name: String,
    arguments: Json<serde_json::Value>,
}

impl From<EventCall> for ToolCall {
    fn from(call: EventCall) -> Self {
        ToolCall {
            call_id: call.call_id,
            name: call.name,
            arguments: call.arguments.0.to_string(),
        }
    }
}

/// The result of a `tool.after` event. Each media item is a `ToolMedia` of `yuke:tools`.
#[derive(FromJs)]
#[qjs(rename_all = "camelCase")]
struct EventResult {
    text: String,
    is_error: bool,
    media: Option<Vec<MediaFile>>,
}

/// The round of a `round.before` or a `round.retry` event, as plain data.
struct EventRound {
    context: Vec<Block>,
    /// `Some` when the event names a window, also `null`. It then replaces the window of the model of the session.
    #[expect(
        clippy::option_option,
        reason = "a missing window keeps the window of the model, and null removes it"
    )]
    window: Option<Option<u64>>,
    input_tokens: Option<u64>,
    system: Option<String>,
    tools: Option<Vec<ToolDefinition>>,
    settings: Option<Settings>,
}

impl<'js> FromJs<'js> for EventRound {
    fn from_js(_ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        let event = Object::from_value(value)?;
        Ok(EventRound {
            context: field::<Json<_>>(&event, "context")?.0,
            window: if event.contains_key("window")? {
                Some(field(&event, "window")?)
            } else {
                None
            },
            input_tokens: field(&event, "inputTokens")?,
            system: field(&event, "system")?,
            tools: field::<Option<Json<_>>>(&event, "tools")?.map(|tools| tools.0),
            settings: field::<Option<Json<_>>>(&event, "settings")?.map(|settings| settings.0),
        })
    }
}

/// An item of the blocks of an `input.before` event: a media item or a block.
enum EventBlock {
    Media(MediaFile),
    Block(Block),
}

impl<'js> FromJs<'js> for EventBlock {
    fn from_js(ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        let object = Object::from_value(value.clone())?;
        if object.contains_key("mimeType")? {
            Ok(EventBlock::Media(MediaFile::from_js(ctx, value)?))
        } else {
            Ok(EventBlock::Block(Json::from_js(ctx, value)?.0))
        }
    }
}

/// One hook point of `run` with its event.
enum Point {
    ToolBefore(ToolCall),
    ToolAfter(ToolCall, EventResult),
    RoundBefore(EventRound),
    RoundRetry {
        round: EventRound,
        failure: String,
        retries: u64,
    },
    RoundAfter {
        text: String,
        finish_reason: Option<FinishReason>,
        continues: u64,
    },
    InputBefore {
        source: InputSource,
        kind: InputKind,
        blocks: Vec<EventBlock>,
    },
    PromptBuild(Vec<PromptSection>),
}

/// A request of `run`: `[id, point, event]`. The JavaScript thread reads it before the host runs it.
pub(crate) struct RunRequest {
    pub(crate) id: SessionId,
    point: Point,
}

impl<'js> FromJs<'js> for RunRequest {
    fn from_js(ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        let request = Array::from_value(value)?;
        let id = request.get::<Json<SessionId>>(0)?.0;
        let name: String = request.get(1)?;
        let event: Object<'js> = request.get(2)?;
        let point = match name.as_str() {
            "tool.before" => Point::ToolBefore(field::<EventCall>(&event, "call")?.into()),
            "tool.after" => Point::ToolAfter(field::<EventCall>(&event, "call")?.into(), field(&event, "result")?),
            "round.before" => Point::RoundBefore(EventRound::from_js(ctx, event.into_value())?),
            "round.retry" => {
                let failure: Object<'js> = field(&event, "failure")?;
                Point::RoundRetry {
                    failure: field(&failure, "kind")?,
                    retries: field::<Option<u64>>(&event, "retries")?.unwrap_or(0),
                    round: EventRound::from_js(ctx, event.into_value())?,
                }
            }
            "round.after" => Point::RoundAfter {
                text: field(&event, "text")?,
                finish_reason: field::<Option<Json<_>>>(&event, "finishReason")?.and_then(|reason| reason.0),
                continues: field::<Option<u64>>(&event, "continues")?.unwrap_or(0),
            },
            "input.before" => Point::InputBefore {
                source: field::<Json<_>>(&event, "source")?.0,
                kind: field::<Json<_>>(&event, "kind")?.0,
                blocks: field(&event, "blocks")?,
            },
            // The order of the sections is the order of the prompt, and an object keeps the order of its keys.
            "prompt.build" => Point::PromptBuild(
                field::<Object<'js>>(&event, "sections")?
                    .props::<String, String>()
                    .map(|section| section.map(|(key, text)| PromptSection { key, text }))
                    .collect::<rquickjs::Result<_>>()?,
            ),
            other => {
                return Err(rquickjs::Error::new_from_js_message(
                    "value",
                    "test event",
                    format!("{other} is no hook point"),
                ));
            }
        };
        Ok(RunRequest { id, point })
    }
}

/// A request of `call`: `[id, tool, args]`.
pub(crate) struct CallRequest {
    pub(crate) id: SessionId,
    tool: String,
    arguments: String,
}

impl<'js> FromJs<'js> for CallRequest {
    fn from_js(_ctx: &Ctx<'js>, value: Value<'js>) -> rquickjs::Result<Self> {
        let request = Array::from_value(value)?;
        Ok(CallRequest {
            id: request.get::<Json<SessionId>>(0)?.0,
            tool: request.get(1)?,
            arguments: request.get::<Json<serde_json::Value>>(2)?.0.to_string(),
        })
    }
}

/// A media item that the host gives back, with its bytes from the store.
pub(crate) struct OutMedia {
    mime_type: String,
    bytes: Vec<u8>,
}

impl<'js> IntoJs<'js> for OutMedia {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<Value<'js>> {
        let object = Object::new(ctx.clone())?;
        object.set("mimeType", self.mime_type)?;
        object.set("size", self.bytes.len())?;
        object.set("bytes", TypedArray::<u8>::new(ctx.clone(), self.bytes)?)?;
        Ok(object.into_value())
    }
}

/// A block of an `input.before` replacement that the host gives back. A media block has its bytes.
pub(crate) enum OutBlock {
    Block(Block),
    Media(OutMedia),
}

/// The decision of the host at a hook point, or the outcome of a call, for `yuke:test`.
pub(crate) enum Decision {
    /// A decision of plain data.
    Json(serde_json::Value),
    /// A tool result. A call also gives its live texts.
    Outcome {
        text: String,
        is_error: bool,
        media: Vec<OutMedia>,
        output: Option<Vec<String>>,
    },
    /// The blocks of an `input.before` replacement.
    Replace(Vec<OutBlock>),
    /// The sections of `prompt.build`, in the order of the prompt.
    Sections(Vec<PromptSection>),
}

impl<'js> IntoJs<'js> for Decision {
    fn into_js(self, ctx: &Ctx<'js>) -> rquickjs::Result<Value<'js>> {
        let object = Object::new(ctx.clone())?;
        match self {
            Decision::Json(value) => return Json(value).into_js(ctx),
            Decision::Outcome {
                text,
                is_error,
                media,
                output,
            } => {
                object.set("text", text)?;
                object.set("isError", is_error)?;
                object.set("media", media)?;
                if let Some(output) = output {
                    object.set("output", output)?;
                }
            }
            Decision::Replace(blocks) => {
                let items = Array::new(ctx.clone())?;
                for (index, block) in blocks.into_iter().enumerate() {
                    match block {
                        OutBlock::Block(block) => items.set(index, Json(block))?,
                        OutBlock::Media(media) => items.set(index, media)?,
                    }
                }
                let replace = Object::new(ctx.clone())?;
                replace.set("blocks", items)?;
                object.set("replace", replace)?;
            }
            Decision::Sections(built) => {
                let sections = Object::new(ctx.clone())?;
                for section in built {
                    sections.set(section.key, section.text)?;
                }
                object.set("sections", sections)?;
            }
        }
        Ok(object.into_value())
    }
}

/// Store each item of `media` in the session of `script`, as for a tool result or a hook answer.
async fn stored(script: &ScriptSession, media: Vec<MediaFile>) -> Result<Vec<Media>, TestError> {
    Ok(store_media(&*script.host, media, &script.host.folder()).await?)
}

/// Read the bytes of each item of `media` of the session `id` from the store.
fn read(host: &dyn TestHost, id: SessionId, media: Vec<Media>) -> Result<Vec<OutMedia>, TestError> {
    media
        .into_iter()
        .map(|item| {
            Ok(OutMedia {
                bytes: host.read_media(id, &item.blob)?,
                mime_type: item.mime,
            })
        })
        .collect()
}

/// The round of `event` with its own copies of the parts that [`RoundStart`] borrows.
struct OwnedRound {
    context: Vec<Block>,
    model: Model,
    settings: Settings,
    system: String,
    tools: Vec<ToolDefinition>,
    input_tokens: Option<u64>,
}

impl OwnedRound {
    /// The round of `event`. The model of the round is the model of the session of `script`, as in a turn.
    fn of(script: &ScriptSession, event: EventRound) -> Result<Self, TestError> {
        let mut model = script.host.model(&script.host.model_reference())?;
        if let Some(window) = event.window {
            model.context_window = window;
        }
        Ok(OwnedRound {
            context: event.context,
            model,
            settings: event.settings.unwrap_or_default(),
            system: event.system.unwrap_or_default(),
            tools: event.tools.unwrap_or_default(),
            input_tokens: event.input_tokens,
        })
    }

    fn start(&self) -> RoundStart<'_> {
        RoundStart {
            context: &self.context,
            model: &self.model,
            settings: &self.settings,
            system: &self.system,
            tools: &self.tools,
            input_tokens: self.input_tokens,
        }
    }
}

/// The failure of a round of the kind `kind`, as a turn meets it.
fn round_error(kind: &str) -> Result<RoundError, TestError> {
    let provider = |kind: ProviderKind| Failure::Provider(kind);
    let cause = match kind {
        "context_overflow" => provider(ProviderKind::ContextOverflow),
        "rate_limited" => provider(ProviderKind::RateLimited),
        "rate_limit_unknown" => provider(ProviderKind::RateLimitUnknown),
        "quota_exhausted" => provider(ProviderKind::QuotaExhausted),
        "server_error" => provider(ProviderKind::ServerError),
        "timeout" => provider(ProviderKind::Timeout),
        "conflict" => provider(ProviderKind::Conflict),
        "auth_failed" => provider(ProviderKind::AuthFailed),
        "permission_denied" => provider(ProviderKind::PermissionDenied),
        "bad_status" => provider(ProviderKind::BadStatus),
        "provider_failed" => provider(ProviderKind::ProviderFailed),
        "transport" => Failure::Transport(yuke_ai::transport::Fault::ConnectionLost),
        "protocol" => Failure::Protocol,
        "response_too_large" => Failure::ResponseTooLarge,
        "incomplete_stream" => Failure::IncompleteStream,
        "credential" => return Ok(RoundError::Credential("the test failed the credential".into())),
        "encode" => {
            return Ok(RoundError::Model(yuke_ai::Error::Encode(
                yuke_ai::EncodeError::Unsupported(yuke_ai::Unsupported::UnnamedDocument),
            )));
        }
        other => return Err(format!("the failure kind {other} has no test form").into()),
    };
    Ok(RoundError::Model(yuke_ai::Error::Attempt(AttemptError {
        cause,
        info: AttemptInfo::default(),
        partial: Vec::new(),
    })))
}

/// The JSON of `plan`: the replacement, the model of the round, and its settings.
fn plan_json(plan: RoundPlan) -> Result<serde_json::Value, TestError> {
    let mut json = serde_json::Map::new();
    if let Some(replace) = plan.replace {
        json.insert(
            "replace".to_owned(),
            json!({ "head": serde_json::to_value(replace.head.as_ref())?, "keep": replace.keep }),
        );
    }
    if let Some(model) = plan.model {
        json.insert(
            "model".to_owned(),
            serde_json::Value::String(model.target.model.to_string()),
        );
    }
    if let Some(settings) = plan.settings {
        json.insert("settings".to_owned(), serde_json::to_value(settings)?);
    }
    Ok(serde_json::Value::Object(json))
}

/// Run the hook point of `request` in its session of `host`, as a turn does, and return the decision of the host.
pub(crate) async fn run_point(
    host: &dyn TestHost,
    request: RunRequest,
    token: CancellationToken,
) -> Result<Decision, TestError> {
    let id = request.id;
    let script = host.script_session(id)?;
    let hooks = script.hooks(token.clone());
    Ok(match request.point {
        Point::ToolBefore(call) => Decision::Json(match hooks.before_tool(&call).await {
            ToolDecision::Run => json!("run"),
            ToolDecision::Block(reason) => json!({ "block": reason }),
        }),
        Point::ToolAfter(call, result) => {
            let result = ToolResult {
                call_id: call.call_id.clone(),
                content: result.text,
                is_error: result.is_error,
                media: stored(&script, result.media.unwrap_or_default()).await?,
                loaded: Vec::new(),
            };
            let changed = hooks.after_tool(&call, &result).await.unwrap_or(result);
            Decision::Outcome {
                text: changed.content,
                is_error: changed.is_error,
                media: read(host, id, changed.media)?,
                output: None,
            }
        }
        Point::RoundBefore(event) => {
            let round = OwnedRound::of(&script, event)?;
            Decision::Json(plan_json(hooks.before_round(&round.start()).await?)?)
        }
        Point::RoundRetry {
            round,
            failure,
            retries,
        } => {
            let round = OwnedRound::of(&script, round)?;
            let failure = round_error(&failure)?;
            hooks.retries.store(retries, Ordering::Relaxed);
            Decision::Json(match hooks.retry_round(&round.start(), &failure).await? {
                Some(plan) => plan_json(plan)?,
                None => serde_json::Value::Null,
            })
        }
        Point::RoundAfter {
            text,
            finish_reason,
            continues,
        } => {
            hooks.continues.store(continues, Ordering::Relaxed);
            Decision::Json(
                match hooks.after_round(&[Block::assistant_text(text)], finish_reason).await? {
                    RoundDecision::Proceed => json!("proceed"),
                    RoundDecision::Stop => json!("stop"),
                },
            )
        }
        Point::InputBefore { source, kind, blocks } => {
            let mut stored_blocks = Vec::with_capacity(blocks.len());
            for item in blocks {
                match item {
                    EventBlock::Block(block) => stored_blocks.push(block),
                    EventBlock::Media(media) => {
                        stored_blocks.extend(stored(&script, vec![media]).await?.into_iter().map(Block::Media));
                    }
                }
            }
            let input = Input::new(source, kind, stored_blocks)?;
            let pending = PendingInput { id: InputId(1), input };
            match hooks.before_input(&pending).await? {
                InputDecision::Keep => Decision::Json(json!("keep")),
                InputDecision::Remove => Decision::Json(json!("remove")),
                InputDecision::Replace(blocks) => Decision::Replace(
                    blocks
                        .into_iter()
                        .map(|block| match block {
                            Block::Media(media) => Ok(OutBlock::Media(read(host, id, vec![media])?.remove(0))),
                            block => Ok(OutBlock::Block(block)),
                        })
                        .collect::<Result<_, TestError>>()?,
                ),
            }
        }
        Point::PromptBuild(sections) => Decision::Sections(script.build_prompt(&sections, &token).await?),
    })
}

/// Call the tool of `request` in its session of `host` with its arguments, as a turn does. Return its result with its
/// live texts in order.
pub(crate) async fn call_tool(
    host: &dyn TestHost,
    request: CallRequest,
    token: CancellationToken,
) -> Result<Decision, TestError> {
    let tools = host.script_session(request.id)?.tools().await?;
    let (_, tool) = tools
        .iter()
        .find(|(definition, _)| definition.name == request.tool)
        .ok_or(format!("the session has no tool {}", request.tool))?;
    let (output, texts) = mpsc::unbounded_channel();
    // A plugin can key its state on the call id, so each call gets its own.
    let call_id = format!("call_{}", CALLS.fetch_add(1, Ordering::Relaxed) + 1);
    let answer = tool.answer(&request.arguments, &call_id, token, output);
    let mut output = Vec::new();
    let Ok(content) = forward(answer, texts, |text| {
        output.push(text.to_owned());
        Ok::<_, Infallible>(())
    })
    .await;
    let output = Some(output);
    Ok(match content {
        Ok(content) => Decision::Outcome {
            text: content.text,
            is_error: content.is_error,
            media: read(host, request.id, content.media)?,
            output,
        },
        Err(text) => Decision::Outcome {
            text,
            is_error: true,
            media: Vec::new(),
            output,
        },
    })
}
