use yuke_ai::Block;
use yuke_ai::transport::Transport;
use yuke_js::ViewEvent;
use yuke_protocol::{
    EventNumber, Input, InputKind, InputSource, ListSessionsParams, ModelReference, SessionSettings, SessionUpdate,
};
use yuke_testing::{ScriptedTransport, Stalled, text_reply, tool_reply};

use super::*;
use crate::app::{App, Mode, Observer};
use crate::testing::{Place, with_key};

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
    App::start(machine, Mode::Server, Arc::new(Silent)).await.unwrap()
}

/// The number of the countdown of the open session `id`.
fn countdown(sessions: &SessionService, id: SessionId) -> u64 {
    match lock(&sessions.registry).slots.get(&id) {
        Some(Slot::Open(open)) => open.countdown,
        _ => panic!("the session {id} is not open"),
    }
}

/// The longest real wait for work on the other threads: the store, the plugins, and the jobs.
const REAL: Duration = Duration::from_secs(10);

/// Wait until `ready` holds, and fail with `what` after [`REAL`]. The paused clock does not advance meanwhile.
async fn until(what: &str, ready: impl Fn() -> bool) {
    let end = std::time::Instant::now() + REAL;
    while !ready() {
        assert!(std::time::Instant::now() < end, "{what}");
        tokio::task::yield_now().await;
    }
}

/// Wait until a countdown closes session `id`: it starts the close within `within` of the paused clock, and the close
/// ends within [`REAL`].
async fn closed(sessions: &SessionService, id: SessionId, within: Duration) {
    let end = tokio::time::Instant::now() + within;
    while sessions.live(id).is_ok() {
        assert!(
            tokio::time::Instant::now() < end,
            "the session {id} did not close within {within:?}"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let end = std::time::Instant::now() + REAL;
    while lock(&sessions.registry).slots.contains_key(&id) {
        assert!(
            std::time::Instant::now() < end,
            "the close of the session {id} did not end"
        );
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

/// Drop `attachment` of session `id`, and wait until its countdown starts.
async fn release(sessions: &SessionService, id: SessionId, attachment: Attachment) {
    let number = countdown(sessions, id);
    drop(attachment);
    until("no countdown starts", || countdown(sessions, id) != number).await;
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
        settings: yuke_ai::Settings::new(),
        cwd: place.work.clone(),
    }
}

async fn saved(sessions: &SessionService) -> usize {
    sessions
        .list(ListSessionsParams {
            cwd: None,
            limit: None,
            cursor: None,
        })
        .await
        .unwrap()
        .sessions
        .len()
}

#[tokio::test]
async fn a_reserved_session_refuses_other_calls_until_the_reservation_drops() {
    let place = Place::new(
        "sessions",
        "a_reserved_session_refuses_other_calls_until_the_reservation_drops",
    );
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place)).await.unwrap();
    sessions.close(id, true).await.unwrap();

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

#[tokio::test]
async fn no_session_opens_or_closes_during_a_reload() {
    let place = Place::new("sessions", "no_session_opens_or_closes_during_a_reload");
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place)).await.unwrap();
    let closed = sessions.create(settings(&place)).await.unwrap();
    sessions.close(closed, true).await.unwrap();

    let reload = sessions.start_reload().unwrap();
    let close = sessions.close(id, true).await;
    let load = sessions.load(closed, None).await;
    let create = sessions.create(settings(&place)).await;
    let during = saved(sessions).await;
    drop(reload);

    assert!(matches!(close, Err(AppError::Reloading)));
    assert!(matches!(load, Err(AppError::Reloading)));
    assert!(matches!(create, Err(AppError::Reloading)));
    assert_eq!(during, 2);
    sessions.close(id, true).await.unwrap();
    app.shutdown().await;
}

#[tokio::test]
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

#[tokio::test]
async fn after_the_shutdown_starts_no_session_opens() {
    let place = Place::new("sessions", "after_the_shutdown_starts_no_session_opens");
    let app = started(&place).await;
    let sessions = Arc::clone(app.sessions());
    let id = sessions.create(settings(&place)).await.unwrap();

    sessions.close_all().await;
    let closed = sessions.jobs(id);
    let create = sessions.create(settings(&place)).await;
    let load = sessions.load(id, None).await;

    assert!(matches!(closed, Err(AppError::NotOpen(_))));
    assert!(matches!(create, Err(AppError::Stopped)));
    assert!(matches!(load, Err(AppError::Stopped)));
    assert_eq!(saved(&sessions).await, 1);
    app.shutdown().await;
}

