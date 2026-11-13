mod ai;
mod exec;
mod fs;
mod globals;
mod hooks;
mod network;
mod plugins;
mod process;
mod session_api;
mod sessions;
mod term;
mod tools;
mod typescript;
mod web;

use std::any::Any;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use rquickjs::{Ctx, FromJs, Promise};
use tokio::sync::mpsc;
use yuke_engine::CancellationToken;

use self::plugins::plugin;
use self::tools::TestHost;
use crate::error::caught;
use crate::{
    CompleteAnswer, CompleteRequest, Error, Models, Options, Plugin, PluginCode, Processes, Report, Runtime,
    ScriptError, ScriptSession, SideRequest,
};

/// A new empty folder for the test `name`.
fn folder(name: &str) -> PathBuf {
    yuke_testing::folder("js", name)
}

/// The module name of the file `file` below `folder`: its absolute path.
fn module(folder: &Path, file: &str) -> String {
    folder.join(file).to_str().unwrap().to_owned()
}

/// Write `files`, each a path below `folder` and its text.
fn write(folder: &Path, files: &[(&str, &str)]) {
    for (path, text) in files {
        let path = folder.join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }
}

/// The test model with the context window `window`.
fn windowed(window: Option<u64>) -> yuke_engine::Model {
    yuke_engine::Model {
        context_window: window,
        ..yuke_testing::model()
    }
}

/// The models of a test runtime: none.
struct NoModels;

#[async_trait::async_trait(?Send)]
impl Models for NoModels {
    async fn complete(
        &self,
        request: CompleteRequest,
        _cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn std::error::Error + Send + Sync>> {
        Err(format!("no model {}/{}", request.model.provider, request.model.model).into())
    }

    async fn side_request(
        &self,
        _request: SideRequest,
        _cancel: CancellationToken,
    ) -> Result<CompleteAnswer, Box<dyn std::error::Error + Send + Sync>> {
        Err("no side request".into())
    }
}

/// The sessions of a test runtime: none. Each request fails.
struct NoSessions;

/// The failure of each request of [`NoSessions`].
fn no_sessions<T>() -> Result<T, crate::SessionsError> {
    Err("no sessions".into())
}

#[async_trait::async_trait(?Send)]
impl crate::Sessions for NoSessions {
    async fn create(
        &self,
        _: yuke_protocol::SessionSettings,
        _: Option<yuke_protocol::SessionId>,
    ) -> Result<yuke_protocol::SessionId, crate::SessionsError> {
        no_sessions()
    }
    async fn fork(
        &self,
        _: yuke_protocol::SessionId,
        _: Option<yuke_protocol::EventNumber>,
    ) -> Result<yuke_protocol::SessionId, crate::SessionsError> {
        no_sessions()
    }
    async fn list(
        &self,
        _: yuke_protocol::ListSessionsParams,
    ) -> Result<yuke_protocol::ListSessionsResult, crate::SessionsError> {
        no_sessions()
    }
    async fn rename(
        &self,
        _id: yuke_protocol::SessionId,
        _title: yuke_protocol::SessionTitle,
    ) -> Result<(), crate::SessionsError> {
        Err("no sessions".into())
    }

