//! The session object of a call: the native functions that need the session or the life of the call, such as the
//! commands and the jobs. The bridge builds one for each call. `yuke:internal/session` keeps it from the tools of
//! plugins.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use rquickjs::function::Async;
use rquickjs::{Ctx, Function, Object};
use yuke_engine::CancellationToken;

use super::exec::exec;
use crate::error::throw;
use crate::processes::Processes;
use crate::processes::Request;
use crate::tools::SessionHost;

/// The session object for one call. `host` gives the data of the session, and `folder` is the session folder at the
/// start of the call. `stop` is the cancellation token of the call. It cancels when the call ends or drops, and it
/// stops the commands of the call.
pub(crate) fn object<'js>(
    ctx: &Ctx<'js>,
    processes: &Arc<Processes>,
    host: &Arc<dyn SessionHost>,
    folder: PathBuf,
    stop: &CancellationToken,
) -> rquickjs::Result<Object<'js>> {
    let object = Object::new(ctx.clone())?;

    let (exec_processes, exec_stop) = (Arc::clone(processes), stop.clone());
    object.set(
        "exec",
        Function::new(
            ctx.clone(),
            Async(
                move |ctx: Ctx<'js>, command: String, limits: Object<'js>, on_output: Function<'js>| {
                    let processes = Arc::clone(&exec_processes);
                    let (folder, stop) = (folder.clone(), exec_stop.clone());
                    async move {
                        let timeout_ms: u32 = limits.get("timeoutMs")?;
                        let max_bytes: u32 = limits.get("maxBytes")?;
                        let request = Request {
                            command,
                            folder,
                            timeout: Duration::from_millis(timeout_ms.into()),
                            max_bytes: max_bytes as usize,
                            stop,
                        };
                        exec(ctx, &processes, request, on_output).await
                    }
                },
            ),
        )?,
    )?;

    let (start_processes, start_host) = (Arc::clone(processes), Arc::clone(host));
    object.set(
        "startJob",
        Function::new(
            ctx.clone(),
            Async(move |ctx: Ctx<'js>, command: String| {
                let (processes, host) = (Arc::clone(&start_processes), Arc::clone(&start_host));
                async move {
                    let started = processes.start_job(command, host).await;
                    let (id, log) = started.map_err(|message| throw(&ctx, "Error", &message))?;
                    let job = Object::new(ctx.clone())?;
                    job.set("id", id)?;
                    job.set("log", log.to_string_lossy().into_owned())?;
                    Ok::<_, rquickjs::Error>(job)
                }
            }),
        )?,
    )?;

    let (stop_processes, stop_host) = (Arc::clone(processes), Arc::clone(host));
    object.set(
        "stopJob",
        Function::new(
            ctx.clone(),
            Async(move |ctx: Ctx<'js>, id: String| {
                let (processes, host) = (Arc::clone(&stop_processes), Arc::clone(&stop_host));
                async move {
                    let Some((label, log)) = processes.stop_job(&id, &host).await else {
                        return Ok(None);
                    };
                    let object = Object::new(ctx.clone())?;
                    object.set("label", label)?;
                    object.set("log", log.to_string_lossy().into_owned())?;
                    Ok::<_, rquickjs::Error>(Some(object))
                }
            }),
        )?,
    )?;

    let (running_processes, running_host) = (Arc::clone(processes), Arc::clone(host));
    object.set(
        "runningJobs",
        Function::new(ctx.clone(), move || {
            running_processes
                .running_jobs(&running_host)
                .into_iter()
                .map(|job| job.id)
                .collect::<Vec<_>>()
        })?,
    )?;
    Ok(object)
}
