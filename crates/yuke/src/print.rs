//! `yuke -p`: one turn with no view. A run opens or creates a session, runs one turn with the built-in tools, and
//! answers how the turn ended and the text of the last answer. It drives the session through the app, as the protocol
//! server does.

use std::path::Path;
use std::sync::{Arc, Mutex};

use tokio::sync::Notify;
use yuke_agent::{Session, StoreError};
use yuke_ai::catalog::{Entry, ReasoningLevel};
use yuke_ai::{Block, Role};
use yuke_engine::{CancellationToken, Outcome, TurnEnd};
use yuke_protocol::{
    LiveUpdate, ModelReference, NoticeLevel, ServerNotification, SessionEvent, SessionId, SessionSettings,
    SessionState, SessionUpdate, StoredEvent,
};

use crate::app::{App, Jobs, Machine, Observer, describe, lock, warn};
use crate::config::Config;
use crate::providers::Providers;

/// What one run of `yuke -p` does.
#[derive(Debug, PartialEq)]
pub(crate) struct Task {
    /// The input of the turn.
    pub(crate) prompt: String,
    /// The model as `provider/model`. For an existing session, it replaces the model of the session.
    pub(crate) model: Option<String>,
    /// The reasoning level. For an existing session, it replaces the level of the session.
    pub(crate) reasoning: Option<ReasoningLevel>,
    /// The session of the turn.
    pub(crate) session: SessionChoice,
}

/// The session that a run continues.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SessionChoice {
    /// A new session in the current folder.
    New,
    /// The session with this id.
    Id(SessionId),
    /// The session of the current folder with the newest event.
    Newest,
}

/// A run that reached its turn.
#[derive(Debug, PartialEq)]
pub(crate) struct Finished {
    /// The session of the turn.
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
    let config_path = machine.paths.config.join("config.json");
    let watcher = Arc::new(Watcher::default());
    let mut app = App::start(machine, Jobs::Refused, Arc::clone(&watcher) as Arc<dyn Observer>).await?;
    // The shutdown must also run after an error.
    let finished = run_turn(task, &mut app, cwd, &config_path, &watcher, &cancellation_token).await;
    app.shutdown().await;
    finished
}

/// Open the session of `task` in `cwd`, run its turn, and close the session. A new session reads its model from the
/// config file `config_path`.
async fn run_turn(
    task: &Task,
    app: &mut App,
    cwd: &Path,
    config_path: &Path,
    watcher: &Watcher,
    cancellation_token: &CancellationToken,
) -> Result<Finished, String> {
    let id = match task.session {
        SessionChoice::New => {
            // Only a new session reads the config, so a broken config does not block a continued session.
            let config = Config::load(config_path)?;
            let selector = task.model.as_deref().or(config.model.as_deref()).ok_or_else(|| {
                format!(
                    "no model: pass --model <provider/model>, or set \"model\" in {}",
                    config_path.display()
                )
            })?;
            let settings = new_settings(task, app.providers(), selector, cwd)?;
            app.create(settings).await.map_err(|error| describe(&error))?
        }
        SessionChoice::Id(id) => existing_session(task, id, app).await?,
        SessionChoice::Newest => {
            let id = app
                .store()
                .newest_session(cwd)
                .await
                .map_err(|error| describe(&error))?
                .ok_or_else(|| format!("no session works in {}", cwd.display()))?;
            existing_session(task, id, app).await?
        }
    };

    let input_id = app
        .input(id, vec![Block::user_text(&task.prompt)])
        .await
        .map_err(|error| describe(&error))?;
    tokio::select! {
        () = watcher.ended.notified() => {}
        () = cancellation_token.cancelled() => {}
    }
    // The close cancels a running turn, and that turn saves its end before the close returns.
    app.close(id, true).await.map_err(|error| describe(&error))?;
    let watched = std::mem::take(&mut *lock(&watcher.watched));
    // A cancel before the turn leaves the input pending, and a later run must not answer it. After a failure, the input
    // stays for a later run.
    if cancellation_token.is_cancelled() && !watched.ran {
        app.store()
            .remove_input(id, input_id)
            .await
            .map_err(|error| describe(&error))?;
    }

    let end = match (watched.end, watched.failure) {
        (Some(end), _) => end,
        (None, Some(failure)) => TurnEnd::Failed(failure),
        (None, None) if cancellation_token.is_cancelled() => TurnEnd::Outcome(Outcome::Cancelled),
        (None, None) => TurnEnd::Failed("the turn saved no end".to_owned()),
    };
    Ok(Finished {
        session: id,
        end,
        text: answer_text(&watched.blocks),
    })
}

