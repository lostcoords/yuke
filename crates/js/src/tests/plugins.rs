//! The plugin loader: the context of `apply`, the tools that a plugin owns, the services, and the failures.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use yuke_protocol::{NoticeLevel, NoticeParams};

use super::tools::TestHost;
use super::{evaluate, folder, module, script_error, start, write};
use crate::{Plugin, PluginError, PluginFailure, Report, Runtime};

/// A plugin `name` in `folder` whose entry is `source`, or a plugin without code when `source` is `None`.
fn plugin(folder: &Path, name: &str, source: Option<&str>, uses: &[&str], provides: &[&str]) -> Plugin {
    let root = folder.join(name);
    std::fs::create_dir_all(&root).unwrap();
    let data_dir = folder.join("data").join(name);
    std::fs::create_dir_all(&data_dir).unwrap();
    let entry = source.map(|source| {
        write(&root, &[("index.ts", source)]);
        root.join("index.ts")
    });
    Plugin {
        name: name.to_owned(),
        root,
        data_dir,
        entry,
        uses: uses.iter().map(|&service| service.to_owned()).collect(),
        provides: provides.iter().map(|&service| service.to_owned()).collect(),
    }
}

/// A tool definition with `name` for a plugin entry.
fn tool(name: &str) -> String {
    format!(
        "{{ name: '{name}', description: 'd', concurrency: 'serial', parameters: {{ type: 'object', properties: {{}} }}, execute: () => 'x' }}"
    )
}

/// The names of the tools of `runtime`, in their order.
async fn tool_names(runtime: &Runtime, folder: &Path) -> Vec<String> {
    let host = Arc::new(TestHost::new(folder));
    let tools = runtime.tools(host).await.unwrap();
    tools.into_iter().map(|(definition, _)| definition.name).collect()
}

/// The name and the first line of the text of each failure. The rest is the stack of a script error.
fn texts(failures: &[PluginFailure]) -> Vec<(String, String)> {
    failures
        .iter()
        .map(|failure| {
            let text = failure.to_string();
            (failure.name.clone(), text.lines().next().unwrap_or_default().to_owned())
        })
        .collect()
}

#[tokio::test]
async fn a_plugin_gets_its_context_and_owns_the_tools_that_it_defines() {
    let folder = folder("a_plugin_gets_its_context_and_owns_the_tools_that_it_defines");
    let (runtime, _reports) = start(&folder).await;
    let one = plugin(
        &folder,
        "one",
        Some(&format!(
            "export default function apply(ctx) {{
               globalThis.seen = [ctx.name, ctx.root, ctx.dataDir, ctx.signal.aborted];
               ctx.tools.define({});
             }}",
            tool("hello")
        )),
        &[],
        &[],
    );
    let two = plugin(
        &folder,
        "two",
        Some(&format!(
            "export default function apply(ctx) {{ ctx.tools.define({}); }}",
            tool("hello")
        )),
        &[],
        &[],
    );

    let failures = runtime.load_plugins(&[one.clone(), two]).await;

    let seen = evaluate::<Vec<String>>(&runtime, "return globalThis.seen.map(String);")
        .await
        .unwrap();
    assert_eq!(
        seen,
        [
            "one".to_owned(),
            one.root.to_string_lossy().into_owned(),
            one.data_dir.to_string_lossy().into_owned(),
            "false".to_owned(),
        ]
    );
    assert_eq!(tool_names(&runtime, &folder).await, ["hello"]);
    assert_eq!(
        texts(&failures),
        [(
            "two".to_owned(),
            "plugin two did not load: TypeError: plugin one already defines a tool with the name 'hello'".to_owned()
        )]
    );
}

