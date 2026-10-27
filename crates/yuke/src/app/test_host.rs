//! The host of `createHost` in `yuke:test`: an app per test with a scripted model, an in-memory store, and no retry
//! waits. The cargo tests of yuke and `yuke test` run each test in one [`TestPlace`].

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use tokio::sync::mpsc;
use yuke_agent::MemoryStore;
use yuke_ai::scripted::{Answer, Call, ScriptedTransport, Sent};
use yuke_ai::{Blob, Protocol};
use yuke_engine::NoWait;
use yuke_js::{Origin, Plugin, Report, Runtime, ScriptError, ScriptSession, TestError, TestHost, TestRuntime};
use yuke_protocol::{ExtensionEventParams, NoticeParams, ServerNotification, SessionId};

use super::sessions::SessionService;
use super::{App, Machine, Mode, Observer, Shared, lock};
use crate::paths::Paths;
use crate::plugins::{check_list, manifest_plugin, valid_name};

/// What the app of a test needs beyond production. It holds the TypeScript cache of the run and the internal imports
/// of the tests of yuke. It also holds the test host of the runtime and the sender of the raw reports to the runner.
pub(crate) struct TestSetup {
    pub(super) cache: PathBuf,
    pub(super) internal_imports: bool,
    /// The folder of the outputs and the logs of the commands, in the place of the test. The end of a test can skip
    /// the shutdown, and the removal of the place of the test then removes the folder.
    pub(super) processes: PathBuf,
    pub(super) host: Arc<AppTestHost>,
    pub(super) reports: mpsc::UnboundedSender<Report>,
}

/// The host of one test: its scripted model, what it recorded, and the app that it reaches after the start.
pub(crate) struct AppTestHost {
    transport: ScriptedTransport,
    /// The app after its start. The runtime gets the host before the app exists, so the host holds weak references.
    app: OnceLock<(Weak<Shared>, Weak<SessionService>)>,
    /// A test creates one host.
    created: AtomicBool,
    /// The test closed its host, so the close checked the model script.
    closed: AtomicBool,
    recorded: Mutex<Recorded>,
    /// The runner of the test: a failed check of the model script reaches it as a fault, so a test that catches the
    /// failure still fails.
    reports: mpsc::UnboundedSender<Report>,
}

#[derive(Default)]
struct Recorded {
    notices: Vec<NoticeParams>,
    events: Vec<ExtensionEventParams>,
}

impl Observer for AppTestHost {
    fn notify(&self, notification: ServerNotification) {
        match notification {
            ServerNotification::Notice(notice) => lock(&self.recorded).notices.push(notice),
            ServerNotification::ExtensionEvent(event) => lock(&self.recorded).events.push(event),
            _ => {}
        }
    }
}

/// The request of `createHost`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CreateRequest {
    plugins: Vec<PluginRequest>,
    replies: Vec<ReplyRequest>,
}

/// One plugin under test: a folder with its manifest, or exports that the test gave.
#[derive(Deserialize)]
#[serde(untagged, deny_unknown_fields)]
enum PluginRequest {
    Folder {
        folder: PathBuf,
        #[serde(default)]
        options: Map<String, Value>,
    },
    Given {
        name: String,
        #[serde(default)]
        options: Map<String, Value>,
        #[serde(default)]
        uses: Vec<String>,
        #[serde(default)]
        provides: Vec<String>,
    },
}

/// One scripted answer of the model.
#[derive(Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum ReplyRequest {
    Text {
        text: String,
        #[serde(default)]
        input_tokens: u64,
    },
    ToolCalls {
        text: String,
        calls: Vec<CallRequest>,
        #[serde(default)]
        input_tokens: u64,
    },
    Cut {
        calls: Vec<CallRequest>,
    },
    Overloaded,
    Overflow,
    Failed {
        text: String,
    },
    Stall {
        text: String,
    },
}

/// One tool call of a scripted answer.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CallRequest {
    name: String,
    args: Value,
}

impl AppTestHost {
    fn new(reports: mpsc::UnboundedSender<Report>) -> Self {
        AppTestHost {
            transport: ScriptedTransport::default(),
            app: OnceLock::new(),
            created: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            recorded: Mutex::default(),
            reports,
        }
    }

    /// Check the model script. A failure also reaches the runner as a fault of the test.
    fn check_script(&self) -> Result<(), TestError> {
        self.transport.check().map_err(|text| {
            let fault = ScriptError {
                name: Some("Error".to_owned()),
                message: format!("the fake model: {text}"),
                stack: None,
            };
            if self.reports.send(Report::Fault(fault)).is_err() {
                // The runner of the test has left.
            }
            format!("the fake model: {text}").into()
        })
    }

    fn app(&self) -> Result<(Arc<Shared>, Arc<SessionService>), TestError> {
        let (shared, sessions) = self.app.get().ok_or("the app of the test has not started")?;
        Ok((
            shared.upgrade().ok_or("the app of the test has stopped")?,
            sessions.upgrade().ok_or("the app of the test has stopped")?,
        ))
    }

