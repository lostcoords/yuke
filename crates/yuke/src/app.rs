//! The core that the modes of yuke share: the store, the JavaScript runtime, the jobs, and the open sessions. `yuke -p`
//! and `yuke --rpc` drive their sessions through an [`App`], and the app tells them what happens with the notifications
//! of the protocol.

mod live;
mod models;
mod trust;

use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::error::Error;
use std::ffi::OsString;
use std::fmt;
use std::hash::{BuildHasher, RandomState};
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, RwLock};
use std::time::{Duration, SystemTime};

use async_trait::async_trait;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use yuke_agent::{Session, SessionError, Store, StoreError};
use yuke_ai::Block;
use yuke_ai::catalog::Auth;
use yuke_ai::oauth::Flow;
use yuke_ai::route::Credential;
use yuke_ai::transport::{Exchange, Transport};
use yuke_engine::{CredentialSource, Model, Timer, chain_text};
use yuke_js::{Options, Origin, Processes, Report, Runtime};
use yuke_protocol::{
    EventNumber, Input, InputId, InputKind, InputSource, InteractionId, InteractionResponse, Job, ModelReference,
    NoticeLevel, NoticeParams, ServerNotification, SessionEvent, SessionId, SessionSettings, StoredEvent,
    UpdateCredentialParams,
};
use yuke_store::SqliteStore;

use self::live::LiveSession;
use self::models::PluginModels;
use crate::auth::{LOCK_LIMIT, LoginSource, Pushed};
use crate::config::{Config, read_json};
use crate::paths::Paths;
use crate::plugins;
use crate::prompt::{self, Environment, Prompt};
use crate::providers::Providers;

/// The source of the notices of yuke. A plugin name has no `:`, so no plugin notice has this source.
pub(crate) const SOURCE: &str = "host:yuke";

/// A function that reads one environment variable.
pub(crate) type Variable = dyn Fn(&str) -> Option<OsString> + Send + Sync;

/// The facts of the machine that the app reads.
pub(crate) struct Machine {
    /// The folders of the profile.
    pub(crate) paths: Paths,
    /// The home folder of the user.
    pub(crate) home: Option<PathBuf>,
    /// Reads one environment variable, for the API key of a provider.
    pub(crate) variable: Box<Variable>,
    /// Sends the requests of the model.
    pub(crate) transport: Arc<dyn Transport>,
    /// Sends the requests of the logins.
    pub(crate) exchange: Arc<dyn Exchange>,
}

/// How the app runs: as a server that clients come to (`yuke --rpc`), or for one task with no client (`yuke -p`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Mode {
    /// A background job runs until it ends, until a stop, or until the close of its session. A question waits for an
    /// answer, also while no client is connected.
    Server,
    /// A background command fails, because the run ends with its turn. A question gets no answer.
    Print,
}

/// Receives the notifications of the app: the updates of each open session, and the notices.
pub(crate) trait Observer: Send + Sync {
    /// Receive one notification. A call must not block, because a turn waits for it.
    fn notify(&self, notification: ServerNotification);
}

/// The parts of the app that each open session uses.
struct Shared {
    machine: Machine,
    /// The parts of the profile that a reload replaces.
    profile: RwLock<Profile>,
    store: Arc<dyn Store>,
    processes: Arc<Processes>,
    observer: Arc<dyn Observer>,
    mode: Mode,
    /// The MCP servers of the user, from `mcp.json` in the config folder.
    mcp: yuke_mcp::Config,
    /// The id of the last question of any session.
    last_question: Arc<AtomicU64>,
    /// The credential of each provider with a login. One source serves each session, so one refresh serves all.
    logins: Mutex<HashMap<String, LoginSource>>,
}

/// The parts of the profile that a reload replaces. A reader takes a copy of an `Arc`, so it never holds the lock.
struct Profile {
    /// The providers of `providers.json` and of the catalog.
    providers: Arc<Providers>,
    /// The folder of each plugin of the profile, in load order, also of a plugin that failed to load.
    plugin_folders: Arc<[PathBuf]>,
}

