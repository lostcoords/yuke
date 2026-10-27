//! The built-in modules: the QuickJS bytecode that `build.rs` wrote from `modules/`.

use rquickjs::module::Declared;
use rquickjs::{Ctx, Module};

// `MODULES`: the name and the bytecode of each built-in module.
include!(concat!(env!("OUT_DIR"), "/baked.rs"));

/// The names of the built-in modules.
#[cfg(test)]
pub(crate) fn names() -> impl Iterator<Item = &'static str> {
    MODULES.iter().map(|(name, _)| *name)
}

/// Declare the built-in module `name`, or `None` when no built-in module has that name.
#[expect(
    unsafe_code,
    reason = "the engine reads bytecode without checks, and build.rs of this build wrote these bytes"
)]
pub(crate) fn load<'js>(ctx: &Ctx<'js>, name: &str) -> Option<rquickjs::Result<Module<'js, Declared>>> {
    let (_, bytes) = MODULES.iter().find(|(module, _)| *module == name)?;
    // SAFETY: build.rs wrote `bytes` with `Module::write` of the same rquickjs version for a target of the same byte
    // order, so the bytecode is valid for this engine.
    Some(unsafe { Module::load(ctx.clone(), bytes) })
}
