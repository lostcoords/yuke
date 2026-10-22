//! The native of `yuke:ai`: `aiComplete` sends one request of a plugin to a model.

use std::path::Path;
use std::sync::Arc;

use rquickjs::{Ctx, FromJs, Function, IntoJs, Object};
use serde_json::{Map, Value};
use yuke_ai::{Block, FinishReason, Settings, Usage};
use yuke_engine::chain_text;
use yuke_protocol::ModelReference;

use super::Operation;
use crate::error::{ErrorClass, throw};
use crate::models::{CompleteRequest, Models, merge_settings};
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
                    match models.complete(request, stop.clone()).await {
                        Ok(answer) => Ok(Completion {
                            text: answer.text,
                            finish_reason: Json(answer.finish_reason),
                            usage: Json(answer.usage),
                        }),
                        Err(_) if stop.is_cancelled() => Err(ctx.throw(Cancelled { cancelled: true }.into_js(&ctx)?)),
                        Err(error) => Err(throw(&ctx, ErrorClass::Error, &chain_text(&*error))),
                    }
                })
            },
        )?,
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