impl Profile {
    /// The profile of `providers` and the folders of `plugins`.
    fn new(providers: Providers, plugins: &[yuke_js::Plugin]) -> Self {
        Profile {
            providers: Arc::new(providers),
            plugin_folders: plugins
                .iter()
                .filter_map(|plugin| match &plugin.origin {
                    Origin::Folder { root, .. } => Some(root.clone()),
                    Origin::Bundled { .. } => None,
                })
                .collect(),
        }
    }
}

impl Shared {
    /// The providers now.
    fn providers(&self) -> Arc<Providers> {
        Arc::clone(&self.profile.read().unwrap_or_else(PoisonError::into_inner).providers)
    }

    /// The plugin folders now.
    fn plugin_folders(&self) -> Arc<[PathBuf]> {
        Arc::clone(
            &self
                .profile
                .read()
                .unwrap_or_else(PoisonError::into_inner)
                .plugin_folders,
        )
    }
}

/// The open sessions of one client, and the parts that they share.
///
/// # Cancel safety
///
/// The methods are not cancel safe. A caller awaits each call to its end, as the request loop of `yuke --rpc` does. A
/// dropped close can leave the jobs of a session running, and a dropped settings change leaves the session stale until
/// its next turn opens it again.
pub(crate) struct App {
    shared: Arc<Shared>,
    runtime: Runtime,
    reporter: JoinHandle<()>,
    processes_folder: PathBuf,
    sessions: HashMap<SessionId, LiveSession>,
}

impl App {
    /// Open the store, start the JavaScript runtime with the built-in tools, and load the bundled plugins and the plugins
    /// of `config.json`. The app tells `observer` what happens.
    ///
    /// # Errors
    ///
    /// Returns a text for the user when a part does not start.
    pub(crate) async fn start(machine: Machine, mode: Mode, observer: Arc<dyn Observer>) -> Result<App, String> {
        let providers = Providers::load(&machine.paths.config)?;
        let config: Config = read_json(&machine.paths.config.join("config.json"))?.unwrap_or_default();
        let mcp: yuke_mcp::Config = read_json(&machine.paths.config.join("mcp.json"))?.unwrap_or_default();
        let plugins = plugins::plugins(
            &machine.paths.config,
            &config.plugins,
            &config.disable,
            &machine.paths.data,
        )?;
        let store: Arc<dyn Store> = Arc::new(
            SqliteStore::open(&machine.paths.data)
                .await
                .map_err(|error| chain_text(&error))?,
        );
        // The full outputs of the commands and the logs of the jobs go to a folder of this process, which the shutdown
        // removes.
        let processes_folder = std::env::temp_dir().join(format!(
            "yuke-{}-{:016x}",
            std::process::id(),
            RandomState::new().hash_one(0_u8)
        ));
        let processes = Arc::new(match mode {
            Mode::Server => Processes::new(processes_folder.clone()),
            Mode::Print => Processes::without_jobs(processes_folder.clone()),
        });
        let shared = Arc::new(Shared {
            machine,
            profile: RwLock::new(Profile::new(providers, &plugins)),
            store,
            processes,
            observer,
            mode,
            mcp,
            last_question: Arc::default(),
            logins: Mutex::default(),
        });
        let (runtime, reporter) = match start_runtime(&shared).await {
            Ok(started) => started,
            Err(error) => {
                if let Err(shutdown) = shared.processes.shutdown().await {
                    warn(&format!("{}: {shutdown}", processes_folder.display()));
                }
                return Err(chain_text(&error));
            }
        };
        let app = App {
            shared,
            runtime,
            reporter,
            processes_folder,
            sessions: HashMap::new(),
        };
        app.report_failures(app.runtime.load_plugins(&plugins).await);
        Ok(app)
    }

