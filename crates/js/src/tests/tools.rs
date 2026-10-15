//! The built-in modules, the tool bridge, and the tools `read`, `write`, `edit`.

use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use rquickjs::Ctx;
use tokio::sync::mpsc;
use yuke_engine::{CancellationToken, Concurrency, Tool, ToolContent};

use super::{evaluate, folder, module, next_fault, script_error, start, write};
use crate::tools::forward;
use crate::{Fault, JobEnded, Runtime, ScriptTool, SessionHost, baked};

/// A session host that keeps the bytes of each stored attachment and each job end.
#[derive(Debug, Default)]
pub(super) struct TestHost {
    pub(super) folder: PathBuf,
    pub(super) media: Mutex<Vec<Vec<u8>>>,
    pub(super) ended: Mutex<Vec<JobEnded>>,
    /// Each start and end of a job, in order.
    pub(super) changed: Mutex<Vec<yuke_protocol::Job>>,
    /// Holds each job end until a notify, when it is set.
    pub(super) end_gate: Option<Arc<tokio::sync::Notify>>,
}

#[async_trait]
impl SessionHost for TestHost {
    fn folder(&self) -> PathBuf {
        self.folder.clone()
    }

    async fn put_media(&self, bytes: Vec<u8>) -> Result<yuke_ai::Blob, String> {
        let blob = yuke_ai::Blob {
            digest: [7; 32],
            len: bytes.len(),
        };
        self.media.lock().unwrap().push(bytes);
        Ok(blob)
    }

    fn job_changed(&self, job: yuke_protocol::Job) {
        self.changed.lock().unwrap().push(job);
    }

    async fn job_ended(&self, ended: JobEnded) {
        if let Some(gate) = &self.end_gate {
            gate.notified().await;
        }
        self.ended.lock().unwrap().push(ended);
    }
}

/// A runtime with the tools of `modules` (module names), for a session in `folder`.
pub(super) async fn tools_of(folder: &Path, modules: &[&str]) -> (Runtime, Arc<TestHost>, HashMap<String, ScriptTool>) {
    let (runtime, _faults) = start(folder).await;
    tools_in(runtime, folder, modules).await
}

/// The tools of `modules` (module names) in `runtime`, for a session in `folder`.
pub(super) async fn tools_in(
    runtime: Runtime,
    folder: &Path,
    modules: &[&str],
) -> (Runtime, Arc<TestHost>, HashMap<String, ScriptTool>) {
    for name in modules {
        tokio::time::timeout(Duration::from_secs(5), runtime.import(name))
            .await
            .unwrap()
            .unwrap();
    }
    let host = Arc::new(TestHost {
        folder: folder.to_owned(),
        ..TestHost::default()
    });
    let tools = runtime
        .tools(Arc::clone(&host) as Arc<dyn SessionHost>)
        .await
        .unwrap()
        .into_iter()
        .map(|(definition, tool)| (definition.name, tool))
        .collect();
    (runtime, host, tools)
}

/// Call `tool` with `arguments`, and return its answer and its live texts. A call that does not answer fails the test
/// after five seconds.
pub(super) async fn call(tool: &ScriptTool, arguments: &str) -> (Result<ToolContent, String>, Vec<String>) {
    call_with(tool, arguments, CancellationToken::new()).await
}

pub(super) async fn call_with(
    tool: &ScriptTool,
    arguments: &str,
    token: CancellationToken,
) -> (Result<ToolContent, String>, Vec<String>) {
    let (output, texts) = mpsc::unbounded_channel();
    let shown = RefCell::new(Vec::new());
    let answer = tool.answer(arguments, "call-1", token, output);
    let forwarded = forward(answer, texts, |text| shown.borrow_mut().push(text.to_owned()));
    let answer = tokio::time::timeout(Duration::from_secs(5), forwarded).await.unwrap();
    (answer, shown.into_inner())
}

/// The text of a call that succeeds.
pub(super) async fn text_of(tool: &ScriptTool, arguments: &str) -> String {
    call(tool, arguments).await.0.unwrap().text
}

/// The error of a call that fails.
pub(super) async fn error_of(tool: &ScriptTool, arguments: &str) -> String {
    call(tool, arguments).await.0.unwrap_err()
}

