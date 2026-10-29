//! The native module `yuke:internal/native`: Rust functions for the built-in modules. The engine builds its export
//! object at its start, so a function can hold Rust state.

pub(crate) mod ai;
pub(crate) mod call;
mod console;
mod encoding;
mod exec;
mod fs;
mod http;
mod lines;
mod process;
mod sessions;
pub(crate) mod term;
mod tools;
mod url;

use std::rc::Rc;

use rquickjs::module::{Declarations, Declared, Exports, ModuleDef};
use rquickjs::{Ctx, Function, IntoJs, Module, Object};

use tokio::sync::mpsc;
use yuke_engine::CancellationToken;

use crate::error::{ErrorClass, Report, throw};
use crate::runtime::Options;
use crate::tools::Registry;

/// The record that the promise of a native rejects with after a call of `cancel`.
#[derive(rquickjs::IntoJs)]
pub(crate) struct Cancelled {
    pub(crate) cancelled: bool,
}

/// A started operation: the promise of its value, and the function that stops it. Rust gives one to JavaScript for a
/// native, and JavaScript gives one to Rust for a tool call or a hook run.
#[derive(rquickjs::IntoJs, rquickjs::FromJs)]
pub(crate) struct Operation<'js> {
    pub(crate) promise: rquickjs::Promise<'js>,
    pub(crate) cancel: Function<'js>,
}

impl<'js> Operation<'js> {
    /// Start the future that `run` makes with a new token. A call of `cancel` cancels the token.
    pub(crate) fn start<F, R>(
        ctx: &Ctx<'js>,
        run: impl FnOnce(Ctx<'js>, CancellationToken) -> F,
    ) -> rquickjs::Result<Self>
    where
        F: Future<Output = rquickjs::Result<R>> + 'js,
        R: IntoJs<'js>,
    {
        let token = CancellationToken::new();
        let promise = rquickjs::Promise::wrap_future(ctx, run(ctx.clone(), token.clone()))?;
        let cancel = Function::new(ctx.clone(), move || token.cancel())?;
        Ok(Self { promise, cancel })
    }
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
            let function = object.get::<_, Function<'js>>(name.as_str())?;
            exports.export(name, function)?;
        }
        Ok(())
    }
}

/// The export object that [`install`] built. It is the only `Object` that the context keeps as user data.
/// The protocol notice level of `name`: `debug`, `info`, `warn`, or `error`.
pub(crate) fn notice_level(name: &str) -> Option<yuke_protocol::NoticeLevel> {
    serde_json::from_value(serde_json::Value::String(name.to_owned())).ok()
}

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
    options: &Options,
    frames: &Rc<term::Frames>,
    consumer: &tokio::runtime::Handle,
    reports: mpsc::UnboundedSender<Report>,
) -> rquickjs::Result<()> {
    let object = Object::new(ctx.clone())?;
    sessions::add(ctx, &object, &options.sessions, consumer, reports.clone())?;
    term::add(ctx, &object, frames)?;
    ai::add(ctx, &object, &options.models)?;
    fs::add(ctx, &object)?;
    http::add(ctx, &object, &options.http)?;
    process::add(ctx, &object, &options.processes)?;
    lines::add(ctx, &object)?;
    encoding::add(ctx, &object)?;
    url::add(ctx, &object)?;
    console::add(ctx, &object, reports.clone())?;
    tools::add(ctx, &object, registry, reports.clone())?;
    crate::test_host::add(ctx, &object, options.test_host.as_ref(), consumer, reports)?;
    match ctx.store_userdata(object) {
        Ok(_) => Ok(()),
        Err(_) => Err(throw(ctx, ErrorClass::Error, "the native module cannot be stored")),
    }
}
