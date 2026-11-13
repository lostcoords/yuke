//! The sessions of the plugins, `ctx.get("sessions")`, on a scripted consumer: the snapshot, the updates, the end of a
//! handle, and the requests.

use std::any::Any;
use std::cell::Cell;
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

use yuke_protocol::{
    ApplyPluginsParams, ApplyPluginsResult, CheckPluginsParams, CheckPluginsResult, EventNumber, Input, InputId,
    InputKind, InputSource, InteractionId, InteractionResponse, Job, ListCatalogResult, ListPluginsResult,
    ListSessionsParams, ListSessionsResult, LiveUpdate, LoginId, LoginOutcome, LoginResult, McpServer, ModelReference,
    SessionId, SessionRow, SessionSettings, SessionSnapshot, SessionState, SessionTitle, SessionUpdate,
    SetApiKeyParams, StoredEvent, SyncPluginsParams, SyncPluginsResult,
};

use super::{evaluate, folder, load_entry, options, write};
use crate::{Fact, FactSink, Processes, Runtime, Sessions, SessionsError, ViewEvent, ViewSink};

/// A consumer that records each request and keeps the sink of each view.
#[derive(Default)]
struct Scripted {
    sinks: RefCell<Vec<ViewSink>>,
    facts: RefCell<Option<FactSink>>,
    calls: RefCell<Vec<String>>,
    folder: PathBuf,
    /// The holds that ended.
    released: Rc<Cell<usize>>,
    follow_up_on_cancel: Cell<bool>,
    /// A login waits for this. A cancel gives the permit, and so does a test that ends the login.
    login_end: tokio::sync::Notify,
}

/// A hold of [`Scripted`]. Its drop counts.
struct Hold(Rc<Cell<usize>>);

impl Drop for Hold {
    fn drop(&mut self) {
        self.0.set(self.0.get() + 1);
    }
}

impl Scripted {
    fn record(&self, call: String) {
        self.calls.borrow_mut().push(call);
    }

    fn calls(&self) -> Vec<String> {
        self.calls.borrow_mut().clone()
    }

    /// Send `update` to the view `index`.
    fn send(&self, index: usize, update: SessionUpdate) {
        let sink = Rc::clone(&self.sinks.borrow_mut()[index]);
        sink(ViewEvent::Update(update));
    }
}

impl Scripted {
    fn publish_before_reply(&self, update: SessionUpdate) {
        let sink = self.facts.borrow().as_ref().unwrap().clone();
        // Several batches must pass before the last host event reaches JavaScript.
        for _ in 0..1200 {
            sink(Fact::Update {
                session_id: session(),
                update: Box::new(state(SessionState::Running)),
            });
        }
        sink(Fact::Update {
            session_id: session(),
            update: Box::new(update),
        });
    }
}

#[async_trait::async_trait(?Send)]
impl yuke_engine::MediaStore for Scripted {
    async fn put_media(&self, bytes: Vec<u8>) -> Result<yuke_ai::Blob, SessionsError> {
        Ok(yuke_agent::blob_of(&bytes))
    }
}

#[async_trait::async_trait(?Send)]
impl crate::SessionHost for Scripted {
    fn session_id(&self) -> SessionId {
        session()
    }
    fn parent(&self) -> Option<SessionId> {
        None
    }
    fn cwd(&self) -> PathBuf {
        self.folder.clone()
    }
    fn is_closed(&self) -> bool {
        false
    }
    fn job_changed(&self, job: Job) {
        if job.state != yuke_protocol::JobState::Ended {
            self.publish_before_reply(SessionUpdate::Live(LiveUpdate::Job { job }));
        }
    }
    async fn accept_input(&self, _: Input) {}
    async fn ask(
        &self,
        source: &str,
        request: yuke_protocol::InteractionRequest,
        _: yuke_engine::CancellationToken,
    ) -> InteractionResponse {
        let sink = self.facts.borrow().as_ref().unwrap().clone();
        sink(Fact::Update {
            session_id: session(),
            update: Box::new(SessionUpdate::Live(LiveUpdate::InteractionRequested {
                interaction_id: InteractionId(4),
                source: source.to_owned(),
                request,
            })),
        });
        self.publish_before_reply(SessionUpdate::Live(LiveUpdate::InteractionClosed {
            interaction_id: InteractionId(4),
        }));
        InteractionResponse::Questions { answers: Vec::new() }
    }
    async fn request(
        &self,
        _: &str,
        _: String,
        _: serde_json::Value,
    ) -> Result<serde_json::Value, crate::RequestFailure> {
        Err(crate::RequestFailure::NoClient)
    }
    fn model(&self, _: &ModelReference) -> Result<yuke_engine::Model, SessionsError> {
        Err("unused".into())
    }
    fn settings(&self) -> SessionSettings {
        settings()
    }
}

