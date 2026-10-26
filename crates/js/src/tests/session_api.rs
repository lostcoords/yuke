//! The sessions of the plugins, `ctx.get("sessions")`, on a scripted consumer: the snapshot, the updates, the end of a
//! handle, and the requests.

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use yuke_protocol::{
    EventNumber, Input, InputId, InputKind, InputSource, InteractionId, InteractionResponse, Job, ListCatalogResult,
    ListSessionsParams, ListSessionsResult, LiveUpdate, McpServer, ModelReference, SessionId, SessionRow,
    SessionSettings, SessionSnapshot, SessionState, SessionUpdate, StoredEvent,
};

use super::{evaluate, folder, load_entry, options, wait_until, write};
use crate::{Processes, Runtime, Sessions, SessionsError, ViewEvent, ViewSink};

/// A consumer that records each request and keeps the sink of each view.
#[derive(Default)]
struct Scripted {
    sinks: Mutex<Vec<ViewSink>>,
    calls: Mutex<Vec<String>>,
    /// The holds that ended.
    released: Arc<AtomicUsize>,
}

/// A hold of [`Scripted`]. Its drop counts.
struct Hold(Arc<AtomicUsize>);

impl Drop for Hold {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

impl Scripted {
    fn record(&self, call: String) {
        self.calls.lock().unwrap().push(call);
    }

    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }

    /// Send `update` to the view `index`.
    fn send(&self, index: usize, update: SessionUpdate) {
        let sink = Arc::clone(&self.sinks.lock().unwrap()[index]);
        sink(ViewEvent::Update(update));
    }
}

fn settings() -> SessionSettings {
    SessionSettings {
        model: ModelReference {
            provider: "minimax".to_owned(),
            model: "MiniMax-M3".to_owned(),
        },
        settings: yuke_ai::Settings::new(),
        cwd: PathBuf::from("/work"),
    }
}

fn state(state: SessionState) -> SessionUpdate {
    SessionUpdate::Live(LiveUpdate::State { state })
}

fn session() -> SessionId {
    SessionId::from_bytes([7; 16])
}

