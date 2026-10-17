//! These tests cover the session of the plugins: its setup, its tools, its failure, and its close.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::mpsc;
use yuke_protocol::{NoticeLevel, NoticeParams};

use super::plugins::{plugin, tool};
use super::tools::{TestHost, Tools, call, error_of};
use super::{evaluate, folder, load_entry, next_notice, start, write};
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
async fn a_tool_of_a_session_reaches_only_that_session() {
    let (folder, runtime, _reports) = loaded(
        "a_tool_of_a_session_reaches_only_that_session",
        &format!(
            "let count = 0;
             export function session(s) {{
               count += 1;
               s.tools.define({{ ...{}, name: `t${{count}}` }});
             }}",
            tool("t")
        ),
    )
    .await;

    let first = Tools::open(&runtime, host(&folder)).await;
    let second = Tools::open(&runtime, host(&folder)).await;

    assert_eq!(first.names(), ["t1"]);
    assert_eq!(second.names(), ["t2"]);
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
    let session = runtime.open_session(host(&folder)).await.unwrap();

    let early = tokio::time::timeout(Duration::from_millis(100), session.tools()).await;
    evaluate::<bool>(&runtime, "globalThis.release(); return true;")
        .await
        .unwrap();
    let tools = session.tools().await.unwrap();

    assert!(early.is_err(), "the wait ended before the session settled");
    let names: Vec<&str> = tools.iter().map(|(definition, _)| definition.name.as_str()).collect();
    assert_eq!(names, ["late"]);
}

#[tokio::test]
async fn a_tool_that_session_defines_after_its_setup_reaches_the_next_tools() {
    let (folder, runtime, _reports) = loaded(
        "a_tool_that_session_defines_after_its_setup_reaches_the_next_tools",
        &format!(
            "export function session(s) {{
               s.tools.define({});
               globalThis.defineLater = () => s.tools.define({});
             }}",
            tool("first"),
            tool("later")
        ),
    )
    .await;
    let tools = Tools::open(&runtime, host(&folder)).await;

    evaluate::<bool>(&runtime, "globalThis.defineLater(); return true;")
        .await
        .unwrap();
    let next = tools.session.tools().await.unwrap();

    assert_eq!(tools.names(), ["first"]);
    let names: Vec<&str> = next.iter().map(|(definition, _)| definition.name.as_str()).collect();
    assert_eq!(names, ["first", "later"]);
}

#[tokio::test]
async fn a_failed_session_drops_only_its_tools_aborts_its_signal_and_sends_one_notice() {
    let folder = folder("a_failed_session_drops_only_its_tools_aborts_its_signal_and_sends_one_notice");
    let (runtime, mut reports) = start(&folder).await;
    let bad = plugin(
        &folder,
        "bad",
        Some(&format!(
            "export async function session(s) {{
               globalThis.bad = s;
               s.tools.define({});
               await null;
               throw new Error('broken');
             }}",
            tool("dropped")
        )),
        &[],
        &[],
    );
    let good = plugin(
        &folder,
        "good",
        Some(&format!(
            "export function session(s) {{ s.tools.define({}); }}",
            tool("kept")
        )),
        &[],
        &[],
    );
    assert!(runtime.load_plugins(&[bad, good]).await.is_empty());
    let host = host(&folder);

    let tools = Tools::open(&runtime, Arc::clone(&host) as Arc<dyn SessionHost>).await;
    let notice = next_notice(&mut reports).await;

    assert_eq!(tools.names(), ["kept"]);
    assert_eq!(
        notice,
        NoticeParams {
            session_id: Some(host.session),
            level: NoticeLevel::Error,
            source: "bad".to_owned(),
            message: "the session setup failed, and its tools are gone: Error: broken".to_owned(),
        }
    );
    assert!(reports.try_recv().is_err(), "a second report came");
    let after = evaluate::<String>(
        &runtime,
        &format!(
            "try {{ globalThis.bad.tools.define({}); return 'defined'; }}
             catch (error) {{ return `${{globalThis.bad.signal.aborted}} ${{error.message}}`; }}",
            tool("again")
        ),
    )
    .await
    .unwrap();
    assert_eq!(after, "true plugin bad defines a tool after the end of its session");
}

#[tokio::test]
async fn a_session_that_throws_at_once_drops_its_tools_and_sends_a_notice() {
    let (folder, runtime, mut reports) = loaded(
        "a_session_that_throws_at_once_drops_its_tools_and_sends_a_notice",
        &format!(
            "export function session(s) {{ s.tools.define({}); throw new Error('at once'); }}",
            tool("gone")
        ),
    )
    .await;

    let tools = Tools::open(&runtime, host(&folder)).await;
    let notice = next_notice(&mut reports).await;

    assert_eq!(tools.names(), Vec::<&str>::new());
    assert_eq!(
        notice.message,
        "the session setup failed, and its tools are gone: Error: at once"
    );
}

