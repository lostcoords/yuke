//! The tool functions of the native module. `register` and `unregister` change the registry of the tools. `notify`
//! sends a notice of a plugin, and `emit` sends an event of a plugin.

use std::rc::Rc;

use rquickjs::convert::Coerced;
use rquickjs::{Ctx, Function, Object};
use yuke_engine::Concurrency;

use tokio::sync::mpsc;
use yuke_protocol::{ExtensionEventParams, NoticeParams, SessionId};

use crate::error::{ErrorClass, Report, throw};
use crate::tools::{Json, Registry};

/// Add `register`, `unregister`, `notify`, and `emit` to `object`, the export object of the native module.
pub(super) fn add<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    registry: &Rc<Registry>,
    reports: mpsc::UnboundedSender<Report>,
) -> rquickjs::Result<()> {
    let removing = Rc::clone(registry);
    object.set(
        "unregister",
        Function::new(ctx.clone(), move |ids: Vec<u64>| removing.remove(&ids))?,
    )?;
    add_reports(ctx, object, reports)?;
    let registry = Rc::clone(registry);
    object.set(
        "register",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, tool: Object<'js>, start: Function<'js>| -> rquickjs::Result<u64> {
                let Coerced(concurrency) = tool.get::<_, Coerced<String>>("concurrency")?;
                let concurrency = match concurrency.as_str() {
                    "serial" => Concurrency::Serial,
                    "parallel" => Concurrency::Parallel,
                    other => {
                        return Err(throw(
                            &ctx,
                            ErrorClass::TypeError,
                            &format!("the concurrency '{other}' is not 'serial' or 'parallel'"),
                        ));
                    }
                };
                let definition = yuke_ai::ToolDefinition {
                    name: tool.get("name")?,
                    description: tool.get("description")?,
                    input_schema: tool.get("parameters")?,
                    defer_loading: tool.get("deferLoading")?,
                };
                let Json(hints) = tool.get("hints")?;
                registry
                    .add(&ctx, definition, concurrency, hints, start, tool.get("open")?)
                    .map_err(|message| throw(&ctx, ErrorClass::TypeError, &message))
            },
        )?,
    )?;
    Ok(())
}

/// Add `notify` and `emit` to `object`. Each sends its report to `reports`.
fn add_reports<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    reports: mpsc::UnboundedSender<Report>,
) -> rquickjs::Result<()> {
    let events = reports.clone();
    object.set(
        "emit",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>,
                  extension: String,
                  event: String,
                  data: String,
                  session_id: Option<String>|
                  -> rquickjs::Result<()> {
                let session_id = session_of(&ctx, "emit", session_id)?;
                let data = serde_json::from_str(&data).map_err(|error| {
                    throw(
                        &ctx,
                        ErrorClass::TypeError,
                        &format!("emit: the data is not JSON: {error}"),
                    )
                })?;
                let event = ExtensionEventParams {
                    session_id,
                    extension,
                    event,
                    data,
                };
                if events.send(Report::Event(event)).is_err() {
                    // The owner dropped the receiver, so it ignores events.
                }
                Ok(())
            },
        )?,
    )?;
    object.set(
        "notify",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>,
                  source: String,
                  level: String,
                  message: String,
                  session_id: Option<String>|
                  -> rquickjs::Result<()> {
                let Some(level) = super::notice_level(&level) else {
                    return Err(throw(
                        &ctx,
                        ErrorClass::TypeError,
                        &format!("notify: '{level}' is not debug, info, warn, or error"),
                    ));
                };
                let session_id = session_of(&ctx, "notify", session_id)?;
                let notice = NoticeParams {
                    session_id,
                    level,
                    source,
                    message,
                };
                if reports.send(Report::Notice(notice)).is_err() {
                    // The owner dropped the receiver, so it ignores notices.
                }
                Ok(())
            },
        )?,
    )?;
    Ok(())
}

/// Read the session id in `text` for the native `function`. A text that is not a session id throws a `TypeError`.
fn session_of(ctx: &Ctx<'_>, function: &str, text: Option<String>) -> rquickjs::Result<Option<SessionId>> {
    text.map(|text| {
        text.parse::<SessionId>().map_err(|_| {
            throw(
                ctx,
                ErrorClass::TypeError,
                &format!("{function}: '{text}' is not a session id"),
            )
        })
    })
    .transpose()
}