#[tokio::test]
async fn a_failed_plugin_drops_its_tools_and_aborts_its_signal() {
    let folder = folder("a_failed_plugin_drops_its_tools_and_aborts_its_signal");
    let (runtime, _reports) = start(&folder).await;
    let bad = plugin(
        &folder,
        "bad",
        Some(&format!(
            "export default async function apply(ctx) {{
               globalThis.badSignal = ctx.signal;
               ctx.tools.define({});
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
            "export default function apply(ctx) {{ ctx.tools.define({}); }}",
            tool("kept")
        )),
        &[],
        &[],
    );

    let failures = runtime.load_plugins(&[bad, good]).await;

    assert_eq!(
        texts(&failures),
        [("bad".to_owned(), "plugin bad did not load: Error: broken".to_owned())]
    );
    assert_eq!(tool_names(&runtime, &folder).await, ["kept"]);
    assert!(
        evaluate::<bool>(&runtime, "return globalThis.badSignal.aborted;")
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn a_failed_plugin_that_replaces_the_web_globals_still_drops_its_tools_and_aborts_its_signal() {
    let folder = folder("a_failed_plugin_that_replaces_the_web_globals_still_drops_its_tools_and_aborts_its_signal");
    let (runtime, _reports) = start(&folder).await;
    let bad = plugin(
        &folder,
        "bad",
        Some(&format!(
            "export default function apply(ctx) {{
               globalThis.badSignal = ctx.signal;
               ctx.tools.define({});
               globalThis.DOMException = undefined;
               globalThis.AbortController = undefined;
               throw new Error('broken');
             }}",
            tool("dropped")
        )),
        &[],
        &[],
    );

    let failures = runtime.load_plugins(&[bad]).await;

    assert_eq!(
        texts(&failures),
        [("bad".to_owned(), "plugin bad did not load: Error: broken".to_owned())]
    );
    assert_eq!(tool_names(&runtime, &folder).await, Vec::<String>::new());
    assert_eq!(
        evaluate::<String>(&runtime, "return globalThis.badSignal.reason.name;")
            .await
            .unwrap(),
        "AbortError"
    );
}

#[tokio::test]
async fn a_native_throws_the_error_class_of_the_start_after_a_plugin_replaces_the_global() {
    let folder = folder("a_native_throws_the_error_class_of_the_start_after_a_plugin_replaces_the_global");
    let (runtime, _reports) = start(&folder).await;
    let one = plugin(
        &folder,
        "one",
        Some(
            "export default function apply(ctx) {
               const original = TypeError;
               globalThis.TypeError = class Fake extends Error {};
               try { ctx.notify('loud', 'x'); } catch (error) { globalThis.seen = error instanceof original; }
               globalThis.TypeError = original;
             }",
        ),
        &[],
        &[],
    );

    let failures = runtime.load_plugins(&[one]).await;

    assert!(failures.is_empty(), "{failures:?}");
    assert!(
        evaluate::<bool>(&runtime, "return globalThis.seen === true;")
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn a_plugin_cannot_abort_the_signal_of_its_context() {
    let folder = folder("a_plugin_cannot_abort_the_signal_of_its_context");
    let (runtime, _reports) = start(&folder).await;
    let one = plugin(
        &folder,
        "one",
        Some(
            "export default function apply(ctx) {
               const signal = ctx.signal;
               globalThis.seen = ['abort' in signal, signal.dispatchEvent(new Event('abort')), signal.aborted].join(' ');
             }",
        ),
        &[],
        &[],
    );

    let failures = runtime.load_plugins(&[one]).await;

    assert!(failures.is_empty(), "{failures:?}");
    assert_eq!(
        evaluate::<String>(&runtime, "return globalThis.seen;").await.unwrap(),
        "false true false"
    );
}

#[tokio::test]
async fn a_service_passes_to_a_later_plugin_and_a_failed_provider_fails_its_users_unrun() {
    let folder = folder("a_service_passes_to_a_later_plugin_and_a_failed_provider_fails_its_users_unrun");
    let (runtime, _reports) = start(&folder).await;
    let notes = plugin(
        &folder,
        "notes",
        Some("export default function apply(ctx) { ctx.provide('notes', { count: 3 }); }"),
        &[],
        &["notes"],
    );
    let reader = plugin(
        &folder,
        "reader",
        Some("export default function apply(ctx) { globalThis.count = ctx.get('notes').count; }"),
        &["notes"],
        &[],
    );
    let broken = plugin(
        &folder,
        "broken",
        Some("export default function apply() { throw new Error('no store'); }"),
        &[],
        &["store"],
    );
    let middle = plugin(
        &folder,
        "middle",
        Some("export default function apply(ctx) { globalThis.ran = true; ctx.provide('index', {}); }"),
        &["store"],
        &["index"],
    );
    let last = plugin(
        &folder,
        "last",
        Some("export default function apply() { globalThis.ran = true; }"),
        &["index"],
        &[],
    );

    let failures = runtime.load_plugins(&[notes, reader, broken, middle, last]).await;

    assert_eq!(evaluate::<i32>(&runtime, "return globalThis.count;").await.unwrap(), 3);
    assert_eq!(
        evaluate::<Option<bool>>(&runtime, "return globalThis.ran;")
            .await
            .unwrap(),
        None
    );
    assert_eq!(
        texts(&failures),
        [
            (
                "broken".to_owned(),
                "plugin broken did not load: Error: no store".to_owned()
            ),
            (
                "middle".to_owned(),
                "plugin middle did not load: it uses 'store', and plugin broken that provides it did not load"
                    .to_owned()
            ),
            (
                "last".to_owned(),
                "plugin last did not load: it uses 'index', and plugin middle that provides it did not load".to_owned()
            ),
        ]
    );
    assert!(matches!(failures[1].reason, PluginError::Provider { .. }));
}

