mod exec;
mod fs;
mod globals;
mod plugins;
mod sessions;
mod tools;
mod web;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use rquickjs::{Ctx, FromJs, Promise};
use tokio::sync::mpsc;

use crate::error::caught;
use crate::{Error, Options, Plugin, PluginError, Processes, Report, Runtime, ScriptError};

/// A new empty folder for the test `name`.
fn folder(name: &str) -> PathBuf {
    // The process id keeps two test runs at once apart.
    let folder = std::env::temp_dir()
        .join(format!("yuke-js-tests-{}", std::process::id()))
        .join(name);
    match std::fs::remove_dir_all(&folder) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => panic!("{}: {error}", folder.display()),
    }
    std::fs::create_dir_all(&folder).unwrap();
    // On macOS, the temporary folder is a symbolic link. A command reports the canonical path of its working folder.
    folder.canonicalize().unwrap()
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

async fn start(folder: &Path) -> (Runtime, mpsc::UnboundedReceiver<Report>) {
    Runtime::start(Options {
        cache: folder.join("cache"),
        processes: Arc::new(Processes::new(folder.join("processes"))),
    })
    .await
    .unwrap()
}

/// Load the module `path` as the entry of the plugin `test`. The module exports `apply`, `session`, or both.
async fn load_entry(runtime: &Runtime, path: &Path) -> Result<(), Error> {
    let root = path.parent().unwrap().to_owned();
    let plugin = Plugin {
        name: "test".to_owned(),
        data_dir: root.join("data"),
        root,
        entry: Some(path.to_owned()),
        uses: Vec::new(),
        provides: Vec::new(),
    };
    match runtime
        .load_plugins(&[plugin])
        .await
        .pop()
        .map(|failure| failure.reason)
    {
        None => Ok(()),
        Some(PluginError::Load(error)) => Err(error),
        Some(other) => panic!("{other:?}"),
    }
}

/// Run the body of an async function, and return the value of its promise.
async fn evaluate<T>(runtime: &Runtime, body: &str) -> Result<T, Error>
where
    T: for<'js> FromJs<'js> + Send + 'static,
{
    let source = format!("(async () => {{ {body} }})()");
    runtime
        .caller
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
    T: for<'js> FromJs<'js> + Send + 'static,
{
    let folder = folder(name);
    let (runtime, mut reports) = start(&folder).await;
    let value = tokio::time::timeout(Duration::from_secs(5), evaluate::<T>(&runtime, body))
        .await
        .unwrap()
        .unwrap();
    if let Ok(report) = reports.try_recv() {
        panic!("unexpected report: {report:?}");
    }
    value
}

/// The JavaScript of a function `names(calls)`. It gives the name of the error of each call, or `none`.
const NAMES: &str = "const names = (calls) => calls.map((call) => {
       try { call(); return 'none'; } catch (error) { return error.name; }
     }).join(' ');";

/// The next fault. A missing fault fails the test after five seconds.
async fn next_fault(faults: &mut mpsc::UnboundedReceiver<Report>) -> ScriptError {
    let report = tokio::time::timeout(Duration::from_secs(5), faults.recv())
        .await
        .unwrap()
        .unwrap();
    match report {
        Report::Fault(error) => error,
        other => panic!("expected a fault, got {other:?}"),
    }
}

/// The next report of `reports`, which must be a notice.
async fn next_notice(reports: &mut mpsc::UnboundedReceiver<Report>) -> yuke_protocol::NoticeParams {
    let report = tokio::time::timeout(Duration::from_secs(5), reports.recv())
        .await
        .unwrap()
        .unwrap();
    match report {
        Report::Notice(notice) => notice,
        other => panic!("expected a notice, got {other:?}"),
    }
}