fn settings() -> SessionSettings {
    SessionSettings {
        model: ModelReference {
            provider: "minimax".to_owned(),
            model: "MiniMax-M3".to_owned(),
        },
        settings: yuke_ai::RequestSettings::new(),
        cwd: PathBuf::from("/work"),
    }
}

fn state(state: SessionState) -> SessionUpdate {
    SessionUpdate::Live(LiveUpdate::State { state })
}

fn session() -> SessionId {
    SessionId::from_bytes([7; 16])
}

#[async_trait::async_trait(?Send)]
impl Sessions for Scripted {
    async fn create(&self, _: SessionSettings, _: Option<SessionId>) -> Result<SessionId, SessionsError> {
        Err("unused".into())
    }
    async fn fork(&self, id: SessionId, through: Option<EventNumber>) -> Result<SessionId, SessionsError> {
        self.record(format!("fork {id} {through:?}"));
        Ok(id)
    }
    async fn list(&self, params: ListSessionsParams) -> Result<ListSessionsResult, SessionsError> {
        self.record(format!("list {:?}", params.limit));
        Ok(ListSessionsResult {
            sessions: Vec::new(),
            next_cursor: None,
        })
    }
    async fn get(&self, id: SessionId) -> Result<SessionRow, SessionsError> {
        Err(format!("no session {id}").into())
    }
    async fn remove(&self, id: SessionId) -> Result<(), SessionsError> {
        self.record(format!("remove {id}"));
        Ok(())
    }
    async fn open(&self, id: SessionId, tail: usize, sink: ViewSink) -> Result<Box<dyn Any>, SessionsError> {
        self.record(format!("open {id} {tail}"));
        sink(ViewEvent::Snapshot(SessionSnapshot {
            settings: settings(),
            updates: vec![state(SessionState::Idle)],
        }));
        self.sinks.borrow_mut().push(sink);
        Ok(Box::new(Hold(Rc::clone(&self.released))))
    }
    fn watch_facts(&self, sink: FactSink) -> Box<dyn Any> {
        *self.facts.borrow_mut() = Some(sink);
        Box::new(())
    }
    async fn events_before(
        &self,
        id: SessionId,
        before: Option<EventNumber>,
        limit: usize,
    ) -> Result<Vec<StoredEvent>, SessionsError> {
        self.record(format!("events {id} {before:?} {limit}"));
        Ok(Vec::new())
    }
    async fn input(&self, id: SessionId, input: Input) -> Result<InputId, SessionsError> {
        let source = match input.source() {
            InputSource::User => "user".to_owned(),
            InputSource::Plugin { name } => name.clone(),
        };
        self.record(format!(
            "input {id} {source} {:?} {}",
            input.kind(),
            serde_json::to_string(input.model_content()).unwrap()
        ));
        Ok(InputId(3))
    }
    fn background(&self, id: SessionId) {
        self.record(format!("background {id}"));
    }
    fn has_movable(&self, _: SessionId) -> bool {
        false
    }
    fn cancel(&self, id: SessionId) {
        if self.follow_up_on_cancel.replace(false) {
            self.send(
                0,
                SessionUpdate::Live(LiveUpdate::InputRemoved { input_id: InputId(9) }),
            );
        } else {
            self.record(format!("cancel {id}"));
        }
    }
    async fn idle(&self, _: SessionId) -> Result<(), SessionsError> {
        // The reply must follow updates across several delivery batches.
        let facts = self.facts.borrow_mut();
        for sink in self.sinks.borrow_mut().iter() {
            for _ in 0..600 {
                for session_state in [SessionState::Running, SessionState::Idle] {
                    let update = state(session_state);
                    if let Some(fact) = facts.as_ref() {
                        fact(Fact::Update {
                            session_id: session(),
                            update: Box::new(update.clone()),
                        });
                    }
                    sink(ViewEvent::Update(update));
                }
            }
        }
        Ok(())
    }
    async fn set_settings(&self, _: SessionId, _: SessionSettings) -> Result<(), SessionsError> {
        Ok(())
    }
    async fn rename(&self, id: SessionId, title: SessionTitle) -> Result<(), SessionsError> {
        self.record(format!("rename {id} {title}"));
        Ok(())
    }
    async fn put_blob(&self, id: SessionId, bytes: Vec<u8>) -> Result<yuke_ai::Blob, SessionsError> {
        // The digest of the answer proves the bytes, so the record keeps their count.
        self.record(format!("put blob {id} {}", bytes.len()));
        Ok(yuke_agent::blob_of(&bytes))
    }
    async fn remove_input(&self, id: SessionId, input_id: InputId) -> Result<bool, SessionsError> {
        self.record(format!("remove input {id} {}", input_id.0));
        Ok(false)
    }
    fn respond(&self, _: SessionId, _: InteractionId, _: InteractionResponse) -> Result<(), SessionsError> {
        Err("no open question 4".into())
    }
    fn jobs(&self, _: SessionId) -> Result<Vec<Job>, SessionsError> {
        Ok(Vec::new())
    }
    async fn stop_job(&self, _: SessionId, _: &str) -> Result<(), SessionsError> {
        Ok(())
    }
    fn mcp_servers(&self, _: SessionId) -> Result<Vec<McpServer>, SessionsError> {
        Ok(Vec::new())
    }
    async fn close(&self, id: SessionId) -> Result<(), SessionsError> {
        self.record(format!("close {id}"));
        for sink in self.sinks.borrow_mut().iter() {
            sink(ViewEvent::Closed);
        }
        Ok(())
    }
    async fn catalog(&self, all: bool) -> Result<ListCatalogResult, SessionsError> {
        self.record(format!("catalog {all}"));
        Ok(ListCatalogResult { providers: Vec::new() })
    }
    async fn login(&self, provider: String) -> Result<LoginResult, SessionsError> {
        self.record(format!("login {provider}"));
        Ok(LoginResult {
            login_id: LoginId(7),
            verification_url: "https://example.com/device".to_owned(),
            user_code: "CODE".to_owned(),
        })
    }
    async fn wait_for_login(&self, id: LoginId) -> Result<LoginOutcome, SessionsError> {
        self.record(format!("wait for login {}", id.0));
        self.login_end.notified().await;
        Ok(LoginOutcome::Cancelled)
    }
    fn cancel_login(&self, id: LoginId) {
        self.record(format!("cancel login {}", id.0));
        self.login_end.notify_one();
    }
    async fn set_api_key(&self, params: SetApiKeyParams) -> Result<(), SessionsError> {
        self.record(format!("set api key {} {}", params.provider, params.api_key));
        Ok(())
    }
    async fn logout(&self, provider: String) -> Result<(), SessionsError> {
        self.record(format!("logout {provider}"));
        Ok(())
    }
    async fn list_plugins(&self) -> Result<ListPluginsResult, SessionsError> {
        self.record("plugins list".to_owned());
        Ok(ListPluginsResult { plugins: Vec::new() })
    }
    async fn sync_plugins(&self, params: SyncPluginsParams) -> Result<SyncPluginsResult, SessionsError> {
        self.record(format!("plugins sync {:?}", params.locked));
        Ok(SyncPluginsResult {
            plugins: Vec::new(),
            written: true,
        })
    }
    /// A check that never ends. Its drop ends a hold, so a test sees the cancel of its task.
    async fn check_plugins(&self, params: CheckPluginsParams) -> Result<CheckPluginsResult, SessionsError> {
        self.record(format!("plugins check {:?}", params.target));
        let _hold = Hold(Rc::clone(&self.released));
        std::future::pending().await
    }
    async fn apply_plugins(&self, params: ApplyPluginsParams) -> Result<ApplyPluginsResult, SessionsError> {
        self.record(format!("plugins apply {}", params.changes[0].new));
        Ok(ApplyPluginsResult { written: false })
    }
    async fn add_plugin(
        &self,
        params: yuke_protocol::AddPluginParams,
    ) -> Result<yuke_protocol::AddPluginResult, SessionsError> {
        self.record(format!("plugins add {} {:?}", params.source.git, params.options));
        Ok(yuke_protocol::AddPluginResult {
            name: "clock".to_owned(),
            source: params.source,
            commit: "c".repeat(40),
        })
    }
    async fn remove_plugin(&self, params: yuke_protocol::RemovePluginParams) -> Result<(), SessionsError> {
        self.record(format!("plugins remove {}", params.name));
        Ok(())
    }
}