    async fn get(&self, _: yuke_protocol::SessionId) -> Result<yuke_protocol::SessionRow, crate::SessionsError> {
        no_sessions()
    }
    async fn remove(&self, _: yuke_protocol::SessionId) -> Result<(), crate::SessionsError> {
        no_sessions()
    }
    async fn open(
        &self,
        _: yuke_protocol::SessionId,
        _: usize,
        _: crate::ViewSink,
    ) -> Result<Box<dyn Any>, crate::SessionsError> {
        no_sessions()
    }
    fn watch_facts(&self, _: crate::FactSink) -> Box<dyn Any> {
        Box::new(())
    }
    async fn events_before(
        &self,
        _: yuke_protocol::SessionId,
        _: Option<yuke_protocol::EventNumber>,
        _: usize,
    ) -> Result<Vec<yuke_protocol::StoredEvent>, crate::SessionsError> {
        no_sessions()
    }
    async fn input(
        &self,
        _: yuke_protocol::SessionId,
        _: yuke_protocol::Input,
    ) -> Result<yuke_protocol::InputId, crate::SessionsError> {
        no_sessions()
    }
    fn cancel(&self, _: yuke_protocol::SessionId) {}
    fn background(&self, _: yuke_protocol::SessionId) {}
    fn has_movable(&self, _: yuke_protocol::SessionId) -> bool {
        false
    }
    async fn idle(&self, _: yuke_protocol::SessionId) -> Result<(), crate::SessionsError> {
        no_sessions()
    }
    async fn set_settings(
        &self,
        _: yuke_protocol::SessionId,
        _: yuke_protocol::SessionSettings,
    ) -> Result<(), crate::SessionsError> {
        no_sessions()
    }
    async fn put_blob(&self, _: yuke_protocol::SessionId, _: Vec<u8>) -> Result<yuke_ai::Blob, crate::SessionsError> {
        no_sessions()
    }
    async fn remove_input(
        &self,
        _: yuke_protocol::SessionId,
        _: yuke_protocol::InputId,
    ) -> Result<bool, crate::SessionsError> {
        no_sessions()
    }
    fn respond(
        &self,
        _: yuke_protocol::SessionId,
        _: yuke_protocol::InteractionId,
        _: yuke_protocol::InteractionResponse,
    ) -> Result<(), crate::SessionsError> {
        no_sessions()
    }
    fn jobs(&self, _: yuke_protocol::SessionId) -> Result<Vec<yuke_protocol::Job>, crate::SessionsError> {
        no_sessions()
    }
    async fn stop_job(&self, _: yuke_protocol::SessionId, _: &str) -> Result<(), crate::SessionsError> {
        no_sessions()
    }
    fn mcp_servers(&self, _: yuke_protocol::SessionId) -> Result<Vec<yuke_protocol::McpServer>, crate::SessionsError> {
        no_sessions()
    }
    async fn close(&self, _: yuke_protocol::SessionId) -> Result<(), crate::SessionsError> {
        no_sessions()
    }
    async fn list_plugins(&self) -> Result<yuke_protocol::ListPluginsResult, crate::SessionsError> {
        no_sessions()
    }
    async fn sync_plugins(
        &self,
        _: yuke_protocol::SyncPluginsParams,
    ) -> Result<yuke_protocol::SyncPluginsResult, crate::SessionsError> {
        no_sessions()
    }
    async fn check_plugins(
        &self,
        _: yuke_protocol::CheckPluginsParams,
    ) -> Result<yuke_protocol::CheckPluginsResult, crate::SessionsError> {
        no_sessions()
    }
    async fn apply_plugins(
        &self,
        _: yuke_protocol::ApplyPluginsParams,
    ) -> Result<yuke_protocol::ApplyPluginsResult, crate::SessionsError> {
        no_sessions()
    }
    async fn add_plugin(
        &self,
        _: yuke_protocol::AddPluginParams,
    ) -> Result<yuke_protocol::AddPluginResult, crate::SessionsError> {
        no_sessions()
    }
    async fn remove_plugin(&self, _: yuke_protocol::RemovePluginParams) -> Result<(), crate::SessionsError> {
        no_sessions()
    }
    async fn catalog(&self, _: bool) -> Result<yuke_protocol::ListCatalogResult, crate::SessionsError> {
        no_sessions()
    }
    async fn login(&self, _: String) -> Result<yuke_protocol::LoginResult, crate::SessionsError> {
        no_sessions()
    }
    async fn wait_for_login(
        &self,
        _: yuke_protocol::LoginId,
    ) -> Result<yuke_protocol::LoginOutcome, crate::SessionsError> {
        no_sessions()
    }
    fn cancel_login(&self, _: yuke_protocol::LoginId) {}
    async fn set_api_key(&self, _: yuke_protocol::SetApiKeyParams) -> Result<(), crate::SessionsError> {
        no_sessions()
    }
    async fn logout(&self, _: String) -> Result<(), crate::SessionsError> {
        no_sessions()
    }
}

/// The options of a test runtime in `folder` with `processes`.
fn options(folder: &Path, processes: Rc<Processes>) -> Options {
    Options {
        cache: folder.join("cache"),
        processes,
        models: Rc::new(NoModels),
        sessions: Rc::new(NoSessions),
        http: Arc::new(
            yuke_http::Client::new(yuke_http::ClientOptions {
                idle_timeout: None,
                user_agent: "yuke-js-test".to_owned(),
            })
            .unwrap(),
        ),
        interface: None,
        internal_imports: false,
        test_host: None,
    }
}

async fn start(folder: &Path) -> (Runtime, mpsc::UnboundedReceiver<Report>) {
    Runtime::start(options(folder, Rc::new(Processes::new(folder.join("processes")))))
        .await
        .unwrap()
}

/// The plugin `name` with its folders, its entry, and its services.
fn descriptor(
    name: &str,
    root: PathBuf,
    data_dir: PathBuf,
    entry: Option<PathBuf>,
    uses: &[&str],
    provides: &[&str],
) -> Plugin {
    Plugin {
        name: name.to_owned(),
        origin: PluginCode::Folder { root, entry },
        data_dir,
        options: serde_json::Map::new(),
        uses: uses.iter().map(|&service| service.to_owned()).collect(),
        provides: provides.iter().map(|&service| service.to_owned()).collect(),
    }
}

/// Load the module `path` as the entry of the plugin `test`. The module exports `apply`, `session`, or both.
async fn load_entry(runtime: &Runtime, path: &Path) -> Result<(), Error> {
    let root = path.parent().unwrap().to_owned();
    let plugin = descriptor("test", root.clone(), root.join("data"), Some(path.to_owned()), &[], &[]);
    runtime.handle().load_plugin(&plugin).await
}

/// Run the body of an async function, and return the value of its promise.
async fn evaluate<T>(runtime: &Runtime, body: &str) -> Result<T, Error>
where
    T: for<'js> FromJs<'js> + 'static,
{
    let source = format!("(async () => {{ {body} }})()");
    runtime
        .access()
        .run(async move |ctx: Ctx<'_>, _registry| {
            let promise: Promise<'_> = caught(&ctx, ctx.eval(source))?;
            caught(&ctx, promise.into_future::<T>().await)
        })
        .await
}