#[async_trait::async_trait]
impl Sessions for Scripted {
    async fn create(&self, _: SessionSettings) -> Result<SessionId, SessionsError> {
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
    async fn open(&self, id: SessionId, tail: usize, sink: ViewSink) -> Result<Box<dyn Send>, SessionsError> {
        self.record(format!("open {id} {tail}"));
        sink(ViewEvent::Snapshot(SessionSnapshot {
            settings: settings(),
            updates: vec![state(SessionState::Idle)],
        }));
        self.sinks.lock().unwrap().push(sink);
        Ok(Box::new(Hold(Arc::clone(&self.released))))
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
    fn cancel(&self, id: SessionId) {
        self.record(format!("cancel {id}"));
    }
    async fn idle(&self, _: SessionId) -> Result<(), SessionsError> {
        Ok(())
    }
    async fn set_settings(&self, _: SessionId, _: SessionSettings) -> Result<(), SessionsError> {
        Ok(())
    }
    async fn remove_input(&self, _: SessionId, _: InputId) -> Result<(), SessionsError> {
        Ok(())
    }
    fn respond(&self, _: SessionId, _: InteractionId, _: InteractionResponse) -> Result<(), SessionsError> {
        Err("no open question 4".into())
    }
    fn jobs(&self, _: SessionId) -> Result<Vec<Job>, SessionsError> {
        Ok(Vec::new())
    }
    async fn stop_job(&self, _: SessionId, _: String) -> Result<(), SessionsError> {
        Ok(())
    }
    fn mcp_servers(&self, _: SessionId) -> Result<Vec<McpServer>, SessionsError> {
        Ok(Vec::new())
    }
    async fn close(&self, id: SessionId, stop_jobs: bool) -> Result<(), SessionsError> {
        self.record(format!("close {id} {stop_jobs}"));
        for sink in self.sinks.lock().unwrap().iter() {
            sink(ViewEvent::Closed);
        }
        Ok(())
    }
    async fn catalog(&self, all: bool) -> Result<ListCatalogResult, SessionsError> {
        self.record(format!("catalog {all}"));
        Ok(ListCatalogResult { providers: Vec::new() })
    }
}

/// A runtime of the test `name` on `scripted` with the plugin `test`, whose `apply` puts `ctx.get("sessions")` and
/// `ctx.get("catalog")` on the global object.
async fn started(name: &str, scripted: &Arc<Scripted>) -> Runtime {
    let folder = folder(name);
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let (runtime, _reports) = Runtime::start(crate::Options {
        sessions: Arc::clone(scripted) as Arc<dyn Sessions>,
        ..options(&folder, processes)
    })
    .await
    .unwrap();
    write(
        &folder,
        &[(
            "index.ts",
            "export function apply(ctx) {
               globalThis.sessions = ctx.get('sessions');
               globalThis.catalog = ctx.get('catalog');
               globalThis.seen = [];
             }",
        )],
    );
    load_entry(&runtime, &folder.join("index.ts")).await.unwrap();
    runtime
}

/// Open the session of [`session`] as `handle`, with each update into `seen`.
async fn open(runtime: &Runtime, signal: &str) -> String {
    evaluate::<String>(
        runtime,
        &format!(
            "globalThis.handle = await sessions.open('{}', {{ tail: 5, signal: {signal}, update: (u) => seen.push(u) }});
             return JSON.stringify(handle.snapshot);",
            session()
        ),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn a_handle_starts_with_its_snapshot_and_gets_each_later_update_in_order() {
    let scripted = Arc::new(Scripted::default());
    let runtime = started(
        "a_handle_starts_with_its_snapshot_and_gets_each_later_update_in_order",
        &scripted,
    )
    .await;

    let snapshot = open(&runtime, "undefined").await;
    // More updates than one delivery takes.
    for _ in 0..600 {
        scripted.send(0, state(SessionState::Running));
        scripted.send(0, state(SessionState::Idle));
    }
    wait_until(&runtime, "return seen.length === 1200;").await;
    let alternate = evaluate::<bool>(
        &runtime,
        "return seen.every((u, i) => u.state === (i % 2 === 0 ? 'running' : 'idle'));",
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
    assert!(alternate);
    assert_eq!(scripted.calls(), [format!("open {} 5", session())]);
}

#[tokio::test]
async fn an_aborted_handle_ends_its_hold_and_gets_no_later_update() {
    let scripted = Arc::new(Scripted::default());
    let runtime = started("an_aborted_handle_ends_its_hold_and_gets_no_later_update", &scripted).await;

    open(&runtime, "(globalThis.pane = new AbortController()).signal").await;
    evaluate::<()>(
        &runtime,
        &format!(
            "globalThis.later = [];
             await sessions.open('{}', {{ tail: 5, update: (u) => later.push(u) }});
             pane.abort();",
            session()
        ),
    )
    .await
    .unwrap();
    // The feed keeps the order, so the update of the second view comes after the one of the first view.
    scripted.send(0, state(SessionState::Running));
    scripted.send(1, state(SessionState::Running));
    wait_until(&runtime, "return later.length === 1;").await;
    let input = evaluate::<String>(
        &runtime,
        "try { await handle.input([]); return 'sent'; } catch (error) { return error.message; }",
    )
    .await
    .unwrap();
    let seen = evaluate::<usize>(&runtime, "return seen.length;").await.unwrap();

    assert_eq!(scripted.released.load(Ordering::SeqCst), 1);
    assert_eq!(input, format!("the handle of the session {} has ended", session()));
    assert_eq!(seen, 0);
}

// The abort comes before the hold exists, so the open itself ends the hold.
#[tokio::test]
async fn an_abort_during_the_open_rejects_it_and_ends_its_hold() {
    let scripted = Arc::new(Scripted::default());
    let runtime = started("an_abort_during_the_open_rejects_it_and_ends_its_hold", &scripted).await;

    let opened = evaluate::<String>(
        &runtime,
        &format!(
            "const pane = new AbortController();
             const opening = sessions.open('{}', {{ tail: 5, signal: pane.signal, update: () => undefined }});
             pane.abort(new Error('the pane closed'));
             try {{ await opening; return 'opened'; }} catch (error) {{ return error.message; }}",
            session()
        ),
    )
    .await
    .unwrap();

    assert_eq!(opened, "the pane closed");
    assert_eq!(scripted.released.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn the_stop_of_the_plugin_ends_its_handles() {
    let scripted = Arc::new(Scripted::default());
    let runtime = started("the_stop_of_the_plugin_ends_its_handles", &scripted).await;

    // The own signal of the handle does not replace the signal of the plugin.
    open(&runtime, "new AbortController().signal").await;
    let signal = evaluate::<bool>(&runtime, "globalThis.signal = handle.signal; return signal.aborted;")
        .await
        .unwrap();
    runtime.close_plugins().await.unwrap();
    let ended = evaluate::<bool>(&runtime, "return signal.aborted;").await.unwrap();

    assert!(!signal && ended);
    assert_eq!(scripted.released.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn the_close_of_the_session_ends_each_handle_on_it() {
    let scripted = Arc::new(Scripted::default());
    let runtime = started("the_close_of_the_session_ends_each_handle_on_it", &scripted).await;
    open(&runtime, "undefined").await;

    evaluate::<()>(
        &runtime,
        "globalThis.other = await sessions.open(handle.id, { tail: 5, update: () => undefined });
         await sessions.close(handle.id);",
    )
    .await
    .unwrap();
    wait_until(&runtime, "return handle.signal.aborted && other.signal.aborted;").await;
    let reason = evaluate::<String>(&runtime, "return handle.signal.reason.message;")
        .await
        .unwrap();
    let input = evaluate::<String>(
        &runtime,
        "try { await other.input([]); return 'sent'; } catch (error) { return error.message; }",
    )
    .await
    .unwrap();

    assert_eq!(reason, format!("the session {} closed", session()));
    assert_eq!(input, format!("the handle of the session {} has ended", session()));
    assert_eq!(scripted.released.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn the_requests_reach_the_consumer_with_the_arguments_of_the_plugin() {
    let scripted = Arc::new(Scripted::default());
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
             const input = await handle.input([{{ user_text: 'hi' }}]);
             await handle.notify('shown', 'told');
             handle.cancel();
             await sessions.fork(id);
             await sessions.events(id, {{ limit: 3 }});
             await sessions.list();
             await catalog.list();
             await sessions.close(id, {{ stopJobs: true }});
             return JSON.stringify([input]);",
            session()
        ),
    )
    .await
    .unwrap();

    let id = session();
    assert_eq!(answers, "[3]");
    assert_eq!(
        scripted.calls()[1..],
        [
            format!("input {id} user {:?} [{{\"user_text\":\"hi\"}}]", InputKind::Message),
            format!(
                "input {id} test {:?} [{{\"user_text\":\"<system_notification plugin=\\\"test\\\">told</system_notification>\"}}]",
                InputKind::Notification
            ),
            format!("cancel {id}"),
            format!("fork {id} None"),
            format!("events {id} None 3"),
            "list None".to_owned(),
            "catalog false".to_owned(),
            format!("close {id} true"),
        ]
    );
}

#[tokio::test]
async fn a_failed_request_rejects_with_the_text_of_its_failure() {
    let scripted = Arc::new(Scripted::default());
    let runtime = started("a_failed_request_rejects_with_the_text_of_its_failure", &scripted).await;
    open(&runtime, "undefined").await;

    let failures = evaluate::<String>(
        &runtime,
        "const failures = [];
         try { await sessions.get(handle.id); } catch (error) { failures.push(error.message); }
         try { handle.respond(4, { kind: 'canceled' }); } catch (error) { failures.push(error.message); }
         return JSON.stringify(failures);",
    )
    .await
    .unwrap();

    assert_eq!(
        failures,
        format!(r#"["no session {}","no open question 4"]"#, session())
    );
}
