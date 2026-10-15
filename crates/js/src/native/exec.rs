//! `exec` of the session object: run a shell command until it ends, its deadline passes, or its call stops it.

use rquickjs::{Ctx, Function, Object};

use crate::error::throw;
use crate::processes::{Processes, Request};

/// Run the command of `request`. Each chunk of output goes to `on_output`. The stop of the call stops the command. It
/// answers `{ output, code, signal, timedOut, stopped }`.
pub(crate) async fn exec<'js>(
    ctx: Ctx<'js>,
    processes: &Processes,
    request: Request,
    on_output: Function<'js>,
) -> rquickjs::Result<Object<'js>> {
    // The command has its own token, so its end stops only this command, not the other commands of the call.
    let mut running = processes.run(Request {
        stop: request.stop.child_token(),
        ..request
    });

    let end = loop {
        tokio::select! {
            // A chunk before the end shows before it.
            biased;
            Some(text) = running.output.recv() => on_output.call::<_, ()>((text,))?,
            end = &mut running.end => break end,
        }
    };
    while let Ok(text) = running.output.try_recv() {
        on_output.call::<_, ()>((text,))?;
    }

    let end = match end {
        Ok(Ok(end)) => end,
        Ok(Err(message)) => return Err(throw(&ctx, "Error", &message)),
        Err(_) => return Err(throw(&ctx, "Error", "the command ended without an answer")),
    };
    let object = Object::new(ctx.clone())?;
    object.set("output", end.output)?;
    object.set("code", end.code)?;
    object.set("signal", end.signal)?;
    object.set("timedOut", end.timed_out)?;
    object.set("stopped", end.stopped)?;
    Ok(object)
}
