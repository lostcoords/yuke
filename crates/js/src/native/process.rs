//! The native of `yuke:process`: `processOutput` runs a program without a shell, and answers its end and its output.
//! `processEnv` reads a variable of the environment of yuke.

use std::sync::Arc;

use rquickjs::{Ctx, Function, Object, TypedArray, Value};

use super::Operation;
use crate::error::{ErrorClass, throw};
use crate::processes::{Processes, Program};

/// Add `processOutput` and `processEnv` to `object`, the export object of the native module.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>, processes: &Arc<Processes>) -> rquickjs::Result<()> {
    // A missing variable and a value that is not valid Unicode both give `undefined`.
    object.set(
        "processEnv",
        Function::new(ctx.clone(), |name: String| std::env::var(name).ok())?,
    )?;
    let processes = Arc::clone(processes);
    object.set(
        "processOutput",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, program: Program| -> rquickjs::Result<Operation<'js>> {
                output(&ctx, Arc::clone(&processes), program)
            },
        )?,
    )
}

/// Start `program`, and answer the operation of its run.
fn output<'js>(ctx: &Ctx<'js>, processes: Arc<Processes>, program: Program) -> rquickjs::Result<Operation<'js>> {
    Operation::start(ctx, move |ctx, stop| async move {
        match processes.output(program, stop).await {
            Ok(end) => {
                let object = Object::new(ctx.clone())?;
                object.set("code", end.code)?;
                // `null` as the type says: a `None` alone would be `undefined`.
                match end.signal {
                    Some(name) => object.set("signal", name)?,
                    None => object.set("signal", Value::new_null(ctx.clone()))?,
                }
                object.set("stdout", TypedArray::<u8>::new(ctx.clone(), end.stdout)?)?;
                object.set("stderr", TypedArray::<u8>::new(ctx.clone(), end.stderr)?)?;
                Ok(object)
            }
            Err(message) => Err(throw(&ctx, ErrorClass::Error, &message)),
        }
    })
}