    /// Push the replies of `replies` to the scripted model, in order.
    fn script(&self, replies: Vec<ReplyRequest>) {
        let mut next_call = 0;
        let mut calls = |requested: Vec<CallRequest>| -> Vec<Call> {
            requested
                .into_iter()
                .map(|call| {
                    next_call += 1;
                    Call {
                        id: format!("call_{next_call}"),
                        name: call.name,
                        arguments: call.args.to_string(),
                    }
                })
                .collect()
        };
        for reply in replies {
            self.transport.push_answer(match reply {
                ReplyRequest::Text { text, input_tokens } => Answer::Text { text, input_tokens },
                ReplyRequest::ToolCalls {
                    text,
                    calls: requested,
                    input_tokens,
                } => Answer::Calls {
                    text,
                    calls: calls(requested),
                    input_tokens,
                    cut: false,
                },
                ReplyRequest::Cut { calls: requested } => Answer::Calls {
                    text: String::new(),
                    calls: calls(requested),
                    input_tokens: 0,
                    cut: true,
                },
                ReplyRequest::Overloaded => Answer::Overloaded,
                ReplyRequest::Overflow => Answer::Overflow,
                ReplyRequest::Failed { text } => Answer::Failed { text },
                ReplyRequest::Stall { text } => Answer::Stall { text },
            });
        }
    }
}

