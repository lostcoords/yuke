//! `yuke -p`: one turn with no view. A run opens or creates a session, runs one turn with the built-in tools, and
//! answers how the turn ended and the text of the last answer.

use std::error::Error;
use std::ffi::OsString;
use std::hash::{BuildHasher, RandomState};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use async_trait::async_trait;
use tokio::sync::mpsc;
use yuke_agent::{Session, Store, StoreError};
use yuke_ai::catalog::{self, Auth, Entry, ReasoningLevel};
use yuke_ai::route::Credential;
use yuke_ai::transport::Transport;
use yuke_ai::{Block, Role, Target};
use yuke_engine::{CancellationToken, Driver, Timer, Toolset, TurnEnd};
use yuke_js::{Fault, JobEnded, Limits, Options, Processes, Runtime, SessionHost};
use yuke_protocol::{ModelReference, SessionId, SessionSettings};
use yuke_store::SqliteStore;

use crate::config::Config;
use crate::paths::Paths;
use crate::prompt::{self, Environment};

/// The limits of the JavaScript: the heap, the stack, and the longest uninterrupted stretch.
const LIMITS: Limits = Limits {
    memory: 64 * 1024 * 1024,
    stack: 4 * 1024 * 1024,
    slice: Duration::from_secs(1),
};

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

/// The facts of the machine that a run reads.
pub(crate) struct Machine<'a> {
    /// The folders of the profile.
    pub(crate) paths: Paths,
    /// The current folder, without links. A new session works in it.
    pub(crate) cwd: PathBuf,
    /// The home folder of the user.
    pub(crate) home: Option<PathBuf>,
    /// Reads one environment variable, for the API key of a provider.
    pub(crate) variable: &'a (dyn Fn(&str) -> Option<OsString> + Sync),
    /// Sends the requests of the model.
    pub(crate) transport: &'a dyn Transport,
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

/// Run `task` on `machine`. A cancel of `cancellation_token` stops the turn. An error before the turn is a text for the
/// user.
pub(crate) async fn run(
    task: &Task,
    machine: &Machine<'_>,
    cancellation_token: CancellationToken,
) -> Result<Finished, String> {
    let store: Arc<dyn Store> = Arc::new(
        SqliteStore::open(&machine.paths.data)
            .await
            .map_err(|error| describe(&error))?,
    );
    let (mut session, target) = match task.session {
        SessionChoice::New => {
            // Only a new session reads the config, so a broken config does not block a continued session.
            let config_path = machine.paths.config.join("config.json");
            let config = Config::load(&config_path)?;
            let selector = task.model.as_deref().or(config.model.as_deref()).ok_or_else(|| {
                format!(
                    "no model: pass --model <provider/model>, or set \"model\" in {}",
                    config_path.display()
                )
            })?;
            new_session(task, selector, machine, &store).await?
        }
        SessionChoice::Id(id) => existing_session(task, id, machine, &store).await?,
        SessionChoice::Newest => {
            let id = store
                .newest_session(&machine.cwd)
                .await
                .map_err(|error| describe(&error))?
                .ok_or_else(|| format!("no session works in {}", machine.cwd.display()))?;
            existing_session(task, id, machine, &store).await?
        }
    };

    // The full outputs of the commands go to a folder of this process, which the run removes at its end.
    let processes_folder = std::env::temp_dir().join(format!(
        "yuke-{}-{:016x}",
        std::process::id(),
        RandomState::new().hash_one(0_u8)
    ));
    let processes = Arc::new(Processes::without_jobs(processes_folder.clone()));
    let finished = turn(
        &task.prompt,
        &mut session,
        &store,
        &target,
        machine,
        &processes,
        cancellation_token,
    )
    .await;
    processes.shutdown().await;
    match std::fs::remove_dir_all(&processes_folder) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => {
            warn(&format!("{}: {error}", processes_folder.display()));
        }
        _ => {}
    }
    finished
}

/// Create a session in the current folder with the model `selector`, and answer it with its target. A missing
/// credential stops the run before the session exists.
async fn new_session(
    task: &Task,
    selector: &str,
    machine: &Machine<'_>,
    store: &Arc<dyn Store>,
) -> Result<(Session, Target), String> {
    let entry = catalog::lookup(selector).map_err(|error| format!("{selector}: {error}"))?;
    let target = target(&entry, machine)?;
    let system = prompt::system_prompt(&Environment {
        workspace: &machine.cwd,
        home: machine.home.as_deref(),
        shell: yuke_js::shell(),
        now: SystemTime::now(),
    })?;
    let settings = SessionSettings {
        model: ModelReference::new(entry.provider.id, entry.model.id),
        settings: yuke_ai::Settings {
            system,
            reasoning: reasoning(&entry, task.reasoning)?,
            ..yuke_ai::Settings::new()
        },
        cwd: machine.cwd.clone(),
    };
    let session = Session::create(Arc::clone(store), settings)
        .await
        .map_err(|error| describe(&error))?;
    Ok((session, target))
}

/// Open session `id`, and answer it with its target. A model or a level of `task` replaces the one of the session
/// with a settings event; a new model without a level takes the default level.
async fn existing_session(
    task: &Task,
    id: SessionId,
    machine: &Machine<'_>,
    store: &Arc<dyn Store>,
) -> Result<(Session, Target), String> {
    let mut session = Session::open(Arc::clone(store), id)
        .await
        .map_err(|error| match error {
            StoreError::NotFound => format!("no session has the id {id}"),
            other => describe(&other),
        })?;
    let mut settings = session.settings().clone();
    let selector = match &task.model {
        Some(model) => model.clone(),
        None => format!("{}/{}", settings.model.provider, settings.model.model),
    };
    let entry = catalog::lookup(&selector).map_err(|error| format!("{selector}: {error}"))?;
    let target = target(&entry, machine)?;
    if task.model.is_some() || task.reasoning.is_some() {
        settings.model = ModelReference::new(entry.provider.id, entry.model.id);
        settings.settings.reasoning = reasoning(&entry, task.reasoning)?;
        session.set_settings(settings).await.map_err(|error| describe(&error))?;
    }
    Ok((session, target))
}