/// A runtime of the test `name` on `scripted` with the plugin `test`, whose `apply` puts `ctx.get("sessions")`,
/// `ctx.get("catalog")`, and the credentials and the plugin manager of `yuke:internal/sessions` on the global object.
async fn started(name: &str, scripted: &Rc<Scripted>) -> Runtime {
    let folder = folder(name);
    let processes = Rc::new(Processes::new(folder.join("processes")));
    let (runtime, _reports) = Runtime::start(crate::Options {
        sessions: Rc::clone(scripted) as Rc<dyn Sessions>,
        // The plugin of the test reaches the credentials and the plugin manager, as the bundled plugins do.
        internal_imports: true,
        ..options(&folder, processes)
    })
    .await
    .unwrap();
    write(
        &folder,
        &[(
            "index.ts",
            "import { auth, plugins } from 'yuke:internal/sessions';
             export function apply(ctx) {
               globalThis.context = ctx;
               globalThis.sessions = ctx.get('sessions');
               globalThis.catalog = ctx.get('catalog');
               globalThis.auth = auth;
               globalThis.plugins = plugins;
               globalThis.seen = [];
             }
             export function session(s) { globalThis.session = s; }",
        )],
    );
    load_entry(&runtime, &folder.join("index.ts")).await.unwrap();
    runtime
}

