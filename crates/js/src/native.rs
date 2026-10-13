//! The native modules: Rust functions under `yuke:internal/native/` for the built-in modules. The engine builds the
//! export object of each module at its start, so a function can hold Rust state.

mod exec;
mod fs;
pub(crate) mod session;
mod tools;

use std::collections::HashMap;
use std::marker::PhantomData;
use std::rc::Rc;

use rquickjs::module::{Declarations, Declared, Exports, ModuleDef};
use rquickjs::{Ctx, Module, Object, Value};

use crate::error::throw;
use crate::tools::Registry;

/// The export objects of the native modules, by module name. The context keeps them as user data.
type Objects<'js> = HashMap<String, Object<'js>>;

/// The name and the exports of one native module.
trait Native {
    const NAME: &'static str;
    const EXPORTS: &'static [&'static str];
}

/// The module definition of the native module `N`. It copies the exports from the object that the engine built.
struct Definition<N>(PhantomData<N>);

impl<N: Native> ModuleDef for Definition<N> {
    fn declare(declarations: &Declarations<'_>) -> rquickjs::Result<()> {
        for name in N::EXPORTS {
            declarations.declare(*name)?;
        }
        Ok(())
    }

    fn evaluate<'js>(ctx: &Ctx<'js>, exports: &Exports<'js>) -> rquickjs::Result<()> {
        let object = ctx
            .userdata::<Objects<'js>>()
            .and_then(|objects| objects.get(N::NAME).cloned())
            .ok_or_else(|| throw(ctx, "Error", &format!("the native module {} has no exports", N::NAME)))?;
        for name in N::EXPORTS {
            exports.export(*name, object.get::<_, Value<'js>>(*name)?)?;
        }
        Ok(())
    }
}

/// The name and the exports of each native module.
#[cfg(test)]
pub(crate) fn modules() -> [(&'static str, &'static [&'static str]); 2] {
    [
        (fs::Fs::NAME, fs::Fs::EXPORTS),
        (tools::Tools::NAME, tools::Tools::EXPORTS),
    ]
}

/// Whether `name` names a native module.
pub(crate) fn is_native(name: &str) -> bool {
    [fs::Fs::NAME, tools::Tools::NAME].contains(&name)
}

/// Declare the native module `name`, or `None` when no native module has the name.
pub(crate) fn declare<'js>(ctx: &Ctx<'js>, name: &str) -> Option<rquickjs::Result<Module<'js, Declared>>> {
    match name {
        fs::Fs::NAME => Some(Module::declare_def::<Definition<fs::Fs>, _>(ctx.clone(), name)),
        tools::Tools::NAME => Some(Module::declare_def::<Definition<tools::Tools>, _>(ctx.clone(), name)),
        _ => None,
    }
}

/// Build the export object of each native module.
pub(crate) fn install(ctx: &Ctx<'_>, registry: &Rc<Registry>) -> rquickjs::Result<()> {
    let objects = Objects::from([
        (fs::Fs::NAME.to_owned(), fs::exports(ctx)?),
        (tools::Tools::NAME.to_owned(), tools::exports(ctx, registry)?),
    ]);
    match ctx.store_userdata(objects) {
        Ok(_) => Ok(()),
        Err(_) => Err(throw(ctx, "Error", "the native modules cannot be stored")),
    }
}
