use yuke_ai::Block;
use yuke_ai::scripted::{ScriptedTransport, Stalled, overloaded_reply, text_reply, tool_reply};
use yuke_ai::transport::Transport;
use yuke_js::ViewEvent;
use yuke_protocol::{
    EventNumber, Input, InputKind, InputSource, ListSessionsParams, ModelReference, SessionSettings, SessionUpdate,
};

use super::*;
use crate::app::{App, Mode, Observer, TokioTimer, open_store};
use crate::testing::{CountedWaits, Place, with_key};
use yuke_agent::StoreError;

/// Drops each notification.
struct Silent;

impl Observer for Silent {
    fn notify(&self, _notification: ServerNotification) {}
}

async fn started(place: &Place) -> App {
    started_with(place, Box::new(ScriptedTransport::default())).await
}

async fn started_with(place: &Place, transport: Box<dyn Transport>) -> App {
    let machine = place.machine(Box::new(with_key), transport);
    let store = open_store(&place.paths.data).await.unwrap();
    App::start(machine, Mode::Server, Rc::new(Silent), store, Rc::new(TokioTimer))
        .await
        .unwrap()
}

/// The idle deadline of the open session `id`, or `None` while a holder or turn keeps it open.
fn deadline(sessions: &SessionService, id: SessionId) -> Option<tokio::time::Instant> {
    match sessions.registry.borrow_mut().slots.get(&id) {
        Some(Slot::Open(open)) => open.deadline,
        _ => panic!("the session {id} is not open"),
    }
}

/// The longest real wait for work outside the runtime: the store thread and the job processes.
const REAL: Duration = Duration::from_secs(10);

/// Wait until `ready` holds, and fail with `what` after [`REAL`]. The paused clock does not advance meanwhile.
async fn until(what: &str, ready: impl Fn() -> bool) {
    let end = std::time::Instant::now() + REAL;
    while !ready() {
        assert!(std::time::Instant::now() < end, "{what}");
        tokio::task::yield_now().await;
    }
}

/// Wait until a countdown closes session `id`: move the paused clock on by `within`, so the countdown fires in that
/// time, then wait up to [`REAL`] for the close, which waits for the store thread in real time.
async fn closed(sessions: &SessionService, id: SessionId, within: Duration) {
    tokio::time::advance(within).await;
    let what = format!("the session {id} did not close within {within:?}");
    until(&what, || !sessions.registry.borrow_mut().slots.contains_key(&id)).await;
}

/// Drop `attachment` of session `id`, and wait until its countdown starts.
async fn release(sessions: &SessionService, id: SessionId, attachment: Attachment) {
    drop(attachment);
    until("no countdown starts", || deadline(sessions, id).is_some()).await;
}

/// A message of the user with `text`.
fn said(text: &str) -> Input {
    Input::new(InputSource::User, InputKind::Message, vec![Block::user_text(text)]).unwrap()
}

fn settings(place: &Place) -> SessionSettings {
    SessionSettings {
        model: ModelReference {
            provider: "minimax".to_owned(),
            model: "MiniMax-M3".to_owned(),
        },
        settings: yuke_ai::RequestSettings::new(),
        cwd: place.work.clone(),
    }
}

async fn saved(sessions: &SessionService) -> usize {
    sessions
        .list(ListSessionsParams {
            cwd: None,
            parent: None,
            limit: None,
            cursor: None,
        })
        .await
        .unwrap()
        .sessions
        .len()
}