#[tokio::test]
async fn every_built_in_module_loads_from_its_bytecode() {
    let folder = folder("every_built_in_module_loads_from_its_bytecode");
    let (runtime, _faults) = start(&folder).await;

    let loaded = runtime
        .run(async |ctx: Ctx<'_>, _registry| {
            let mut loaded = Vec::new();
            for name in baked::names() {
                let module = crate::error::caught(&ctx, baked::load(&ctx, baked::bytecode(name).unwrap()))?;
                let module_name: String = crate::error::caught(&ctx, module.name())?;
                loaded.push(module_name);
            }
            Ok(loaded)
        })
        .await
        .unwrap();

    assert_eq!(loaded, baked::names().collect::<Vec<_>>());
    assert!(loaded.contains(&"yuke:builtins".to_owned()), "{loaded:?}");
}

#[tokio::test]
async fn a_user_module_imports_a_public_built_in_module() {
    let folder = folder("a_user_module_imports_a_public_built_in_module");
    write(
        &folder,
        &[(
            "main.ts",
            "import { define } from 'yuke:tools';\nglobalThis.defineType = typeof define;\n",
        )],
    );
    let (runtime, _faults) = start(&folder).await;

    runtime.import(&module(&folder, "main.ts")).await.unwrap();

    assert_eq!(
        evaluate::<String>(&runtime, "return globalThis.defineType;")
            .await
            .unwrap(),
        "function"
    );
}

#[tokio::test]
async fn a_user_module_cannot_import_an_internal_module() {
    let folder = folder("a_user_module_cannot_import_an_internal_module");
    write(
        &folder,
        &[(
            "main.ts",
            "import { CallSignal } from 'yuke:internal/signal';\nglobalThis.signal = CallSignal;\n",
        )],
    );
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(runtime.import(&module(&folder, "main.ts")).await);

    assert_eq!(error.name.as_deref(), Some("TypeError"));
    assert!(
        error.message.contains("only a built-in module imports"),
        "{}",
        error.message
    );
}

#[tokio::test]
async fn an_unknown_built_in_name_does_not_resolve() {
    let folder = folder("an_unknown_built_in_name_does_not_resolve");
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(runtime.import("yuke:nothing").await);

    assert_eq!(error.name.as_deref(), Some("TypeError"));
    assert!(
        error.message.contains("no built-in module has the name 'yuke:nothing'"),
        "{}",
        error.message
    );
}

#[tokio::test]
async fn a_long_syntax_error_keeps_every_byte_of_its_message() {
    let folder = folder("a_long_syntax_error_keeps_every_byte_of_its_message");
    // The path alone is longer than the 255 bytes of a typed throw of the engine.
    let file = format!("{}broken.ts", "deep/".repeat(80));
    write(&folder, &[(&file, "const broken: = 2;\n")]);
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(runtime.import(&module(&folder, &file)).await);

    assert_eq!(error.name.as_deref(), Some("SyntaxError"));
    assert!(error.message.len() > 400, "{}", error.message.len());
    assert!(
        error.message.contains(&format!("{}:1:", folder.join(&file).display())),
        "{}",
        error.message
    );
}

#[tokio::test]
async fn the_built_in_tools_come_with_their_definitions() {
    let folder = folder("the_built_in_tools_come_with_their_definitions");
    let (runtime, _faults) = start(&folder).await;
    runtime.import("yuke:builtins").await.unwrap();
    let host: Arc<dyn SessionHost> = Arc::new(TestHost {
        folder: folder.clone(),
        ..TestHost::default()
    });

    let tools = runtime.tools(host).await.unwrap();

    let names: Vec<&str> = tools.iter().map(|(definition, _)| definition.name.as_str()).collect();
    assert_eq!(names, ["read", "write", "edit", "exec", "stop"]);
    let (read, read_tool) = &tools[0];
    assert!(read.input_schema.contains("\"offset\""), "{}", read.input_schema);
    assert_eq!(read_tool.concurrency(), Concurrency::Parallel);
    assert_eq!(tools[1].1.concurrency(), Concurrency::Serial);
}

