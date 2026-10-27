//! These tests cover the session of the plugins: its setup, its tools, its failure, and its close.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::mpsc;

use super::plugins::tool;
use super::tools::{TestHost, Tools, call, error_of};
use super::{evaluate, folder, load_entry, start, write};
use crate::{Report, Runtime, SessionHost};

/// A runtime in a new folder `name` with the plugin `test` whose entry is `source`.
async fn loaded(name: &str, source: &str) -> (PathBuf, Runtime, mpsc::UnboundedReceiver<Report>) {
    let folder = folder(name);
    write(&folder, &[("main.ts", source)]);
    let (runtime, reports) = start(&folder).await;
    load_entry(&runtime, &folder.join("main.ts")).await.unwrap();
    (folder, runtime, reports)
}

fn host(folder: &Path) -> Arc<TestHost> {
    Arc::new(TestHost::new(folder))
}

/// The global `name` after it equals `expected`, or after five seconds.
async fn global_once(runtime: &Runtime, name: &str, expected: i32) -> i32 {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let value = evaluate::<i32>(runtime, &format!("return globalThis.{name};"))
            .await
            .unwrap();
        if value == expected || Instant::now() > deadline {
            return value;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
async fn the_first_tools_wait_for_session_and_a_dropped_wait_leaves_it_running() {
    let (folder, runtime, _reports) = loaded(
        "the_first_tools_wait_for_session_and_a_dropped_wait_leaves_it_running",
        &format!(
            "export async function session(s) {{
               await new Promise((resolve) => {{ globalThis.release = resolve; }});
               s.tools.define({});
             }}",
            tool("late")
        ),
    )
    .await;
    let session = runtime.handle().open_session(host(&folder)).await.unwrap();

    let early = tokio::time::timeout(Duration::from_millis(100), session.tools()).await;
    evaluate::<bool>(&runtime, "globalThis.release(); return true;")
        .await
        .unwrap();
    let tools = session.tools().await.unwrap();

    assert!(early.is_err(), "the wait ended before the session settled");
    let names: Vec<&str> = tools.iter().map(|(definition, _)| definition.name.as_str()).collect();
    assert_eq!(names, ["late"]);
}

// A removed tool can still be in the tools of a running turn, so its handle answers an error, also after a new tool
// takes its name.
#[tokio::test]
async fn a_held_tool_that_its_plugin_removed_answers_an_error() {
    let (folder, runtime, _reports) = loaded(
        "a_held_tool_that_its_plugin_removed_answers_an_error",
        &format!(
            "export function session(s) {{
               const remove = s.tools.define({});
               globalThis.replace = () => {{ remove(); s.tools.define({}); }};
             }}",
            tool("gone"),
            tool("gone")
        ),
    )
    .await;
    let tools = Tools::open(&runtime, host(&folder)).await;

    evaluate::<()>(&runtime, "globalThis.replace();").await.unwrap();

    assert_eq!(error_of(&tools["gone"], "{}").await, "the tool is no longer defined");
}

#[tokio::test]
async fn a_closed_session_has_no_tools() {
    let folder = folder("a_closed_session_has_no_tools");
    let (runtime, _reports) = start(&folder).await;
    runtime.import("yuke:internal/builtins").await.unwrap();
    let session = runtime.handle().open_session(host(&folder)).await.unwrap();

    session.close().await.unwrap();

    assert!(session.tools().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_drop_closes_the_session_once_and_a_second_close_or_a_drop_after_a_close_does_nothing() {
    let (folder, runtime, _reports) = loaded(
        "a_drop_closes_the_session_once_and_a_second_close_or_a_drop_after_a_close_does_nothing",
        "globalThis.cleaned = 0;
         export function session() { return () => { globalThis.cleaned += 1; }; }",
    )
    .await;
    let dropped = Tools::open(&runtime, host(&folder)).await;
    let closed = Tools::open(&runtime, host(&folder)).await;

    drop(dropped);
    let after_drop = global_once(&runtime, "cleaned", 1).await;
    closed.session.close().await.unwrap();
    closed.session.close().await.unwrap();
    drop(closed);
    // The close that the drop posts comes before this call on the thread.
    let after_close = evaluate::<i32>(&runtime, "return globalThis.cleaned;").await.unwrap();

    assert_eq!(after_drop, 1);
    assert_eq!(after_close, 2);
}

#[tokio::test]
async fn a_tool_of_yuke_fails_after_its_session_closes_and_a_new_open_does_not_revive_it() {
    let folder = folder("a_tool_of_yuke_fails_after_its_session_closes_and_a_new_open_does_not_revive_it");
    write(&folder, &[("notes.txt", "alpha\n")]);
    let (runtime, _reports) = start(&folder).await;
    runtime.import("yuke:internal/builtins").await.unwrap();
    let host = host(&folder);
    let first = Tools::open(&runtime, Arc::clone(&host) as Arc<dyn SessionHost>).await;
    let old_read = first["read"].clone();

    first.session.close().await.unwrap();
    let second = Tools::open(&runtime, Arc::clone(&host) as Arc<dyn SessionHost>).await;
    // The close that this drop posts names the old open, so it leaves the new one open.
    drop(first);

    assert_eq!(
        error_of(&old_read, r#"{"path": "notes.txt"}"#).await,
        "the session is closed"
    );
    assert!(call(&second["read"], r#"{"path": "notes.txt"}"#).await.0.is_ok());
    assert_eq!(second.session.tools().await.unwrap().len(), 5);
}

#[tokio::test]
async fn a_shutdown_ends_while_a_session_waits_for_its_setup() {
    let (folder, runtime, _reports) = loaded(
        "a_shutdown_ends_while_a_session_waits_for_its_setup",
        "export function session() { return new Promise(() => {}); }",
    )
    .await;
    let session = runtime.handle().open_session(host(&folder)).await.unwrap();

    let ended = tokio::time::timeout(Duration::from_secs(5), runtime.shutdown()).await;

    assert!(matches!(ended, Ok(Ok(()))), "{ended:?}");
    drop(session);
}
