//! The native module `yuke:internal/native`: Rust functions for the built-in modules. The engine builds its export
//! object at its start, so a function can hold Rust state.

pub(crate) mod call;
mod console;
mod encoding;
mod exec;
mod fs;
mod lines;
mod process;
mod tools;

use std::rc::Rc;
use std::sync::Arc;

use rquickjs::module::{Declarations, Declared, Exports, ModuleDef};
use rquickjs::{Ctx, Function, Module, Object};

use tokio::sync::mpsc;

use crate::error::{ErrorClass, Report, throw};
use crate::processes::Processes;
use crate::tools::Registry;

/// A started operation: the promise of its value, and the function that stops it.
#[derive(rquickjs::IntoJs)]
pub(crate) struct Operation<'js> {
    pub(crate) promise: rquickjs::Promise<'js>,
    pub(crate) cancel: Function<'js>,
}

/// The name of the native module.
const NAME: &str = "yuke:internal/native";

/// The module definition of the native module. Its exports are the functions of the object that the engine built, so
/// one place names each function.
struct Native;

impl ModuleDef for Native {
    fn declare(declarations: &Declarations<'_>) -> rquickjs::Result<()> {
        for name in names(declarations.module().ctx())? {
            declarations.declare(name)?;
        }
        Ok(())
    }

    fn evaluate<'js>(ctx: &Ctx<'js>, exports: &Exports<'js>) -> rquickjs::Result<()> {
        let object = exports_object(ctx)?;
        for name in names(ctx)? {
            exports.export(name.clone(), object.get::<_, Function<'js>>(name)?)?;
        }
        Ok(())
    }
}

/// The export object that [`install`] built. It is the only `Object` that the context keeps as user data.
fn exports_object<'js>(ctx: &Ctx<'js>) -> rquickjs::Result<Object<'js>> {
    ctx.userdata::<Object<'js>>()
        .map(|object| object.clone())
        .ok_or_else(|| throw(ctx, ErrorClass::Error, "the native module has no exports"))
}

/// The names of the functions of the native module.
pub(crate) fn names(ctx: &Ctx<'_>) -> rquickjs::Result<Vec<String>> {
    exports_object(ctx)?.keys::<String>().collect()
}

/// Declare the native module when `name` names it, or `None` otherwise.
pub(crate) fn declare<'js>(ctx: &Ctx<'js>, name: &str) -> Option<rquickjs::Result<Module<'js, Declared>>> {
    (name == NAME).then(|| Module::declare_def::<Native, _>(ctx.clone(), name))
}

/// Build the export object of the native module.
pub(crate) fn install(
    ctx: &Ctx<'_>,
    registry: &Rc<Registry>,
    processes: &Arc<Processes>,
    reports: mpsc::UnboundedSender<Report>,
) -> rquickjs::Result<()> {
    let object = Object::new(ctx.clone())?;
    fs::add(ctx, &object)?;
    process::add(ctx, &object, processes)?;
    lines::add(ctx, &object)?;
    encoding::add(ctx, &object)?;
    console::add(ctx, &object, reports.clone())?;
    tools::add(ctx, &object, registry, reports)?;
    match ctx.store_userdata(object) {
        Ok(_) => Ok(()),
        Err(_) => Err(throw(ctx, ErrorClass::Error, "the native module cannot be stored")),
    }
}
