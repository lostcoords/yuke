//! `yuke:internal/native/tools`: the registry of the tools that `yuke:tools` defines.

use std::rc::Rc;

use rquickjs::convert::Coerced;
use rquickjs::{Ctx, Function, Object};
use yuke_engine::Concurrency;

use super::Native;
use crate::error::throw;
use crate::tools::Registry;

pub(crate) struct Tools;

impl Native for Tools {
    const NAME: &'static str = "yuke:internal/native/tools";
    const EXPORTS: &'static [&'static str] = &["register"];
}

/// The export object of the module.
pub(super) fn exports<'js>(ctx: &Ctx<'js>, registry: &Rc<Registry>) -> rquickjs::Result<Object<'js>> {
    let object = Object::new(ctx.clone())?;
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
                let definition = yuke_ai::ToolDefinition::new(name, description, parameters);
                registry
                    .add(&ctx, definition, concurrency, start)
                    .map_err(|message| throw(&ctx, "TypeError", &message))
            },
        )?,
    )?;
    Ok(object)
}