/// Run `body` in a new runtime as the body of an async function, and return the value of its promise. A promise that
/// does not settle in five seconds fails the test, and so does a report, such as a fault, that came before the end.
async fn run<T>(name: &str, body: &str) -> T
where
    T: for<'js> FromJs<'js> + 'static,
{
    let folder = folder(name);
    let (runtime, mut reports) = start(&folder).await;
    let value = tokio::time::timeout(Duration::from_secs(5), evaluate::<T>(&runtime, body))
        .await
        .unwrap()
        .unwrap();
    crate::wait_for_settled().await;
    if let Ok(report) = reports.try_recv() {
        panic!("unexpected report: {report:?}");
    }
    value
}

/// Free each unreachable value, and run the finalization callbacks.
async fn collect_garbage(runtime: &Runtime) {
    runtime
        .access()
        .run(async |ctx: Ctx<'_>, _registry| {
            ctx.run_gc();
            Ok(())
        })
        .await
        .unwrap();
    crate::wait_for_settled().await;
}

/// The JavaScript of a function `names(calls)`. It gives the name of the error of each call, or `none`.
const NAMES: &str = "const names = (calls) => calls.map((call) => {
       try { call(); return 'none'; } catch (error) { return error.name; }
     }).join(' ');";

/// The next report. A missing report fails the test after five seconds.
async fn next_report(reports: &mut mpsc::UnboundedReceiver<Report>) -> Report {
    tokio::time::timeout(Duration::from_secs(5), reports.recv())
        .await
        .unwrap()
        .unwrap()
}

/// The next fault. A missing fault fails the test after five seconds.
async fn next_fault(reports: &mut mpsc::UnboundedReceiver<Report>) -> ScriptError {
    match next_report(reports).await {
        Report::Fault(error) => error,
        other => panic!("expected a fault, got {other:?}"),
    }
}

fn script_error(result: Result<impl std::fmt::Debug, Error>) -> ScriptError {
    match result {
        Err(Error::Script(error)) => error,
        other => panic!("expected a script error, got {other:?}"),
    }
}

