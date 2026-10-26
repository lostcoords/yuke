//! The plugin loader: the context of `apply`, the exports, the services, and the failures.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use yuke_protocol::{NoticeLevel, NoticeParams};

use super::tools::{TestHost, Tools};
use super::{descriptor, evaluate, folder, module, script_error, start, write};
use crate::{Origin, Plugin, PluginFailure, Report, Runtime};

/// A plugin `name` in `folder` whose entry is `source`, or a plugin without code when `source` is `None`.
pub(super) fn plugin(folder: &Path, name: &str, source: Option<&str>, uses: &[&str], provides: &[&str]) -> Plugin {
    let root = folder.join(name);
    std::fs::create_dir_all(&root).unwrap();
    let data_dir = folder.join("data").join(name);
    std::fs::create_dir_all(&data_dir).unwrap();
    let entry = source.map(|source| {
        write(&root, &[("index.ts", source)]);
        root.join("index.ts")
    });
    descriptor(name, root, data_dir, entry, uses, provides)
}

/// A tool definition with `name` for a plugin entry.
pub(super) fn tool(name: &str) -> String {
    format!(
        "{{ name: '{name}', description: 'd', concurrency: 'serial', parameters: {{ type: 'object', properties: {{}} }}, execute: () => 'x' }}"
    )
}

