//! The built-in modules, the tool bridge, and the tools `read`, `write`, `edit`.

use std::cell::RefCell;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use rquickjs::Ctx;
use tokio::sync::mpsc;
use yuke_engine::{CancellationToken, Concurrency, Tool, ToolContent};
use yuke_protocol::SessionId;

use super::{evaluate, folder, load_entry, module, next_fault, next_notice, script_error, start, write};
use crate::tools::forward;
use crate::{JobEnded, Runtime, ScriptSession, ScriptTool, SessionHost, baked};

/// A session host that keeps the bytes of each stored attachment and each job end.
#[derive(Debug)]
pub(super) struct TestHost {
    pub(super) session: SessionId,
    /// The folder of the session. A test can change it while a call runs.
    pub(super) folder: Mutex<PathBuf>,
    pub(super) media: Mutex<Vec<Vec<u8>>>,
    pub(super) ended: Mutex<Vec<JobEnded>>,
    /// Each start and end of a job, in order.
    pub(super) changed: Mutex<Vec<yuke_protocol::Job>>,
    /// Holds each job end until a notify, when it is set.
    pub(super) end_gate: Option<Arc<tokio::sync::Notify>>,
}

impl TestHost {
    /// A host for a session in `folder`.
    pub(super) fn new(folder: &Path) -> Self {
        TestHost {
            session: SessionId::generate(),
            folder: Mutex::new(folder.to_owned()),
            media: Mutex::default(),
            ended: Mutex::default(),
            changed: Mutex::default(),
            end_gate: None,
        }
    }
}

#[async_trait]
impl SessionHost for TestHost {
    fn session_id(&self) -> SessionId {
        self.session
    }