#[tokio::test]
async fn a_session_without_a_holder_closes_after_the_grace() {
    let place = Place::new("sessions", "a_session_without_a_holder_closes_after_the_grace");
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place)).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    tokio::time::pause();

    release(sessions, id, attachment).await;
    tokio::time::sleep(GRACE.saturating_sub(Duration::from_secs(1))).await;
    let before_the_grace = sessions.live(id).is_ok();
    closed(sessions, id, Duration::from_secs(2)).await;

    assert!(before_the_grace);
    app.shutdown().await;
}

#[tokio::test]
async fn a_session_that_nobody_attaches_closes_after_the_grace() {
    let place = Place::new("sessions", "a_session_that_nobody_attaches_closes_after_the_grace");
    let app = started(&place).await;
    let sessions = app.sessions();
    tokio::time::pause();

    let id = sessions.create(settings(&place)).await.unwrap();
    tokio::time::sleep(GRACE.saturating_sub(Duration::from_secs(1))).await;
    let before_the_grace = sessions.live(id).is_ok();
    closed(sessions, id, Duration::from_secs(2)).await;

    assert!(before_the_grace);
    app.shutdown().await;
}

#[tokio::test]
async fn a_session_with_a_holder_stays_open_after_its_turn() {
    let place = Place::new("sessions", "a_session_with_a_holder_stays_open_after_its_turn");
    let transport = ScriptedTransport::new([text_reply("Hello.")]);
    let app = started_with(&place, Box::new(transport.clone())).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place)).await.unwrap();
    let attachment = sessions.attach(id).unwrap();

    sessions.input(id, said("Hi.")).await.unwrap();
    // The first turn waits for the plugins on their own thread, so the clock pauses after the turn.
    while transport.requests().is_empty() || sessions.live(id).unwrap().state() == SessionState::Running {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    tokio::time::pause();
    tokio::time::sleep(GRACE * 4).await;

    assert!(sessions.live(id).is_ok());
    drop(attachment);
    app.shutdown().await;
}

#[tokio::test]
async fn a_view_ends_at_the_close_of_its_session_and_a_new_open_does_not_reach_it() {
    let place = Place::new(
        "sessions",
        "a_view_ends_at_the_close_of_its_session_and_a_new_open_does_not_reach_it",
    );
    let transport = ScriptedTransport::new([text_reply("Hello.")]);
    let app = started_with(&place, Box::new(transport.clone())).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place)).await.unwrap();
    let events = Arc::new(Mutex::new(Vec::new()));
    let kept = Arc::clone(&events);
    let view = sessions
        .view(id, 1, Arc::new(move |event| lock(&kept).push(event)))
        .await
        .unwrap();

    sessions.close(id, false).await.unwrap();
    let at_the_close = lock(&events).len();
    sessions.open(id, |_, _| Ok(None)).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    sessions.input(id, said("Hi.")).await.unwrap();
    sessions.idle(id).await.unwrap();
    drop(view);

    let events = std::mem::take(&mut *lock(&events));
    assert_eq!(events.len(), at_the_close);
    assert!(matches!(events.last(), Some(ViewEvent::Closed)), "{events:?}");
    assert_eq!(transport.requests().len(), 1);
    drop(attachment);
    app.shutdown().await;
}

// The input leaves the session idle until its task wakes, so only the count of the accepted inputs makes idle wait.
#[tokio::test]
async fn idle_waits_for_the_turn_of_an_input_that_came_before_it() {
    let place = Place::new("sessions", "idle_waits_for_the_turn_of_an_input_that_came_before_it");
    let transport = ScriptedTransport::new([text_reply("Hello.")]);
    let app = started_with(&place, Box::new(transport.clone())).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place)).await.unwrap();
    let attachment = sessions.attach(id).unwrap();

    sessions.input(id, said("Hi.")).await.unwrap();
    sessions.idle(id).await.unwrap();

    assert_eq!(transport.requests().len(), 1);
    assert_eq!(sessions.live(id).unwrap().state(), SessionState::Idle);
    drop(attachment);
    app.shutdown().await;
}