#[tokio::test]
async fn a_closed_session_has_no_tools() {
    let folder = folder("a_closed_session_has_no_tools");
    let (runtime, _reports) = start(&folder).await;
    runtime.import("yuke:internal/builtins").await.unwrap();
    let session = runtime.open_session(host(&folder)).await.unwrap();

    session.close().await.unwrap();

    assert!(session.tools().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_session_that_returns_a_value_that_is_no_cleanup_fails() {
    let (folder, runtime, mut reports) = loaded(
        "a_session_that_returns_a_value_that_is_no_cleanup_fails",
        &format!(
            "export function session(s) {{ s.tools.define({}); return 5; }}",
            tool("gone")
        ),
    )
    .await;

    let tools = Tools::open(&runtime, host(&folder)).await;
    let notice = next_notice(&mut reports).await;

    assert_eq!(tools.names(), Vec::<&str>::new());
    assert_eq!(
        notice.message,
        "the session setup failed, and its tools are gone: TypeError: session must return nothing or a cleanup function"
    );
}

#[tokio::test]
async fn a_tool_of_a_session_with_the_name_of_a_tool_of_yuke_fails_its_session() {
    let (folder, runtime, mut reports) = loaded(
        "a_tool_of_a_session_with_the_name_of_a_tool_of_yuke_fails_its_session",
        &format!("export function session(s) {{ s.tools.define({}); }}", tool("read")),
    )
    .await;
    runtime.import("yuke:internal/builtins").await.unwrap();

    let tools = Tools::open(&runtime, host(&folder)).await;
    let notice = next_notice(&mut reports).await;

    assert_eq!(tools.names(), ["read", "write", "edit", "exec", "stop"]);
    assert_eq!(
        notice.message,
        "the session setup failed, and its tools are gone: TypeError: the session already has a tool with the name 'read'"
    );
}

#[tokio::test]
async fn a_notice_of_a_session_names_its_session() {
    let (folder, runtime, mut reports) = loaded(
        "a_notice_of_a_session_names_its_session",
        "export function session(s) { s.notify('info', 'opened'); }",
    )
    .await;
    let host = host(&folder);

    let _tools = Tools::open(&runtime, Arc::clone(&host) as Arc<dyn SessionHost>).await;
    let notice = next_notice(&mut reports).await;

    assert_eq!(
        notice,
        NoticeParams {
            session_id: Some(host.session),
            level: NoticeLevel::Info,
            source: "test".to_owned(),
            message: "opened".to_owned(),
        }
    );
}

#[tokio::test]
async fn a_close_refuses_definitions_before_the_abort_and_awaits_every_cleanup() {
    let folder = folder("a_close_refuses_definitions_before_the_abort_and_awaits_every_cleanup");
    let (runtime, mut reports) = start(&folder).await;
    let broken = plugin(
        &folder,
        "broken",
        Some("export function session() { return () => { throw new Error('no cleanup'); }; }"),
        &[],
        &[],
    );
    let kept = plugin(
        &folder,
        "kept",
        Some(&format!(
            "globalThis.cleaned = 0;
             export function session(s) {{
               s.signal.addEventListener('abort', () => {{
                 try {{ s.tools.define({}); }} catch (error) {{ globalThis.refused = error.message; }}
               }});
               s.tools.define({});
               return async () => {{
                 await new Promise((resolve) => setTimeout(resolve, 20));
                 globalThis.cleaned += 1;
               }};
             }}",
            tool("late"),
            tool("kept")
        )),
        &[],
        &[],
    );
    assert!(runtime.load_plugins(&[broken, kept]).await.is_empty());
    let tools = Tools::open(&runtime, host(&folder)).await;
    let kept = tools["kept"].clone();

    tokio::time::timeout(Duration::from_secs(5), tools.session.close())
        .await
        .unwrap()
        .unwrap();

    assert_eq!(
        evaluate::<i32>(&runtime, "return globalThis.cleaned;").await.unwrap(),
        1
    );
    assert_eq!(
        evaluate::<String>(&runtime, "return globalThis.refused;")
            .await
            .unwrap(),
        "plugin kept defines a tool after the end of its session"
    );
    assert_eq!(
        next_notice(&mut reports).await.message,
        "the cleanup of the session failed: Error: no cleanup"
    );
    assert_eq!(error_of(&kept, "{}").await, "the session is closed");
}

#[tokio::test]
async fn a_close_during_the_setup_ends_and_runs_the_late_cleanup_once() {
    let (folder, runtime, _reports) = loaded(
        "a_close_during_the_setup_ends_and_runs_the_late_cleanup_once",
        "globalThis.cleaned = 0;
         export async function session(s) {
           await new Promise((resolve) => s.signal.addEventListener('abort', resolve));
           return () => { globalThis.cleaned += 1; };
         }",
    )
    .await;
    let session = runtime.open_session(host(&folder)).await.unwrap();

    tokio::time::timeout(Duration::from_secs(5), session.close())
        .await
        .unwrap()
        .unwrap();

    assert_eq!(
        evaluate::<i32>(&runtime, "return globalThis.cleaned;").await.unwrap(),
        1
    );
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
    let session = runtime.open_session(host(&folder)).await.unwrap();

    let ended = tokio::time::timeout(Duration::from_secs(5), runtime.shutdown()).await;

    assert!(matches!(ended, Ok(Ok(()))), "{ended:?}");
    drop(session);
}