/// Run one turn of `session` with `prompt` as its input and the built-in tools.
async fn turn(
    prompt: &str,
    session: &mut Session,
    store: &Arc<dyn Store>,
    target: &Target,
    machine: &Machine<'_>,
    processes: &Arc<Processes>,
    cancellation_token: CancellationToken,
) -> Result<Finished, String> {
    let (runtime, faults) = Runtime::start(Options {
        limits: LIMITS,
        cache: machine.paths.cache.join("js"),
        processes: Arc::clone(processes),
    })
    .await
    .map_err(|error| describe(&error))?;
    tokio::spawn(report(faults));
    let finished = turn_in_runtime(prompt, session, store, target, machine, &runtime, cancellation_token).await;
    if let Err(error) = runtime.shutdown().await {
        warn(&describe(&error));
    }
    finished
}

async fn turn_in_runtime(
    prompt: &str,
    session: &mut Session,
    store: &Arc<dyn Store>,
    target: &Target,
    machine: &Machine<'_>,
    runtime: &Runtime,
    cancellation_token: CancellationToken,
) -> Result<Finished, String> {
    runtime
        .import("yuke:builtins")
        .await
        .map_err(|error| describe(&error))?;
    let host = Arc::new(Host {
        folder: session.settings().cwd.clone(),
        store: Arc::clone(store),
        session: session.id(),
    });
    let mut toolset = Toolset::new();
    for (definition, tool) in runtime.tools(host).await.map_err(|error| describe(&error))? {
        toolset.add(definition, tool).map_err(|error| describe(&error))?;
    }
    let mut settings = session.settings().settings.clone();
    settings.session_id = session.id().to_string();
    let driver = Driver::new(machine.transport, target, &TokioTimer)
        .toolset(&toolset)
        .settings(&settings);

    session
        .input()
        .send(&[Block::user_text(prompt)])
        .await
        .map_err(|error| describe(&error))?;
    let end = match session.turn(driver).cancellation_token(cancellation_token).run().await {
        Ok(outcome) => TurnEnd::Outcome(outcome),
        Err(error) => TurnEnd::Failed(describe(&error)),
    };
    Ok(Finished {
        session: session.id(),
        end,
        text: answer_text(session.context()),
    })
}

/// The target of `entry` with the credential from the environment of `machine`.
fn target(entry: &Entry<'_>, machine: &Machine<'_>) -> Result<Target, String> {
    let provider = entry.provider;
    let credential = match provider.auth {
        Auth::ApiKey(Some(name)) => {
            let key = (machine.variable)(name)
                .and_then(|key| key.into_string().ok())
                .filter(|key| !key.is_empty())
                .ok_or_else(|| format!("no API key: set {name} for {}", provider.name))?;
            Credential::ApiKey(key.into())
        }
        Auth::ApiKey(None) => Credential::None,
        Auth::OAuth(_) => return Err(format!("{} needs a login, and yuke has no login yet", provider.name)),
    };
    entry
        .bind(credential)
        .map_err(|error| format!("{}/{}: {error}", provider.id, entry.model.id))
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

/// The text of the last answer: the text blocks after the last block of the user.
fn answer_text(context: &[Block]) -> String {
    let start = context
        .iter()
        .rposition(|block| block.role() != Role::Assistant)
        .map_or(0, |last| last + 1);
    let texts: Vec<&str> = context[start..]
        .iter()
        .filter_map(|block| match block {
            Block::AssistantText(text) => Some(text.as_str()),
            _ => None,
        })
        .collect();
    texts.join("\n")
}

/// The text of `error` and of each of its causes.
pub(crate) fn describe(error: &dyn Error) -> String {
    let mut text = error.to_string();
    let mut source = error.source();
    while let Some(cause) = source {
        text.push_str(": ");
        text.push_str(&cause.to_string());
        source = cause.source();
    }
    text
}

/// Write `text` to stderr as a notice of yuke.
pub(crate) fn warn(text: &str) {
    if writeln!(io::stderr(), "yuke: {text}").is_err() {
        // No one reads stderr, so the notice has nowhere to go.
    }
}

/// Write each fault of the JavaScript to stderr.
async fn report(mut faults: mpsc::UnboundedReceiver<Fault>) {
    while let Some(fault) = faults.recv().await {
        warn(&format!("a script failed: {fault}"));
    }
}

/// Waits with the tokio timer.
struct TokioTimer;

#[async_trait]
impl Timer for TokioTimer {
    async fn sleep(&self, duration: Duration) {
        tokio::time::sleep(duration).await;
    }
}

/// The session of the tools: its folder and its blob store.
struct Host {
    folder: PathBuf,
    store: Arc<dyn Store>,
    session: SessionId,
}

#[async_trait]
impl SessionHost for Host {
    fn folder(&self) -> &Path {
        &self.folder
    }

    async fn put_media(&self, bytes: Vec<u8>) -> Result<yuke_ai::Blob, String> {
        self.store
            .put_blob(self.session, bytes)
            .await
            .map_err(|error| describe(&error))
    }

    // `Processes::without_jobs` starts no job, so no job ends.
    fn job_ended(&self, _ended: JobEnded) {}
}

#[cfg(test)]
mod tests;