    /// Send a notice for each plugin that did not load. The other plugins load.
    fn report_failures(&self, failures: Vec<yuke_js::PluginFailure>) {
        for failure in failures {
            self.shared.observer.notify(ServerNotification::Notice(NoticeParams {
                session_id: None,
                level: NoticeLevel::Error,
                source: SOURCE.to_owned(),
                message: chain_text(&failure),
            }));
        }
    }

    /// Load the plugins of `config.json` and the providers of `providers.json` again. Each open session stays open, and
    /// its jobs go on. Its next turn takes the tools and hooks of the new plugins. A new session scans the skill folders
    /// of the new plugin list.
    ///
    /// # Errors
    ///
    /// - Returns [`AppError::TurnRuns`] while a turn runs in an open session.
    /// - Returns [`AppError::Invalid`] when yuke cannot read or check `config.json`, `providers.json`, or a plugin folder.
    /// - Returns [`AppError::Internal`] when the new runtime does not start.
    ///
    /// Each error keeps the old plugins and providers.
    pub(crate) async fn reload(&mut self) -> Result<(), AppError> {
        // A turn starts only under the session lock, so no turn starts while the reload holds each one.
        let mut held = Vec::with_capacity(self.sessions.len());
        for live in self.sessions.values() {
            held.push(live.hold().ok_or(AppError::TurnRuns)?);
        }
        let paths = &self.shared.machine.paths;
        let providers = Providers::load(&paths.config).map_err(AppError::Invalid)?;
        let config: Config = read_json(&paths.config.join("config.json"))
            .map_err(AppError::Invalid)?
            .unwrap_or_default();
        let plugins = plugins::plugins(&paths.config, &config.plugins, &config.disable, &paths.data)
            .map_err(AppError::Invalid)?;
        // The new plugins use the new providers, for example in a model request of their `apply`.
        let old_profile = std::mem::replace(
            &mut *self.shared.profile.write().unwrap_or_else(PoisonError::into_inner),
            Profile::new(providers, &plugins),
        );
        // The new plugins load before the old plugins close. A runtime cannot load plugins after it closes its plugins.
        let (runtime, reporter) = match start_runtime(&self.shared).await {
            Ok(started) => started,
            Err(error) => {
                *self.shared.profile.write().unwrap_or_else(PoisonError::into_inner) = old_profile;
                return Err(AppError::Internal(chain_text(&error)));
            }
        };
        self.report_failures(runtime.load_plugins(&plugins).await);
        let mut opened = Vec::with_capacity(self.sessions.len());
        for live in self.sessions.values() {
            match live.open_plugins(&runtime).await {
                Ok(script) => opened.push((live, script)),
                Err(error) => {
                    // Each cleanup ends before the runtime stops.
                    for (_, script) in opened {
                        if let Err(error) = script.close().await {
                            warn(&chain_text(&error));
                        }
                    }
                    stop_runtime(runtime, reporter).await;
                    *self.shared.profile.write().unwrap_or_else(PoisonError::into_inner) = old_profile;
                    return Err(error);
                }
            }
        }
        for (live, script) in opened {
            live.replace_plugins(script).await;
        }
        let old_runtime = std::mem::replace(&mut self.runtime, runtime);
        let old_reporter = std::mem::replace(&mut self.reporter, reporter);
        stop_runtime(old_runtime, old_reporter).await;
        drop(held);
        Ok(())
    }

    /// The store of the sessions.
    pub(crate) fn store(&self) -> &Arc<dyn Store> {
        &self.shared.store
    }

    /// The providers of the profile now.
    pub(crate) fn providers(&self) -> Arc<Providers> {
        self.shared.providers()
    }

    /// Check that the model of `settings` can run: the catalog knows it, and its credential source exists. An API key
    /// must be set. A login is read at each attempt.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for an unknown model, a missing API key, or a provider with no login flow.
    fn check_model(&self, settings: &SessionSettings) -> Result<(), AppError> {
        model_of(&settings.model, &self.shared).map(drop)
    }