/// Open the session of [`session`] as `handle`, with each event into `seen`. Return its snapshot.
async fn open(runtime: &Runtime, signal: &str) -> String {
    evaluate::<String>(
        runtime,
        &format!(
            "globalThis.handle = await sessions.open('{}', {{ tail: 5, signal: {signal}, onEvent: (e) => seen.push(e) }});
             return JSON.stringify(seen[0].snapshot);",
            session()
        ),
    )
    .await
    .unwrap()
}

#[tokio::test(flavor = "local")]
async fn idle_delivers_each_update_in_order_after_the_snapshot() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started("idle_delivers_each_update_in_order_after_the_snapshot", &scripted).await;

    let snapshot = open(&runtime, "undefined").await;
    let updates = evaluate::<Vec<String>>(
        &runtime,
        "await handle.waitForIdle(); return seen.slice(1).map(event => event.update.state);",
    )
    .await
    .unwrap();

    assert_eq!(
        serde_json::from_str::<SessionSnapshot>(&snapshot).unwrap(),
        SessionSnapshot {
            settings: settings(),
            updates: vec![state(SessionState::Idle)],
        }
    );
    assert_eq!(updates, ["running", "idle"].repeat(600));
    assert_eq!(scripted.calls(), [format!("open {} 5", session())]);
}

#[tokio::test(flavor = "local")]
async fn idle_preserves_the_order_of_facts_and_view_events_across_batches() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started(
        "idle_preserves_the_order_of_facts_and_view_events_across_batches",
        &scripted,
    )
    .await;
    let delivered = evaluate::<Vec<String>>(
        &runtime,
        &format!(
            "const delivered = [];
             context.addListener('session.update', data => delivered.push(`fact ${{data.update.state}}`));
             const handle = await sessions.open('{}', {{ tail: 5, onEvent(event) {{
               if (event.kind === 'update') delivered.push(`view ${{event.update.state}}`);
             }} }});
             await handle.waitForIdle();
             return delivered;",
            session()
        ),
    )
    .await
    .unwrap();

    assert_eq!(
        delivered,
        ["fact running", "view running", "fact idle", "view idle"].repeat(600)
    );
}

