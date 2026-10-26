use yuke_protocol::{ListSessionsParams, ModelReference, SessionSettings};
use yuke_testing::ScriptedTransport;

use super::*;
use crate::app::{App, Mode, Observer};
use crate::testing::{Place, with_key};

/// Drops each notification.
struct Silent;

impl Observer for Silent {
    fn notify(&self, _notification: ServerNotification) {}
}

async fn started(place: &Place) -> App {
    let machine = place.machine(Box::new(with_key), Box::new(ScriptedTransport::default()));
    App::start(machine, Mode::Server, Arc::new(Silent)).await.unwrap()
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
    let input = sessions.input(id, vec![Block::user_text("Hi.")]).await;
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
