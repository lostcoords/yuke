//! The plugin loader: the context of `apply`, the exports, the services, and the failures.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use super::tools::{TestHost, Tools};
use super::{descriptor, evaluate, folder, start, write};
use crate::{Origin, Plugin, PluginFailure, Runtime};

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