/// The names of the tools of a new session of `runtime`, in their order.
async fn tool_names(runtime: &Runtime, folder: &Path) -> Vec<String> {
    let tools = Tools::open(runtime, Arc::new(TestHost::new(folder))).await;
    tools.names().into_iter().map(str::to_owned).collect()
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
async fn apply_runs_once_with_its_context_and_session_runs_for_each_session() {
    let folder = folder("apply_runs_once_with_its_context_and_session_runs_for_each_session");
    let (runtime, _reports) = start(&folder).await;
    let one = plugin(
        &folder,
        "one",
        Some(&format!(
            "globalThis.applied = 0;
             globalThis.sessions = [];
             export function apply(ctx) {{
               globalThis.applied += 1;
               globalThis.seen = [ctx.name, ctx.root, ctx.dataDir, ctx.signal.aborted, 'tools' in ctx];
             }}
             export function session(s) {{
               globalThis.sessions.push(s.folder);
               s.tools.define({});
             }}",
            tool("hello")
        )),
        &[],
        &[],
    );

    let failures = runtime.load_plugins(std::slice::from_ref(&one)).await;
    let first = tool_names(&runtime, &folder.join("a")).await;
    let second = tool_names(&runtime, &folder.join("b")).await;

    assert!(failures.is_empty(), "{failures:?}");
    assert_eq!(first, ["hello"]);
    assert_eq!(second, ["hello"]);
    let seen = evaluate::<Vec<String>>(&runtime, "return globalThis.seen.map(String);")
        .await
        .unwrap();
    assert_eq!(
        seen,
        [
            "one".to_owned(),
            folder.join("one").to_string_lossy().into_owned(),
            one.data_dir.to_string_lossy().into_owned(),
            "false".to_owned(),
            "false".to_owned(),
        ]
    );
    assert_eq!(
        evaluate::<i32>(&runtime, "return globalThis.applied;").await.unwrap(),
        1
    );
    assert_eq!(
        evaluate::<Vec<String>>(&runtime, "return globalThis.sessions;")
            .await
            .unwrap(),
        [
            folder.join("a").to_string_lossy().into_owned(),
            folder.join("b").to_string_lossy().into_owned()
        ]
    );
}

#[tokio::test]
async fn a_failed_apply_aborts_its_signal_and_its_session_never_runs() {
    let folder = folder("a_failed_apply_aborts_its_signal_and_its_session_never_runs");
    let (runtime, _reports) = start(&folder).await;
    let bad = plugin(
        &folder,
        "bad",
        Some(&format!(
            "export async function apply(ctx) {{
               globalThis.badSignal = ctx.signal;
               await null;
               throw new Error('broken');
             }}
             export function session(s) {{ s.tools.define({}); }}",
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
async fn the_close_aborts_each_signal_then_awaits_each_cleanup_newest_first_once() {
    let folder = folder("the_close_aborts_each_signal_then_awaits_each_cleanup_newest_first_once");
    let (runtime, mut reports) = start(&folder).await;
    let one = plugin(
        &folder,
        "one",
        Some(
            "globalThis.events = []; globalThis.signals = [];
             export function apply(ctx) {
               globalThis.signals.push(ctx.signal);
               return async () => {
                 await new Promise((resolve) => setTimeout(resolve, 10));
                 globalThis.events.push('one');
               };
             }",
        ),
        &[],
        &[],
    );
    let two = plugin(
        &folder,
        "two",
        Some(
            "export async function apply(ctx) {
               globalThis.signals.push(ctx.signal);
               return () => { globalThis.events.push(`two ${globalThis.signals.map((signal) => signal.aborted)}`); };
             }",
        ),
        &[],
        &[],
    );
    let three = plugin(
        &folder,
        "three",
        Some(
            "export function apply(ctx) {
               globalThis.signals.push(ctx.signal);
               return () => { globalThis.events.push('three'); throw Object.create(null); };
             }",
        ),
        &[],
        &[],
    );
    assert!(runtime.load_plugins(&[one, two, three]).await.is_empty());

    runtime.close_plugins().await.unwrap();
    runtime.close_plugins().await.unwrap();

    assert_eq!(
        evaluate::<String>(&runtime, "return globalThis.events.join(' | ');")
            .await
            .unwrap(),
        "three | two true,true,true | one"
    );
    let report = tokio::time::timeout(Duration::from_secs(5), reports.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        report,
        Report::Notice(NoticeParams {
            session_id: None,
            level: NoticeLevel::Error,
            source: "three".to_owned(),
            message: "the cleanup of the plugin failed: a value without a text form".to_owned(),
        })
    );
}

#[tokio::test]
async fn a_plugin_that_fails_after_its_apply_returned_runs_its_cleanup_once() {
    let folder = folder("a_plugin_that_fails_after_its_apply_returned_runs_its_cleanup_once");
    let (runtime, _reports) = start(&folder).await;
    let silent = plugin(
        &folder,
        "silent",
        Some(
            "globalThis.cleanups = [];
             export function apply(ctx) { return () => { globalThis.cleanups.push(ctx.signal.aborted); }; }",
        ),
        &[],
        &["a"],
    );

    let failures = runtime.load_plugins(&[silent]).await;
    runtime.close_plugins().await.unwrap();

    assert_eq!(
        texts(&failures),
        [(
            "silent".to_owned(),
            "plugin silent did not load: TypeError: apply did not provide a of provides".to_owned()
        )]
    );
    assert_eq!(
        evaluate::<String>(&runtime, "return globalThis.cleanups.join(' ');")
            .await
            .unwrap(),
        "true"
    );
}

#[tokio::test]
async fn a_load_during_or_after_the_close_fails_and_runs_its_cleanup() {
    let folder = folder("a_load_during_or_after_the_close_fails_and_runs_its_cleanup");
    let (runtime, _reports) = start(&folder).await;
    let slow = plugin(
        &folder,
        "slow",
        Some(
            "globalThis.cleanups = [];
             export async function apply(ctx) {
               await new Promise((resolve) => setTimeout(resolve, 50));
               return () => { globalThis.cleanups.push(`slow ${ctx.signal.aborted}`); };
             }",
        ),
        &[],
        &[],
    );
    let late = plugin(&folder, "late", Some("export function apply() {}"), &[], &[]);

    let slow = [slow];
    let (during, ()) = tokio::join!(runtime.load_plugins(&slow), async {
        tokio::time::sleep(Duration::from_millis(10)).await;
        runtime.close_plugins().await.unwrap();
    });
    let after = runtime.load_plugins(&[late]).await;

    assert_eq!(
        texts(&during),
        [(
            "slow".to_owned(),
            "plugin slow did not load: TypeError: plugin slow loads after the close of the plugins".to_owned()
        )]
    );
    assert_eq!(
        texts(&after),
        [(
            "late".to_owned(),
            "plugin late did not load: TypeError: plugin late loads after the close of the plugins".to_owned()
        )]
    );
    assert_eq!(
        evaluate::<String>(&runtime, "return globalThis.cleanups.join(' ');")
            .await
            .unwrap(),
        "slow true"
    );
}

#[tokio::test]
async fn a_failed_apply_that_replaces_the_web_globals_still_aborts_its_signal() {
    let folder = folder("a_failed_apply_that_replaces_the_web_globals_still_aborts_its_signal");
    let (runtime, _reports) = start(&folder).await;
    let bad = plugin(
        &folder,
        "bad",
        Some(
            "export function apply(ctx) {
               globalThis.badSignal = ctx.signal;
               globalThis.DOMException = undefined;
               globalThis.AbortController = undefined;
               throw new Error('broken');
             }",
        ),
        &[],
        &[],
    );

    let failures = runtime.load_plugins(&[bad]).await;

    assert_eq!(
        texts(&failures),
        [("bad".to_owned(), "plugin bad did not load: Error: broken".to_owned())]
    );
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
            "export function apply(ctx) {
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
            "export function apply(ctx) {
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
        Some("export function apply(ctx) { ctx.provide('notes', { count: 3 }); }"),
        &[],
        &["notes"],
    );
    let reader = plugin(
        &folder,
        "reader",
        Some("export function apply(ctx) { globalThis.count = ctx.get('notes').count; }"),
        &["notes"],
        &[],
    );
    let broken = plugin(
        &folder,
        "broken",
        Some("export function apply() { throw new Error('no store'); }"),
        &[],
        &["store"],
    );
    let middle = plugin(
        &folder,
        "middle",
        Some("export function apply(ctx) { globalThis.ran = true; ctx.provide('index', {}); }"),
        &["store"],
        &["index"],
    );
    let last = plugin(
        &folder,
        "last",
        Some("export function apply() { globalThis.ran = true; }"),
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
}

