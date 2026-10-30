//! The host of `createHost` in `yuke:test`: a capability that the consumer gives to the runtime of a test, and the
//! natives that reach it. A runtime without it has natives that fail with a clear text.

use std::sync::Arc;

use async_trait::async_trait;
use rquickjs::{Ctx, FromJs, Function, IntoJs, Object, Promise};
use tokio::runtime::Handle;
use tokio::sync::mpsc;
use yuke_ai::Blob;
use yuke_engine::CancellationToken;
use yuke_protocol::SessionId;

use crate::ScriptSession;
use crate::error::{Barrier, ErrorClass, Report, throw};
use crate::native::Operation;
use crate::test_drive::{CallRequest, RunRequest, call_tool, run_point};
use crate::test_runner::TestError;
use crate::tools::Json;

/// The text of a native call in a runtime without a test host.
const NO_HOST: &str = "no test host: run this file with yuke test";

/// The host of the tests of a runtime: the app around the runtime of one test. The runtime calls each method from a
/// native of `yuke:test`. Each async method runs on the tokio runtime of the consumer.
#[async_trait]
pub trait TestHost: Send + Sync {
    /// Load the plugins and the model script of a new host. `request` is the JSON of `createHost`: the plugins under
    /// test in their order, and the scripted replies. The JavaScript gave the exports of each given plugin already.
    ///
    /// # Errors
    ///
    /// Returns why the host did not start: a request of the wrong shape, a plugin list that breaks a rule, or a plugin
    /// that did not load.
    async fn create(&self, request: serde_json::Value) -> Result<(), TestError>;

    /// What the host recorded so far, as the JSON of `yuke:test`: the notices, the events, and the model requests. The
    /// call runs on the JavaScript thread, so it must not block.
    fn record(&self) -> serde_json::Value;

    /// Close the sessions and the plugins of the host, then check the model script.
    ///
    /// # Errors
    ///
    /// Returns why the check failed: a request after the last scripted reply, or a reply without a request.
    async fn close(&self) -> Result<(), TestError>;

    /// The script session of the open session `id`, for the hook and the tool drivers.
    ///
    /// # Errors
    ///
    /// Returns why the session has none: it is not open.
    fn script_session(&self, id: SessionId) -> Result<Arc<ScriptSession>, TestError>;

    /// The bytes of the media `blob` of the session `id`, for the media that a driver gives back.
    ///
    /// # Errors
    ///
    /// Returns why the bytes did not read: the store failed, or it has no such blob.
    fn read_media(&self, id: SessionId, blob: &Blob) -> Result<Vec<u8>, TestError>;
}

/// Add the natives of the test host to `object`, the export object of the native module.
pub(crate) fn add<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    host: Option<&Arc<dyn TestHost>>,
    consumer: &Handle,
    reports: mpsc::UnboundedSender<Report>,
) -> rquickjs::Result<()> {
    let settle_host = host.is_some();
    object.set(
        "testHostSettle",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>| -> rquickjs::Result<Promise<'js>> {
            if !settle_host {
                return Err(throw(&ctx, ErrorClass::Error, NO_HOST));
            }
            // The reports go in order, so the consumer releases the barrier after each report before it.
            let (barrier, released) = Barrier::new();
            let sent = reports.send(Report::Barrier(barrier));
            let error_ctx = ctx.clone();
            Promise::wrap_future(&ctx, async move {
                let ended = || throw(&error_ctx, ErrorClass::Error, "the reports of the runtime have ended");
                sent.map_err(|_| ended())?;
                released.await.map_err(|_| ended())
            })
        })?,
    )?;
    let record_host = host.cloned();
    object.set(
        "testHostRecord",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>| -> rquickjs::Result<Json<serde_json::Value>> {
                let host = record_host
                    .as_ref()
                    .ok_or_else(|| throw(&ctx, ErrorClass::Error, NO_HOST))?;
                Ok(Json(host.record()))
            },
        )?,
    )?;
    add_operation(
        object,
        "testHostCreate",
        host,
        consumer,
        |host, request: Json<serde_json::Value>, _token| async move { host.create(request.0).await.map(Json) },
    )?;
    add_operation(
        object,
        "testHostClose",
        host,
        consumer,
        |host, _request: Json<()>, _token| async move { host.close().await.map(Json) },
    )?;
    add_operation(
        object,
        "testHostRun",
        host,
        consumer,
        |host, request: RunRequest, token| async move { run_point(&*host, request, token).await },
    )?;
    add_operation(
        object,
        "testHostCall",
        host,
        consumer,
        |host, request: CallRequest, token| async move { call_tool(&*host, request, token).await },
    )
}

/// Add the native `name`. The JavaScript thread reads its argument, and `run` runs on the runtime of the consumer. It
/// answers an operation that gives the result. A cancel of the operation cancels the token of `run`.
fn add_operation<'js, A, T, F>(
    object: &Object<'js>,
    name: &str,
    host: Option<&Arc<dyn TestHost>>,
    consumer: &Handle,
    run: impl Fn(Arc<dyn TestHost>, A, CancellationToken) -> F + 'js,
) -> rquickjs::Result<()>
where
    A: FromJs<'js> + Send + 'static,
    T: IntoJs<'js> + Send + 'static,
    F: Future<Output = Result<T, TestError>> + Send + 'static,
{
    let (host, consumer) = (host.cloned(), consumer.clone());
    object.set(
        name,
        Function::new(
            object.ctx().clone(),
            move |ctx: Ctx<'js>, argument: A| -> rquickjs::Result<Operation<'js>> {
                let host = host.clone().ok_or_else(|| throw(&ctx, ErrorClass::Error, NO_HOST))?;
                Operation::start(&ctx, |ctx, token| {
                    let task = consumer.spawn(run(host, argument, token));
                    async move { joined(&ctx, task.await) }
                })
            },
        )?,
    )
}

/// The answer of a host task for JavaScript: its value, or a throw with the text of its failure.
fn joined<T>(ctx: &Ctx<'_>, joined: Result<Result<T, TestError>, tokio::task::JoinError>) -> rquickjs::Result<T> {
    match joined {
        Ok(Ok(value)) => Ok(value),
        // A throw of a plugin keeps its name, its message, and its stack, as in the plugin.
        Ok(Err(error)) => Err(match error.downcast_ref::<crate::Error>() {
            Some(crate::Error::Script(script)) => script.rethrow(ctx),
            _ => throw(ctx, ErrorClass::Error, &yuke_engine::chain_text(error.as_ref())),
        }),
        Err(error) => Err(throw(ctx, ErrorClass::Error, &error.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::joined;

    #[test]
    fn a_host_task_error_reaches_javascript_with_each_cause() {
        let runtime = rquickjs::Runtime::new().unwrap();
        let context = rquickjs::Context::full(&runtime).unwrap();
        context.with(|ctx| {
            let failure = crate::Error::Thread(std::io::Error::other("the cause"));
            let result = joined::<()>(&ctx, Ok(Err(failure.into())));
            let error = crate::error::caught(&ctx, result).unwrap_err();

            assert_eq!(
                error.to_string(),
                "Error: the JavaScript thread did not start: the cause"
            );
        });
    }
}
