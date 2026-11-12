//! `yuke -p`: one turn with no view. A run opens or creates a session, runs one turn with the built-in tools, and
//! answers how the turn ended and the text of the last answer. It drives the session through the app, as the protocol
//! server does.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;
use std::rc::Rc;

use serde::Serialize;
use tokio::sync::Notify;
use yuke_agent::{Store, StoreError};
use yuke_ai::Block;
use yuke_engine::{CancellationToken, TurnEnd, answer_text, chain_text};
use yuke_protocol::{
    Input, InputKind, InputSource, LiveUpdate, ModelReference, NoticeLevel, NoticeParams, ReasoningLevel,
    ServerNotification, SessionEvent, SessionId, SessionSettings, SessionState, SessionUpdate, SessionUpdateParams,
    StoredEvent,
};

use crate::app::{App, AppError, Machine, Mode, Observer, SOURCE, TokioTimer, open_store, warn};
use crate::providers::Providers;

/// What one run of `yuke -p` does.
#[derive(Debug, PartialEq)]
pub(crate) struct Task {
    /// The input of the turn.
    pub(crate) prompt: String,
    /// The model as `provider/model`. A new session needs it. For an existing session, it replaces the model of the
    /// session, and the run then needs a reasoning choice too.
    pub(crate) model: Option<String>,
    /// The reasoning choice. A new session needs it. For an existing session, it replaces the level of the session.
    pub(crate) reasoning: Option<ReasoningLevel>,
    /// The session of the turn.
    pub(crate) session: SessionChoice,
}

/// The session that a run or the terminal interface opens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SessionChoice {
    /// A new session in the current folder.
    New,
    /// The session with this id.
    Id(SessionId),
    /// The session without a parent of the current folder with the newest event.
    Newest,
}

/// Find the session without a parent of `cwd` with the newest event.
///
/// # Errors
///
/// Returns a text for the user when `cwd` has no session, or when the store fails.
pub(crate) async fn newest_session(store: &dyn Store, cwd: &Path) -> Result<SessionId, String> {
    let page = store
        .list_sessions(Some(cwd), None, None, 1)
        .await
        .map_err(|error| chain_text(&error))?;
    page.sessions
        .first()
        .map(|session| session.session_id)
        .ok_or_else(|| format!("no session works in {}", cwd.display()))
}

/// A run that reached its turn. With `--json`, yuke writes this value.
#[derive(Debug, PartialEq, Serialize)]
pub(crate) struct Finished {
    /// The session of the turn.
    #[serde(rename = "sessionId")]
    pub(crate) session: SessionId,
    /// How the turn ended.
    pub(crate) end: TurnEnd,
    /// The text of the last answer of the model.
    pub(crate) text: String,
}

/// Run `task` on `machine`, in the current folder `cwd` without links. A cancel of `cancellation_token` stops the
/// turn. An error before the turn is a text for the user.
pub(crate) async fn run(
    task: &Task,
    machine: Machine,
    cwd: &Path,
    cancellation_token: CancellationToken,
) -> Result<Finished, String> {
    let watcher = Rc::new(Watcher::default());
    let store = open_store(&machine.paths.data).await?;
    let app = App::start(
        machine,
        Mode::Print,
        Rc::clone(&watcher) as Rc<dyn Observer>,
        store,
        Rc::new(TokioTimer),
    )
    .await?;
    // The shutdown must also run after an error.
    let finished = run_turn(task, &app, cwd, &watcher, &cancellation_token).await;
    app.shutdown().await;
    finished
}