#[tokio::test(flavor = "local")]
async fn idle_delivers_prior_events_when_a_listener_calls_the_host() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started("idle_delivers_prior_events_when_a_listener_calls_the_host", &scripted).await;
    evaluate::<()>(
        &runtime,
        &format!(
            "globalThis.updates = [];
             globalThis.delivering = false;
             globalThis.recursed = false;
             globalThis.called = false;
             globalThis.handle = await sessions.open('{}', {{ tail: 5, onEvent(event) {{
               recursed ||= delivering;
               delivering = true;
               if (event.kind === 'update') {{
                 updates.push(event.update.sessionUpdate === 'state' ? event.update.state : 'follow-up');
                 if (!called) {{ called = true; handle.cancel(); }}
               }}
               delivering = false;
             }} }});",
            session()
        ),
    )
    .await
    .unwrap();
    scripted.follow_up_on_cancel.set(true);
    let prior = evaluate::<Vec<String>>(
        &runtime,
        "await handle.waitForIdle(); return updates.filter(state => state !== 'follow-up');",
    )
    .await
    .unwrap();
    crate::wait_for_settled().await;
    let all = evaluate::<Vec<String>>(&runtime, "return updates;").await.unwrap();
    let recursed = evaluate::<bool>(&runtime, "return recursed;").await.unwrap();

    assert_eq!(prior, ["running", "idle"].repeat(600));
    let mut expected = ["running", "idle"].repeat(600);
    expected.push("follow-up");
    assert_eq!(all, expected);
    assert!(!recursed);
}

#[tokio::test(flavor = "local")]
async fn an_aborted_handle_ends_its_hold_and_gets_no_later_update() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started("an_aborted_handle_ends_its_hold_and_gets_no_later_update", &scripted).await;

    open(&runtime, "(globalThis.pane = new AbortController()).signal").await;
    evaluate::<()>(
        &runtime,
        &format!(
            "globalThis.later = [];
             await sessions.open('{}', {{ tail: 5, onEvent: (e) => later.push(e) }});
             pane.abort();",
            session()
        ),
    )
    .await
    .unwrap();
    // The feed keeps the order, so the update of the second view comes after the one of the first view.
    scripted.send(0, state(SessionState::Running));
    scripted.send(1, state(SessionState::Running));
    crate::wait_for_settled().await;
    assert_eq!(evaluate::<usize>(&runtime, "return later.length;").await.unwrap(), 2);
    let input = evaluate::<String>(
        &runtime,
        "try { await handle.sendMessage({ content: [] }); return 'sent'; } catch (error) { return error.message; }",
    )
    .await
    .unwrap();
    let seen = evaluate::<usize>(&runtime, "return seen.length;").await.unwrap();

    assert_eq!(scripted.released.get(), 1);
    assert_eq!(input, format!("the handle of the session {} has ended", session()));
    assert_eq!(seen, 1);
}

// The abort comes before the hold exists, so the open itself ends the hold.
#[tokio::test(flavor = "local")]
async fn an_abort_during_the_open_rejects_it_and_ends_its_hold() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started("an_abort_during_the_open_rejects_it_and_ends_its_hold", &scripted).await;

    let opened = evaluate::<String>(
        &runtime,
        &format!(
            "const pane = new AbortController();
             const opening = sessions.open('{}', {{ tail: 5, signal: pane.signal, onEvent: () => undefined }});
             pane.abort(new Error('the pane closed'));
             try {{ await opening; return 'opened'; }} catch (error) {{ return error.message; }}",
            session()
        ),
    )
    .await
    .unwrap();

    assert_eq!(opened, "the pane closed");
    assert_eq!(scripted.released.get(), 1);
}

#[tokio::test(flavor = "local")]
async fn the_stop_of_the_plugin_ends_its_handles() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started("the_stop_of_the_plugin_ends_its_handles", &scripted).await;

    // The own signal of the handle does not replace the signal of the plugin.
    open(&runtime, "new AbortController().signal").await;
    let signal = evaluate::<bool>(&runtime, "globalThis.signal = handle.signal; return signal.aborted;")
        .await
        .unwrap();
    runtime.close_plugins().await.unwrap();
    let ended = evaluate::<bool>(&runtime, "return signal.aborted;").await.unwrap();

    assert!(!signal && ended);
    assert_eq!(scripted.released.get(), 1);
}