#[tokio::test]
async fn the_context_refuses_undeclared_services_and_apply_must_provide_each_declared_one() {
    let folder = folder("the_context_refuses_undeclared_services_and_apply_must_provide_each_declared_one");
    let (runtime, _reports) = start(&folder).await;
    let cases = [
        plugin(
            &folder,
            "silent",
            Some("export default function apply() {}"),
            &[],
            &["a"],
        ),
        plugin(
            &folder,
            "reach",
            Some("export default function apply(ctx) { ctx.get('z'); }"),
            &[],
            &[],
        ),
        plugin(
            &folder,
            "other",
            Some("export default function apply(ctx) { ctx.provide('c', 1); }"),
            &[],
            &["b"],
        ),
        plugin(
            &folder,
            "value",
            Some("export default function apply() { return 5; }"),
            &[],
            &[],
        ),
        plugin(&folder, "plain", Some("export const apply = () => {};"), &[], &[]),
    ];

    let failures = runtime.load_plugins(&cases).await;

    let entry = |name: &str| {
        cases
            .iter()
            .find(|plugin| plugin.name == name)
            .unwrap()
            .entry
            .clone()
            .unwrap()
    };
    assert_eq!(
        texts(&failures),
        [
            (
                "silent".to_owned(),
                "plugin silent did not load: TypeError: apply did not provide a of provides".to_owned()
            ),
            (
                "reach".to_owned(),
                "plugin reach did not load: TypeError: get: plugin reach has no 'z' in uses".to_owned()
            ),
            (
                "other".to_owned(),
                "plugin other did not load: TypeError: provide: plugin other has no 'c' in provides".to_owned()
            ),
            (
                "value".to_owned(),
                "plugin value did not load: TypeError: apply must return nothing or a promise of nothing".to_owned()
            ),
            (
                "plain".to_owned(),
                format!(
                    "plugin plain did not load: TypeError: {} has no default export function: a plugin entry exports apply(ctx) as default",
                    entry("plain").display()
                )
            ),
        ]
    );
}

#[tokio::test]
async fn a_plugin_needs_no_code_and_yuke_tools_gives_no_free_define() {
    let folder = folder("a_plugin_needs_no_code_and_yuke_tools_gives_no_free_define");
    let (runtime, _reports) = start(&folder).await;
    write(
        &folder,
        &[(
            "late.ts",
            &format!("import {{ define }} from 'yuke:tools';\ndefine({});\n", tool("late")),
        )],
    );

    let failures = runtime.load_plugins(&[plugin(&folder, "empty", None, &[], &[])]).await;
    let error = script_error(runtime.import(&module(&folder, "late.ts")).await);

    assert!(failures.is_empty(), "{failures:?}");
    assert_eq!(error.name.as_deref(), Some("SyntaxError"));
    assert!(error.message.contains("'define'"), "{}", error.message);
}

#[tokio::test]
async fn notify_sends_a_notice_of_the_plugin_and_refuses_an_unknown_level() {
    let folder = folder("notify_sends_a_notice_of_the_plugin_and_refuses_an_unknown_level");
    let (runtime, mut reports) = start(&folder).await;
    let loud = plugin(
        &folder,
        "loud",
        Some(
            "export default function apply(ctx) {
               ctx.notify('warn', 'careful');
               try { ctx.notify('loud', 'x'); } catch (error) { globalThis.refused = error.message; }
             }",
        ),
        &[],
        &[],
    );

    let failures = runtime.load_plugins(&[loud]).await;
    let report = tokio::time::timeout(Duration::from_secs(5), reports.recv())
        .await
        .unwrap()
        .unwrap();

    assert!(failures.is_empty(), "{failures:?}");
    assert_eq!(
        report,
        Report::Notice(NoticeParams {
            session_id: None,
            level: NoticeLevel::Warn,
            source: "loud".to_owned(),
            message: "careful".to_owned(),
        })
    );
    assert_eq!(
        evaluate::<String>(&runtime, "return globalThis.refused;")
            .await
            .unwrap(),
        "notify: 'loud' is not debug, info, warn, or error"
    );
}