#[tokio::test]
async fn an_attachment_during_the_countdown_keeps_the_session_open() {
    let place = Place::new("sessions", "an_attachment_during_the_countdown_keeps_the_session_open");
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place)).await.unwrap();
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

#[tokio::test]
async fn an_attachment_of_an_earlier_open_does_not_release_a_later_open() {
    let place = Place::new(
        "sessions",
        "an_attachment_of_an_earlier_open_does_not_release_a_later_open",
    );
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place)).await.unwrap();
    let earlier = sessions.attach(id).unwrap();
    sessions.close(id, true).await.unwrap();
    sessions.load(id, None).await.unwrap();
    let later = sessions.attach(id).unwrap();
    tokio::time::pause();

    drop(earlier);
    tokio::time::sleep(GRACE * 4).await;

    assert!(sessions.live(id).is_ok());
    drop(later);
    app.shutdown().await;
}

#[tokio::test]
async fn an_input_during_the_countdown_keeps_the_session_open_until_its_turn_ends() {
    let place = Place::new(
        "sessions",
        "an_input_during_the_countdown_keeps_the_session_open_until_its_turn_ends",
    );
    let app = started_with(&place, Box::new(Stalled)).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place)).await.unwrap();
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
    let number = countdown(sessions, id);
    sessions.cancel(id);
    until("no countdown starts", || countdown(sessions, id) != number).await;
    closed(sessions, id, GRACE + Duration::from_secs(1)).await;

    assert!(during_the_turn);
    app.shutdown().await;
}

#[tokio::test]
async fn a_countdown_that_ends_during_a_reload_starts_again() {
    let place = Place::new("sessions", "a_countdown_that_ends_during_a_reload_starts_again");
    let app = started(&place).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place)).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    tokio::time::pause();
    release(sessions, id, attachment).await;

    let reload = sessions.start_reload().unwrap();
    let number = countdown(sessions, id);
    tokio::time::sleep(GRACE + Duration::from_secs(1)).await;
    let restarted = countdown(sessions, id) != number;
    drop(reload);
    closed(sessions, id, GRACE + Duration::from_secs(1)).await;

    assert!(restarted);
    app.shutdown().await;
}

#[tokio::test]
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
    let id = sessions.create(settings(&place)).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    sessions.input(id, said("Start a job.")).await.unwrap();
    // The turn ends before the release, so the task reports once.
    while transport.requests().len() < 2 || sessions.live(id).unwrap().state() == SessionState::Running {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(pid.exists() && !sessions.jobs(id).unwrap().is_empty());
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

#[tokio::test]
async fn a_view_gets_the_last_events_and_the_next_turn_and_older_events_come_in_pages() {
    let place = Place::new(
        "sessions",
        "a_view_gets_the_last_events_and_the_next_turn_and_older_events_come_in_pages",
    );
    let transport = ScriptedTransport::new([text_reply("One."), text_reply("Two."), text_reply("Three.")]);
    let app = started_with(&place, Box::new(transport.clone())).await;
    let sessions = app.sessions();
    let id = sessions.create(settings(&place)).await.unwrap();
    let attachment = sessions.attach(id).unwrap();
    for (turn, text) in ["One?", "Two?"].into_iter().enumerate() {
        sessions.input(id, said(text)).await.unwrap();
        while transport.requests().len() <= turn || sessions.live(id).unwrap().state() == SessionState::Running {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
    let last = sessions.events_before(id, None, 1).await.unwrap()[0].event_number.0;
    let events = Arc::new(Mutex::new(Vec::new()));
    let kept = Arc::clone(&events);

    let view = sessions
        .view(id, 1, Arc::new(move |event| lock(&kept).push(event)))
        .await
        .unwrap();
    sessions.input(id, said("Three?")).await.unwrap();
    while transport.requests().len() < 3 || sessions.live(id).unwrap().state() == SessionState::Running {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let older = sessions.events_before(id, Some(EventNumber(last)), 100).await.unwrap();
    drop(view);

    let events = std::mem::take(&mut *lock(&events));
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
