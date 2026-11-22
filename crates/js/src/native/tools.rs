//! The native tool functions register definitions and name removals. They also send plugin notices and events.

use std::rc::Rc;

use rquickjs::convert::Coerced;
use rquickjs::{Ctx, Function, Object, Persistent};
use yuke_engine::{Concurrency, ToolHints};

use tokio::sync::mpsc;
use yuke_protocol::{ExtensionEventParams, NoticeParams, SessionId};

use crate::error::{ErrorClass, Report, throw};
use crate::tools::{Json, Registration, Registry, ToolChange, ToolOwner};

/// Add the native tool functions to the export object.
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
    let removing = Rc::clone(registry);
    object.set(
        "removeTool",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, owner: ToolOwner, name: String| -> rquickjs::Result<u64> {
                removing
                    .add(Some(owner), ToolChange::Remove { name })
                    .map(|registration| registration.id)
                    .map_err(|message| throw(&ctx, ErrorClass::TypeError, &message))
            },
        )?,
    )?;
    add_reports(ctx, object, reports)?;
    let registry = Rc::clone(registry);
    object.set(
        "register",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, tool: Object<'js>, start: Function<'js>| -> rquickjs::Result<Registration> {
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
                    input_schema: tool.get("inputSchema")?,
                    defer_loading: tool.get::<_, Option<bool>>("deferLoading")?.unwrap_or_default(),
                };
                let hints = tool
                    .get::<_, Option<Json<ToolHints>>>("hints")?
                    .map_or_else(ToolHints::default, |Json(hints)| hints);
                registry
                    .add(
                        tool.get("owner")?,
                        ToolChange::Define {
                            definition,
                            concurrency,
                            hints,
                            start: Persistent::save(&ctx, start),
                        },
                    )
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
            move |extension: String,
                  event: String,
                  Json(data): Json<serde_json::Value>,
                  session_id: Option<Json<SessionId>>|
                  -> rquickjs::Result<()> {
                let event = ExtensionEventParams {
                    session_id: session_id.map(|Json(id)| id),
                    extension,
                    event,
                    data,
                };
                // The owner dropped the receiver, so it ignores events.
                _ = events.send(Report::Event(event));
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
                  text: String,
                  session_id: Option<Json<SessionId>>|
                  -> rquickjs::Result<()> {
                let Some(level) = super::notice_level(&level) else {
                    return Err(throw(
                        &ctx,
                        ErrorClass::TypeError,
                        &format!("notify: '{level}' is not debug, info, warn, or error"),
                    ));
                };
                let notice = NoticeParams {
                    session_id: session_id.map(|Json(id)| id),
                    level,
                    source,
                    text,
                };
                // The owner dropped the receiver, so it ignores notices.
                _ = reports.send(Report::Notice(notice));
                Ok(())
            },
        )?,
    )?;
    Ok(())
}
