//! The drivers of `run` and `call` in `yuke:test`. A driver runs one hook point or one tool of a session from plain
//! data. It uses the real hooks and tools, so each point keeps the conversions and the checks of a turn.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value, json};
use tokio::sync::mpsc;
use yuke_agent::{InputDecision, InputHook, PromptSection};
use yuke_ai::route::{Credential, Route};
use yuke_ai::{
    AnthropicWire, AttemptError, AttemptInfo, Block, Failure, FinishReason, Media, ProviderKind, Settings, Target,
    ToolCall, ToolDefinition, ToolResult, Wire, decode_base64, encode_base64_into,
};
use yuke_engine::{CancellationToken, Hooks, Model, RoundDecision, RoundError, RoundPlan, RoundStart, ToolDecision};
use yuke_protocol::{Input, InputId, InputKind, InputSource, PendingInput, SessionId};

use crate::ScriptSession;
use crate::test_host::TestHost;
use crate::test_runner::TestError;
use crate::tools::{MediaFile, Source, forward, store_media};

/// The calls of `call` so far, for the id of the next call.
static CALLS: AtomicU64 = AtomicU64::new(0);

/// A media item of an event of `run`: the `ToolMedia` of `yuke:tools`. It has a path, or its bytes in base64.
#[derive(Deserialize)]
#[serde(untagged)]
enum EventMedia {
    Path {
        #[serde(rename = "mimeType")]
        mime_type: String,
        path: String,
    },
    Bytes {
        #[serde(rename = "mimeType")]
        mime_type: String,
        base64: String,
    },
}

/// An item of the blocks of an `input.before` event: a media item or a block.
#[derive(Deserialize)]
#[serde(untagged)]
enum EventBlock {
    Media(EventMedia),
    Block(Block),
}

/// Store each item of `media` in the session of `script`, as a tool result or an answer of a hook does.
async fn stored(script: &ScriptSession, media: Vec<EventMedia>) -> Result<Vec<Media>, TestError> {
    let files = media
        .into_iter()
        .map(|item| match item {
            EventMedia::Path { mime_type, path } => Ok(MediaFile {
                mime_type,
                source: Source::Path(path),
            }),
            EventMedia::Bytes { mime_type, base64 } => Ok(MediaFile {
                mime_type,
                source: Source::Bytes(decode_base64(base64.as_bytes()).ok_or("a media item has no base64 bytes")?),
            }),
        })
        .collect::<Result<Vec<_>, TestError>>()?;
    Ok(store_media(&*script.host, files, &script.host.folder()).await?)
}

/// The view of `media` of the session `id` for `yuke:test`: its media type, its size, and its bytes in base64.
fn media_view(host: &dyn TestHost, id: SessionId, media: &[Media]) -> Result<Vec<Value>, TestError> {
    media
        .iter()
        .map(|item| {
            let mut base64 = Vec::new();
            encode_base64_into(&mut base64, &host.read_media(id, &item.blob)?);
            Ok(json!({
                "mimeType": item.mime,
                "size": item.blob.len,
                "base64": String::from_utf8_lossy(&base64),
            }))
        })
        .collect()
}

/// The field `name` of `event`, as `T`.
fn field<T: DeserializeOwned>(event: &Value, name: &str) -> Result<T, TestError> {
    let value = event.get(name).cloned().unwrap_or(Value::Null);
    serde_json::from_value(value).map_err(|error| format!("the field {name} of the event: {error}").into())
}

/// The field `name` of `event`, or `None` when it is missing or `null`.
fn optional<T: DeserializeOwned>(event: &Value, name: &str) -> Result<Option<T>, TestError> {
    match event.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(_) => field(event, name).map(Some),
    }
}