#[tokio::test(flavor = "local")]
async fn a_rename_keeps_a_running_turn_and_also_works_after_the_session_closes() {
    let place = Place::new("sessions", "a_rename_keeps_a_running_turn");
    let app = started_with(&place, Box::new(Stalled)).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    sessions.input(id, said("Investigate login.")).await.unwrap();
    until("the turn did not start", || {
        sessions.live(id).unwrap().state() == SessionState::Running
    })
    .await;

    sessions
        .rename(id, SessionTitle::new("Login fix").unwrap())
        .await
        .unwrap();

    let running = sessions.get(id).await.unwrap();
    assert_eq!(running.session.title.as_deref(), Some("Login fix"));
    assert_eq!(running.state, SessionState::Running);
    sessions.close(id).await.unwrap();
    sessions
        .rename(id, SessionTitle::new("Saved login fix").unwrap())
        .await
        .unwrap();
    let closed = sessions.get(id).await.unwrap();
    assert_eq!(closed.session.title.as_deref(), Some("Saved login fix"));
    assert_eq!(closed.state, SessionState::Closed);
    drop(attachment);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_reserved_session_refuses_other_calls_until_the_reservation_drops() {
    let place = Place::new(
        "sessions",
        "a_reserved_session_refuses_other_calls_until_the_reservation_drops",
    );
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    sessions.close(id).await.unwrap();

    let opening = sessions.reserve(id).unwrap();
    let second = sessions.load(id, None).await;
    let input = sessions.input(id, said("Hi.")).await;
    drop(opening);
    let after = sessions.load(id, None).await;

    assert!(matches!(second, Err(AppError::Changing(changing)) if changing == id));
    assert!(matches!(input, Err(AppError::NotOpen(_))));
    after.unwrap();
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn no_session_opens_or_closes_during_a_reload() {
    let place = Place::new("sessions", "no_session_opens_or_closes_during_a_reload");
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let closed = sessions.create(settings(&place), None).await.unwrap();
    sessions.close(closed).await.unwrap();

    let reload = sessions.start_reload().unwrap();
    let close = sessions.close(id).await;
    let load = sessions.load(closed, None).await;
    let create = sessions.create(settings(&place), None).await;
    let during = saved(sessions).await;
    drop(reload);

    assert!(matches!(close, Err(AppError::Reloading)));
    assert!(matches!(load, Err(AppError::Reloading)));
    assert!(matches!(create, Err(AppError::Reloading)));
    assert_eq!(during, 2);
    sessions.close(id).await.unwrap();
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_reload_refuses_to_start_while_a_session_opens() {
    let place = Place::new("sessions", "a_reload_refuses_to_start_while_a_session_opens");
    let app = started(&place).await;
    let id = SessionId::generate();

    let opening = app.sessions().reserve(id).unwrap();
    let reload = app.sessions().start_reload().map(drop);
    drop(opening);

    assert!(matches!(reload, Err(AppError::Changing(changing)) if changing == id));
    app.sessions().start_reload().unwrap();
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn after_the_shutdown_starts_no_session_opens() {
    let place = Place::new("sessions", "after_the_shutdown_starts_no_session_opens");
    let app = started(&place).await;
    let sessions = Rc::clone(app.sessions());
    let id = sessions.create(settings(&place), None).await.unwrap();

    sessions.close_all().await;
    let closed = sessions.jobs(id);
    let create = sessions.create(settings(&place), None).await;
    let load = sessions.load(id, None).await;

    assert!(matches!(closed, Err(AppError::NotOpen(_))));
    assert!(matches!(create, Err(AppError::Stopped)));
    assert!(matches!(load, Err(AppError::Stopped)));
    assert_eq!(saved(&sessions).await, 1);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_session_without_a_holder_closes_after_the_grace() {
    let place = Place::new("sessions", "a_session_without_a_holder_closes_after_the_grace");
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    tokio::time::pause();

    release(sessions, id, attachment).await;
    tokio::time::sleep(GRACE.saturating_sub(Duration::from_secs(1))).await;
    let before_the_grace = sessions.live(id).is_ok();
    closed(sessions, id, Duration::from_secs(2)).await;

    assert!(before_the_grace);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_session_that_nobody_attaches_closes_after_the_grace() {
    let place = Place::new("sessions", "a_session_that_nobody_attaches_closes_after_the_grace");
    let app = started(&place).await;
    let sessions = app.sessions();
    tokio::time::pause();

    let id = sessions.create(settings(&place), None).await.unwrap();
    tokio::time::sleep(GRACE.saturating_sub(Duration::from_secs(1))).await;
    let before_the_grace = sessions.live(id).is_ok();
    closed(sessions, id, Duration::from_secs(2)).await;

    assert!(before_the_grace);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_session_with_a_holder_stays_open_after_its_turn() {
    let place = Place::new("sessions", "a_session_with_a_holder_stays_open_after_its_turn");
    let transport = ScriptedTransport::new([text_reply("Hello.")]);
    let app = started_with(&place, Box::new(transport.clone())).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let attachment = sessions.attach(id).unwrap();

    sessions.input(id, said("Hi.")).await.unwrap();
    // The first turn waits for the plugins to load, so the clock pauses after the turn.
    sessions.idle(id).await.unwrap();
    assert_eq!(
        (transport.requests().len(), sessions.live(id).unwrap().state()),
        (1, SessionState::Idle)
    );
    tokio::time::pause();
    tokio::time::sleep(GRACE * 4).await;

    assert!(sessions.live(id).is_ok());
    drop(attachment);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_view_ends_at_the_close_of_its_session_and_a_new_open_does_not_reach_it() {
    let place = Place::new(
        "sessions",
        "a_view_ends_at_the_close_of_its_session_and_a_new_open_does_not_reach_it",
    );
    let transport = ScriptedTransport::new([text_reply("Hello.")]);
    let app = started_with(&place, Box::new(transport.clone())).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let events = Rc::new(RefCell::new(Vec::new()));
    let kept = Rc::clone(&events);
    let view = sessions
        .view(id, 1, Rc::new(move |event| kept.borrow_mut().push(event)))
        .await
        .unwrap();

    sessions.close(id).await.unwrap();
    let at_the_close = events.borrow_mut().len();
    sessions.open(id, |_, _| Ok(None)).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    sessions.input(id, said("Hi.")).await.unwrap();
    sessions.idle(id).await.unwrap();
    drop(view);

    let events = std::mem::take(&mut *events.borrow_mut());
    assert_eq!(events.len(), at_the_close);
    assert!(matches!(events.last(), Some(ViewEvent::Closed)), "{events:?}");
    assert_eq!(transport.requests().len(), 1);
    drop(attachment);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_retry_of_the_model_request_of_a_turn_waits_with_the_timer_of_the_app() {
    let place = Place::new(
        "sessions",
        "a_retry_of_the_model_request_of_a_turn_waits_with_the_timer_of_the_app",
    );
    let transport = ScriptedTransport::new([overloaded_reply(), text_reply("Hello.")]);
    let timer = Rc::new(CountedWaits::default());
    let machine = place.machine(Box::new(with_key), Box::new(transport.clone()));
    let store = open_store(&place.paths.data).await.unwrap();
    let app = App::start(machine, Mode::Server, Rc::new(Silent), store, Rc::clone(&timer) as _)
        .await
        .unwrap();
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let attachment = sessions.attach(id).unwrap();

    sessions.input(id, said("Hi.")).await.unwrap();
    sessions.idle(id).await.unwrap();

    assert_eq!(transport.requests().len(), 2);
    assert_eq!(timer.count(), 1);
    drop(attachment);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn an_attachment_during_the_countdown_keeps_the_session_open() {
    let place = Place::new("sessions", "an_attachment_during_the_countdown_keeps_the_session_open");
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let first = sessions.attach(id).unwrap();
    tokio::time::pause();
    release(sessions, id, first).await;

    tokio::time::sleep(GRACE / 2).await;
    let second = sessions.attach(id).unwrap();
    tokio::time::sleep(GRACE * 4).await;

    assert!(sessions.live(id).is_ok());
    drop(second);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn an_attachment_of_an_earlier_open_does_not_release_a_later_open() {
    let place = Place::new(
        "sessions",
        "an_attachment_of_an_earlier_open_does_not_release_a_later_open",
    );
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let earlier = sessions.attach(id).unwrap();
    sessions.close(id).await.unwrap();
    sessions.load(id, None).await.unwrap();
    let later = sessions.attach(id).unwrap();
    tokio::time::pause();

    drop(earlier);
    tokio::time::sleep(GRACE * 4).await;

    assert!(sessions.live(id).is_ok());
    drop(later);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn an_input_during_the_countdown_keeps_the_session_open_until_its_turn_ends() {
    let place = Place::new(
        "sessions",
        "an_input_during_the_countdown_keeps_the_session_open_until_its_turn_ends",
    );
    let app = started_with(&place, Box::new(Stalled)).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    tokio::time::pause();
    release(sessions, id, attachment).await;
    tokio::time::sleep(GRACE / 2).await;

    // The save of the input waits for the store thread, and a paused clock would jump to the end of the countdown.
    tokio::time::resume();
    sessions.input(id, said("Hi.")).await.unwrap();
    until("no turn runs", || {
        sessions.live(id).unwrap().state() == SessionState::Running
    })
    .await;
    tokio::time::pause();
    tokio::time::sleep(GRACE * 2).await;
    let during_the_turn = sessions.live(id).is_ok();
    sessions.cancel(id);
    until("no countdown starts", || deadline(sessions, id).is_some()).await;
    closed(sessions, id, GRACE + Duration::from_secs(1)).await;

    assert!(during_the_turn);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_countdown_that_ends_during_a_reload_starts_again() {
    let place = Place::new("sessions", "a_countdown_that_ends_during_a_reload_starts_again");
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    tokio::time::pause();
    release(sessions, id, attachment).await;

    let reload = sessions.start_reload().unwrap();
    let before = deadline(sessions, id);
    tokio::time::sleep(GRACE + Duration::from_secs(1)).await;
    let restarted = deadline(sessions, id) != before;
    drop(reload);
    closed(sessions, id, GRACE + Duration::from_secs(1)).await;

    assert!(restarted);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_countdown_starts_when_idle_is_reported_not_when_its_task_first_runs() {
    let place = Place::new(
        "sessions",
        "a_countdown_starts_when_idle_is_reported_not_when_its_task_first_runs",
    );
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    tokio::time::pause();
    drop(attachment);

    // No yield separates the new countdown from the clock advance, so its task first runs after its deadline.
    sessions.report_idle(id);
    closed(sessions, id, GRACE + Duration::from_secs(1)).await;

    assert_eq!(sessions.get(id).await.unwrap().state, SessionState::Closed);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_repeated_idle_report_does_not_extend_the_countdown() {
    let place = Place::new("sessions", "a_repeated_idle_report_does_not_extend_the_countdown");
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    tokio::time::pause();
    release(sessions, id, attachment).await;
    tokio::time::advance(GRACE / 2).await;

    sessions.report_idle(id);
    closed(sessions, id, GRACE / 2 + Duration::from_secs(1)).await;

    assert_eq!(sessions.get(id).await.unwrap().state, SessionState::Closed);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_session_with_a_running_job_waits_the_idle_minutes_then_stops_the_job() {
    let place = Place::new(
        "sessions",
        "a_session_with_a_running_job_waits_the_idle_minutes_then_stops_the_job",
    );
    std::fs::create_dir_all(&place.paths.config).unwrap();
    std::fs::write(place.paths.config.join("config.json"), r#"{ "sessionIdleMinutes": 2 }"#).unwrap();
    let pid = place.work.join("pid");
    let command = format!(
        "echo $$ > {pid}.part && mv {pid}.part {pid} && exec sleep 3600",
        pid = pid.display()
    );
    let arguments = serde_json::json!({ "command": command, "background": true }).to_string();
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "exec", &arguments)]), text_reply("Started.")]);
    let app = started_with(&place, Box::new(transport.clone())).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    sessions.input(id, said("Start a job.")).await.unwrap();
    // The turn ends before the release, so the task reports once.
    sessions.idle(id).await.unwrap();
    assert_eq!(
        (transport.requests().len(), sessions.live(id).unwrap().state()),
        (2, SessionState::Idle)
    );
    // The shell of the job writes its pid after the turn can end.
    until("the job writes its pid", || pid.exists()).await;
    assert_eq!(sessions.jobs(id).unwrap().len(), 1);
    let process: u32 = std::fs::read_to_string(&pid).unwrap().trim().parse().unwrap();
    tokio::time::pause();

    release(sessions, id, attachment).await;
    tokio::time::sleep(Duration::from_secs(119)).await;
    let before_the_minutes = sessions.live(id).is_ok() && runs(process);
    closed(sessions, id, Duration::from_secs(2)).await;

    assert!(before_the_minutes);
    assert!(!runs(process));
    app.shutdown().await;
}

/// Whether the process `process` runs.
fn runs(process: u32) -> bool {
    std::process::Command::new("kill")
        .args(["-0", &process.to_string()])
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success()
}

#[tokio::test(flavor = "local")]
async fn a_view_gets_the_last_events_and_the_next_turn_and_older_events_come_in_pages() {
    let place = Place::new(
        "sessions",
        "a_view_gets_the_last_events_and_the_next_turn_and_older_events_come_in_pages",
    );
    let transport = ScriptedTransport::new([text_reply("One."), text_reply("Two."), text_reply("Three.")]);
    let app = started_with(&place, Box::new(transport.clone())).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place), None).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    for (turn, text) in ["One?", "Two?"].into_iter().enumerate() {
        sessions.input(id, said(text)).await.unwrap();
        sessions.idle(id).await.unwrap();
        assert_eq!(
            (transport.requests().len(), sessions.live(id).unwrap().state()),
            (turn + 1, SessionState::Idle)
        );
    }
    let last = sessions.events_before(id, None, 1).await.unwrap()[0].event_number.0;
    let events = Rc::new(RefCell::new(Vec::new()));
    let kept = Rc::clone(&events);

    let view = sessions
        .view(id, 1, Rc::new(move |event| kept.borrow_mut().push(event)))
        .await
        .unwrap();
    sessions.input(id, said("Three?")).await.unwrap();
    sessions.idle(id).await.unwrap();
    assert_eq!(
        (transport.requests().len(), sessions.live(id).unwrap().state()),
        (3, SessionState::Idle)
    );
    let older = sessions.events_before(id, Some(EventNumber(last)), 100).await.unwrap();
    drop(view);

    let events = std::mem::take(&mut *events.borrow_mut());
    let ViewEvent::Snapshot(snapshot) = &events[0] else {
        panic!("the first view event is no snapshot: {events:?}");
    };
    assert_eq!(snapshot.settings.cwd, settings(&place).cwd);
    let saved: Vec<u64> = snapshot
        .updates
        .iter()
        .filter_map(|update| match update {
            SessionUpdate::Saved(event) => Some(event.event_number.0),
            SessionUpdate::Live(_) => None,
        })
        .collect();
    assert_eq!(saved, [last]);
    let later: Vec<u64> = events[1..]
        .iter()
        .filter_map(|event| match event {
            ViewEvent::Update(SessionUpdate::Saved(event)) => Some(event.event_number.0),
            _ => None,
        })
        .collect();
    assert!(
        !later.is_empty() && later.iter().all(|number| *number > last),
        "{later:?}"
    );
    let older: Vec<u64> = older.iter().map(|event| event.event_number.0).collect();
    assert_eq!(older, (1..last).collect::<Vec<_>>());
    drop(attachment);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_removal_of_a_parent_removes_its_whole_tree() {
    let place = Place::new("sessions", "a_removal_of_a_parent_removes_its_whole_tree");
    let app = started(&place).await;
    let sessions = app.sessions();
    let parent = sessions.create(settings(&place), None).await.unwrap();
    let child = sessions.create(settings(&place), Some(parent)).await.unwrap();
    let grandchild = sessions.create(settings(&place), Some(child)).await.unwrap();
    let other = sessions.create(settings(&place), None).await.unwrap();
    for id in [parent, child, grandchild, other] {
        sessions.close(id).await.unwrap();
    }

    sessions.remove(parent).await.unwrap();

    for id in [parent, child, grandchild] {
        assert!(sessions.get(id).await.is_err(), "{id}");
    }
    assert!(sessions.get(other).await.is_ok());
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_removal_fails_while_a_session_of_the_tree_is_open_and_removes_nothing() {
    let place = Place::new("sessions", "a_removal_fails_while_a_session_of_the_tree_is_open");
    let app = started(&place).await;
    let sessions = app.sessions();
    let parent = sessions.create(settings(&place), None).await.unwrap();
    let first = sessions.create(settings(&place), Some(parent)).await.unwrap();
    let open = sessions.create(settings(&place), Some(first)).await.unwrap();
    sessions.close(parent).await.unwrap();
    sessions.close(first).await.unwrap();

    let refused = sessions.remove(parent).await;

    assert!(matches!(refused, Err(AppError::Open(id)) if id == open), "{refused:?}");
    for id in [parent, first, open] {
        assert!(sessions.get(id).await.is_ok(), "{id}");
    }
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_create_with_an_unknown_parent_fails_and_saves_nothing() {
    let place = Place::new("sessions", "a_create_with_an_unknown_parent_fails");
    let app = started(&place).await;
    let sessions = app.sessions();

    let refused = sessions.create(settings(&place), Some(SessionId::generate())).await;
    let listed = sessions.list(ListSessionsParams::default()).await.unwrap();

    assert!(
        matches!(refused, Err(AppError::Store(StoreError::NotFound))),
        "{refused:?}"
    );
    assert_eq!(listed.sessions.len(), 0);
    app.shutdown().await;
}

#[tokio::test(flavor = "local")]
async fn a_cursor_reads_only_in_the_list_of_its_parent() {
    let place = Place::new("sessions", "a_cursor_reads_only_in_the_list_of_its_parent");
    let app = started(&place).await;
    let sessions = app.sessions();
    let parent = sessions.create(settings(&place), None).await.unwrap();
    let older = sessions.create(settings(&place), Some(parent)).await.unwrap();
    let newer = sessions.create(settings(&place), Some(parent)).await.unwrap();
    let of_parent = |limit, cursor| ListSessionsParams {
        parent: Some(parent),
        limit,
        cursor,
        ..ListSessionsParams::default()
    };

    let first = sessions.list(of_parent(Some(1), None)).await.unwrap();
    let cursor = first.next_cursor.clone().unwrap();
    let second = sessions.list(of_parent(None, Some(cursor.clone()))).await.unwrap();
    let wrong = sessions
        .list(ListSessionsParams {
            cursor: Some(cursor),
            ..ListSessionsParams::default()
        })
        .await;

    let ids = |page: &ListSessionsResult| {
        page.sessions
            .iter()
            .map(|row| row.session.session_id)
            .collect::<Vec<_>>()
    };
    assert_eq!((ids(&first), ids(&second)), (vec![newer], vec![older]));
    assert!(matches!(wrong, Err(AppError::Invalid(_))), "{wrong:?}");
    app.shutdown().await;
}
