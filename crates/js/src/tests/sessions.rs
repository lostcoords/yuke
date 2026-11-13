//! These tests cover the session of the plugins: its setup, its tools, its failure, and its close.

use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

use tokio::sync::mpsc;

use super::plugins::tool;
use super::tools::{TestHost, Tools, call, error_of, text_of};
use super::{evaluate, folder, load_entry, start, write};
use crate::{Error, Report, Runtime, SessionHost};

/// A runtime in a new folder `name` with the plugin `test` whose entry is `source`.
async fn loaded(name: &str, source: &str) -> (PathBuf, Runtime, mpsc::UnboundedReceiver<Report>) {
    let folder = folder(name);
    write(&folder, &[("main.ts", source)]);
    let (runtime, reports) = start(&folder).await;
    load_entry(&runtime, &folder.join("main.ts")).await.unwrap();
    (folder, runtime, reports)
}

#[tokio::test(flavor = "local")]
async fn the_first_tools_wait_for_session_and_a_dropped_wait_leaves_it_running() {
    let (folder, runtime, _reports) = loaded(
        "the_first_tools_wait_for_session_and_a_dropped_wait_leaves_it_running",
        &format!(
            "export async function session(s) {{
               await new Promise((resolve) => {{ globalThis.release = resolve; }});
               s.tools.add({});
             }}",
            tool("late")
        ),
    )
    .await;
    let session = runtime
        .handle()
        .open_session(Rc::new(TestHost::new(&folder)))
        .await
        .unwrap();

    {
        let pending = session.tools();
        tokio::pin!(pending);
        tokio::select! {
            biased;
            _ = &mut pending => panic!("the tools arrived before release"),
            () = crate::wait_for_settled() => {}
        }
    }
    evaluate::<bool>(&runtime, "globalThis.release(); return true;")
        .await
        .unwrap();
    let tools = session.tools().await.unwrap();

    let names: Vec<&str> = tools.iter().map(|(definition, _)| definition.name.as_str()).collect();
    assert_eq!(names, ["late"]);
}

// A removed tool can still be in the tools of a running turn, so its handle answers an error, also after a new tool
// takes its name.
#[tokio::test(flavor = "local")]
async fn a_held_tool_that_its_plugin_removed_answers_an_error() {
    let (folder, runtime, _reports) = loaded(
        "a_held_tool_that_its_plugin_removed_answers_an_error",
        &format!(
            "export function session(s) {{
               const remove = s.tools.add({});
               globalThis.replace = () => {{ remove(); s.tools.add({}); }};
             }}",
            tool("gone"),
            tool("gone")
        ),
    )
    .await;
    let tools = Tools::open(&runtime, Rc::new(TestHost::new(&folder))).await;

    evaluate::<()>(&runtime, "globalThis.replace();").await.unwrap();

    assert_eq!(error_of(&tools["gone"], "{}").await, "the tool is no longer defined");
}

#[tokio::test(flavor = "local")]
async fn a_replacement_changes_new_snapshots_but_keeps_existing_handles() {
    let (folder, runtime, _reports) = loaded(
        "a_replacement_changes_new_snapshots_but_keeps_existing_handles",
        "export function session(s) {
           s.tools.add({ name: 'held', description: 'original', concurrency: 'serial',
             inputSchema: { type: 'object', properties: {} }, execute: () => 'old' });
           globalThis.replace = () => s.tools.add({
             name: 'held', description: 'replacement', concurrency: 'parallel',
             hints: { preview: 'tail' }, deferLoading: true,
             inputSchema: { type: 'object', properties: { value: { type: 'number' } }, required: ['value'] },
             execute: (args) => `new ${args.value}` });
         }",
    )
    .await;
    let tools = Tools::open(&runtime, Rc::new(TestHost::new(&folder))).await;

    evaluate::<()>(&runtime, "globalThis.replace();").await.unwrap();
    let current = tools.session.tools().await.unwrap();

    assert_eq!(text_of(&tools["held"], "{}").await, "old");
    assert_eq!(current.len(), 1);
    let (definition, tool) = &current[0];
    assert_eq!(text_of(tool, r#"{"value":7}"#).await, "new 7");
    assert_eq!(definition.description, "replacement");
    assert!(definition.defer_loading);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&definition.input_schema).unwrap(),
        serde_json::json!({"type": "object", "properties": {"value": {"type": "number"}}, "required": ["value"]})
    );
    assert_eq!(tool.concurrency, yuke_engine::Concurrency::Parallel);
    assert_eq!(tool.hints.preview, yuke_engine::Preview::Tail);
}

#[tokio::test(flavor = "local")]
async fn a_closed_session_has_no_tools() {
    let folder = folder("a_closed_session_has_no_tools");
    let (runtime, _reports) = start(&folder).await;
    runtime.import("yuke:internal/builtins").await.unwrap();
    let session = runtime
        .handle()
        .open_session(Rc::new(TestHost::new(&folder)))
        .await
        .unwrap();

    session.close().await.unwrap();

    assert!(session.tools().await.unwrap().is_empty());
}