    /// Create a session with `settings`, and open it. The folder loses its links, and the app builds the system prompt
    /// of that folder. A missing API key stops the create before the session exists.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for a folder that does not exist or a model that cannot run, and
    /// [`AppError::Store`] when the store fails.
    pub(crate) async fn create(&mut self, mut settings: SessionSettings) -> Result<SessionId, AppError> {
        settings.cwd = canonical(settings.cwd).await?;
        let prompt = system_prompt(
            settings.cwd.clone(),
            self.shared.machine.home.clone(),
            self.shared.plugin_folders().to_vec(),
        )
        .await?;
        self.check_model(&settings)?;
        let session = Session::create(Arc::clone(&self.shared.store), &settings, &prompt.sections)
            .await
            .map_err(AppError::Store)?;
        let id = self.start_new(session).await?;
        for warning in prompt.warnings {
            self.shared.observer.notify(ServerNotification::Notice(NoticeParams {
                session_id: Some(id),
                level: NoticeLevel::Warn,
                source: SOURCE.to_owned(),
                message: warning,
            }));
        }
        Ok(id)
    }

    /// Fork session `id` through event `through`, and open the fork.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Store`] when the store fails, and [`AppError::Invalid`] for a model that cannot run.
    pub(crate) async fn fork(&mut self, id: SessionId, through: Option<EventNumber>) -> Result<SessionId, AppError> {
        let session = Session::fork(Arc::clone(&self.shared.store), id, through)
            .await
            .map_err(AppError::Store)?;
        self.start_new(session).await
    }

    /// Open session `id`, which is not open. `change` gets the saved settings and the providers, and it can return new
    /// settings. The app saves them before the session starts, so a waiting input runs with them. An open runs no turn
    /// and sends no update. [`App::load`] sends the saved events.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Store`] when the store fails. Returns [`AppError::Invalid`] for an open session or a model
    /// that cannot run. Returns the error of `change` as it is.
    pub(crate) async fn open(
        &mut self,
        id: SessionId,
        change: impl FnOnce(&SessionSettings, &Providers) -> Result<Option<SessionSettings>, AppError>,
    ) -> Result<(), AppError> {
        if self.sessions.contains_key(&id) {
            return Err(AppError::Invalid(format!("the session {id} is open already")));
        }
        let mut session = Session::open(Arc::clone(&self.shared.store), id)
            .await
            .map_err(AppError::Store)?;
        match change(session.settings(), &self.shared.providers())? {
            Some(settings) => drop(save_settings(&mut session, settings, &self.shared).await?),
            None => self.check_model(session.settings())?,
        }
        self.start_session(session).await
    }

    /// Open session `id` when it is not open, and send it as updates: its saved events after `after`, its state, its
    /// pending inputs, and its running jobs. The live updates of the session that come during the load follow them.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Store`] when the store fails, and [`AppError::Invalid`] for a model that cannot run.
    pub(crate) async fn load(&mut self, id: SessionId, after: Option<EventNumber>) -> Result<(), AppError> {
        if !self.sessions.contains_key(&id) {
            self.open(id, |_, _| Ok(None)).await?;
        }
        self.live(id)?.load(after).await
    }

    /// Close session `id`: its turn stops, and its task ends. Waiting input stays saved. A session with running jobs
    /// closes only with `stop_jobs`, which stops them.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`], or [`AppError::JobsRun`] for running jobs without `stop_jobs`.
    pub(crate) async fn close(&mut self, id: SessionId, stop_jobs: bool) -> Result<(), AppError> {
        let Entry::Occupied(live) = self.sessions.entry(id) else {
            return Err(AppError::NotOpen(id));
        };
        if !stop_jobs {
            let jobs = live.get().jobs();
            if !jobs.is_empty() {
                return Err(AppError::JobsRun(jobs.into_iter().map(|job| job.id).collect()));
            }
        }
        live.remove().close().await;
        Ok(())
    }

