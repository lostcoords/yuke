//! The built-in modules: the QuickJS bytecode that `build.rs` wrote from `modules/`.

use rquickjs::module::Declared;
use rquickjs::{Ctx, Module};

// `MODULES`: the name and the bytecode of each built-in module.
include!(concat!(env!("OUT_DIR"), "/baked.rs"));

/// The bytecode of the built-in module `name`.
pub(crate) fn bytecode(name: &str) -> Option<&'static [u8]> {
    MODULES
        .iter()
        .find(|(module, _)| *module == name)
        .map(|(_, bytes)| *bytes)
}

/// The names of the built-in modules.
#[cfg(test)]
pub(crate) fn names() -> impl Iterator<Item = &'static str> {
    MODULES.iter().map(|(name, _)| *name)
}

/// Declare the built-in module of `bytes`.
#[expect(
    unsafe_code,
    reason = "the engine reads bytecode without checks, and build.rs of this build wrote these bytes"
)]
pub(crate) fn load<'js>(ctx: &Ctx<'js>, bytes: &'static [u8]) -> rquickjs::Result<Module<'js, Declared>> {
    // SAFETY: build.rs wrote `bytes` with `Module::write` of the same rquickjs version for a target of the same byte
    // order, so the bytecode is valid for this engine.
    unsafe { Module::load(ctx.clone(), bytes) }
}