#[tokio::test(flavor = "local")]
async fn concurrent_callers_get_the_values_of_their_promises() {
    let folder = folder("concurrent_callers_get_the_values_of_their_promises");
    let (runtime, _reports) = start(&folder).await;

    let mut calls = Vec::new();
    for number in 0..50 {
        let access = runtime.access();
        calls.push(tokio::task::spawn_local(async move {
            access
                .run(async move |ctx: Ctx<'_>, _registry| {
                    let promise: Promise<'_> = caught(
                        &ctx,
                        ctx.eval(format!(
                            "new Promise(resolve => setTimeout(() => resolve({number}), 10))"
                        )),
                    )?;
                    caught(&ctx, promise.into_future::<i32>().await)
                })
                .await
                .unwrap()
        }));
    }
    let mut numbers = Vec::new();
    for call in calls {
        numbers.push(call.await.unwrap());
    }
    assert_eq!(numbers, (0..50).collect::<Vec<_>>());
}

#[tokio::test(flavor = "local")]
async fn a_dropped_call_stops_its_future() {
    let folder = folder("a_dropped_call_stops_its_future");
    let (runtime, _faults) = start(&folder).await;
    let access = runtime.access();
    let (started, entered) = tokio::sync::oneshot::channel();

    {
        let call = access.run(async move |ctx: Ctx<'_>, _registry| {
            let promise: Promise<'_> = caught(
                &ctx,
                ctx.eval("new Promise(resolve => { globalThis.finishCall = resolve; })"),
            )?;
            started.send(()).unwrap();
            caught(&ctx, promise.into_future::<()>().await)?;
            caught(&ctx, ctx.globals().set("finished", true))
        });
        tokio::select! {
            result = call => panic!("the call ended before its promise resolved: {result:?}"),
            result = entered => result.unwrap(),
        }
    }
    crate::wait_for_settled().await;
    evaluate::<()>(&runtime, "finishCall();").await.unwrap();
    crate::wait_for_settled().await;

    assert_eq!(
        evaluate::<Option<bool>>(&runtime, "return globalThis.finished;")
            .await
            .unwrap(),
        None
    );
}

#[tokio::test(flavor = "local")]
async fn shutdown_ends_a_pending_call_and_releases_reports_while_handles_live() {
    let folder = folder("shutdown_ends_a_pending_call_and_releases_reports_while_handles_live");
    let (runtime, mut reports) = start(&folder).await;
    let handle = runtime.handle();
    let access = runtime.access();
    let (started, entered) = tokio::sync::oneshot::channel();
    let call = tokio::task::spawn_local(async move {
        access
            .run(async move |ctx: Ctx<'_>, _registry| {
                let promise: Promise<'_> = caught(&ctx, ctx.eval("new Promise(() => {})"))?;
                started.send(()).unwrap();
                caught(&ctx, promise.into_future::<()>().await)
            })
            .await
    });
    entered.await.unwrap();

    runtime.shutdown().await.unwrap();

    assert!(matches!(call.await.unwrap(), Err(Error::Stopped)));
    assert!(matches!(handle.close_plugins().await, Err(Error::Stopped)));
    assert!(reports.recv().await.is_none());
}

#[tokio::test(flavor = "local")]
async fn a_drive_panic_stops_pending_and_later_calls() {
    let folder = folder("a_drive_panic_stops_pending_and_later_calls");
    let (runtime, _reports) = start(&folder).await;
    let handle = runtime.handle();
    let access = runtime.access();
    let (started, entered) = tokio::sync::oneshot::channel();
    let call = tokio::task::spawn_local(async move {
        access
            .run(async move |ctx: Ctx<'_>, _registry| {
                let promise: Promise<'_> = caught(&ctx, ctx.eval("new Promise(() => {})"))?;
                started.send(()).unwrap();
                caught(&ctx, promise.into_future::<()>().await)
            })
            .await
    });
    entered.await.unwrap();

    runtime
        .access()
        .post(async move |_ctx: Ctx<'_>, _registry| panic!("drive failure"))
        .await
        .unwrap();

    let pending = tokio::time::timeout(Duration::from_secs(5), call).await;
    assert!(matches!(pending, Ok(Ok(Err(Error::Stopped)))), "{pending:?}");
    let later = tokio::time::timeout(Duration::from_secs(5), handle.close_plugins()).await;
    assert!(matches!(later, Ok(Err(Error::Stopped))), "{later:?}");
    let imported = tokio::time::timeout(Duration::from_secs(5), runtime.import("yuke:tools")).await;
    assert!(matches!(imported, Ok(Err(Error::Stopped))), "{imported:?}");
    assert!(matches!(runtime.shutdown().await, Err(Error::Panicked(message)) if message == "drive failure"));
}

