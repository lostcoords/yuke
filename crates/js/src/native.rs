//! The native module `yuke:internal/native`: Rust functions for the built-in modules. The engine builds its export
//! object at its start, so a function can hold Rust state.

mod exec;
mod fs;
pub(crate) mod session;
mod tools;

use std::rc::Rc;

use rquickjs::module::{Declarations, Declared, Exports, ModuleDef};
use rquickjs::{Ctx, Function, Module, Object};

use tokio::sync::mpsc;

use crate::error::{Report, throw};
use crate::tools::Registry;

/// The name of the native module.
const NAME: &str = "yuke:internal/native";

/// The names that the native module exports.
pub(crate) const EXPORTS: &[&str] = &[
    "readLines",
    "readText",
    "writeText",
    "register",
    "removeTools",
    "notify",
];

/// The module definition of the native module. It copies the exports from the object that the engine built.
struct Native;

impl ModuleDef for Native {
    fn declare(declarations: &Declarations<'_>) -> rquickjs::Result<()> {
        for name in EXPORTS {
            declarations.declare(*name)?;
        }
        Ok(())
    }

    fn evaluate<'js>(ctx: &Ctx<'js>, exports: &Exports<'js>) -> rquickjs::Result<()> {
        // The export object is the only `Object` that the context keeps as user data.
        let object = ctx
            .userdata::<Object<'js>>()
            .map(|object| object.clone())
            .ok_or_else(|| throw(ctx, "Error", "the native module has no exports"))?;
        for name in EXPORTS {
            exports.export(*name, object.get::<_, Function<'js>>(*name)?)?;
        }
        Ok(())
    }
}

/// Declare the native module when `name` names it, or `None` otherwise.
pub(crate) fn declare<'js>(ctx: &Ctx<'js>, name: &str) -> Option<rquickjs::Result<Module<'js, Declared>>> {
    (name == NAME).then(|| Module::declare_def::<Native, _>(ctx.clone(), name))
}

/// Build the export object of the native module.
pub(crate) fn install(
    ctx: &Ctx<'_>,
    registry: &Rc<Registry>,
    reports: mpsc::UnboundedSender<Report>,
) -> rquickjs::Result<()> {
    let object = Object::new(ctx.clone())?;
    fs::add(ctx, &object)?;
    tools::add(ctx, &object, registry, reports)?;
    match ctx.store_userdata(object) {
        Ok(_) => Ok(()),
        Err(_) => Err(throw(ctx, "Error", "the native module cannot be stored")),
    }
}
