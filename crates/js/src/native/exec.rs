//! `exec` of the session object: run a shell command until it ends, its deadline passes, or its call stops it.

use std::rc::Rc;

use rquickjs::{Ctx, Function, Object};
use tokio::sync::mpsc;

use super::delivery::Queue;

use crate::error::{ErrorClass, throw};
use crate::processes::{EndCause, Processes, Request};
use crate::tools::forward;

/// Run the command of `request`. Each chunk of output goes to `on_output`. The stop of the call stops the command. It
/// answers `{ output, cause }`. The cause is `exit` with `code`, `signal` with `signal`, `moved` with `id` and `log`, `timeout`, or `cancelled`.
pub(crate) async fn exec<'js>(
    ctx: Ctx<'js>,
    processes: Rc<Processes>,
    request: Request,
    on_output: Function<'js>,
    queue: Queue<'js>,
) -> rquickjs::Result<Object<'js>> {
    let (chunks, texts) = mpsc::unbounded_channel();
    // The command has its own token, so its end stops only this command, not the other commands of the call. When
    // `on_output` throws, the guard cancels the command.
    let request = Request {
        stop: request.stop.child_token(),
        ..request
    };
    let _guard = request.stop.clone().drop_guard();
    let (promise, _abort) = queue.request(
        &ctx,
        async move { processes.run(request, chunks).await },
        |ctx, result| {
            let end = result
                .map_err(|error| throw(ctx, ErrorClass::Error, &error.to_string()))?
                .map_err(|message| throw(ctx, ErrorClass::Error, &message))?;
            let object = Object::new(ctx.clone())?;
            object.set("output", end.output)?;
            match end.cause {
                EndCause::Exit(code) => {
                    object.set("cause", "exit")?;
                    object.set("code", code)?;
                }
                EndCause::Signal(signal) => {
                    object.set("cause", "signal")?;
                    object.set("signal", signal)?;
                }
                EndCause::Timeout => object.set("cause", "timeout")?,
                EndCause::Cancelled => object.set("cause", "cancelled")?,
                EndCause::Moved { id, log } => {
                    object.set("cause", "moved")?;
                    object.set("id", id)?;
                    object.set("log", log.to_string_lossy().into_owned())?;
                }
            }
            Ok(object)
        },
    )?;
    forward(promise.into_future::<Object>(), texts, |text| {
        on_output.call::<_, ()>((text,))
    })
    .await?
}