    fn folder(&self) -> PathBuf {
        self.folder.lock().unwrap().clone()
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
/// The fixture keeps one session open, with its tools, until the fixture drops.
pub(super) struct Tools {
    pub(super) session: ScriptSession,
    pub(super) list: Vec<(yuke_ai::ToolDefinition, ScriptTool)>,
}

impl Tools {
    /// Open the session of `host` on `runtime`, and wait for its tools.
    pub(super) async fn open(runtime: &Runtime, host: Arc<dyn SessionHost>) -> Tools {
        let session = runtime.open_session(host).await.unwrap();
        let list = tokio::time::timeout(Duration::from_secs(5), session.tools())
            .await
            .unwrap()
            .unwrap();
        Tools { session, list }
    }

    /// The names of the tools, in their order.
    pub(super) fn names(&self) -> Vec<&str> {
        self.list
            .iter()
            .map(|(definition, _)| definition.name.as_str())
            .collect()
    }
}

impl std::ops::Index<&str> for Tools {
    type Output = ScriptTool;

    fn index(&self, name: &str) -> &ScriptTool {
        let found = self.list.iter().find(|(definition, _)| definition.name == name);
        &found.unwrap_or_else(|| panic!("no tool {name}")).1
    }
}

pub(super) async fn tools_of(folder: &Path, modules: &[&str]) -> (Runtime, Arc<TestHost>, Tools) {
    let (runtime, _faults) = start(folder).await;
    tools_in(runtime, Arc::new(TestHost::new(folder)), modules).await
}

pub(super) async fn tools_in(
    runtime: Runtime,
    host: Arc<TestHost>,
    modules: &[&str],
) -> (Runtime, Arc<TestHost>, Tools) {
    for name in modules {
        let loaded = tokio::time::timeout(Duration::from_secs(5), async {
            if name.starts_with("yuke:") {
                runtime.import(name).await
            } else {
                load_entry(&runtime, Path::new(name)).await
            }
        });
        loaded.await.unwrap().unwrap();
    }
    let tools = Tools::open(&runtime, Arc::clone(&host) as Arc<dyn SessionHost>).await;
    (runtime, host, tools)
}

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
        .caller
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
    assert!(loaded.contains(&"yuke:internal/builtins".to_owned()), "{loaded:?}");
}

#[tokio::test]
async fn a_user_module_imports_a_public_built_in_module() {
    let folder = folder("a_user_module_imports_a_public_built_in_module");
    write(
        &folder,
        &[(
            "main.ts",
            "import * as plugins from 'yuke:plugins';\nglobalThis.loaded = typeof plugins;\n",
        )],
    );
    let (runtime, _faults) = start(&folder).await;

    runtime.import(&module(&folder, "main.ts")).await.unwrap();

    assert_eq!(
        evaluate::<String>(&runtime, "return globalThis.loaded;").await.unwrap(),
        "object"
    );
}

#[tokio::test]
async fn a_user_module_cannot_import_an_internal_module() {
    let folder = folder("a_user_module_cannot_import_an_internal_module");
    write(
        &folder,
        &[(
            "main.ts",
            "import { checkParameters } from 'yuke:internal/arguments';\nglobalThis.check = checkParameters;\n",
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
async fn an_unknown_built_in_name_does_not_load() {
    let folder = folder("an_unknown_built_in_name_does_not_load");
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
    runtime.import("yuke:internal/builtins").await.unwrap();
    let host: Arc<dyn SessionHost> = Arc::new(TestHost::new(&folder));

    let tools = Tools::open(&runtime, host).await;

    assert_eq!(tools.names(), ["read", "write", "edit", "exec", "stop"]);
    let (read, read_tool) = &tools.list[0];
    assert!(read.input_schema.contains("\"offset\""), "{}", read.input_schema);
    assert_eq!(read_tool.concurrency(), Concurrency::Parallel);
    assert_eq!(tools.list[1].1.concurrency(), Concurrency::Serial);
}

#[tokio::test]
async fn a_change_of_a_tool_after_its_definition_changes_neither_its_schema_nor_its_execute() {
    let folder = folder("a_change_of_a_tool_after_its_definition_changes_neither_its_schema_nor_its_execute");
    write(
        &folder,
        &[(
            "tools.ts",
            "export function session({ tools: { define } }) {\n\
               const tool = { name: 'fixed', description: 'd', concurrency: 'serial',\n\
                 parameters: { type: 'object', properties: { n: { type: 'integer' } }, required: ['n'] },\n\
                 execute: (args) => `n=${args.n}` };\n\
               define(tool);\n\
               tool.parameters.required = [];\n\
               tool.execute = () => 'changed';\n\
             }\n",
        )],
    );
    let (_runtime, _host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;

    assert_eq!(text_of(&tools["fixed"], r#"{"n": 2}"#).await, "n=2");
    assert!(error_of(&tools["fixed"], "{}").await.starts_with("Set n to "));
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
                "export function session({{ tools: {{ define }} }}) {{\n\
                 define({{ name: 'rare', description: 'd', concurrency: 'serial', deferLoading: true, {empty} }});\n\
                 define({{ name: 'common', description: 'd', concurrency: 'serial', {empty} }});\n\
                 }}\n"
            ),
        )],
    );
    let (runtime, _faults) = start(&folder).await;
    load_entry(&runtime, &folder.join("main.ts")).await.unwrap();
    let host: Arc<dyn SessionHost> = Arc::new(TestHost::new(&folder));

    let tools = Tools::open(&runtime, host).await;

    let deferred: Vec<(&str, bool)> = tools
        .list
        .iter()
        .map(|(definition, _)| (definition.name.as_str(), definition.defer_loading))
        .collect();
    assert_eq!(deferred, [("rare", true), ("common", false)]);
}

#[tokio::test]
async fn a_bad_tool_definition_fails_the_session_with_a_notice_that_names_its_problem() {
    let base = "name: 'bad', description: 'd', execute: () => 'x'";
    let empty = "parameters: { type: 'object', properties: {} }";
    let cases = [
        (
            format!("{base}, {empty}"),
            "the concurrency 'undefined' is not 'serial' or 'parallel'",
        ),
        (
            format!(
                "{base}, concurrency: 'serial', parameters: {{ type: 'object', properties: {{ mode: {{ type: 'string', enum: ['a'] }} }} }}"
            ),
            "parameters.properties.mode: yuke does not check the keyword 'enum'",
        ),
        (
            format!(
                "{base}, concurrency: 'serial', parameters: {{ type: 'object', properties: {{ n: {{ type: 'integer', minimum: null }} }} }}"
            ),
            "parameters.properties.n.minimum is not a finite number",
        ),
        (
            format!("name: 'tool_search', description: 'd', execute: () => 'x', concurrency: 'serial', {empty}"),
            "the engine reserves the tool name \"tool_search\"",
        ),
        (
            format!("{base}, concurrency: 'serial', parameters: {{ type: 'string' }}"),
            "parameters.type is not object",
        ),
        (
            format!("name: 'bad', description: 'd', execute: 'x', concurrency: 'serial', {empty}"),
            "execute is not a function",
        ),
        // The check reads the copy that the model gets, so a `toJSON` cannot hide a keyword from it.
        (
            format!(
                "{base}, concurrency: 'serial', parameters: {{ type: 'object', properties: {{}}, \
                 toJSON: () => ({{ type: 'object', properties: {{ m: {{ type: 'string', enum: ['a'] }} }} }}) }}"
            ),
            "parameters.properties.m: yuke does not check the keyword 'enum'",
        ),
    ];

    for (index, (tool, expected)) in cases.iter().enumerate() {
        let folder = folder(&format!(
            "a_bad_tool_definition_fails_the_session_with_a_notice_that_names_its_problem/{index}"
        ));
        let source = format!("export function session({{ tools: {{ define }} }}) {{ define({{ {tool} }}); }}\n");
        write(&folder, &[("main.ts", &source)]);
        let (runtime, mut reports) = start(&folder).await;
        load_entry(&runtime, &folder.join("main.ts")).await.unwrap();

        let tools = Tools::open(&runtime, Arc::new(TestHost::new(&folder))).await;
        let notice = next_notice(&mut reports).await;

        assert!(tools.names().is_empty(), "{tool}");
        let failure = notice
            .message
            .strip_prefix("the session setup failed, and its tools and hooks are gone: TypeError: ")
            .unwrap_or_else(|| panic!("{tool}: {}", notice.message));
        assert!(failure.contains(expected), "{tool}: {failure}");
    }
}

#[tokio::test]
async fn a_shutdown_ends_the_thread_while_a_tool_lives() {
    let folder = folder("a_shutdown_ends_the_thread_while_a_tool_lives");
    let (runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

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
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;
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
async fn an_argument_named_proto_is_an_own_field() {
    let folder = folder("an_argument_named_proto_is_an_own_field");
    write(
        &folder,
        &[(
            "tools.ts",
            "export function session({ tools: { define } }) {\n\
               define({ name: 'proto', description: 'd', concurrency: 'serial',\n\
                 parameters: { type: 'object', properties: { ['__proto__']: { type: 'string' } }, required: ['__proto__'] },\n\
                 execute: (args) => String(Object.hasOwn(args, '__proto__') && args['__proto__']) });\n\
             }\n",
        )],
    );
    let (_runtime, _host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;

    assert_eq!(text_of(&tools["proto"], r#"{"__proto__": "x"}"#).await, "x");
}

#[tokio::test]
async fn a_null_optional_field_counts_as_absent() {
    let folder = folder("a_null_optional_field_counts_as_absent");
    write(&folder, &[("notes.txt", "one\ntwo\n")]);
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

    let text = text_of(
        &tools["read"],
        r#"{"path": "notes.txt", "offset": null, "limit": null}"#,
    )
    .await;

    assert_eq!(text, "1: one\n2: two");
}

/// A module that defines the tools of the bridge tests.
const BRIDGE_TOOLS: &str = "export function session({ tools: { define } }) {\n\
    const empty = { type: 'object', properties: {} } as const;\n\
    define({ name: 'fail', description: 'd', concurrency: 'serial', parameters: empty, execute() { throw new Error('the disk is full'); } });\n\
    define({ name: 'talk', description: 'd', concurrency: 'serial', parameters: empty, execute(_args, context) {\n\
      context.output('one'); context.output('two'); return 'done';\n\
    } });\n\
    define({ name: 'wait', description: 'd', concurrency: 'serial', parameters: empty, execute(_args, context) {\n\
      return new Promise((resolve) => context.signal.addEventListener('abort', () =>\n\
        resolve(`stopped: ${context.signal.reason instanceof DOMException} ${String(context.signal.reason)}`)));\n\
    } });\n\
    define({ name: 'keep', description: 'd', concurrency: 'serial', parameters: empty, execute(_args, context) {\n\
      (globalThis as Record<string, unknown>).kept = context.signal; return context.folder;\n\
    } });\n\
    }\n";

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

    assert_eq!(
        answer.unwrap().text,
        "stopped: true AbortError: The tool call was cancelled"
    );
}

#[tokio::test]
async fn a_cancel_reaches_the_signal_after_a_plugin_replaces_the_web_globals() {
    let folder = folder("a_cancel_reaches_the_signal_after_a_plugin_replaces_the_web_globals");
    write(
        &folder,
        &[(
            "tools.ts",
            "export function session({ tools: { define } }) {\n\
             const global = globalThis as Record<string, unknown>;\n\
             const signals = AbortController.prototype as unknown as Record<string, unknown>;\n\
             signals.abort = () => {};\n\
             global.AbortController = undefined; global.AbortSignal = undefined; global.Event = undefined;\n\
             global.DOMException = undefined;\n\
             define({ name: 'wait', description: 'd', concurrency: 'serial', parameters: { type: 'object', properties: {} },\n\
               execute(_args, context) {\n\
                 return new Promise((resolve) => context.signal.addEventListener('abort', () =>\n\
                   resolve(`stopped ${'abort' in context.signal} ${(context.signal.reason as Error).name}`)));\n\
               } });\n\
             }\n",
        )],
    );
    let (_runtime, _host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;
    let token = CancellationToken::new();
    let cancel = token.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        cancel.cancel();
    });

    let (answer, _texts) = call_with(&tools["wait"], "{}", token).await;

    assert_eq!(answer.unwrap().text, "stopped false AbortError");
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
            "export function session({ tools: { define } }) {\n\
             define({ name: 'listen', description: 'd', concurrency: 'serial', parameters: { type: 'object', properties: {} },\n\
               execute(_args, context) {\n\
                 context.signal.addEventListener('abort', () => { throw new Error('the listener broke'); });\n\
                 context.signal.addEventListener('abort', () => { (globalThis as Record<string, unknown>).second = true; });\n\
                 return 'x';\n\
               } });\n\
             }\n",
        )],
    );
    let (runtime, mut faults) = start(&folder).await;
    load_entry(&runtime, &folder.join("tools.ts")).await.unwrap();
    let host: Arc<dyn SessionHost> = Arc::new(TestHost::new(&folder));
    let tools = Tools::open(&runtime, host).await;

    let text = call(&tools.list[0].1, "{}").await.0.unwrap().text;

    assert_eq!(text, "x");
    assert_eq!(next_fault(&mut faults).await.message, "the listener broke");
    assert!(evaluate::<bool>(&runtime, "return globalThis.second;").await.unwrap());
}

#[tokio::test]
async fn read_numbers_the_lines_and_names_the_next_offset() {
    let folder = folder("read_numbers_the_lines_and_names_the_next_offset");
    write(&folder, &[("notes.txt", "alpha\nbeta\ngamma\ndelta\n")]);
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

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
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

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
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

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
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

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
    let (_runtime, host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

    let content = call(&tools["read"], r#"{"path": "dot.png"}"#).await.0.unwrap();

    assert_eq!(content.text, "Image read successfully");
    assert_eq!(content.media.len(), 1);
    assert_eq!(content.media[0].mime, "image/png");
    assert_eq!(content.media[0].blob.len, png.len());
    assert_eq!(*host.media.lock().unwrap(), [png]);
}

/// A tool that answers the media files that its arguments name.
const ATTACH_TOOL: &str = "export function session({ tools: { define } }) {\n\
    const files = { type: 'object', properties: { paths: { type: 'array', items: { type: 'string' } } } } as const;\n\
    define({ name: 'attach', description: 'd', concurrency: 'serial', parameters: files, execute(args) {\n\
      return { text: 'attached', media: (args.paths ?? []).map((path) => ({ path, mimeType: 'image/png' })) };\n\
    } });\n\
    }\n";

// A provider refuses a large image in each later request, so the session must never store one.
#[tokio::test]
async fn media_over_the_limit_fails_the_call_and_stores_no_file_of_it() {
    let folder = folder("media_over_the_limit_fails_the_call_and_stores_no_file_of_it");
    write(&folder, &[("tools.ts", ATTACH_TOOL)]);
    let limit = 5 * 1024 * 1024 / 4 * 3;
    let mut png = vec![0; limit];
    std::fs::write(folder.join("fits.png"), &png).unwrap();
    png.push(0);
    std::fs::write(folder.join("large.png"), &png).unwrap();
    let (_runtime, host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;

    let large = error_of(&tools["attach"], r#"{"paths": ["fits.png", "large.png"]}"#).await;
    let stored_after_large = host.media.lock().unwrap().len();
    let fits = call(&tools["attach"], r#"{"paths": ["fits.png"]}"#).await.0;

    assert_eq!(
        large,
        format!("large.png: the media is larger than the limit of {limit} bytes")
    );
    assert_eq!(stored_after_large, 0);
    assert_eq!(fits.unwrap().media[0].blob.len, limit);
}

#[tokio::test]
async fn write_makes_the_missing_folders_in_the_workspace() {
    let folder = folder("write_makes_the_missing_folders_in_the_workspace");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

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
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

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
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;
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
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

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

#[tokio::test]
async fn edit_of_a_missing_file_names_its_path() {
    let folder = folder("edit_of_a_missing_file_names_its_path");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

    let error = error_of(
        &tools["edit"],
        r#"{"path": "gone.txt", "old_string": "a", "new_string": "b"}"#,
    )
    .await;

    assert_eq!(error, format!("the path does not exist: {}/gone.txt", folder.display()));
}

/// A module that defines the tools of the result tests.
const RESULT_TOOLS: &str = "export function session({ tools: { define } }) {\n\
    const empty = { type: 'object', properties: {} } as const;\n\
    const define0 = (name, execute) => define({ name, description: 'd', concurrency: 'serial', parameters: empty, execute });\n\
    define0('facts', (_args, context) => JSON.stringify([context.sessionId, context.callId, context.folder]));\n\
    define0('failed', () => ({ text: 'the render failed', media: [{ path: 'dot.png', mimeType: 'image/png' }], isError: true }));\n\
    define0('drawn', (_args, context) => {\n\
      const view = new Uint8Array([9, 1, 2, 9]).subarray(1, 3);\n\
      context.signal.addEventListener('abort', () => view.fill(7));\n\
      return { text: 'drawn', media: [{ bytes: view, mimeType: 'image/png' }] };\n\
    });\n\
    define0('own', (_args, context) => {\n\
      class Own extends Uint8Array { slice() { return this; } }\n\
      const bytes = new Own([1, 2]);\n\
      context.signal.addEventListener('abort', () => bytes.fill(7));\n\
      return { text: 'own', media: [{ bytes, mimeType: 'image/png' }] };\n\
    });\n\
    define0('large', () => ({ text: 'large', media: [{ bytes: new Uint8Array(5 * 1024 * 1024 / 4 * 3 + 1), mimeType: 'image/png' }] }));\n\
    const shapes = [5, { output: 'x' }, { text: 1 }, { text: 'x', isError: 'yes' }, { text: 'x', media: {} },\n\
      { text: 'x', media: [{ mimeType: 'image/png' }] },\n\
      { text: 'x', media: [{ mimeType: 'image/png', path: 'a', bytes: new Uint8Array(1) }] },\n\
      { text: 'x', media: [{ mimeType: 'image/png', bytes: [1] }] }, { text: 'x', media: [{ mimeType: 'image/png', path: 5 }] },\n\
      { text: 'x', media: [{ mimeType: 5, path: 'a' }] }, Object.defineProperty({ text: 'x' }, 'hidden', { value: 1 }),\n\
      { text: 'x', [Symbol('tag')]: 1 }, Object.create({ text: 'x' }), { text: 'x', media: null },\n\
      { text: 'x', media: [{ mimeType: 'image/png', path: 'a', bytes: undefined }] },\n\
      { text: 'x', media: [, { mimeType: 'image/png', path: 'a' }] }];\n\
    define({ name: 'shape', description: 'd', concurrency: 'serial',\n\
      parameters: { type: 'object', properties: { index: { type: 'integer' } }, required: ['index'] },\n\
      execute: (args) => shapes[args.index] });\n\
    }\n";

#[tokio::test]
async fn a_call_gets_the_id_of_its_session_its_call_id_and_its_folder() {
    let folder = folder("a_call_gets_the_id_of_its_session_its_call_id_and_its_folder");
    write(&folder, &[("tools.ts", RESULT_TOOLS)]);
    let (runtime, host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;
    let other = Arc::new(TestHost::new(&folder.join("other")));
    let other_tools = Tools::open(&runtime, Arc::clone(&other) as Arc<dyn SessionHost>).await;

    let content = call(&tools["facts"], "{}").await.0.unwrap();
    let other_text = text_of(&other_tools["facts"], "{}").await;

    assert!(!content.is_error);
    let text = content.text;

    assert_eq!(text, format!(r#"["{}","call-1","{}"]"#, host.session, folder.display()));
    assert_eq!(
        other_text,
        format!(r#"["{}","call-1","{}"]"#, other.session, folder.join("other").display())
    );
}

#[tokio::test]
async fn an_error_result_keeps_its_text_and_its_media() {
    let folder = folder("an_error_result_keeps_its_text_and_its_media");
    write(&folder, &[("tools.ts", RESULT_TOOLS), ("dot.png", "png")]);
    let (_runtime, host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;

    let content = call(&tools["failed"], "{}").await.0.unwrap();

    assert!(content.is_error);
    assert_eq!(content.text, "the render failed");
    assert_eq!(content.media.len(), 1);
    assert_eq!(*host.media.lock().unwrap(), [b"png".to_vec()]);
}

#[tokio::test]
async fn media_bytes_reach_the_store_as_the_view_held_them_at_the_return() {
    let folder = folder("media_bytes_reach_the_store_as_the_view_held_them_at_the_return");
    write(&folder, &[("tools.ts", RESULT_TOOLS)]);
    let (_runtime, host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;

    let content = call(&tools["drawn"], "{}").await.0.unwrap();

    assert!(!content.is_error);
    assert_eq!(content.media[0].mime, "image/png");
    assert_eq!(*host.media.lock().unwrap(), [vec![1, 2]]);
}

#[tokio::test]
async fn media_bytes_of_a_subclass_with_its_own_slice_are_copied_too() {
    let folder = folder("media_bytes_of_a_subclass_with_its_own_slice_are_copied_too");
    write(&folder, &[("tools.ts", RESULT_TOOLS)]);
    let (_runtime, host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;

    let content = call(&tools["own"], "{}").await.0.unwrap();

    assert_eq!(content.media.len(), 1);
    assert_eq!(*host.media.lock().unwrap(), [vec![1, 2]]);
}

#[tokio::test]
async fn media_bytes_over_the_limit_fail_the_call_and_store_nothing() {
    let folder = folder("media_bytes_over_the_limit_fail_the_call_and_store_nothing");
    write(&folder, &[("tools.ts", RESULT_TOOLS)]);
    let (_runtime, host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;

    let error = error_of(&tools["large"], "{}").await;

    assert_eq!(
        error,
        format!(
            "the media is larger than the limit of {} bytes",
            5 * 1024 * 1024 / 4 * 3
        )
    );
    assert!(host.media.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_result_of_another_shape_is_an_error_that_names_the_problem() {
    let folder = folder("a_result_of_another_shape_is_an_error_that_names_the_problem");
    write(&folder, &[("tools.ts", RESULT_TOOLS)]);
    let (_runtime, _host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;

    let mut errors = Vec::new();
    for index in 0..16 {
        errors.push(error_of(&tools["shape"], &format!(r#"{{"index": {index}}}"#)).await);
    }

    assert_eq!(
        errors,
        [
            "the result is not an object",
            "the result has the unknown field 'output'",
            "the result text is not a string",
            "the result isError is not a boolean",
            "the result media is not an array",
            "the result media[0] needs exactly one of path and bytes",
            "the result media[0] needs exactly one of path and bytes",
            "the result media[0].bytes is not a Uint8Array",
            "the result media[0].path is not a string",
            "the result media[0].mimeType is not a string",
            "the result has the unknown field 'hidden'",
            "the result has a symbol key",
            "the result text is not a string",
            "the result media is not an array",
            "the result media[0] needs exactly one of path and bytes",
            "the result media[0] is not an object",
        ]
    );
}

#[tokio::test]
async fn a_media_path_starts_in_the_folder_of_the_start_of_the_call() {
    let folder = folder("a_media_path_starts_in_the_folder_of_the_start_of_the_call");
    write(
        &folder,
        &[
            ("first/dot.png", "first"),
            ("second/dot.png", "second"),
            (
                "tools.ts",
                "export function session({ tools: { define } }) {\n\
                 define({ name: 'later', description: 'd', concurrency: 'serial', parameters: { type: 'object', properties: {} },\n\
                   execute: () => new Promise((resolve) => {\n\
                     globalThis.release = () => resolve({ text: 'x', media: [{ path: 'dot.png', mimeType: 'image/png' }] });\n\
                   }) });\n\
                 }\n",
            ),
        ],
    );
    let (runtime, _faults) = start(&folder).await;
    let host = Arc::new(TestHost::new(&folder.join("first")));
    let (runtime, host, tools) = tools_in(runtime, host, &[&module(&folder, "tools.ts")]).await;

    let release = async {
        while !evaluate::<bool>(&runtime, "return typeof globalThis.release === 'function';")
            .await
            .unwrap()
        {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        *host.folder.lock().unwrap() = folder.join("second");
        evaluate::<()>(&runtime, "globalThis.release();").await.unwrap();
    };
    let ((answer, _texts), ()) = tokio::join!(call(&tools["later"], "{}"), release);

    assert_eq!(answer.unwrap().media.len(), 1);
    assert_eq!(*host.media.lock().unwrap(), [b"first".to_vec()]);
}

#[tokio::test]
async fn a_plugin_that_patches_weak_map_never_gets_the_session_of_a_call() {
    let folder = folder("a_plugin_that_patches_weak_map_never_gets_the_session_of_a_call");
    write(
        &folder,
        &[(
            "tools.ts",
            "export function session({ tools: { define } }) {\n\
             const set = WeakMap.prototype.set;\n\
             WeakMap.prototype.set = function (key, value) {\n\
               if (value !== null && typeof value === 'object' && 'exec' in value) globalThis.leaked = true;\n\
               return set.call(this, key, value);\n\
             };\n\
             define({ name: 'plain', description: 'd', concurrency: 'serial', parameters: { type: 'object', properties: {} },\n\
               execute: () => 'x' });\n\
             }\n",
        )],
    );
    let (runtime, _host, tools) = tools_of(&folder, &[&module(&folder, "tools.ts")]).await;

    let text = text_of(&tools["plain"], "{}").await;

    assert_eq!(text, "x");
    assert!(
        !evaluate::<bool>(&runtime, "return globalThis.leaked === true;")
            .await
            .unwrap()
    );
}