#[tokio::test(flavor = "local")]
async fn javascript_runs_without_a_time_limit() {
    let folder = folder("javascript_runs_without_a_time_limit");
    let (runtime, mut faults) = start(&folder).await;

    // This stretch runs for more than one second without an await.
    let spun = evaluate::<bool>(
        &runtime,
        "const end = Date.now() + 1200; while (Date.now() < end) {} return true;",
    )
    .await;

    assert!(matches!(spun, Ok(true)), "{spun:?}");
    assert!(faults.try_recv().is_err());
}

#[tokio::test(flavor = "local")]
async fn a_shutdown_with_waiting_timers_ends_the_engine_task() {
    let folder = folder("a_shutdown_with_waiting_timers_ends_the_engine_task");
    let (runtime, _faults) = start(&folder).await;
    evaluate::<()>(
        &runtime,
        "setTimeout(() => {}, 60000, { held: true });
         setInterval(() => {}, 60000);",
    )
    .await
    .unwrap();

    // A saved timer value that outlives the engine aborts the process, so the end must free each timer first.
    tokio::time::timeout(Duration::from_secs(5), runtime.shutdown())
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test(flavor = "local")]
async fn a_throw_in_a_timer_callback_is_a_fault() {
    let folder = folder("a_throw_in_a_timer_callback_is_a_fault");
    let (runtime, mut faults) = start(&folder).await;

    evaluate::<()>(&runtime, "setTimeout(() => { throw new TypeError('late'); }, 1);")
        .await
        .unwrap();

    let error = next_fault(&mut faults).await;
    assert_eq!(error.name.as_deref(), Some("TypeError"));
    assert_eq!(error.message, "late");
}

#[tokio::test(flavor = "local")]
async fn a_throw_in_a_microtask_of_a_timer_is_a_fault() {
    let folder = folder("a_throw_in_a_microtask_of_a_timer_is_a_fault");
    let (runtime, mut faults) = start(&folder).await;

    evaluate::<()>(
        &runtime,
        "setTimeout(() => queueMicrotask(() => { throw new TypeError('from a timer'); }), 1);",
    )
    .await
    .unwrap();

    assert_eq!(next_fault(&mut faults).await.message, "from a timer");
}

#[tokio::test(flavor = "local")]
async fn a_throw_in_a_microtask_is_a_fault() {
    let folder = folder("a_throw_in_a_microtask_is_a_fault");
    let (runtime, mut faults) = start(&folder).await;

    let refused = evaluate::<String>(
        &runtime,
        "try { queueMicrotask(1); return 'none'; } catch (error) { return error.name; }",
    )
    .await
    .unwrap();
    evaluate::<()>(&runtime, "queueMicrotask(() => { throw new TypeError('direct'); });")
        .await
        .unwrap();

    assert_eq!(refused, "TypeError");
    assert_eq!(next_fault(&mut faults).await.message, "direct");
}

#[tokio::test(flavor = "local")]
async fn a_rejection_without_a_handler_is_a_fault() {
    let folder = folder("a_rejection_without_a_handler_is_a_fault");
    let (runtime, mut faults) = start(&folder).await;

    evaluate::<()>(&runtime, "Promise.reject(new Error('lost'));")
        .await
        .unwrap();

    assert_eq!(next_fault(&mut faults).await.message, "lost");
}