#[tokio::test]
async fn the_context_refuses_undeclared_services_and_apply_must_provide_each_declared_one() {
    let folder = folder("the_context_refuses_undeclared_services_and_apply_must_provide_each_declared_one");
    let (runtime, _reports) = start(&folder).await;
    let cases = [
        plugin(&folder, "silent", Some("export function apply() {}"), &[], &["a"]),
        plugin(
            &folder,
            "reach",
            Some("export function apply(ctx) { ctx.get('z'); }"),
            &[],
            &[],
        ),
        plugin(
            &folder,
            "other",
            Some("export function apply(ctx) { ctx.provide('c', 1); }"),
            &[],
            &["b"],
        ),
        plugin(
            &folder,
            "value",
            Some("export function apply() { return 5; }"),
            &[],
            &[],
        ),
        plugin(&folder, "neither", Some("export default function apply() {}"), &[], &[]),
        plugin(&folder, "number", Some("export const session = 5;"), &[], &[]),
    ];

    let failures = runtime.load_plugins(&cases).await;

    let entry = |name: &str| match &cases.iter().find(|plugin| plugin.name == name).unwrap().origin {
        Origin::Folder { entry: Some(entry), .. } => entry.clone(),
        other => panic!("{other:?}"),
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
                "plugin value did not load: TypeError: apply must return nothing or a cleanup function".to_owned()
            ),
            (
                "neither".to_owned(),
                format!(
                    "plugin neither did not load: TypeError: {} exports neither apply nor session: a plugin entry exports one or both",
                    entry("neither").display()
                )
            ),
            (
                "number".to_owned(),
                "plugin number did not load: TypeError: the session export is no function".to_owned()
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
            "export function apply(ctx) {
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

#[tokio::test]
async fn a_bundled_plugin_runs_from_its_module_and_its_context_has_no_root() {
    let folder = folder("a_bundled_plugin_runs_from_its_module_and_its_context_has_no_root");
    let (runtime, _reports) = start(&folder).await;
    write(
        &folder,
        &[(
            "bundled.ts",
            &format!(
                "export function apply(ctx) {{ globalThis.seen = [ctx.name, String('root' in ctx), ctx.dataDir]; }}
                 export function session(s) {{ s.tools.define({}); }}",
                tool("bundled_tool")
            ),
        )],
    );
    let data_dir = folder.join("data");
    std::fs::create_dir_all(&data_dir).unwrap();
    let bundled = Plugin {
        name: "bundled".to_owned(),
        // This test names a file. A bundled plugin of the app names a baked `yuke:` module.
        origin: Origin::Bundled {
            module: folder.join("bundled.ts").to_str().unwrap().to_owned(),
        },
        data_dir: data_dir.clone(),
        options: serde_json::Map::new(),
        uses: Vec::new(),
        provides: Vec::new(),
    };

    let failures = runtime.load_plugins(&[bundled]).await;
    let tools = tool_names(&runtime, &folder).await;

    assert!(failures.is_empty(), "{failures:?}");
    assert_eq!(tools, ["bundled_tool"]);
    assert_eq!(
        evaluate::<Vec<String>>(&runtime, "return globalThis.seen;")
            .await
            .unwrap(),
        [
            "bundled".to_owned(),
            "false".to_owned(),
            data_dir.to_string_lossy().into_owned()
        ]
    );
}

/// `plugin` with `options`, a JSON object.
fn with_options(plugin: Plugin, options: serde_json::Value) -> Plugin {
    let serde_json::Value::Object(options) = options else {
        panic!("the options are not a JSON object: {options}");
    };
    Plugin { options, ..plugin }
}

/// The options schema of the test plugins: one required string and two optional fields.
const NOTES_SCHEMA: &str = "export const optionsSchema = {
       type: 'object',
       properties: {
         folder: { type: 'string' },
         depth: { type: 'integer', minimum: 1 },
         tags: { type: 'array', items: { type: 'string' } },
       },
       required: ['folder'],
     };";

#[tokio::test]
async fn the_checked_options_reach_apply_and_each_session_as_one_frozen_object() {
    let folder = folder("the_checked_options_reach_apply_and_each_session_as_one_frozen_object");
    let (runtime, _reports) = start(&folder).await;
    let notes = plugin(
        &folder,
        "notes",
        Some(&format!(
            "{NOTES_SCHEMA}
             export function apply(ctx) {{ globalThis.applied = ctx.options; }}
             export function session(s) {{ globalThis.sessions = [...(globalThis.sessions ?? []), s.options]; }}"
        )),
        &[],
        &[],
    );
    let notes = with_options(
        notes,
        serde_json::json!({ "folder": "~/notes", "depth": null, "tags": ["a"] }),
    );
    let plain = plugin(
        &folder,
        "plain",
        Some("export function session(s) { globalThis.plain = s.options; }"),
        &[],
        &[],
    );

    let failures = runtime.load_plugins(&[notes, plain]).await;
    tool_names(&runtime, &folder.join("a")).await;
    tool_names(&runtime, &folder.join("b")).await;

    assert!(failures.is_empty(), "{failures:?}");
    let seen = evaluate::<Vec<String>>(
        &runtime,
        "const { applied, sessions, plain } = globalThis;
         return [
           JSON.stringify(applied),
           String(sessions.length === 2 && sessions.every((options) => options === applied)),
           String(Object.isFrozen(applied) && Object.isFrozen(applied.tags)),
           JSON.stringify(plain),
           String(Object.isFrozen(plain)),
         ];",
    )
    .await
    .unwrap();
    assert_eq!(
        seen,
        [r#"{"folder":"~/notes","tags":["a"]}"#, "true", "true", "{}", "true"]
    );
}

#[tokio::test]
async fn options_that_fail_the_check_fail_the_load_of_that_plugin_before_its_apply() {
    let folder = folder("options_that_fail_the_check_fail_the_load_of_that_plugin_before_its_apply");
    let (runtime, _reports) = start(&folder).await;
    let checked = |name: &str| {
        plugin(
            &folder,
            name,
            Some(&format!(
                "{NOTES_SCHEMA}
                 export function apply() {{ globalThis.applied = [...(globalThis.applied ?? []), '{name}']; }}"
            )),
            &[],
            &[],
        )
    };
    let missing = checked("missing");
    let wrong = with_options(checked("wrong"), serde_json::json!({ "folder": "x", "depth": 0 }));
    let extra = with_options(checked("extra"), serde_json::json!({ "folder": "x", "colour": "red" }));
    let unasked = with_options(
        plugin(&folder, "unasked", Some("export function apply() {}"), &[], &[]),
        serde_json::json!({ "a": 1 }),
    );
    let codeless = with_options(
        plugin(&folder, "codeless", None, &[], &[]),
        serde_json::json!({ "a": 1 }),
    );
    let unchecked = plugin(
        &folder,
        "unchecked",
        Some(
            "export const optionsSchema = { type: 'object', properties: { a: { type: 'string', default: 'b' } } };
             export function apply() {}",
        ),
        &[],
        &[],
    );
    let good = with_options(checked("good"), serde_json::json!({ "folder": "x" }));

    let failures = runtime
        .load_plugins(&[missing, wrong, extra, unasked, codeless, unchecked, good])
        .await;

    let failure = |name: &str, text: &str| {
        (
            name.to_owned(),
            format!("plugin {name} did not load: TypeError: {text}"),
        )
    };
    assert_eq!(
        texts(&failures),
        [
            failure("missing", "the options of config.json: Set folder to a string."),
            failure(
                "wrong",
                "the options of config.json: Set depth to an integer of at least 1."
            ),
            failure(
                "extra",
                "the options of config.json: Remove colour. The fields are: folder, depth, tags."
            ),
            failure(
                "unasked",
                "config.json gives options, and the plugin exports no optionsSchema"
            ),
            failure(
                "codeless",
                "config.json gives options, and the plugin exports no optionsSchema"
            ),
            failure(
                "unchecked",
                "optionsSchema.properties.a: yuke does not check the keyword 'default'"
            ),
        ]
    );
    assert_eq!(
        evaluate::<Vec<String>>(&runtime, "return globalThis.applied;")
            .await
            .unwrap(),
        ["good"]
    );
}

#[tokio::test]
async fn get_tui_is_undefined_outside_the_terminal_interface_and_needs_no_uses_entry() {
    let folder = folder("get_tui_is_undefined_outside_the_terminal_interface");
    let (runtime, _reports) = start(&folder).await;
    let one = plugin(
        &folder,
        "one",
        Some("export function apply(ctx) { globalThis.seen = String(ctx.get('tui')); }"),
        &[],
        &[],
    );

    let failures = runtime.load_plugins(&[one]).await;

    assert!(failures.is_empty(), "{failures:?}");
    assert_eq!(
        evaluate::<String>(&runtime, "return globalThis.seen;").await.unwrap(),
        "undefined"
    );
}