#[tokio::test(flavor = "local")]
async fn the_close_of_the_session_ends_each_handle_on_it() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started("the_close_of_the_session_ends_each_handle_on_it", &scripted).await;
    open(&runtime, "undefined").await;

    let ended = evaluate::<Vec<bool>>(
        &runtime,
        "globalThis.other = await sessions.open(handle.id, { tail: 5, onEvent: () => undefined });
         await sessions.closeForAll(handle.id);
         return [handle.signal.aborted, other.signal.aborted];",
    )
    .await
    .unwrap();
    assert_eq!(ended, [true, true]);
    let reason = evaluate::<String>(&runtime, "return handle.signal.reason.message;")
        .await
        .unwrap();
    let input = evaluate::<String>(
        &runtime,
        "try { await other.sendMessage({ content: [] }); return 'sent'; } catch (error) { return error.message; }",
    )
    .await
    .unwrap();

    assert_eq!(reason, format!("the session {} closed", session()));
    assert_eq!(input, format!("the handle of the session {} has ended", session()));
    assert_eq!(scripted.released.get(), 2);
}

#[tokio::test(flavor = "local")]
async fn the_requests_reach_the_consumer_with_the_arguments_of_the_plugin() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started(
        "the_requests_reach_the_consumer_with_the_arguments_of_the_plugin",
        &scripted,
    )
    .await;
    open(&runtime, "undefined").await;

    let answers = evaluate::<String>(
        &runtime,
        &format!(
            "const id = '{}';
             const input = await handle.sendMessage({{ content: [{{ kind: 'userText', text: 'hi' }}] }});
             const removed = await handle.removeInput(input);
             await handle.sendMessage({{ content: [{{ kind: 'userText', text: 'Review @main.rs' }}], modelContent: [{{ kind: 'userText', text: 'Review main.rs.' }}] }});
             await handle.notifyModel({{ display: 'shown', text: 'told' }});
             handle.cancel();
             handle.moveJobsToBackground();
             await sessions.rename(id, '  renamed   session ');
             await sessions.fork(id);
             await sessions.events(id, {{ limit: 3 }});
             await sessions.list();
             await catalog.list();
             await auth.setApiKey('opencode', 'the-key');
             await auth.logout('opencode');
             await sessions.closeForAll(id);
             return JSON.stringify([input, removed]);",
            session()
        ),
    )
    .await
    .unwrap();

    let id = session();
    assert_eq!(answers, "[3,false]");
    assert_eq!(
        scripted.calls()[1..],
        [
            format!(
                "input {id} user {:?} [{{\"kind\":\"userText\",\"text\":\"hi\"}}]",
                InputKind::Message
            ),
            format!("remove input {id} 3"),
            format!(
                "input {id} user {:?} [{{\"kind\":\"userText\",\"text\":\"Review main.rs.\"}}]",
                InputKind::Message
            ),
            format!(
                "input {id} test {:?} [{{\"kind\":\"userText\",\"text\":\"<system_notification plugin=\\\"test\\\">told</system_notification>\"}}]",
                InputKind::Notification
            ),
            format!("cancel {id}"),
            format!("background {id}"),
            format!("rename {id} renamed session"),
            format!("fork {id} None"),
            format!("events {id} None 3"),
            "list None".to_owned(),
            "catalog false".to_owned(),
            "set api key opencode the-key".to_owned(),
            "logout opencode".to_owned(),
            format!("close {id}"),
        ]
    );
}

#[tokio::test(flavor = "local")]
async fn a_login_gives_its_code_and_an_abort_cancels_it_and_each_wait_shares_one_end() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started(
        "a_login_gives_its_code_and_an_abort_cancels_it_and_each_wait_shares_one_end",
        &scripted,
    )
    .await;

    let answer = evaluate::<String>(
        &runtime,
        "const control = new AbortController();
         const login = await auth.login('xai-grok', { signal: control.signal });
         control.abort();
         const outcome = await login.waitForEnd();
         await login.waitForEnd();
         return JSON.stringify([login.verificationUrl, login.userCode, outcome]);",
    )
    .await
    .unwrap();

    assert_eq!(answer, r#"["https://example.com/device","CODE",{"kind":"cancelled"}]"#);
    assert_eq!(
        scripted.calls(),
        ["login xai-grok", "cancel login 7", "wait for login 7"]
    );
}