// The report of a rejection reads the message of its error, and that read runs script that can reject again.
#[tokio::test(flavor = "local")]
async fn a_rejection_during_the_report_of_a_rejection_is_a_fault_too() {
    let folder = folder("a_rejection_during_the_report_of_a_rejection_is_a_fault_too");
    let (runtime, mut faults) = start(&folder).await;

    evaluate::<()>(
        &runtime,
        "let first = true;
         const error = new Error();
         Object.defineProperty(error, 'message', {
           get() {
             if (first) { first = false; Promise.reject(new Error('inner')); }
             return 'outer';
           },
         });
         Promise.reject(error);",
    )
    .await
    .unwrap();

    let mut messages = Vec::new();
    for _ in 0..2 {
        messages.push(next_fault(&mut faults).await.message);
    }
    messages.sort();
    assert_eq!(messages, ["inner", "outer"]);
}

#[tokio::test(flavor = "local")]
async fn a_rejection_that_gets_a_handler_in_its_drive_is_no_fault() {
    let folder = folder("a_rejection_that_gets_a_handler_in_its_drive_is_no_fault");
    let (runtime, mut faults) = start(&folder).await;

    evaluate::<()>(
        &runtime,
        "const rejected = Promise.reject(new Error('handled'));
         await null;
         rejected.catch(() => {});",
    )
    .await
    .unwrap();

    crate::wait_for_settled().await;
    assert!(faults.try_recv().is_err());
}

#[tokio::test(flavor = "local")]
async fn a_thrown_value_that_is_no_error_keeps_its_string_form() {
    let folder = folder("a_thrown_value_that_is_no_error_keeps_its_string_form");
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(evaluate::<()>(&runtime, "throw 42;").await);
    assert_eq!(
        error,
        ScriptError {
            name: None,
            message: "42".into(),
            stack: None
        }
    );
}

#[tokio::test(flavor = "local")]
async fn a_suppressed_error_names_the_first_error_and_the_error_of_the_disposal() {
    let folder = folder("a_suppressed_error_names_the_first_error_and_the_error_of_the_disposal");
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(
        evaluate::<()>(
            &runtime,
            "throw new SuppressedError(new TypeError('close failed'), new RangeError('body failed'), '');",
        )
        .await,
    );

    assert_eq!(error.name.as_deref(), Some("SuppressedError"));
    let (first, then) = error.message.split_once("\nThen a disposal threw: ").unwrap();
    assert!(first.starts_with("RangeError: body failed\n"), "{first}");
    assert!(then.starts_with("TypeError: close failed\n"), "{then}");
}

#[tokio::test(flavor = "local")]
async fn a_typescript_module_imports_typescript_modules_by_relative_paths() {
    let folder = folder("a_typescript_module_imports_typescript_modules_by_relative_paths");
    write(
        &folder,
        &[
            (
                "plugin/main.ts",
                "import type { Count } from './types.ts';\nimport { double } from './lib/double.ts';\nconst count: Count = double(21);\nglobalThis.count = count;\n",
            ),
            ("plugin/types.ts", "export type Count = number;\n"),
            (
                "plugin/lib/double.ts",
                "export function double(value: number): number {\n  return value * 2;\n}\n",
            ),
        ],
    );
    let (runtime, _faults) = start(&folder).await;

    runtime.import(&module(&folder, "plugin/main.ts")).await.unwrap();

    assert_eq!(evaluate::<i32>(&runtime, "return globalThis.count;").await.unwrap(), 42);
}

#[tokio::test(flavor = "local")]
async fn two_names_of_one_file_give_one_module() {
    let folder = folder("two_names_of_one_file_give_one_module");
    write(
        &folder,
        &[
            (
                "main.js",
                "import './counter.js';\nimport './lib/../counter.js';\nimport './lib/again.js';\n",
            ),
            ("lib/again.js", "import '../counter.js';\n"),
            ("counter.js", "globalThis.loads = (globalThis.loads ?? 0) + 1;\n"),
        ],
    );
    let (runtime, _faults) = start(&folder).await;

    runtime.import(&module(&folder, "main.js")).await.unwrap();

    assert_eq!(evaluate::<i32>(&runtime, "return globalThis.loads;").await.unwrap(), 1);
}