#[tokio::test]
async fn a_deferred_tool_is_defined_for_the_tool_search_and_others_are_not() {
    let folder = folder("a_deferred_tool_is_defined_for_the_tool_search_and_others_are_not");
    let empty = "parameters: { type: 'object', properties: {} }, execute: () => 'x'";
    write(
        &folder,
        &[(
            "main.ts",
            &format!(
                "import {{ define }} from 'yuke:tools';\n\
                 define({{ name: 'rare', description: 'd', concurrency: 'serial', defer: true, {empty} }});\n\
                 define({{ name: 'common', description: 'd', concurrency: 'serial', {empty} }});\n"
            ),
        )],
    );
    let (runtime, _faults) = start(&folder).await;
    runtime.import(&module(&folder, "main.ts")).await.unwrap();
    let host: Arc<dyn SessionHost> = Arc::new(TestHost {
        folder: folder.clone(),
        ..TestHost::default()
    });

    let tools = runtime.tools(host).await.unwrap();

    let deferred: Vec<(&str, bool)> = tools
        .iter()
        .map(|(definition, _)| (definition.name.as_str(), definition.defer_loading))
        .collect();
    assert_eq!(deferred, [("rare", true), ("common", false)]);
}

#[tokio::test]
async fn a_second_tool_with_one_name_throws() {
    let folder = folder("a_second_tool_with_one_name_throws");
    let tool = "{ name: 'twice', description: 'd', concurrency: 'serial', parameters: { type: 'object', properties: {} }, execute: () => 'x' }";
    write(
        &folder,
        &[(
            "main.ts",
            &format!("import {{ define }} from 'yuke:tools';\ndefine({tool});\ndefine({tool});\n"),
        )],
    );
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(runtime.import(&module(&folder, "main.ts")).await);

    assert_eq!(error.name.as_deref(), Some("TypeError"));
    assert!(
        error.message.contains("'twice' is already defined"),
        "{}",
        error.message
    );
}

#[tokio::test]
async fn a_tool_without_a_concurrency_throws_at_its_definition() {
    let folder = folder("a_tool_without_a_concurrency_throws_at_its_definition");
    write(
        &folder,
        &[(
            "main.ts",
            "import { define } from 'yuke:tools';\n\
             define({ name: 'loose', description: 'd', execute: () => 'x',\n\
               parameters: { type: 'object', properties: {} } } as never);\n",
        )],
    );
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(runtime.import(&module(&folder, "main.ts")).await);

    assert_eq!(error.name.as_deref(), Some("TypeError"));
    assert!(
        error
            .message
            .contains("the concurrency 'undefined' is not 'serial' or 'parallel'"),
        "{}",
        error.message
    );
}

#[tokio::test]
async fn a_schema_keyword_without_a_check_throws_at_its_definition() {
    let folder = folder("a_schema_keyword_without_a_check_throws_at_its_definition");
    write(
        &folder,
        &[(
            "main.ts",
            "import { define } from 'yuke:tools';\n\
             define({ name: 'pick', description: 'd', concurrency: 'serial', execute: () => 'x',\n\
               parameters: { type: 'object', properties: { mode: { type: 'string', enum: ['a'] } } } } as never);\n",
        )],
    );
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(runtime.import(&module(&folder, "main.ts")).await);

    assert_eq!(error.name.as_deref(), Some("TypeError"));
    assert!(
        error
            .message
            .contains("parameters.properties.mode: yuke does not check the keyword 'enum'"),
        "{}",
        error.message
    );
}

#[tokio::test]
async fn a_schema_bound_that_is_no_number_throws_at_its_definition() {
    let folder = folder("a_schema_bound_that_is_no_number_throws_at_its_definition");
    write(
        &folder,
        &[(
            "main.ts",
            "import { define } from 'yuke:tools';\n\
             define({ name: 'count', description: 'd', concurrency: 'serial', execute: () => 'x',\n\
               parameters: { type: 'object', properties: { n: { type: 'integer', minimum: null } } } } as never);\n",
        )],
    );
    let (runtime, _faults) = start(&folder).await;

    let error = script_error(runtime.import(&module(&folder, "main.ts")).await);

    assert_eq!(error.name.as_deref(), Some("TypeError"));
    assert!(
        error
            .message
            .contains("parameters.properties.n.minimum is not a finite number"),
        "{}",
        error.message
    );
}