    /// Cancel the running turn of session `id`. A session that is not open or runs no turn has nothing to cancel.
    pub(crate) fn cancel(&self, id: SessionId) {
        if let Some(live) = self.sessions.get(&id) {
            live.cancel();
        }
    }

    /// Save `content` as an input of the user, and start a turn when the session is idle.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for content that is no input, and [`AppError::Store`] when the store fails.
    pub(crate) async fn input(&self, id: SessionId, content: Vec<Block>) -> Result<InputId, AppError> {
        let live = self.live(id)?;
        let input = Input::new(InputSource::User, InputKind::Message, content)
            .map_err(|error| AppError::Invalid(chain_text(&error)))?;
        live.inbox().accept(input).await.map_err(AppError::Store)
    }

    /// Remove the pending input `input_id` of session `id`.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Store`] when the input is not pending or the store fails.
    pub(crate) async fn remove_input(&self, id: SessionId, input_id: InputId) -> Result<(), AppError> {
        self.live(id)?.inbox().remove(input_id).await.map_err(AppError::Store)
    }

    /// Save `settings` for session `id`. The session keeps its system prompt.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Busy`] while a turn runs or input waits, and [`AppError::Invalid`] for a folder or a model
    /// that cannot work.
    pub(crate) async fn set_settings(&self, id: SessionId, settings: SessionSettings) -> Result<(), AppError> {
        self.live(id)?.set_settings(settings).await
    }

    /// Use the token of `params` for each model request of its provider from the next attempt on, in place of the
    /// stored login. Each open session of the provider takes it, also during a turn.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for a provider without a login flow and for a bad field. A refused update changes
    /// nothing.
    pub(crate) fn update_credential(&self, params: UpdateCredentialParams) -> Result<(), AppError> {
        let providers = self.shared.providers();
        let Ok((provider, flow)) = providers.login(&params.provider) else {
            return Err(AppError::Invalid(format!(
                "provider: {} has no login flow, so it takes no credential/update",
                params.provider
            )));
        };
        let source = login_source(&self.shared, &provider.id, flow);
        source.push(Pushed::new(params, flow, SystemTime::now()).map_err(AppError::Invalid)?);
        Ok(())
    }

    /// The running background jobs of session `id`, oldest first.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`].
    pub(crate) fn jobs(&self, id: SessionId) -> Result<Vec<Job>, AppError> {
        Ok(self.live(id)?.jobs())
    }

    /// Stop the job `job_id` of session `id`, and wait for its end. The `job` update with the end comes first.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NoJob`] when the session runs no such job.
    pub(crate) async fn stop_job(&self, id: SessionId, job_id: &str) -> Result<(), AppError> {
        if self.live(id)?.stop_job(job_id).await {
            Ok(())
        } else {
            Err(AppError::NoJob(job_id.to_owned()))
        }
    }

    /// The MCP servers of session `id` and their states, in config order.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NotOpen`].
    pub(crate) fn mcp_servers(&self, id: SessionId) -> Result<Vec<yuke_protocol::McpServer>, AppError> {
        Ok(self.live(id)?.mcp_servers())
    }

    /// Give `response` to the open question `interaction_id` of session `id`.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NoInteraction`] when the session has no such open question, and [`AppError::Invalid`] when
    /// the answer does not fit the question.
    pub(crate) fn respond(
        &self,
        id: SessionId,
        interaction_id: InteractionId,
        response: InteractionResponse,
    ) -> Result<(), AppError> {
        self.live(id)?.answer(interaction_id, response)
    }