/// Open the session of `task` in `cwd`, run its turn, and close the session.
async fn run_turn(
    task: &Task,
    app: &App,
    cwd: &Path,
    watcher: &Watcher,
    cancellation_token: &CancellationToken,
) -> Result<Finished, String> {
    let id = match task.session {
        SessionChoice::New => {
            let selector = task.model.as_deref().ok_or("no model: pass --model <provider/model>")?;
            let choice = task.reasoning.ok_or(NO_REASONING)?;
            let settings = new_settings(&app.providers(), selector, choice, cwd)?;
            app.sessions()
                .create(settings, None)
                .await
                .map_err(|error| chain_text(&error))?
        }
        SessionChoice::Id(id) => existing_session(task, id, app).await?,
        SessionChoice::Newest => existing_session(task, newest_session(app.store(), cwd).await?, app).await?,
    };

    let input_id = app
        .sessions()
        .input(
            id,
            Input::new(
                InputSource::User,
                InputKind::Message,
                vec![Block::user_text(&task.prompt)],
            )
            .map_err(|error| chain_text(&error))?,
        )
        .await
        .map_err(|error| chain_text(&error))?;
    // A wake can come from another session, for example a session of a plugin, so the run checks its own.
    while !watcher.has_ended(id) {
        tokio::select! {
            () = watcher.ended.notified() => {}
            () = cancellation_token.cancelled() => break,
        }
    }
    // The close cancels a running turn, and that turn saves its end before the close returns.
    app.sessions().close(id).await.map_err(|error| chain_text(&error))?;
    let watched = watcher.watched.borrow_mut().remove(&id).unwrap_or_default();
    // A cancel before the turn leaves the input pending, and a later run must not answer it. After a failure, the input
    // stays for a later run.
    if cancellation_token.is_cancelled() && !watched.ran {
        app.store()
            .remove_input(id, input_id)
            .await
            .map_err(|error| chain_text(&error))?;
    }

    let end = match (watched.end, watched.failure) {
        (Some(end), _) => end,
        (None, Some(failure)) => TurnEnd::Failed { error: failure },
        (None, None) if cancellation_token.is_cancelled() => TurnEnd::Cancelled,
        // A plugin denied or handled the input, so no turn ran.
        (None, None) if watched.removed => TurnEnd::Stopped,
        (None, None) => TurnEnd::Failed {
            error: "the turn saved no end".to_owned(),
        },
    };
    Ok(Finished {
        session: id,
        end,
        text: answer_text(&watched.blocks),
    })
}

/// The error of a run that needs a reasoning choice and has none.
const NO_REASONING: &str =
    "no reasoning choice: pass --reasoning <choice>, or --reasoning default to let the endpoint choose";

/// The settings of a new session in `cwd` with the model `selector` of `providers` and the reasoning `choice`. The app
/// builds the system prompt.
fn new_settings(
    providers: &Providers,
    selector: &str,
    choice: ReasoningLevel,
    cwd: &Path,
) -> Result<SessionSettings, String> {
    let (model, reasoning) = choose(providers, selector, choice)?;
    Ok(SessionSettings {
        model,
        settings: yuke_ai::RequestSettings {
            reasoning,
            ..yuke_ai::RequestSettings::new()
        },
        cwd: cwd.to_owned(),
    })
}

/// Open session `id` in `app`. A model or a level of `task` replaces the one of the session with a settings event. A
/// new model needs a reasoning choice too, because the level of the session may not fit it.
async fn existing_session(task: &Task, id: SessionId, app: &App) -> Result<SessionId, String> {
    if task.model.is_some() && task.reasoning.is_none() {
        return Err(NO_REASONING.to_owned());
    }
    let changed = |saved: &SessionSettings, providers: &Providers| {
        let Some(choice) = task.reasoning else {
            return Ok(None);
        };
        let selector = match &task.model {
            Some(model) => model.clone(),
            None => format!("{}/{}", saved.model.provider, saved.model.model),
        };
        let (model, reasoning) = choose(providers, &selector, choice).map_err(AppError::Invalid)?;
        let mut settings = saved.clone();
        settings.model = model;
        settings.settings.reasoning = reasoning;
        Ok(Some(settings))
    };
    match app.sessions().open(id, changed).await {
        Ok(()) => Ok(id),
        Err(AppError::Store(StoreError::NotFound)) => Err(format!("no session has the id {id}")),
        Err(error) => Err(chain_text(&error)),
    }
}