fn script_error(result: Result<impl std::fmt::Debug, Error>) -> ScriptError {
    match result {
        Err(Error::Script(error)) => error,
        other => panic!("expected a script error, got {other:?}"),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn callers_on_many_threads_get_the_values_of_their_promises() {
    let folder = folder("callers_on_many_threads_get_the_values_of_their_promises");
    let runtime = Arc::new(start(&folder).await.0);

    let mut calls = Vec::new();
    for number in 0..50 {
        let runtime = Arc::clone(&runtime);
        calls.push(tokio::spawn(async move {
            evaluate::<i32>(
                &runtime,
                &format!("return await new Promise(resolve => setTimeout(() => resolve({number}), 10));"),
            )
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

#[tokio::test]
async fn a_dropped_call_stops_its_future_on_the_javascript_thread() {
    let folder = folder("a_dropped_call_stops_its_future_on_the_javascript_thread");
    let (runtime, _faults) = start(&folder).await;

    let call = runtime.caller.run(async |ctx: Ctx<'_>, _registry| {
        let promise: Promise<'_> = caught(&ctx, ctx.eval("new Promise(resolve => setTimeout(resolve, 100))"))?;
        caught(&ctx, promise.into_future::<()>().await)?;
        caught(&ctx, ctx.globals().set("finished", true))
    });
    assert!(tokio::time::timeout(Duration::from_millis(10), call).await.is_err());
    tokio::time::sleep(Duration::from_millis(200)).await;

    assert_eq!(
        evaluate::<Option<bool>>(&runtime, "return globalThis.finished;")
            .await
            .unwrap(),
        None
    );
}

#[tokio::test]
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

#[tokio::test]
async fn a_shutdown_stops_a_loop_without_an_await() {
    let folder = folder("a_shutdown_stops_a_loop_without_an_await");
    let (runtime, _faults) = start(&folder).await;
    let runtime = Arc::new(runtime);
    let looping = tokio::spawn({
        let runtime = Arc::clone(&runtime);
        async move { evaluate::<()>(&runtime, "for (;;) {}").await }
    });
    tokio::time::sleep(Duration::from_millis(20)).await;
    looping.abort();
    assert!(looping.await.unwrap_err().is_cancelled());

    tokio::time::timeout(Duration::from_secs(5), Arc::into_inner(runtime).unwrap().shutdown())
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn a_shutdown_ends_a_call_in_flight_as_stopped() {
    let folder = folder("a_shutdown_ends_a_call_in_flight_as_stopped");
    let (runtime, _faults) = start(&folder).await;
    // A tool keeps a clone of the caller, so its call can outlive the runtime.
    let caller = runtime.caller.clone();
    let looping = tokio::spawn(async move {
        caller
            .run(async |ctx: Ctx<'_>, _registry| caught(&ctx, ctx.eval::<(), _>("for (;;) {}")))
            .await
    });
    tokio::time::sleep(Duration::from_millis(20)).await;

    tokio::time::timeout(Duration::from_secs(5), runtime.shutdown())
        .await
        .unwrap()
        .unwrap();

    let ended = tokio::time::timeout(Duration::from_secs(5), looping)
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(ended, Err(Error::Stopped)), "{ended:?}");
}

#[tokio::test]
async fn a_deep_recursion_throws_a_catchable_range_error() {
    let folder = folder("a_deep_recursion_throws_a_catchable_range_error");
    let (runtime, _faults) = start(&folder).await;

    let name = evaluate::<String>(
        &runtime,
        "function deep(depth) { return deep(depth + 1) + 1; }
         try { deep(0); } catch (error) { return error.name; }",
    )
    .await
    .unwrap();
    assert_eq!(name, "RangeError");
}

#[tokio::test]
async fn a_shutdown_with_waiting_timers_ends_the_thread() {
    let folder = folder("a_shutdown_with_waiting_timers_ends_the_thread");
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

#[tokio::test]
async fn a_drop_does_not_wait_for_the_javascript() {
    let folder = folder("a_drop_does_not_wait_for_the_javascript");
    let (runtime, _faults) = start(&folder).await;
    let runtime = Arc::new(runtime);
    let looping = tokio::spawn({
        let runtime = Arc::clone(&runtime);
        async move { evaluate::<()>(&runtime, "for (;;) {}").await }
    });
    tokio::time::sleep(Duration::from_millis(20)).await;

    // The loop holds the thread until the drop stops it, and the drop of the last handle must not wait for it.
    looping.abort();
    assert!(looping.await.unwrap_err().is_cancelled());
    let begin = Instant::now();
    drop(Arc::into_inner(runtime).unwrap());
    assert!(begin.elapsed() < Duration::from_millis(50), "{:?}", begin.elapsed());
}

#[tokio::test]
async fn timers_with_one_delay_fire_in_the_order_of_their_set() {
    let folder = folder("timers_with_one_delay_fire_in_the_order_of_their_set");
    let (runtime, _faults) = start(&folder).await;

    let order = evaluate::<Vec<i32>>(
        &runtime,
        "const order = [];
         for (let index = 0; index < 20; index++) setTimeout(() => order.push(index), 5);
         await new Promise(resolve => setTimeout(resolve, 50));
         return order;",
    )
    .await
    .unwrap();
    assert_eq!(order, (0..20).collect::<Vec<_>>());
}

#[tokio::test]
async fn a_promise_job_of_a_timer_callback_runs_before_the_next_callback() {
    let folder = folder("a_promise_job_of_a_timer_callback_runs_before_the_next_callback");
    let (runtime, _faults) = start(&folder).await;

    let order = evaluate::<Vec<String>>(
        &runtime,
        "const order = [];
         setTimeout(() => { order.push('first'); Promise.resolve().then(() => order.push('job')); }, 5);
         setTimeout(() => order.push('second'), 5);
         await new Promise(resolve => setTimeout(resolve, 50));
         return order;",
    )
    .await
    .unwrap();
    assert_eq!(order, ["first", "job", "second"]);
}

#[tokio::test]
async fn a_cleared_timer_does_not_fire() {
    let folder = folder("a_cleared_timer_does_not_fire");
    let (runtime, _faults) = start(&folder).await;

    // The first callback clears a timer of the same round.
    let fired = evaluate::<Vec<String>>(
        &runtime,
        "const fired = [];
         let later;
         setTimeout(() => { fired.push('first'); clearTimeout(later); }, 5);
         later = setTimeout(() => fired.push('later'), 5);
         const never = setTimeout(() => fired.push('never'), 10);
         clearTimeout(never);
         await new Promise(resolve => setTimeout(resolve, 50));
         return fired;",
    )
    .await
    .unwrap();
    assert_eq!(fired, ["first"]);
}

#[tokio::test]
async fn an_interval_repeats_until_its_own_callback_clears_it() {
    let folder = folder("an_interval_repeats_until_its_own_callback_clears_it");
    let (runtime, _faults) = start(&folder).await;

    let count = evaluate::<i32>(
        &runtime,
        "let count = 0;
         const interval = setInterval(() => { count += 1; if (count === 3) clearInterval(interval); }, 2);
         await new Promise(resolve => setTimeout(resolve, 100));
         return count;",
    )
    .await
    .unwrap();
    assert_eq!(count, 3);
}

#[tokio::test]
async fn an_interval_waits_its_delay_between_calls() {
    let folder = folder("an_interval_waits_its_delay_between_calls");
    let (runtime, _faults) = start(&folder).await;

    let elapsed = evaluate::<f64>(
        &runtime,
        "const begin = Date.now();
         await new Promise(resolve => {
           let count = 0;
           const interval = setInterval(() => { count += 1; if (count === 3) { clearInterval(interval); resolve(); } }, 30);
         });
         return Date.now() - begin;",
    )
    .await
    .unwrap();
    // The third call comes 90 ms or later after the set. `Date.now` counts whole milliseconds.
    assert!(elapsed >= 89.0, "{elapsed}");
}

#[tokio::test]
async fn a_timer_callback_gets_the_extra_arguments() {
    let folder = folder("a_timer_callback_gets_the_extra_arguments");
    let (runtime, _faults) = start(&folder).await;

    let arguments = evaluate::<Vec<String>>(
        &runtime,
        "return await new Promise(resolve => setTimeout((...values) => resolve(values), undefined, 'a', 'b'));",
    )
    .await
    .unwrap();
    assert_eq!(arguments, ["a", "b"]);
}

#[tokio::test]
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

#[tokio::test]
async fn a_rejection_without_a_handler_is_a_fault() {
    let folder = folder("a_rejection_without_a_handler_is_a_fault");
    let (runtime, mut faults) = start(&folder).await;

    evaluate::<()>(&runtime, "Promise.reject(new Error('lost'));")
        .await
        .unwrap();

    assert_eq!(next_fault(&mut faults).await.message, "lost");
}

// The report of a rejection reads the message of its error, and that read runs script that can reject again.
#[tokio::test]
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

#[tokio::test]
async fn a_rejection_that_gets_a_handler_in_its_drive_is_no_fault() {
    let folder = folder("a_rejection_that_gets_a_handler_in_its_drive_is_no_fault");
    let (runtime, mut faults) = start(&folder).await;

    evaluate::<()>(
        &runtime,
        "const rejected = Promise.reject(new Error('handled'));
         await null;
         rejected.catch(() => {});
         setTimeout(() => { throw new Error('marker'); }, 1);",
    )
    .await
    .unwrap();

    // The marker fault comes after the drive of the rejection, so a fault of the rejection would come first.
    assert_eq!(next_fault(&mut faults).await.message, "marker");
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(faults.try_recv().is_err());
}

#[tokio::test]
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

#[tokio::test]
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

#[tokio::test]
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

#[tokio::test]
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

#[tokio::test]
async fn a_typescript_syntax_error_names_its_line_and_column() {
    let folder = folder("a_typescript_syntax_error_names_its_line_and_column");
    write(&folder, &[("broken.ts", "const fine = 1;\nconst broken: = 2;\n")]);
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(runtime.import(&module(&folder, "broken.ts")).await);

    assert_eq!(error.name.as_deref(), Some("SyntaxError"));
    let place = format!("{}:2:", folder.join("broken.ts").display());
    assert!(error.message.starts_with(&place), "{}", error.message);
}

#[tokio::test]
async fn a_bare_module_name_does_not_resolve() {
    let folder = folder("a_bare_module_name_does_not_resolve");
    write(&folder, &[("main.js", "import 'lodash';\n")]);
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(runtime.import(&module(&folder, "main.js")).await);

    assert_eq!(error.name.as_deref(), Some("TypeError"));
    assert!(error.message.contains("cannot resolve 'lodash'"), "{}", error.message);
}

#[tokio::test]
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

#[tokio::test]
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