    /// Close each session, close the plugins, stop the runtime, and stop the jobs.
    pub(crate) async fn shutdown(self) {
        let App {
            shared,
            runtime,
            reporter,
            processes_folder,
            mut sessions,
        } = self;
        // Each session stops before the first wait, so the sessions end together.
        for live in sessions.values() {
            live.stop();
        }
        for (_, live) in sessions.drain() {
            live.close().await;
        }
        stop_runtime(runtime, reporter).await;
        if let Err(error) = shared.processes.shutdown().await {
            warn(&format!("{}: {error}", processes_folder.display()));
        }
    }

    /// Open `session`, which this app saved just now. A session that cannot start is deleted again, so no session that
    /// cannot run stays in the store.
    async fn start_new(&mut self, session: Session) -> Result<SessionId, AppError> {
        let id = session.id();
        // The drop frees the lease of the session, and the delete refuses a session with a lease.
        let started = match self.check_model(session.settings()) {
            Ok(()) => self.start_session(session).await,
            Err(error) => {
                drop(session);
                Err(error)
            }
        };
        if started.is_err() {
            self.shared.store.delete_session(id).await.map_err(AppError::Store)?;
        }
        started.map(|()| id)
    }

    /// Start the task of `session`.
    async fn start_session(&mut self, session: Session) -> Result<(), AppError> {
        let id = session.id();
        let live = LiveSession::start(session, &self.runtime, Arc::clone(&self.shared)).await?;
        self.sessions.insert(id, live);
        Ok(())
    }

    /// The open session `id`.
    fn live(&self, id: SessionId) -> Result<&LiveSession, AppError> {
        self.sessions.get(&id).ok_or(AppError::NotOpen(id))
    }
}

/// Why the app refused or failed a request.
#[derive(Debug)]
pub(crate) enum AppError {
    /// The session is not open.
    NotOpen(SessionId),
    /// A value of the request cannot work: a model, a folder, or an input. The text tells why.
    Invalid(String),
    /// A turn runs or input waits, so the settings cannot change.
    Busy,
    /// A turn runs in an open session, so the plugins cannot reload.
    TurnRuns,
    /// The session runs the jobs with these ids.
    JobsRun(Vec<String>),
    /// The session runs no job with this id.
    NoJob(String),
    /// The session has no open question with this id.
    NoInteraction(InteractionId),
    /// The store failed.
    Store(StoreError),
    /// A part of yuke failed. The text tells why.
    Internal(String),
}

impl fmt::Display for AppError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AppError::NotOpen(id) => write!(f, "the session {id} is not open: create, fork, or load it first"),
            AppError::Invalid(text) | AppError::Internal(text) => f.write_str(text),
            AppError::Busy => f.write_str("a turn runs or waits: change the settings after it ends"),
            AppError::TurnRuns => f.write_str("a turn runs: reload after it ends"),
            AppError::JobsRun(ids) => write!(
                f,
                "the session runs the jobs {}: stop them, or close with stopJobs: true",
                ids.join(", ")
            ),
            AppError::NoJob(id) => write!(f, "the session runs no job {id}"),
            AppError::NoInteraction(id) => write!(f, "the session has no open question {}", id.0),
            AppError::Store(error) => fmt::Display::fmt(error, f),
        }
    }
}

impl Error for AppError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            AppError::Store(error) => error.source(),
            _ => None,
        }
    }
}

/// Start a JavaScript runtime for `shared`, import the tools of yuke into it, and start the task that reports its faults
/// and notices.
async fn start_runtime(shared: &Arc<Shared>) -> Result<(Runtime, JoinHandle<()>), yuke_js::Error> {
    let (runtime, reports) = Runtime::start(Options {
        cache: shared.machine.paths.cache.join("js"),
        processes: Arc::clone(&shared.processes),
        models: Arc::new(PluginModels(Arc::clone(shared))),
    })
    .await?;
    let reporter = tokio::spawn(report(reports, Arc::clone(&shared.observer), io::stderr()));
    if let Err(error) = runtime.import("yuke:internal/builtins").await {
        stop_runtime(runtime, reporter).await;
        return Err(error);
    }
    Ok((runtime, reporter))
}