#[tokio::test(flavor = "local")]
async fn a_drop_closes_the_session_once_and_a_second_close_or_a_drop_after_a_close_does_nothing() {
    let (folder, runtime, _reports) = loaded(
        "a_drop_closes_the_session_once_and_a_second_close_or_a_drop_after_a_close_does_nothing",
        "globalThis.cleaned = 0;
         export function session() { return () => { globalThis.cleaned += 1; }; }",
    )
    .await;
    let dropped = Tools::open(&runtime, Rc::new(TestHost::new(&folder))).await;
    let closed = Tools::open(&runtime, Rc::new(TestHost::new(&folder))).await;

    drop(dropped);
    // The close that the drop requests comes before the next call.
    let after_drop = evaluate::<i32>(&runtime, "return globalThis.cleaned;").await.unwrap();
    closed.session.close().await.unwrap();
    closed.session.close().await.unwrap();
    drop(closed);
    // A drop after an awaited close must not run the cleanup again.
    let after_close = evaluate::<i32>(&runtime, "return globalThis.cleaned;").await.unwrap();

    assert_eq!(after_drop, 1);
    assert_eq!(after_close, 2);
}

#[tokio::test(flavor = "local")]
async fn a_tool_of_yuke_fails_after_its_session_closes_and_a_new_open_does_not_revive_it() {
    let folder = folder("a_tool_of_yuke_fails_after_its_session_closes_and_a_new_open_does_not_revive_it");
    write(&folder, &[("notes.txt", "alpha\n")]);
    let (runtime, _reports) = start(&folder).await;
    runtime.import("yuke:internal/builtins").await.unwrap();
    let host = Rc::new(TestHost::new(&folder));
    let first = Tools::open(&runtime, Rc::clone(&host) as Rc<dyn SessionHost>).await;
    let old_read = first["read"].clone();

    first.session.close().await.unwrap();
    let second = Tools::open(&runtime, Rc::clone(&host) as Rc<dyn SessionHost>).await;
    // The close that this drop asks for names the old open, so it leaves the new one open.
    drop(first);

    assert_eq!(
        error_of(&old_read, r#"{"path": "notes.txt"}"#).await,
        "the session is closed"
    );
    assert!(call(&second["read"], r#"{"path": "notes.txt"}"#).await.is_ok());
}

#[tokio::test(flavor = "local")]
async fn a_shutdown_ends_while_a_session_waits_for_its_setup() {
    let (folder, runtime, _reports) = loaded(
        "a_shutdown_ends_while_a_session_waits_for_its_setup",
        "export function session() { return new Promise(() => {}); }",
    )
    .await;
    let session = runtime
        .handle()
        .open_session(Rc::new(TestHost::new(&folder)))
        .await
        .unwrap();

    let ended = tokio::time::timeout(Duration::from_secs(5), runtime.shutdown()).await;

    assert!(matches!(ended, Ok(Ok(()))), "{ended:?}");
    let closed = tokio::time::timeout(Duration::from_secs(5), session.close()).await;
    assert!(matches!(closed, Ok(Err(Error::Stopped))), "{closed:?}");
}

#[tokio::test(flavor = "local")]
async fn sessions_and_tools_do_not_keep_the_engine_alive_after_shutdown() {
    let (folder, runtime, _reports) = loaded(
        "sessions_and_tools_do_not_keep_the_engine_alive_after_shutdown",
        &format!("export function session(s) {{ s.tools.add({}); }}", tool("held")),
    )
    .await;
    let access = runtime.access();
    let tools = Tools::open(&runtime, Rc::new(TestHost::new(&folder))).await;

    runtime.shutdown().await.unwrap();

    assert!(access.engine.upgrade().is_none());
    let session_call = tokio::time::timeout(Duration::ZERO, tools.session.tools())
        .await
        .unwrap();
    assert!(matches!(session_call, Err(Error::Stopped)));
    let tool_call = tokio::time::timeout(Duration::ZERO, call(&tools["held"], "{}"))
        .await
        .unwrap();
    assert!(matches!(
        tool_call.unwrap_err().downcast_ref::<Error>(),
        Some(Error::Stopped)
    ));
}

#[test]
fn a_session_drop_without_a_local_executor_wakes_the_drive() {
    let executor = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build_local(tokio::runtime::LocalOptions::default())
        .unwrap();
    let (runtime, mut reports, tools) = executor.block_on(async {
        let (folder, runtime, reports) = loaded(
            "a_session_drop_without_a_local_executor_wakes_the_drive",
            "export function session() { return () => { console.log('closed'); }; }",
        )
        .await;
        let tools = Tools::open(&runtime, Rc::new(TestHost::new(&folder))).await;
        (runtime, reports, tools)
    });

    drop(tools);

    executor.block_on(async {
        assert!(matches!(
            super::next_report(&mut reports).await,
            Report::Console { text, .. } if text == "closed"
        ));
        runtime.shutdown().await.unwrap();
    });
}