#[tokio::test(flavor = "local")]
async fn an_abort_while_a_login_starts_cancels_it_and_an_abort_before_the_start_starts_nothing() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started(
        "an_abort_while_a_login_starts_cancels_it_and_an_abort_before_the_start_starts_nothing",
        &scripted,
    )
    .await;

    let before = evaluate::<String>(
        &runtime,
        "const control = new AbortController();
         control.abort(new Error('stopped first'));
         try { await auth.login('xai-grok', { signal: control.signal }); return 'started'; }
         catch (error) { return error.message; }",
    )
    .await
    .unwrap();
    let calls_before = scripted.calls();
    let during = evaluate::<String>(
        &runtime,
        "const control = new AbortController();
         const starting = auth.login('xai-grok', { signal: control.signal });
         control.abort();
         const login = await starting;
         return JSON.stringify(await login.waitForEnd());",
    )
    .await
    .unwrap();

    assert_eq!(before, "stopped first");
    assert!(calls_before.is_empty(), "{calls_before:?}");
    assert_eq!(during, r#"{"kind":"cancelled"}"#);
    assert_eq!(
        scripted.calls(),
        ["login xai-grok", "cancel login 7", "wait for login 7"]
    );
}

#[tokio::test(flavor = "local")]
async fn the_plugin_requests_reach_the_consumer_and_an_abort_of_a_check_drops_its_task() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started(
        "the_plugin_requests_reach_the_consumer_and_an_abort_of_a_check_drops_its_task",
        &scripted,
    )
    .await;

    let answers = evaluate::<String>(
        &runtime,
        "const listed = await plugins.list();
         const synced = await plugins.sync({ locked: true });
         const change = { name: 'clock', source: { git: 'https://host/repo' }, old: 'a'.repeat(40),
                          new: 'b'.repeat(40), log: { kind: 'commits', commits: [] } };
         const applied = await plugins.apply([change]);
         globalThis.controller = new AbortController();
         globalThis.checked = plugins.check({ kind: 'names', names: ['clock'] }, { signal: controller.signal });
         const added = await plugins.add({ source: { git: 'https://host/clock' }, options: { format: '24h' } });
         await plugins.remove('clock');
         return JSON.stringify([listed, synced.written, applied.written, added.name]);",
    )
    .await
    .unwrap();
    // An abort before the first poll creates no hold, so the drop assertion must wait for the task to start.
    crate::wait_for_settled().await;
    let aborted = evaluate::<bool>(
        &runtime,
        "controller.abort();
         return await checked.then(() => false, (error) => error === controller.signal.reason);",
    )
    .await
    .unwrap();
    // The abort of the task drops it at the next poll of the host runtime.
    crate::wait_for_settled().await;

    assert_eq!(answers, r#"[{"plugins":[]},true,false,"clock"]"#);
    assert!(aborted);
    assert_eq!(scripted.released.get(), 1);
    assert_eq!(
        scripted.calls(),
        [
            "plugins list".to_owned(),
            "plugins sync true".to_owned(),
            format!("plugins apply {}", "b".repeat(40)),
            r#"plugins check Names { names: ["clock"] }"#.to_owned(),
            r#"plugins add https://host/clock Some({"format": String("24h")})"#.to_owned(),
            "plugins remove clock".to_owned(),
        ]
    );
}

#[tokio::test(flavor = "local")]
async fn a_blob_takes_the_bytes_of_its_view_at_the_call() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started("a_blob_takes_the_bytes_of_its_view_at_the_call", &scripted).await;
    open(&runtime, "undefined").await;

    let answers = evaluate::<String>(
        &runtime,
        "const buffer = new Uint8Array([9, 1, 2, 3, 9]);
         const put = handle.putBlob(buffer.subarray(1, 4));
         buffer[2] = 7;
         const blob = await put;
         return JSON.stringify(blob);",
    )
    .await
    .unwrap();

    let id = session();
    assert_eq!(
        answers,
        r#"{"digest":"039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81","len":3}"#
    );
    let puts: Vec<String> = scripted
        .calls()
        .into_iter()
        .filter(|call| call.starts_with("put blob"))
        .collect();
    assert_eq!(puts, [format!("put blob {id} 3")]);
}

