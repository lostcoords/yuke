//! `exec` of the session object: run a shell command until it ends, its deadline passes, or its call stops it.

use rquickjs::function::This;
use rquickjs::{Ctx, Function, Object};

use crate::error::throw;
use crate::processes::{Processes, Request};

/// Run the command of `request`. Each chunk of output goes to `on_output`. The abort of `signal` and the stop of the
/// call stop the command. It answers `{ output, code, signal, timedOut, stopped }`.
pub(crate) async fn exec<'js>(
    ctx: Ctx<'js>,
    processes: &Processes,
    request: Request,
    signal: Object<'js>,
    on_output: Function<'js>,
) -> rquickjs::Result<Object<'js>> {
    let mut running = processes.run(Request {
        stop: request.stop.child_token(),
        ..request
    });
    let stop = running.stop.0.clone();
    let on_abort: Function<'js> = signal.get("onAbort")?;
    let remove: Function<'js> = on_abort.call((This(signal), Function::new(ctx.clone(), move || stop.cancel())?))?;

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
    remove.call::<_, ()>(())?;

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