/// Close the plugins of `runtime`, and stop the runtime. Then wait for the end of `reporter`. The jobs go on, because
/// they belong to the processes.
async fn stop_runtime(runtime: Runtime, reporter: JoinHandle<()>) {
    if let Err(error) = runtime.close_plugins().await {
        warn(&chain_text(&error));
    }
    if let Err(error) = runtime.shutdown().await {
        warn(&chain_text(&error));
    }
    // The shutdown of the runtime closes the channel of the reports, so the reporter ends.
    if let Err(error) = reporter.await {
        warn(&format!(
            "yuke could not report the faults and notices of the JavaScript: {error}"
        ));
    }
}

/// The model of `reference`, with the credential source of its provider: an API key, or the login of `shared`.
fn model_of(reference: &ModelReference, shared: &Shared) -> Result<Model, AppError> {
    let selector = format!("{}/{}", reference.provider, reference.model);
    let providers = shared.providers();
    let entry = providers
        .lookup(&selector)
        .map_err(|error| AppError::Invalid(format!("{selector}: {error}")))?;
    let provider = entry.provider;
    let source: Arc<dyn CredentialSource> = match &provider.auth {
        Auth::ApiKey(Some(name)) => {
            let key = (shared.machine.variable)(name)
                .and_then(|key| key.into_string().ok())
                .filter(|key| !key.is_empty())
                .ok_or_else(|| AppError::Invalid(format!("no API key: set {name} for {}", provider.name)))?;
            Arc::new(Credential::ApiKey(key.into()))
        }
        Auth::ApiKey(None) => Arc::new(Credential::None),
        Auth::OAuth(flow) => Arc::new(login_source(shared, &provider.id, *flow)),
    };
    let target = entry
        .bind()
        .map_err(|error| AppError::Invalid(format!("{}/{}: {error}", provider.id, entry.model.id)))?;
    Ok(Model {
        target,
        source,
        context_window: entry.model.limits.context_window,
    })
}

/// Save `settings` in `session`, and return the saved event. A new folder is saved without links, and the saved folder
/// stays as it is. A model that cannot run saves nothing.
async fn save_settings(
    session: &mut Session,
    mut settings: SessionSettings,
    shared: &Shared,
) -> Result<StoredEvent, AppError> {
    if settings.cwd != session.settings().cwd {
        settings.cwd = canonical(settings.cwd).await?;
    }
    model_of(&settings.model, shared)?;
    let event_number = session
        .set_settings(settings.clone())
        .await
        .map_err(|error| match error {
            SessionError::Store(error) => AppError::Store(error),
            error => AppError::Internal(chain_text(&error)),
        })?;
    Ok(StoredEvent {
        event_number,
        event: SessionEvent::Settings(settings),
    })
}

/// The credential source of the provider `id` with the login `flow`. Each session of the provider shares it, so one
/// refresh and one push serve them all.
fn login_source(shared: &Shared, id: &str, flow: Flow) -> LoginSource {
    let mut logins = lock(&shared.logins);
    if let Some(source) = logins.get(id) {
        return source.clone();
    }
    let source = LoginSource::new(
        id.to_owned(),
        flow,
        shared.machine.paths.data.clone(),
        Arc::clone(&shared.machine.exchange),
        LOCK_LIMIT,
    );
    logins.insert(id.to_owned(), source.clone());
    source
}

/// `folder` without links. It must be a folder.
async fn canonical(folder: PathBuf) -> Result<PathBuf, AppError> {
    blocking(move || {
        let canonical = folder
            .canonicalize()
            .map_err(|error| AppError::Invalid(format!("{}: {error}", folder.display())))?;
        if !canonical.is_dir() {
            return Err(AppError::Invalid(format!("{}: not a folder", folder.display())));
        }
        Ok(canonical)
    })
    .await
}