#[tokio::test(flavor = "local")]
async fn a_failed_request_rejects_with_the_text_of_its_failure() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started("a_failed_request_rejects_with_the_text_of_its_failure", &scripted).await;
    open(&runtime, "undefined").await;

    let failures = evaluate::<String>(
        &runtime,
        "const failures = [];
         try { await sessions.get(handle.id); } catch (error) { failures.push(error.message); }
         try { handle.respond(4, { kind: 'cancelled' }); } catch (error) { failures.push(error.message); }
         return JSON.stringify(failures);",
    )
    .await
    .unwrap();

    assert_eq!(
        failures,
        format!(r#"["no session {}","no open question 4"]"#, session())
    );
}

#[tokio::test(flavor = "local")]
async fn ask_delivers_host_events_before_its_reply() {
    let scripted = Rc::new(Scripted::default());
    let runtime = started("ask_delivers_host_events_before_its_reply", &scripted).await;
    let session = runtime
        .handle()
        .open_session(Rc::clone(&scripted) as Rc<dyn crate::SessionHost>)
        .await
        .unwrap();
    session.tools().await.unwrap();

    let delivered = evaluate::<Vec<String>>(
        &runtime,
        "context.addListener('session.update', data => seen.push(data.update.sessionUpdate));
         const answer = await session.ask({ questions: [{ id: 'choice', header: 'Choice', question: 'Which?', options: [] }] });
         seen.push(`reply ${answer.length}`);
         return seen;",
    )
    .await
    .unwrap();

    let mut expected = vec!["interactionRequested"];
    expected.resize(1201, "state");
    expected.extend(["interactionClosed", "reply 0"]);
    assert_eq!(delivered, expected);
}

#[tokio::test(flavor = "local")]
async fn start_job_delivers_host_events_before_its_reply() {
    let name = "start_job_delivers_host_events_before_its_reply";
    let scripted = Rc::new(Scripted {
        folder: folder(name),
        ..Scripted::default()
    });
    let runtime = started(name, &scripted).await;
    runtime
        .access()
        .run(async move |ctx: rquickjs::Ctx<'_>, registry| {
            let host = Rc::clone(&scripted) as Rc<dyn crate::SessionHost>;
            let call = crate::native::call::object(
                &ctx,
                &registry.processes,
                &host,
                scripted.folder.clone(),
                &yuke_engine::CancellationToken::new(),
            )
            .unwrap();
            ctx.globals().set("call", call).unwrap();
            Ok(())
        })
        .await
        .unwrap();

    let delivered = evaluate::<Vec<String>>(
        &runtime,
        "context.addListener('session.update', data => {
           if (data.update.sessionUpdate !== 'job' || data.update.job.state === 'running') {
             seen.push(data.update.sessionUpdate);
           }
         });
         await call.startJob('true', undefined);
         seen.push('reply');
         return seen;",
    )
    .await
    .unwrap();

    let mut expected = vec!["state"; 1200];
    expected.extend(["job", "reply"]);
    assert_eq!(delivered, expected);
}

#[tokio::test(flavor = "local")]
async fn stop_job_delivers_host_events_before_its_reply() {
    let name = "stop_job_delivers_host_events_before_its_reply";
    let scripted = Rc::new(Scripted {
        folder: folder(name),
        ..Scripted::default()
    });
    let runtime = started(name, &scripted).await;
    runtime
        .access()
        .run(async move |ctx: rquickjs::Ctx<'_>, registry| {
            let host = Rc::clone(&scripted) as Rc<dyn crate::SessionHost>;
            let call = crate::native::call::object(
                &ctx,
                &registry.processes,
                &host,
                scripted.folder.clone(),
                &yuke_engine::CancellationToken::new(),
            )
            .unwrap();
            ctx.globals().set("call", call).unwrap();
            Ok(())
        })
        .await
        .unwrap();

    let delivered = evaluate::<Vec<String>>(
        &runtime,
        "let recording = false;
         context.addListener('session.update', data => {
           if (recording && (data.update.sessionUpdate !== 'job' || data.update.job.state === 'stopped')) {
             seen.push(data.update.sessionUpdate);
           }
         });
         // The events of the start arrive before its reply, so the record holds only the events of the stop.
         const started = await call.startJob('exec sleep 30', undefined);
         recording = true;
         const answer = await call.stopJob(started.id);
         seen.push(`reply ${answer}`);
         return seen;",
    )
    .await
    .unwrap();

    let mut expected = vec!["state"; 1200];
    expected.extend(["job", "reply stopped"]);
    assert_eq!(delivered, expected);
}