/// The text of `content`, a text or a list of parts: the text parts and the content of the tool results, one per line.
fn text_of(content: &Value) -> String {
    match content {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts
            .iter()
            // A part with no text and no content, such as a call, adds no line.
            .filter_map(|part| match part.get("text") {
                Some(Value::String(text)) => Some(text.clone()),
                _ => part.get("content").map(text_of),
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

/// The view of one model request for `yuke:test`. It holds the system prompt, the text of each message, the tool
/// names, and the body. The messages keep the order and the roles of the protocol of the request.
fn request_view(sent: &Sent) -> Value {
    let body: Value = serde_json::from_str(&sent.body).unwrap_or(Value::Null);
    let list = |key: &str| body.get(key).and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    let message = |role: Option<&Value>, content: Option<&Value>| json!({ "role": role.cloned().unwrap_or(Value::Null), "text": content.map(text_of).unwrap_or_default() });
    let names = |pointer: &str| -> Vec<Value> {
        list("tools")
            .iter()
            .filter_map(|tool| tool.pointer(pointer).cloned())
            .collect()
    };
    let (system, messages, tools): (String, Vec<Value>, Vec<Value>) = match sent.protocol() {
        Some(Protocol::OpenaiChat) => {
            let (system, rest): (Vec<&Value>, Vec<&Value>) = list("messages")
                .iter()
                .partition(|message| message.get("role").and_then(Value::as_str) == Some("system"));
            let system: Vec<String> = system
                .iter()
                .filter_map(|message| message.get("content"))
                .map(text_of)
                .collect();
            let rest = rest.iter().map(|item| message(item.get("role"), item.get("content")));
            (system.join("\n"), rest.collect(), names("/function/name"))
        }
        Some(Protocol::OpenaiResponses) => {
            // A tool result is an item without a role, and a call item has no text.
            let tool = json!("tool");
            let items = list("input")
                .iter()
                .filter_map(|item| match item.get("type").and_then(Value::as_str) {
                    Some("message") => Some(message(item.get("role"), item.get("content"))),
                    Some("function_call_output") => Some(message(Some(&tool), item.get("output"))),
                    _ => None,
                });
            let system = body.get("instructions").map(text_of).unwrap_or_default();
            (system, items.collect(), names("/name"))
        }
        Some(Protocol::AnthropicMessages) | None => {
            let messages = list("messages")
                .iter()
                .map(|item| message(item.get("role"), item.get("content")));
            let system = body.get("system").map(text_of).unwrap_or_default();
            (system, messages.collect(), names("/name"))
        }
    };
    json!({ "system": system, "messages": messages, "tools": tools, "body": body })
}

#[async_trait]
impl TestHost for AppTestHost {
    async fn create(&self, request: Value) -> Result<(), TestError> {
        if self.created.swap(true, Ordering::SeqCst) {
            return Err("a test creates one host".into());
        }
        let request: CreateRequest = serde_json::from_value(request)?;
        let (shared, sessions) = self.app()?;
        let data = &shared.machine.paths.data;
        let mut plugins = Vec::with_capacity(request.plugins.len());
        let mut folders = Vec::new();
        for requested in request.plugins {
            plugins.push(match requested {
                PluginRequest::Folder { folder, options } => {
                    // A relative folder would depend on the folder that started `yuke test`.
                    if folder.is_relative() {
                        return Err(format!("plugin folder {}: the folder is not absolute", folder.display()).into());
                    }
                    let root = folder
                        .canonicalize()
                        .map_err(|error| format!("plugin folder {}: {error}", folder.display()))?;
                    folders.push(root.clone());
                    manifest_plugin(&root, data, options)
                        .map_err(|error| format!("plugin folder {}: {error}", root.display()))?
                }
                PluginRequest::Given {
                    name,
                    options,
                    uses,
                    provides,
                } => {
                    // The name is a folder below the data folder, so it follows the rule of a manifest name.
                    valid_name(&name).map_err(|error| format!("plugin {name}: {error}"))?;
                    Plugin {
                        data_dir: data.join("plugins").join(&name),
                        name,
                        origin: Origin::Given,
                        options,
                        uses,
                        provides,
                    }
                }
            });
        }
        check_list(&plugins)?;
        for plugin in &plugins {
            std::fs::create_dir_all(&plugin.data_dir)
                .map_err(|error| format!("{}: {error}", plugin.data_dir.display()))?;
        }
        // A session reads the skills of the folder plugins, so the profile names their folders.
        shared
            .profile
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .plugin_folders = folders.into();
        let handle = sessions.plugins().ok_or("the app of the test has no runtime")?;
        let failures = handle.load_plugins(&plugins).await;
        if !failures.is_empty() {
            let texts: Vec<String> = failures.iter().map(ToString::to_string).collect();
            return Err(texts.join("\n").into());
        }
        self.script(request.replies);
        Ok(())
    }

    fn record(&self) -> Value {
        let recorded = lock(&self.recorded);
        json!({
            "notices": recorded.notices,
            "events": recorded.events,
            "requests": self.transport.sent().iter().map(request_view).collect::<Vec<_>>(),
        })
    }

    async fn close(&self) -> Result<(), TestError> {
        let (_shared, sessions) = self.app()?;
        self.closed.store(true, Ordering::SeqCst);
        sessions.close_all().await;
        if let Some(handle) = sessions.plugins() {
            handle.close_plugins().await?;
        }
        self.check_script()
    }

    fn script_session(&self, id: SessionId) -> Result<Arc<ScriptSession>, TestError> {
        let (_shared, sessions) = self.app()?;
        Ok(sessions.live(id)?.script_session())
    }

    fn read_media(&self, id: SessionId, blob: &Blob) -> Result<Vec<u8>, TestError> {
        let (shared, _sessions) = self.app()?;
        let bytes = shared.store.read_blob(id, &blob.digest)?;
        Ok(bytes.ok_or("the store has no bytes of the media")?)
    }
}

/// The app of one test, and the owner of its runtime for the runner.
pub(crate) struct TestPlace {
    app: App,
    host: Arc<AppTestHost>,
}

impl TestRuntime for TestPlace {
    fn runtime(&self) -> &Runtime {
        &self.app.runtime
    }

    async fn shutdown(self, timed_out: bool) -> Result<(), TestError> {
        // A test past its time limit can still loop, and the close of the sessions would wait for it.
        if timed_out {
            self.app.runtime.interrupt();
        }
        // A host that the test did not close checks its script here, so an unused reply still fails the test.
        let unchecked = self.host.created.load(Ordering::SeqCst) && !self.host.closed.load(Ordering::SeqCst);
        if unchecked && !timed_out && self.host.check_script().is_err() {
            // The fault of the check reached the runner.
        }
        self.app.shutdown().await;
        Ok(())
    }
}

impl TestPlace {
    /// Start the app of a test in the empty folder `place`, with the TypeScript cache `cache` of the run. With
    /// `internal_imports`, the test can import the `yuke:internal/` modules, as the tests of yuke do.
    ///
    /// # Errors
    ///
    /// Returns why the app did not start.
    pub(crate) async fn start(
        place: &Path,
        cache: &Path,
        internal_imports: bool,
    ) -> Result<(TestPlace, mpsc::UnboundedReceiver<Report>), TestError> {
        let (reports, report_receiver) = mpsc::unbounded_channel();
        let host = Arc::new(AppTestHost::new(reports.clone()));
        let fetch = Arc::new(yuke_http::Client::new(yuke_http::ClientOptions {
            idle_timeout: None,
            user_agent: "yuke-test".to_owned(),
        })?);
        let machine = Machine {
            paths: Paths {
                config: place.join("config"),
                data: place.join("data"),
                cache: place.join("cache"),
            },
            home: None,
            // Each provider key exists, so a session can name any model of the catalog.
            variable: Box::new(|name| name.ends_with("_API_KEY").then(|| OsString::from("test-key"))),
            transport: Arc::new(host.transport.clone()),
            exchange: Arc::clone(&fetch) as _,
            fetch,
            display: None,
            test: Some(TestSetup {
                cache: cache.to_owned(),
                internal_imports,
                processes: place.join("processes"),
                host: Arc::clone(&host),
                reports,
            }),
        };
        let observer = Arc::clone(&host) as Arc<dyn Observer>;
        // The plugins under test come from `createHost`, so the bundled plugins do not load.
        let (app, _bundled) = App::prepare(
            machine,
            Mode::Server,
            observer,
            Arc::new(MemoryStore::default()),
            Arc::new(NoWait),
        )
        .await?;
        if host
            .app
            .set((Arc::downgrade(&app.shared), Arc::downgrade(&app.sessions)))
            .is_err()
        {
            unreachable!("a new host has no app");
        }
        Ok((TestPlace { app, host }, report_receiver))
    }
}