#[tokio::test(flavor = "local")]
async fn a_throw_in_a_typescript_module_names_the_file_in_its_stack() {
    let folder = folder("a_throw_in_a_typescript_module_names_the_file_in_its_stack");
    write(
        &folder,
        &[(
            "broken.ts",
            "const reason: string = 'broken';\nthrow new Error(reason);\n",
        )],
    );
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(runtime.import(&module(&folder, "broken.ts")).await);

    assert_eq!(error.message, "broken");
    let stack = error.stack.unwrap();
    assert!(stack.contains(&*folder.join("broken.ts").to_string_lossy()), "{stack}");
}

#[tokio::test(flavor = "local")]
async fn a_typescript_syntax_error_names_its_line_and_column() {
    let folder = folder("a_typescript_syntax_error_names_its_line_and_column");
    write(&folder, &[("broken.ts", "const fine = 1;\nconst broken: = 2;\n")]);
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(runtime.import(&module(&folder, "broken.ts")).await);

    assert_eq!(error.name.as_deref(), Some("SyntaxError"));
    let place = format!("{}:2:", folder.join("broken.ts").display());
    assert!(error.message.starts_with(&place), "{}", error.message);
}

#[tokio::test(flavor = "local")]
async fn a_bare_module_name_does_not_resolve() {
    let folder = folder("a_bare_module_name_does_not_resolve");
    write(&folder, &[("main.js", "import 'lodash';\n")]);
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(runtime.import(&module(&folder, "main.js")).await);

    assert_eq!(error.name.as_deref(), Some("TypeError"));
    assert!(error.message.contains("cannot resolve 'lodash'"), "{}", error.message);
}

#[tokio::test(flavor = "local")]
async fn a_typescript_file_loads_from_its_cache_file() {
    let folder = folder("a_typescript_file_loads_from_its_cache_file");
    write(&folder, &[("main.ts", "globalThis.origin = 'source' as string;\n")]);
    {
        let (runtime, _faults) = start(&folder).await;
        runtime.import(&module(&folder, "main.ts")).await.unwrap();
    }

    // A changed cache file proves that the second runtime reads it and does not strip the source again.
    let files: Vec<PathBuf> = std::fs::read_dir(folder.join("cache"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    assert_eq!(files.len(), 1, "{files:?}");
    std::fs::write(&files[0], "globalThis.origin = 'cache';\n").unwrap();

    let (runtime, _faults) = start(&folder).await;
    runtime.import(&module(&folder, "main.ts")).await.unwrap();
    assert_eq!(
        evaluate::<String>(&runtime, "return globalThis.origin;").await.unwrap(),
        "cache"
    );
}

#[tokio::test(flavor = "local")]
async fn a_changed_typescript_file_gets_a_new_cache_file() {
    let folder = folder("a_changed_typescript_file_gets_a_new_cache_file");
    write(
        &folder,
        &[
            ("first.ts", "globalThis.value = 1 as number;\n"),
            ("second.ts", "globalThis.value = 2 as number;\n"),
        ],
    );
    let (runtime, _faults) = start(&folder).await;

    runtime.import(&module(&folder, "first.ts")).await.unwrap();
    runtime.import(&module(&folder, "second.ts")).await.unwrap();

    assert_eq!(std::fs::read_dir(folder.join("cache")).unwrap().count(), 2);
    assert_eq!(evaluate::<i32>(&runtime, "return globalThis.value;").await.unwrap(), 2);
}

/// A runtime in a new folder `name` with one plugin per `(name, entry)`, in that order, an open session, and the
/// reports of the runtime.
async fn opened(name: &str, plugins: &[(&str, &str)]) -> (Runtime, ScriptSession, mpsc::UnboundedReceiver<Report>) {
    let folder = folder(name);
    let (runtime, reports) = start(&folder).await;
    let specs: Vec<_> = plugins
        .iter()
        .map(|(plugin_name, source)| plugin(&folder, plugin_name, Some(source), &[], &[]))
        .collect();
    assert!(runtime.load_plugins(&specs).await.is_empty());
    let session = runtime
        .handle()
        .open_session(Rc::new(TestHost::new(&folder)))
        .await
        .unwrap();
    (runtime, session, reports)
}
