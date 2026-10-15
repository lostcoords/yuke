//! The `register` function of the native module: the registry of the tools that `yuke:tools` defines.

use std::rc::Rc;

use rquickjs::convert::Coerced;
use rquickjs::{Ctx, Function, Object};
use yuke_engine::Concurrency;

use crate::error::throw;
use crate::tools::Registry;

/// Add `register` to `object`, the export object of the native module.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>, registry: &Rc<Registry>) -> rquickjs::Result<()> {
    let registry = Rc::clone(registry);
    object.set(
        "register",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>,
                  name: String,
                  description: String,
                  parameters: String,
                  Coerced(concurrency): Coerced<String>,
                  defer: bool,
                  start: Function<'js>|
                  -> rquickjs::Result<()> {
                let concurrency = match concurrency.as_str() {
                    "serial" => Concurrency::Serial,
                    "parallel" => Concurrency::Parallel,
                    other => {
                        return Err(throw(
                            &ctx,
                            "TypeError",
                            &format!("the concurrency '{other}' is not 'serial' or 'parallel'"),
                        ));
                    }
                };
                let definition = yuke_ai::ToolDefinition {
                    name,
                    description,
                    input_schema: parameters,
                    defer_loading: defer,
                };
                registry
                    .add(&ctx, definition, concurrency, start)
                    .map_err(|message| throw(&ctx, "TypeError", &message))
            },
        )?,
    )?;
    Ok(())
}