/// Find the model of `selector` in `providers`. Give its reference and the reasoning settings of `choice` for that model.
fn choose(
    providers: &Providers,
    selector: &str,
    choice: ReasoningLevel,
) -> Result<(ModelReference, yuke_ai::ReasoningSettings), String> {
    let entry = providers
        .lookup(selector)
        .map_err(|error| format!("{selector}: {error}"))?;
    let level = match choice {
        ReasoningLevel::Default => None,
        ReasoningLevel::Off => Some(yuke_ai::catalog::ReasoningLevel::Off),
        ReasoningLevel::Effort(effort) => Some(yuke_ai::catalog::ReasoningLevel::Effort(effort)),
    };
    let reasoning = match level {
        Some(level) => entry
            .model
            .reasoning(level)
            .map_err(|error| format!("{}/{}: {error}", entry.provider.id, entry.model.id))?,
        None => yuke_ai::ReasoningSettings::default(),
    };
    let model = ModelReference {
        provider: entry.provider.id.to_string(),
        model: entry.model.id.to_string(),
    };
    Ok((model, reasoning))
}

/// Keeps what a run needs from the notifications of each session: the saved blocks of the turn, its end, and a
/// failure: an error notice of yuke for the session. Other notices, also those of plugins, go to stderr.
#[derive(Default)]
struct Watcher {
    watched: RefCell<HashMap<SessionId, Watched>>,
    /// Wakes the run when a turn ends, or when a failure stops a session before its turn.
    ended: Notify,
}

impl Watcher {
    /// Whether the turn of session `id` ended, or a failure stopped the session.
    fn has_ended(&self, id: SessionId) -> bool {
        self.watched.borrow().get(&id).is_some_and(|watched| watched.ended)
    }

    /// Change what the watcher keeps of session `id`.
    fn change(&self, id: SessionId, change: impl FnOnce(&mut Watched)) {
        change(self.watched.borrow_mut().entry(id).or_default());
    }
}

#[derive(Default)]
struct Watched {
    /// Whether the turn ended, or a failure stopped the session.
    ended: bool,
    /// Whether a turn started.
    ran: bool,
    /// Whether an `input.before` hook removed the input.
    removed: bool,
    blocks: Vec<Block>,
    end: Option<TurnEnd>,
    failure: Option<String>,
}

impl Observer for Watcher {
    fn notify(&self, notification: ServerNotification) {
        match notification {
            ServerNotification::SessionUpdate(params) => {
                let SessionUpdateParams { session_id, update } = *params;
                match update {
                    SessionUpdate::Saved(StoredEvent {
                        event: SessionEvent::Commit { commit, .. },
                        ..
                    }) => self.change(session_id, |watched| {
                        // A replacement starts the context again, and the answer comes after it.
                        if commit.replaced.is_some() {
                            watched.blocks.clear();
                        }
                        watched.blocks.extend(commit.blocks.into_owned());
                        if commit.end.is_some() {
                            watched.end = commit.end;
                        }
                    }),
                    SessionUpdate::Live(LiveUpdate::State {
                        state: SessionState::Running,
                    }) => self.change(session_id, |watched| watched.ran = true),
                    SessionUpdate::Live(LiveUpdate::InputRemoved { .. }) => {
                        self.change(session_id, |watched| watched.removed = true);
                    }
                    SessionUpdate::Live(LiveUpdate::State {
                        state: SessionState::Idle,
                    }) => {
                        self.change(session_id, |watched| watched.ended = true);
                        self.ended.notify_one();
                    }
                    _ => {}
                }
            }
            ServerNotification::Notice(NoticeParams {
                session_id: Some(session_id),
                level: NoticeLevel::Error,
                source,
                text,
            }) if source == SOURCE => {
                self.change(session_id, |watched| {
                    watched.failure = Some(text);
                    watched.ended = true;
                });
                self.ended.notify_one();
            }
            ServerNotification::Notice(notice) => warn(&format!("{}: {}", notice.source, notice.text)),
            // A run has no client for the events of plugins, and it starts no login of `auth/login`.
            ServerNotification::ExtensionEvent(_)
            | ServerNotification::ExtensionCancel(_)
            | ServerNotification::LoginFinished(_) => {}
        }
    }
}

#[cfg(test)]
mod tests;
