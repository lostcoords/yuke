//! The model requests of the plugins: `aiComplete` of `yuke:ai`, and `sideRequest` of a round event.

use std::error::Error;
use std::path::Path;
use std::sync::Arc;

use rquickjs::{Ctx, FromJs, Function, IntoJs, Object};
use serde_json::{Map, Value};
use yuke_ai::{Block, FinishReason, Settings, ToolDefinition, Usage};
use yuke_engine::{CancellationToken, Model, chain_text};
use yuke_protocol::{ModelReference, SessionId};

use super::Operation;
use crate::error::{ErrorClass, throw};
use crate::models::{CompleteAnswer, CompleteRequest, Models, SideRequest, merge_settings};
use crate::tools::{Json, MediaFile, read_media};

/// The request of `aiComplete`, as `yuke:ai` builds it after its checks.
#[derive(FromJs)]
struct Request {
    model: Json<ModelReference>,
    system: String,
    /// The blocks stay JSON until the check, so a bad block throws a `TypeError` with its cause.
    blocks: Json<Value>,
    /// The settings that the caller gives. Each other setting keeps the default of the endpoint.
    settings: Json<Map<String, Value>>,
    /// The media after the blocks. Each path is absolute.
    attachments: Vec<MediaFile>,
}

/// The answer of `aiComplete`.
#[derive(IntoJs)]
#[qjs(rename_all = "camelCase")]
struct Completion {
    text: String,
    finish_reason: Json<FinishReason>,
    usage: Json<Usage>,
}

/// The record that the promise rejects with after a call of `cancel`.
#[derive(IntoJs)]
struct Cancelled {
    cancelled: bool,
}

/// Add `aiComplete` to `object`, the export object of the native module.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>, models: &Arc<dyn Models>) -> rquickjs::Result<()> {
    let models = Arc::clone(models);
    object.set(
        "aiComplete",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, request: Request| -> rquickjs::Result<Operation<'js>> {
                let (mut request, files) = checked(&ctx, request)?;
                let models = Arc::clone(&models);
                Operation::start(&ctx, move |ctx, stop| async move {
                    // Each path is absolute, so the join keeps it. A read can block, as on a FIFO, so a stop ends the wait.
                    let read = tokio::select! {
                        read = read_media(files, Path::new("/")) => read,
                        () = stop.cancelled() => return Err(ctx.throw(Cancelled { cancelled: true }.into_js(&ctx)?)),
                    };
                    request.attachments = read.map_err(|error| throw(&ctx, ErrorClass::Error, &error))?;
                    let answer = models.complete(request, stop.clone()).await;
                    completion(&ctx, answer, &stop)
                })
            },
        )?,
    )
}

/// The answer of a model request for JavaScript. A failure after a stop rejects with the cancel record.
fn completion(
    ctx: &Ctx<'_>,
    answer: Result<CompleteAnswer, Box<dyn Error + Send + Sync>>,
    stop: &CancellationToken,
) -> rquickjs::Result<Completion> {
    match answer {
        Ok(answer) => Ok(Completion {
            text: answer.text,
            finish_reason: Json(answer.finish_reason),
            usage: Json(answer.usage),
        }),
        Err(_) if stop.is_cancelled() => Err(ctx.throw(Cancelled { cancelled: true }.into_js(ctx)?)),
        Err(error) => Err(throw(ctx, ErrorClass::Error, &chain_text(&*error))),
    }
}

/// What a side request of a round repeats: the request of the round and its context.
#[derive(Debug)]
pub(crate) struct Round {
    pub(crate) model: Model,
    pub(crate) system: String,
    pub(crate) tools: Vec<ToolDefinition>,
    pub(crate) settings: Settings,
    pub(crate) session_id: SessionId,
    pub(crate) context: Vec<Block>,
}

/// The request of `sideRequest`, as the round event builds it after its checks.
#[derive(FromJs)]
#[qjs(rename_all = "camelCase")]
struct SideOptions {
    /// The head of the replacements of the earlier handlers. It stays JSON until the check.
    head: Json<Value>,
    /// The number of blocks of the context of the round after `head`.
    kept: usize,
    /// The number of blocks to send, of `head` and the kept blocks.
    blocks: usize,
    prompt: String,
    max_output_tokens: Option<u32>,
}

/// The native `sideRequest(options)` of a round event: the request of `round`, with the context as the handler sees
/// it, cut to `blocks`, then `prompt`. A head that is not a list of blocks throws a `TypeError`.
pub(crate) fn side_request<'js>(
    ctx: &Ctx<'js>,
    round: Arc<Round>,
    models: Arc<dyn Models>,
) -> rquickjs::Result<Function<'js>> {
    Function::new(
        ctx.clone(),
        move |ctx: Ctx<'js>, options: SideOptions| -> rquickjs::Result<Operation<'js>> {
            let head: Vec<Block> = serde_json::from_value(options.head.0).map_err(|error| {
                let message = format!("the head is not a list of blocks: {error}");
                throw(&ctx, ErrorClass::TypeError, &message)
            })?;
            let kept = &round.context[round.context.len().saturating_sub(options.kept)..];
            let blocks: Vec<Block> = head
                .into_iter()
                .chain(kept.iter().cloned())
                .take(options.blocks)
                .collect();
            let settings = match options.max_output_tokens {
                Some(limit) => round.settings.clone().max_output_tokens(limit),
                None => round.settings.clone(),
            };
            let request = SideRequest {
                model: round.model.clone(),
                system: round.system.clone(),
                tools: round.tools.clone(),
                settings,
                session_id: round.session_id,
                blocks,
                prompt: options.prompt,
            };
            let models = Arc::clone(&models);
            Operation::start(&ctx, move |ctx, stop| async move {
                let answer = models.side_request(request, stop.clone()).await;
                completion(&ctx, answer, &stop)
            })
        },
    )
}

/// Check `request`, and convert it for [`Models::complete`], with its media files apart for a read. A block of another
/// shape or a bad setting throws a `TypeError`.
fn checked(ctx: &Ctx<'_>, request: Request) -> rquickjs::Result<(CompleteRequest, Vec<MediaFile>)> {
    let blocks: Vec<Block> = serde_json::from_value(request.blocks.0).map_err(|error| {
        throw(
            ctx,
            ErrorClass::TypeError,
            &format!("the blocks are not a list of blocks: {error}"),
        )
    })?;
    let settings = merge_settings(&Settings::new(), request.settings.0)
        .map_err(|error| throw(ctx, ErrorClass::TypeError, &error))?;
    for (index, file) in request.attachments.iter().enumerate() {
        // `yuke:ai` has no workspace folder, so a relative path has no start.
        if file.path().is_some_and(|path| !Path::new(path).is_absolute()) {
            let message = format!("attachments[{index}].path is not an absolute path");
            return Err(throw(ctx, ErrorClass::TypeError, &message));
        }
    }
    let complete = CompleteRequest {
        model: request.model.0,
        system: request.system,
        blocks,
        settings,
        attachments: Vec::new(),
    };
    Ok((complete, request.attachments))
}