#[tokio::test]
async fn a_shutdown_ends_the_thread_while_a_tool_lives() {
    let folder = folder("a_shutdown_ends_the_thread_while_a_tool_lives");
    let (runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    tokio::time::timeout(Duration::from_secs(5), runtime.shutdown())
        .await
        .unwrap()
        .unwrap();

    assert_eq!(
        error_of(&tools["read"], r#"{"path": "a.txt"}"#).await,
        "the JavaScript thread has ended"
    );
}

#[tokio::test]
async fn arguments_that_do_not_fit_the_schema_fail_before_the_tool_runs() {
    let folder = folder("arguments_that_do_not_fit_the_schema_fail_before_the_tool_runs");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;
    let write_tool = &tools["write"];

    assert_eq!(error_of(write_tool, "[]").await, "Pass the arguments as a JSON object.");
    assert_eq!(
        error_of(write_tool, r#"{"path": "a.txt", "content": "x", "mode": 1}"#).await,
        "Remove mode. The arguments are: path, content."
    );
    assert_eq!(
        error_of(write_tool, r#"{"path": 1, "content": "x"}"#).await,
        "Set path to a string."
    );
    assert_eq!(
        error_of(write_tool, r#"{"path": "a.txt"}"#).await,
        "Set content to a string."
    );
    assert_eq!(
        error_of(write_tool, r#"{"path": "a.txt", "content": "x", "toString": 1}"#).await,
        "Remove toString. The arguments are: path, content."
    );
    assert_eq!(
        error_of(&tools["read"], r#"{"path": "a.txt", "offset": 0}"#).await,
        "Set offset to an integer from 1 to 4294967295."
    );
    assert!(!folder.join("a.txt").exists());
}

#[tokio::test]
async fn a_null_optional_field_counts_as_absent() {
    let folder = folder("a_null_optional_field_counts_as_absent");
    write(&folder, &[("notes.txt", "one\ntwo\n")]);
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let text = text_of(
        &tools["read"],
        r#"{"path": "notes.txt", "offset": null, "limit": null}"#,
    )
    .await;

    assert_eq!(text, "1: one\n2: two");
}

/// A module that defines the tools of the bridge tests.
const BRIDGE_TOOLS: &str = "import { define } from 'yuke:tools';\n\
    const empty = { type: 'object', properties: {} } as const;\n\
    define({ name: 'fail', description: 'd', concurrency: 'serial', parameters: empty, execute() { throw new Error('the disk is full'); } });\n\
    define({ name: 'talk', description: 'd', concurrency: 'serial', parameters: empty, execute(_args, context) {\n\
      context.output('one'); context.output('two'); return 'done';\n\
    } });\n\
    define({ name: 'wait', description: 'd', concurrency: 'serial', parameters: empty, execute(_args, context) {\n\
      return new Promise((resolve) => context.signal.onAbort(() =>\n\
        resolve(`stopped: ${(context.signal.reason as DOMException).name}`)));\n\
    } });\n\
    define({ name: 'keep', description: 'd', concurrency: 'serial', parameters: empty, execute(_args, context) {\n\
      (globalThis as Record<string, unknown>).kept = context.signal; return context.folder;\n\
    } });\n";

#[tokio::test]
async fn a_throw_of_a_tool_is_an_error_with_its_message() {
    let folder = folder("a_throw_of_a_tool_is_an_error_with_its_message");
    write(&folder, &[("tools.ts", BRIDGE_TOOLS)]);
    let (_runtime, _host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;

    assert_eq!(error_of(&tools["fail"], "{}").await, "the disk is full");
}

#[tokio::test]
async fn the_live_texts_of_a_call_arrive_in_order() {
    let folder = folder("the_live_texts_of_a_call_arrive_in_order");
    write(&folder, &[("tools.ts", BRIDGE_TOOLS)]);
    let (_runtime, _host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;

    let (answer, texts) = call(&tools["talk"], "{}").await;

    assert_eq!(answer.unwrap().text, "done");
    assert_eq!(texts, ["one", "two"]);
}

#[tokio::test]
async fn a_cancel_aborts_the_signal_and_the_tool_still_answers() {
    let folder = folder("a_cancel_aborts_the_signal_and_the_tool_still_answers");
    write(&folder, &[("tools.ts", BRIDGE_TOOLS)]);
    let (_runtime, _host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;
    let token = CancellationToken::new();
    let cancel = token.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        cancel.cancel();
    });

    let (answer, _texts) = call_with(&tools["wait"], "{}", token).await;

    assert_eq!(answer.unwrap().text, "stopped: AbortError");
}

#[tokio::test]
async fn the_signal_aborts_when_the_call_ends() {
    let folder = folder("the_signal_aborts_when_the_call_ends");
    write(&folder, &[("tools.ts", BRIDGE_TOOLS)]);
    let (runtime, _host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;

    let text = text_of(&tools["keep"], "{}").await;

    assert_eq!(text, folder.to_str().unwrap());
    let aborted = evaluate::<bool>(&runtime, "return globalThis.kept.aborted;")
        .await
        .unwrap();
    assert!(aborted);
}

#[tokio::test]
async fn a_throw_of_an_abort_listener_is_a_fault_and_the_next_listener_runs() {
    let folder = folder("a_throw_of_an_abort_listener_is_a_fault_and_the_next_listener_runs");
    write(
        &folder,
        &[(
            "tools.ts",
            "import { define } from 'yuke:tools';\n\
             define({ name: 'listen', description: 'd', concurrency: 'serial', parameters: { type: 'object', properties: {} },\n\
               execute(_args, context) {\n\
                 context.signal.onAbort(() => { throw new Error('the listener broke'); });\n\
                 context.signal.onAbort(() => { (globalThis as Record<string, unknown>).second = true; });\n\
                 return 'x';\n\
               } });\n",
        )],
    );
    let (runtime, mut faults) = start(&folder).await;
    runtime.import(&module(&folder, "tools.ts")).await.unwrap();
    let host: Arc<dyn SessionHost> = Arc::new(TestHost {
        folder: folder.clone(),
        ..TestHost::default()
    });
    let tools = runtime.tools(host).await.unwrap();

    let text = call(&tools[0].1, "{}").await.0.unwrap().text;

    assert_eq!(text, "x");
    match next_fault(&mut faults).await {
        Fault::Script(error) => assert_eq!(error.message, "the listener broke"),
        other @ Fault::Interrupted => panic!("expected a script fault, got {other:?}"),
    }
    assert!(evaluate::<bool>(&runtime, "return globalThis.second;").await.unwrap());
}

#[tokio::test]
async fn a_throw_of_a_listener_added_after_the_abort_is_a_fault() {
    let folder = folder("a_throw_of_a_listener_added_after_the_abort_is_a_fault");
    write(
        &folder,
        &[(
            "tools.ts",
            "import { define } from 'yuke:tools';\n\
             define({ name: 'late', description: 'd', concurrency: 'serial',\n\
               parameters: { type: 'object', properties: {} },\n\
               execute(_args, context) {\n\
                 context.signal.abort(new Error('stopped'));\n\
                 context.signal.onAbort(() => { throw new Error('the late listener broke'); });\n\
                 return 'x';\n\
               } });\n",
        )],
    );
    let (runtime, mut faults) = start(&folder).await;
    runtime.import(&module(&folder, "tools.ts")).await.unwrap();
    let host: Arc<dyn SessionHost> = Arc::new(TestHost {
        folder: folder.clone(),
        ..TestHost::default()
    });
    let tools = runtime.tools(host).await.unwrap();

    let text = call(&tools[0].1, "{}").await.0.unwrap().text;

    assert_eq!(text, "x");
    match next_fault(&mut faults).await {
        Fault::Script(error) => assert_eq!(error.message, "the late listener broke"),
        other @ Fault::Interrupted => panic!("expected a script fault, got {other:?}"),
    }
}

#[tokio::test]
async fn read_numbers_the_lines_and_names_the_next_offset() {
    let folder = folder("read_numbers_the_lines_and_names_the_next_offset");
    write(&folder, &[("notes.txt", "alpha\nbeta\ngamma\ndelta\n")]);
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let text = text_of(&tools["read"], r#"{"path": "notes.txt", "offset": 2, "limit": 2}"#).await;

    assert_eq!(text, "2: beta\n3: gamma\n[read more: offset 4.]");
}

#[tokio::test]
async fn read_stops_at_the_output_cap_after_a_whole_line() {
    let folder = folder("read_stops_at_the_output_cap_after_a_whole_line");
    let mut lines = String::new();
    for number in 1..=2000 {
        writeln!(lines, "line {number:>40}").unwrap();
    }
    write(&folder, &[("long.txt", &lines)]);
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let text = text_of(&tools["read"], r#"{"path": "long.txt"}"#).await;

    let (shown, marker) = text.rsplit_once('\n').unwrap();
    assert!(shown.len() < 50 * 1024, "{}", shown.len());
    let last: u32 = shown
        .lines()
        .last()
        .unwrap()
        .split(':')
        .next()
        .unwrap()
        .parse()
        .unwrap();
    assert_eq!(marker, format!("[read more: offset {}.]", last + 1));
    assert!(shown.len() + 60 > 50 * 1024, "{}", shown.len());
}

#[tokio::test]
async fn a_line_longer_than_the_cap_is_cut() {
    let folder = folder("a_line_longer_than_the_cap_is_cut");
    let long = "é".repeat(40 * 1024);
    write(&folder, &[("one.txt", &format!("{long}\nshort\n"))]);
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let text = text_of(&tools["read"], r#"{"path": "one.txt"}"#).await;

    let mut parts = text.rsplitn(3, '\n');
    assert_eq!(parts.next(), Some("[read more: offset 2.]"));
    assert_eq!(parts.next(), Some("[read cut: line 1 at 50 KiB.]"));
    let shown = parts.next().unwrap();
    assert!(shown.starts_with("1: éé"), "{}", &shown[..10]);
    assert!(
        shown.len() <= 50 * 1024 && shown.len() > 50 * 1024 - 4,
        "{}",
        shown.len()
    );
}

#[tokio::test]
async fn read_of_a_missing_file_or_of_bytes_that_are_no_text_fails() {
    let folder = folder("read_of_a_missing_file_or_of_bytes_that_are_no_text_fails");
    std::fs::write(folder.join("binary.dat"), [0x61, 0xff, 0xfe, 0x0a]).unwrap();
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    assert_eq!(
        error_of(&tools["read"], r#"{"path": "gone.txt"}"#).await,
        "the path does not exist"
    );
    assert_eq!(
        error_of(&tools["read"], r#"{"path": "binary.dat"}"#).await,
        "the file holds invalid UTF-8"
    );
}

#[tokio::test]
async fn an_image_read_answers_media_through_the_host() {
    let folder = folder("an_image_read_answers_media_through_the_host");
    let png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
    std::fs::write(folder.join("dot.png"), &png).unwrap();
    let (_runtime, host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let content = call(&tools["read"], r#"{"path": "dot.png"}"#).await.0.unwrap();

    assert_eq!(content.text, "Image read successfully");
    assert_eq!(content.media.len(), 1);
    assert_eq!(content.media[0].mime, "image/png");
    assert_eq!(content.media[0].blob.len, png.len());
    assert_eq!(*host.media.lock().unwrap(), [png]);
}

#[tokio::test]
async fn write_makes_the_missing_folders_in_the_workspace() {
    let folder = folder("write_makes_the_missing_folders_in_the_workspace");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let text = text_of(&tools["write"], r#"{"path": "src/deep/new.txt", "content": "héllo"}"#).await;

    assert_eq!(text, "The tool wrote 6 bytes.");
    assert_eq!(
        std::fs::read_to_string(folder.join("src/deep/new.txt")).unwrap(),
        "héllo"
    );
}

#[tokio::test]
async fn edit_replaces_one_exact_match() {
    let folder = folder("edit_replaces_one_exact_match");
    write(&folder, &[("main.rs", "fn main() {\n    old();\n}\n")]);
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let text = text_of(
        &tools["edit"],
        r#"{"path": "main.rs", "old_string": "old();", "new_string": "new($&);"}"#,
    )
    .await;

    assert_eq!(text, "The tool replaced 1 match(es).");
    assert_eq!(
        std::fs::read_to_string(folder.join("main.rs")).unwrap(),
        "fn main() {\n    new($&);\n}\n"
    );
}

#[tokio::test]
async fn edit_of_two_matches_needs_replace_all() {
    let folder = folder("edit_of_two_matches_needs_replace_all");
    write(&folder, &[("list.txt", "a, b, a\n")]);
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;
    let edit = &tools["edit"];

    let error = error_of(edit, r#"{"path": "list.txt", "old_string": "a", "new_string": "c"}"#).await;
    let unchanged = std::fs::read_to_string(folder.join("list.txt")).unwrap();
    let text = text_of(
        edit,
        r#"{"path": "list.txt", "old_string": "a", "new_string": "c", "replace_all": true}"#,
    )
    .await;

    assert_eq!(
        error,
        "old_string matches more than one place. Add context to old_string, or set replace_all to true."
    );
    assert_eq!(unchanged, "a, b, a\n");
    assert_eq!(text, "The tool replaced 2 match(es).");
    assert_eq!(std::fs::read_to_string(folder.join("list.txt")).unwrap(), "c, b, c\n");
}

#[tokio::test]
async fn edit_without_a_match_fails() {
    let folder = folder("edit_without_a_match_fails");
    write(&folder, &[("list.txt", "a, b\n")]);
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let error = error_of(
        &tools["edit"],
        r#"{"path": "list.txt", "old_string": "z", "new_string": "c"}"#,
    )
    .await;

    assert_eq!(
        error,
        "The file has no match for old_string. Read the file and copy the exact text."
    );
}
