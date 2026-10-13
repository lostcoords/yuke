//! `exec` of the session object: run a shell command until it ends, its deadline passes, or its call stops it.

use std::path::PathBuf;
use std::time::Duration;

use rquickjs::function::This;
use rquickjs::{Ctx, Function, Object};
use yuke_engine::CancellationToken;

use crate::error::throw;
use crate::processes::Processes;

/// One command of a call.
pub(crate) struct Request {
    pub(crate) command: String,
    pub(crate) folder: PathBuf,
    pub(crate) timeout: Duration,
    pub(crate) max_bytes: usize,
    /// The cancellation token of the call. It cancels when the call ends or drops.
    pub(crate) stop: CancellationToken,
}

/// Run the command of `request`. Each chunk of output goes to `on_output`. The abort of `signal` and the stop of the
/// call stop the command. It answers `{ output, code, signal, timedOut, stopped }`.
pub(crate) async fn exec<'js>(
    ctx: Ctx<'js>,
    processes: &Processes,
    request: Request,
    signal: Object<'js>,
    on_output: Function<'js>,
) -> rquickjs::Result<Object<'js>> {
    let mut running = processes.run(
        request.command,
        request.folder,
        request.timeout,
        request.max_bytes,
        request.stop.child_token(),
    );
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
