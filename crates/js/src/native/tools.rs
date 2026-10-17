//! The tool functions of the native module: `register` and `removeTools` change the registry of the tools, and `notify`
//! sends a notice of a plugin.

use std::rc::Rc;

use rquickjs::convert::Coerced;
use rquickjs::{Ctx, Function, Object};
use yuke_engine::Concurrency;

use tokio::sync::mpsc;
use yuke_protocol::{NoticeLevel, NoticeParams, SessionId};

use crate::error::{ErrorClass, Report, throw};
use crate::tools::Registry;

/// Add `register`, `removeTools`, and `notify` to `object`, the export object of the native module.
pub(super) fn add<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    registry: &Rc<Registry>,
    reports: mpsc::UnboundedSender<Report>,
) -> rquickjs::Result<()> {
    let removing = Rc::clone(registry);
    object.set(
        "removeTools",
        Function::new(ctx.clone(), move |owner: String| removing.remove_owner(&owner))?,
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
                let level = match level.as_str() {
                    "debug" => NoticeLevel::Debug,
                    "info" => NoticeLevel::Info,
                    "warn" => NoticeLevel::Warn,
                    "error" => NoticeLevel::Error,
                    other => {
                        return Err(throw(
                            &ctx,
                            ErrorClass::TypeError,
                            &format!("notify: '{other}' is not debug, info, warn, or error"),
                        ));
                    }
                };
                let session_id = session_id
                    .map(|text| {
                        text.parse::<SessionId>().map_err(|_| {
                            throw(
                                &ctx,
                                ErrorClass::TypeError,
                                &format!("notify: '{text}' is not a session id"),
                            )
                        })
                    })
                    .transpose()?;
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
    let registry = Rc::clone(registry);
    object.set(
        "register",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, tool: Object<'js>, start: Function<'js>| -> rquickjs::Result<()> {
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
                registry
                    .add(&ctx, definition, concurrency, start, tool.get("owner")?)
                    .map_err(|message| throw(&ctx, ErrorClass::TypeError, &message))
            },
        )?,
    )?;
    Ok(())
}
