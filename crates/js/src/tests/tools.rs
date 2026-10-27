//! The built-in modules, the tool bridge, and the tools `read`, `write`, `edit`.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use rquickjs::Ctx;
use tokio::sync::mpsc;
use yuke_engine::{CancellationToken, Concurrency, MediaStore, Tool, ToolContent};
use yuke_protocol::{InteractionRequest, InteractionResponse, SessionId};

use super::{evaluate, folder, load_entry, module, next_fault, script_error, start, write};
use crate::tools::forward;
use crate::{Runtime, ScriptSession, ScriptTool, SessionHost, baked};

/// A session host that keeps the bytes of each stored attachment and each input.
#[derive(Debug)]
pub(super) struct TestHost {
    pub(super) session: SessionId,
    /// The folder of the session. A test can change it while a call runs.
    pub(super) folder: Mutex<PathBuf>,
    pub(super) media: Mutex<Vec<Vec<u8>>>,
    /// Each start and end of a job, in order.
    pub(super) changed: Mutex<Vec<yuke_protocol::Job>>,
    /// Holds each input until a notify, when it is set.
    pub(super) end_gate: Option<Arc<tokio::sync::Notify>>,
    /// Each input that the plugins and the jobs gave the session, in order.
    pub(super) inputs: Mutex<Vec<yuke_protocol::Input>>,
    /// The model of the session. A test can change it.
    pub(super) model: Mutex<yuke_protocol::ModelReference>,
}

impl TestHost {
    /// A host for a session in `folder`.
    pub(super) fn new(folder: &Path) -> Self {
        TestHost {
            session: SessionId::generate(),
            folder: Mutex::new(folder.to_owned()),
            media: Mutex::default(),
            changed: Mutex::default(),
            end_gate: None,
            inputs: Mutex::default(),
            model: Mutex::new(yuke_protocol::ModelReference {
                provider: "test".to_owned(),
                model: "test-model".to_owned(),
            }),
        }
    }
}

#[async_trait]
impl MediaStore for TestHost {
    async fn put_media(&self, bytes: Vec<u8>) -> Result<yuke_ai::Blob, String> {
        let blob = yuke_ai::Blob {
            digest: [7; 32],
            len: bytes.len(),
        };
        self.media.lock().unwrap().push(bytes);
        Ok(blob)
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

    fn job_changed(&self, job: yuke_protocol::Job) {
        self.changed.lock().unwrap().push(job);
    }

    async fn accept_input(&self, input: yuke_protocol::Input) {
        if let Some(gate) = &self.end_gate {
            gate.notified().await;
        }
        self.inputs.lock().unwrap().push(input);
    }

    // A question waits for its cancel, as with a client that never answers.
    async fn ask(&self, _source: &str, _request: InteractionRequest, cancel: CancellationToken) -> InteractionResponse {
        cancel.cancelled().await;
        InteractionResponse::Canceled
    }

    fn model(&self, reference: &yuke_protocol::ModelReference) -> Result<yuke_engine::Model, String> {
        // The test catalog knows one other model.
        if (reference.provider.as_str(), reference.model.as_str()) != ("test", "other-model") {
            return Err(format!("no model {}/{}", reference.provider, reference.model));
        }
        Ok(yuke_testing::model_of(yuke_ai::Target {
            model: "other-model".into(),
            ..yuke_testing::target()
        }))
    }

    fn model_reference(&self) -> yuke_protocol::ModelReference {
        self.model.lock().unwrap().clone()
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
        let session = runtime.handle().open_session(host).await.unwrap();
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
                let module = crate::error::caught(&ctx, baked::load(&ctx, name).unwrap())?;
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
