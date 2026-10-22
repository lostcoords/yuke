//! The native of `yuke:process`: `processOutput` runs a program without a shell, and answers its end and its output.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;

use rquickjs::{Ctx, FromJs, Function, Object, TypedArray};

use super::Operation;
use crate::error::{ErrorClass, throw};
use crate::processes::{Processes, Program};

/// The request of `processOutput`, as `yuke:process` builds it after its checks.
#[derive(FromJs)]
#[qjs(rename_all = "camelCase")]
struct Request {
    command: String,
    args: Vec<String>,
    cwd: String,
    env: BTreeMap<String, String>,
    clear_env: bool,
    stdout: bool,
    stderr: bool,
}

/// Add `processOutput` to `object`, the export object of the native module.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>, processes: &Arc<Processes>) -> rquickjs::Result<()> {
    let processes = Arc::clone(processes);
    object.set(
        "processOutput",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, request: Request| -> rquickjs::Result<Operation<'js>> {
                let program = Program {
                    command: request.command,
                    args: request.args,
                    cwd: PathBuf::from(request.cwd),
                    env: request.env.into_iter().collect(),
                    clear_env: request.clear_env,
                    stdout: request.stdout,
                    stderr: request.stderr,
                };
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
                object.set("signal", end.signal)?;
                object.set("stdout", TypedArray::<u8>::new(ctx.clone(), end.stdout)?)?;
                object.set("stderr", TypedArray::<u8>::new(ctx.clone(), end.stderr)?)?;
                Ok(object)
            }
            Err(message) => Err(throw(&ctx, ErrorClass::Error, &message)),
        }
    })
}
