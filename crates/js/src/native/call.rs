//! The host of a call: the native functions that need the session or the life of the call, such as the commands and
//! the jobs. The bridge builds one for each call. `yuke:internal/call` keeps it from the tools of plugins.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use rquickjs::function::Async;
use rquickjs::{Ctx, Function, Object};
use yuke_engine::CancellationToken;

use super::delivery::Queue;
use super::exec::exec;
use crate::error::{ErrorClass, throw};
use crate::processes::Processes;
use crate::processes::Request;
use crate::tools::SessionHost;

/// The host of one call. `host` gives the data of the session, and `folder` is the session folder at the
/// start of the call. `stop` is the cancellation token of the call. It cancels when the call ends or drops, and it
/// stops the commands of the call.
pub(crate) fn object<'js>(
    ctx: &Ctx<'js>,
    processes: &Arc<Processes>,
    host: &Arc<dyn SessionHost>,
    folder: PathBuf,
    stop: &CancellationToken,
    queue: &Queue<'js>,
) -> rquickjs::Result<Object<'js>> {
    let object = Object::new(ctx.clone())?;

    let exec_queue = queue.clone();
    let (exec_processes, exec_stop, exec_host) = (Arc::clone(processes), stop.clone(), Arc::clone(host));
    object.set(
        "exec",
        Function::new(
            ctx.clone(),
            Async(
                move |ctx: Ctx<'js>, command: String, limits: Object<'js>, on_output: Function<'js>| {
                    let processes = Arc::clone(&exec_processes);
                    let queue = exec_queue.clone();
                    let (folder, stop, owner) = (folder.clone(), exec_stop.clone(), Arc::clone(&exec_host));
                    async move {
                        let timeout_ms: u32 = limits.get("timeoutMs")?;
                        let max_bytes: u32 = limits.get("maxBytes")?;
                        let request = Request {
                            command,
                            folder,
                            timeout: Duration::from_millis(timeout_ms.into()),
                            max_bytes: max_bytes as usize,
                            stop,
                            owner,
                        };
                        exec(ctx, processes, request, on_output, queue).await
                    }
                },
            ),
        )?,
    )?;

    let start_queue = queue.clone();
    let (start_processes, start_host) = (Arc::clone(processes), Arc::clone(host));
    object.set(
        "startJob",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, command: String, timeout_ms: Option<u32>| {
                let (processes, host) = (Arc::clone(&start_processes), Arc::clone(&start_host));
                let (promise, _abort) = start_queue.request(
                    &ctx,
                    async move {
                        let timeout = timeout_ms.map(|ms| Duration::from_millis(ms.into()));
                        processes.start_job(command, timeout, host).await
                    },
                    |ctx, result| {
                        result
                            .map_err(|error| throw(ctx, ErrorClass::Error, &error.to_string()))?
                            .map_err(|message| throw(ctx, ErrorClass::Error, &message))
                    },
                )?;
                Ok::<_, rquickjs::Error>(promise)
            },
        )?,
    )?;

    let (stop_processes, stop_host, stop_call) = (Arc::clone(processes), Arc::clone(host), stop.clone());
    let stop_queue = queue.clone();
    object.set(
        "stopJob",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, id: String| {
            let (processes, host, call) = (Arc::clone(&stop_processes), Arc::clone(&stop_host), stop_call.clone());
            // The answer goes through the queue, so the `job_changed` event of the stop reaches JavaScript first.
            let (promise, _abort) = stop_queue.request(
                &ctx,
                async move {
                    // A plugin can take long to end its job, and a cancel of the call ends this wait, not the stop. The
                    // stop polls first, so a cancelled call still sends the stop.
                    tokio::select! {
                        biased;
                        found = processes.jobs().stop(host.session_id(), &id) => if found { "stopped" } else { "unknown" },
                        () = call.cancelled() => "stopping",
                    }
                },
                |ctx, result| result.map_err(|error| throw(ctx, ErrorClass::Error, &error.to_string())),
            )?;
            Ok::<_, rquickjs::Error>(promise)
        })?,
    )?;

    let (running_processes, running_host) = (Arc::clone(processes), Arc::clone(host));
    object.set(
        "runningJobs",
        Function::new(ctx.clone(), move || {
            running_processes
                .jobs()
                .running(running_host.session_id())
                .into_iter()
                .map(|job| job.id)
                .collect::<Vec<_>>()
        })?,
    )?;
    Ok(object)
}