/// The system prompt of a session in `workspace`, with the skills of the plugin folders `plugins`.
async fn system_prompt(workspace: PathBuf, home: Option<PathBuf>, plugins: Vec<PathBuf>) -> Result<Prompt, AppError> {
    blocking(move || {
        prompt::system_prompt(&Environment {
            workspace: &workspace,
            home: home.as_deref(),
            plugins: &plugins,
            shell: yuke_js::shell(),
            now: SystemTime::now(),
        })
        .map_err(AppError::Internal)
    })
    .await
}

/// Run `f` on a thread for blocking work, so a slow file system does not hold the other sessions.
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> Result<T, AppError> + Send + 'static) -> Result<T, AppError> {
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|error| AppError::Internal(error.to_string()))?
}

/// Send a script fault to `observer` as a warning of yuke, and a plugin notice as it is. An entry of `console` goes to
/// `console` (stderr in the app), because it is for the operator and stdout can carry the protocol.
async fn report(
    mut reports: mpsc::UnboundedReceiver<Report>,
    observer: Arc<dyn Observer>,
    mut console: impl Write + Send,
) {
    while let Some(report) = reports.recv().await {
        let notice = match report {
            Report::Fault(fault) => NoticeParams {
                session_id: None,
                level: NoticeLevel::Warn,
                source: SOURCE.to_owned(),
                message: format!("a script failed: {fault}"),
            },
            Report::Notice(notice) => notice,
            Report::Console { level, text } => {
                let level = match level {
                    NoticeLevel::Debug => "debug",
                    NoticeLevel::Info => "info",
                    NoticeLevel::Warn => "warn",
                    NoticeLevel::Error => "error",
                };
                if writeln!(console, "console {level}: {text}").is_err() {
                    // No one reads stderr, so the line has nowhere to go.
                }
                continue;
            }
        };
        observer.notify(ServerNotification::Notice(notice));
    }
}

/// Write `text` to stderr as a notice of yuke.
pub(crate) fn warn(text: &str) {
    if writeln!(io::stderr(), "yuke: {text}").is_err() {
        // No one reads stderr, so the notice has nowhere to go.
    }
}

/// Lock `mutex`. A panic of another holder leaves a valid value.
pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Waits with the tokio timer.
struct TokioTimer;

#[async_trait]
impl Timer for TokioTimer {
    async fn sleep(&self, duration: Duration) {
        tokio::time::sleep(duration).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Keeps each notification that it receives.
    #[derive(Default)]
    struct Recorder(Mutex<Vec<ServerNotification>>);

    impl Observer for Recorder {
        fn notify(&self, notification: ServerNotification) {
            lock(&self.0).push(notification);
        }
    }

    /// A writer that keeps its bytes for the test.
    #[derive(Clone, Default)]
    struct Kept(Arc<Mutex<Vec<u8>>>);

    impl Write for Kept {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            lock(&self.0).extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn a_console_entry_goes_to_its_writer_and_is_no_notice() {
        let (reports, receiver) = mpsc::unbounded_channel();
        let recorder = Arc::new(Recorder::default());
        reports
            .send(Report::Console {
                level: NoticeLevel::Error,
                text: "for the operator".to_owned(),
            })
            .unwrap();
        reports
            .send(Report::Fault(yuke_js::ScriptError {
                name: None,
                message: "lost".to_owned(),
                stack: None,
            }))
            .unwrap();
        drop(reports);

        let console = Kept::default();
        report(receiver, Arc::clone(&recorder) as Arc<dyn Observer>, console.clone()).await;

        let messages: Vec<String> = lock(&recorder.0)
            .iter()
            .map(|notification| match notification {
                ServerNotification::Notice(notice) => notice.message.clone(),
                other @ ServerNotification::SessionUpdate(_) => panic!("expected a notice, got {other:?}"),
            })
            .collect();
        assert_eq!(messages, ["a script failed: lost"]);
        assert_eq!(lock(&console.0).as_slice(), b"console error: for the operator\n");
    }
}