/// The tool call of `event`: `{ call: { id, name, arguments } }`, with the arguments as their parsed JSON.
fn tool_call(event: &Value) -> Result<ToolCall, TestError> {
    let call: Value = field(event, "call")?;
    Ok(ToolCall {
        call_id: field(&call, "id")?,
        name: field(&call, "name")?,
        arguments: call.get("arguments").cloned().unwrap_or(Value::Null).to_string(),
    })
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
    /// `{ context, window?, inputTokens?, system?, tools?, settings? }`. The model of the round is a test target with the
    /// context window `window`.
    fn of(event: &Value) -> Result<Self, TestError> {
        Ok(OwnedRound {
            context: field(event, "context")?,
            model: Model {
                target: Target {
                    model: "test-model".into(),
                    route: Route::default(),
                    wire: Wire::AnthropicMessages(AnthropicWire {
                        max_tokens: 1024,
                        cache: false,
                    }),
                    tool_search: false,
                },
                source: Arc::new(Credential::None),
                context_window: optional(event, "window")?,
            },
            settings: optional(event, "settings")?.unwrap_or_else(Settings::new),
            system: optional(event, "system")?.unwrap_or_default(),
            tools: optional(event, "tools")?.unwrap_or_default(),
            input_tokens: optional(event, "inputTokens")?,
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
fn plan_json(plan: RoundPlan) -> Result<Value, TestError> {
    let mut json = Map::new();
    if let Some(replace) = plan.replace {
        json.insert(
            "replace".to_owned(),
            json!({ "head": serde_json::to_value(replace.head.as_ref())?, "keep": replace.keep }),
        );
    }
    if let Some(model) = plan.model {
        json.insert("model".to_owned(), Value::String(model.target.model.to_string()));
    }
    if let Some(settings) = plan.settings {
        json.insert("settings".to_owned(), serde_json::to_value(settings)?);
    }
    Ok(Value::Object(json))
}

/// Run the hook point `point` of the session `id` of `host` with `event`, as a turn does, and return the decision of
/// the host.
pub(crate) async fn run_point(
    host: &dyn TestHost,
    id: SessionId,
    point: &str,
    event: &Value,
    token: CancellationToken,
) -> Result<Value, TestError> {
    let script = host.script_session(id)?;
    let hooks = script.hooks(token.clone());
    match point {
        "tool.before" => Ok(match hooks.before_tool(&tool_call(event)?).await {
            ToolDecision::Run => json!("run"),
            ToolDecision::Block(reason) => json!({ "block": reason }),
        }),
        "tool.after" => {
            let call = tool_call(event)?;
            let result: Value = field(event, "result")?;
            let media = optional(&result, "media")?.unwrap_or_default();
            let result = ToolResult {
                call_id: call.call_id.clone(),
                content: field(&result, "text")?,
                is_error: field(&result, "isError")?,
                media: stored(&script, media).await?,
                loaded: Vec::new(),
            };
            let changed = hooks.after_tool(&call, &result).await.unwrap_or(result);
            let media = media_view(host, id, &changed.media)?;
            Ok(json!({ "text": changed.content, "isError": changed.is_error, "media": media }))
        }
        "round.before" => {
            let round = OwnedRound::of(event)?;
            plan_json(hooks.before_round(&round.start()).await?)
        }
        "round.retry" => {
            let round = OwnedRound::of(event)?;
            let failure: Value = field(event, "failure")?;
            let failure = round_error(&field::<String>(&failure, "kind")?)?;
            hooks
                .retries
                .store(optional(event, "retries")?.unwrap_or(0), Ordering::Relaxed);
            match hooks.retry_round(&round.start(), &failure).await? {
                Some(plan) => plan_json(plan),
                None => Ok(Value::Null),
            }
        }
        "round.after" => {
            let text: String = field(event, "text")?;
            let finish_reason: Option<FinishReason> = optional(event, "finishReason")?;
            hooks
                .continues
                .store(optional(event, "continues")?.unwrap_or(0), Ordering::Relaxed);
            Ok(
                match hooks.after_round(&[Block::assistant_text(text)], finish_reason).await? {
                    RoundDecision::Proceed => json!("proceed"),
                    RoundDecision::Stop => json!("stop"),
                },
            )
        }
        "input.before" => {
            let source: InputSource = field(event, "source")?;
            let kind: InputKind = field(event, "kind")?;
            let mut blocks = Vec::new();
            for item in field::<Vec<EventBlock>>(event, "blocks")? {
                blocks.extend(match item {
                    EventBlock::Block(block) => vec![block],
                    EventBlock::Media(media) => stored(&script, vec![media])
                        .await?
                        .into_iter()
                        .map(Block::Media)
                        .collect(),
                });
            }
            let input = Input::new(source, kind, blocks)?;
            let pending = PendingInput { id: InputId(1), input };
            Ok(match hooks.before_input(&pending).await? {
                InputDecision::Keep => json!("keep"),
                InputDecision::Remove => json!("remove"),
                InputDecision::Replace(blocks) => {
                    let mut items = Vec::with_capacity(blocks.len());
                    for block in blocks {
                        items.push(match block {
                            Block::Media(media) => media_view(host, id, &[media])?.remove(0),
                            block => serde_json::to_value(block)?,
                        });
                    }
                    json!({ "replace": { "blocks": items } })
                }
            })
        }
        "prompt.build" => {
            let given: Map<String, Value> = field(event, "sections")?;
            let mut sections = Vec::with_capacity(given.len());
            for (key, text) in given {
                let text = text.as_str().ok_or(format!("the section {key} is no text"))?.to_owned();
                sections.push(PromptSection { key, text });
            }
            let built = script.build_prompt(&sections, &token).await?;
            let sections: Map<String, Value> = built
                .into_iter()
                .map(|section| (section.key, Value::String(section.text)))
                .collect();
            Ok(json!({ "sections": sections }))
        }
        other => Err(format!("{other} is no hook point").into()),
    }
}

/// Call the tool `name` of the session `id` of `host` with `args`, as a turn does. Return its result with its live
/// texts in order.
pub(crate) async fn call_tool(
    host: &dyn TestHost,
    id: SessionId,
    name: &str,
    args: &Value,
    token: CancellationToken,
) -> Result<Value, TestError> {
    let tools = host.script_session(id)?.tools().await?;
    let (_, tool) = tools
        .iter()
        .find(|(definition, _)| definition.name == name)
        .ok_or(format!("the session has no tool {name}"))?;
    let (output, texts) = mpsc::unbounded_channel();
    let shown = std::sync::Mutex::new(Vec::new());
    let arguments = args.to_string();
    // A plugin can key its state on the call id, so each call gets its own.
    let call_id = format!("call_{}", CALLS.fetch_add(1, Ordering::Relaxed) + 1);
    let answer = tool.answer(&arguments, &call_id, token, output);
    let content = forward(answer, texts, |text| {
        shown
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(text.to_owned());
    })
    .await;
    let output = shown.into_inner().unwrap_or_else(std::sync::PoisonError::into_inner);
    Ok(match content {
        Ok(content) => {
            let media = media_view(host, id, &content.media)?;
            json!({ "text": content.text, "isError": content.is_error, "media": media, "output": output })
        }
        Err(text) => json!({ "text": text, "isError": true, "media": [], "output": output }),
    })
}