/// The settings of a new session in `cwd` with the model `selector` of `providers`. The app writes the system prompt.
fn new_settings(task: &Task, providers: &Providers, selector: &str, cwd: &Path) -> Result<SessionSettings, String> {
    let entry = providers
        .lookup(selector)
        .map_err(|error| format!("{selector}: {error}"))?;
    Ok(SessionSettings {
        model: ModelReference {
            provider: entry.provider.id.to_string(),
            model: entry.model.id.to_string(),
        },
        settings: yuke_ai::Settings {
            reasoning: reasoning(&entry, task.reasoning)?,
            ..yuke_ai::Settings::new()
        },
        cwd: cwd.to_owned(),
    })
}

/// Open session `id` in `app`. A model or a level of `task` replaces the one of the session with a settings event; a
/// new model without a level takes the default level.
async fn existing_session(task: &Task, id: SessionId, app: &mut App) -> Result<SessionId, String> {
    let mut session = Session::open(Arc::clone(app.store()), id)
        .await
        .map_err(|error| match error {
            StoreError::NotFound => format!("no session has the id {id}"),
            other => describe(&other),
        })?;
    if task.model.is_some() || task.reasoning.is_some() {
        let mut settings = session.settings().clone();
        let selector = match &task.model {
            Some(model) => model.clone(),
            None => format!("{}/{}", settings.model.provider, settings.model.model),
        };
        let entry = app
            .providers()
            .lookup(&selector)
            .map_err(|error| format!("{selector}: {error}"))?;
        settings.model = ModelReference {
            provider: entry.provider.id.to_string(),
            model: entry.model.id.to_string(),
        };
        settings.settings.reasoning = reasoning(&entry, task.reasoning)?;
        // The credential comes first, so a model that cannot run saves no settings.
        app.check_model(&settings).map_err(|error| describe(&error))?;
        session.set_settings(settings).await.map_err(|error| describe(&error))?;
    }
    app.open(session).await.map_err(|error| describe(&error))
}

/// The reasoning settings of `level` on the model of `entry`. No level leaves the default of the endpoint.
fn reasoning(entry: &Entry<'_>, level: Option<ReasoningLevel>) -> Result<yuke_ai::ReasoningSettings, String> {
    let Some(level) = level else {
        return Ok(yuke_ai::ReasoningSettings::default());
    };
    entry
        .model
        .reasoning(level)
        .map_err(|error| format!("{}/{}: {error}", entry.provider.id, entry.model.id))
}

/// The text of the last answer: the text blocks of the last run of assistant blocks.
fn answer_text(context: &[Block]) -> String {
    // A cancel after a tool call saves error results after the answer. A tool result has the user role.
    let end = context
        .iter()
        .rposition(|block| block.role() == Role::Assistant)
        .map_or(0, |last| last + 1);
    let start = context[..end]
        .iter()
        .rposition(|block| block.role() != Role::Assistant)
        .map_or(0, |last| last + 1);
    let texts: Vec<&str> = context[start..end]
        .iter()
        .filter_map(|block| match block {
            Block::AssistantText(text) => Some(text.as_str()),
            _ => None,
        })
        .collect();
    texts.join("\n")
}

/// Keeps what a run needs from the notifications of its session: the saved blocks of the turn, its end, and a
/// failure. Other notices go to stderr.
#[derive(Default)]
struct Watcher {
    watched: Mutex<Watched>,
    /// Wakes the run when the turn ends, or when a failure stops the session before its turn.
    ended: Notify,
}

#[derive(Default)]
struct Watched {
    /// Whether a turn started.
    ran: bool,
    blocks: Vec<Block>,
    end: Option<TurnEnd>,
    failure: Option<String>,
}

impl Observer for Watcher {
    fn notify(&self, notification: ServerNotification) {
        match notification {
            ServerNotification::SessionUpdate(params) => match params.update {
                SessionUpdate::Saved(StoredEvent {
                    event: SessionEvent::Commit { commit, .. },
                    ..
                }) => {
                    let mut watched = lock(&self.watched);
                    // A replacement starts the context again, and the answer comes after it.
                    if commit.replaced.is_some() {
                        watched.blocks.clear();
                    }
                    watched.blocks.extend(commit.blocks.into_owned());
                    if commit.end.is_some() {
                        watched.end = commit.end;
                    }
                }
                SessionUpdate::Live(LiveUpdate::State {
                    state: SessionState::Running,
                }) => lock(&self.watched).ran = true,
                SessionUpdate::Live(LiveUpdate::State {
                    state: SessionState::Idle,
                }) => self.ended.notify_one(),
                _ => {}
            },
            ServerNotification::Notice(notice) if notice.session_id.is_some() && notice.level == NoticeLevel::Error => {
                lock(&self.watched).failure = Some(notice.message);
                self.ended.notify_one();
            }
            ServerNotification::Notice(notice) => warn(&notice.message),
        }
    }
}

#[cfg(test)]
mod tests;
