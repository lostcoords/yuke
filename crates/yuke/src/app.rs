//! The core that the modes of yuke share: the store, the JavaScript runtime, the jobs, and the open sessions. `yuke -p`
//! and `yuke --rpc` drive their sessions through an [`App`], and the app tells them what happens with the notifications
//! of the protocol.

mod catalog;
mod live;
mod models;
mod plugin_sessions;
mod sessions;
mod test_host;
mod trust;

use std::collections::HashMap;
use std::error::Error;
use std::ffi::OsString;
use std::fmt;
use std::hash::{BuildHasher, RandomState};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, RwLock};
use std::time::{Duration, SystemTime};

use async_trait::async_trait;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use yuke_agent::{Session, SessionError, Store, StoreError};
use yuke_ai::catalog::Auth;
use yuke_ai::oauth::Flow;
use yuke_ai::route::Credential;
use yuke_ai::transport::{Exchange, Transport};
use yuke_engine::{CancellationToken, CredentialSource, Model, Timer, chain_text};
use yuke_js::{Options, Origin, Processes, Report, Runtime};
use yuke_protocol::{
    ExtensionRequestParams, InteractionId, ListCatalogResult, LoginFinishedParams, LoginId, LoginOutcome, LoginResult,
    ModelReference, NoticeLevel, NoticeParams, ProviderState, ResponseError, ServerNotification, SessionEvent,
    SessionId, SessionSettings, StoredEvent, UpdateCredentialParams,
};
use yuke_store::SqliteStore;

use self::models::PluginModels;
use self::plugin_sessions::PluginSessions;
pub(crate) use self::sessions::{Attachment, SessionService};
pub(crate) use self::test_host::{TestPlace, TestSetup};
use crate::auth::{LOCK_LIMIT, LoginSource, Pushed, StoredKind};
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
    /// Sends the requests of `fetch` in the plugins. It has no idle timeout, so only the signal stops a slow fetch.
    pub(crate) fetch: Arc<yuke_http::Client>,
    /// The terminal interface, or `None` with no view.
    /// Each runtime of a reload draws on its display.
    pub(crate) interface: Option<yuke_js::Interface>,
    /// What the app of a test needs beyond production, or `None` outside a test.
    pub(crate) test: Option<TestSetup>,
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

/// Receives the notifications of the app: the updates of each open session, and the notices. It also sends the
/// requests of the plugins to the client.
pub(crate) trait Observer: Send + Sync {
    /// Receive one notification. A call must not block, because a turn waits for it.
    fn notify(&self, notification: ServerNotification);

    /// Send `params` to the client as a request, and give its id and the receiver of the answer. Give `None` when no
    /// client can answer. The receiver fails when the client disconnects first. A call must not block.
    fn request(&self, _params: ExtensionRequestParams) -> Option<(i64, oneshot::Receiver<Answer>)> {
        None
    }

    /// Forget the request `id`. When the request still waits for its answer, tell the client.
    fn cancel_request(&self, _id: i64) {}
}

/// The answer of a client to a request: its result or its error.
pub(crate) type Answer = Result<serde_json::Value, ResponseError>;

/// The parts of the app that each open session uses.
struct Shared {
    machine: Machine,
    /// The parts of the profile that a reload replaces.
    profile: RwLock<Profile>,
    store: Arc<dyn Store>,
    /// Waits before each retry of a model request.
    timer: Arc<dyn Timer>,
    processes: Arc<Processes>,
    observer: Arc<dyn Observer>,
    mode: Mode,
    /// The MCP servers of the user, from `mcp.json` in the config folder.
    mcp: yuke_mcp::Config,
    /// The id of the last question of any session.
    last_question: Arc<AtomicU64>,
    /// The credential of each provider with a login. One source serves each session, so one refresh serves all.
    logins: Mutex<HashMap<String, LoginSource>>,
    /// The login in progress of each provider, from `auth/login`.
    pending_logins: Mutex<HashMap<String, InProgress>>,
    /// The id of the last login of `auth/login`.
    last_login: AtomicU64,
}

/// A login in progress: its id, the token that stops its polls, and its task.
struct InProgress {
    id: LoginId,
    stop: CancellationToken,
    task: JoinHandle<()>,
}

/// The parts of the profile that a reload replaces. A reader takes a copy of an `Arc`, so it never holds the lock.
struct Profile {
    /// The providers of `providers.json` and of the catalog.
    providers: Arc<Providers>,
    /// The folder of each plugin of the profile, in load order, also of a plugin that failed to load.
    plugin_folders: Arc<[PathBuf]>,
    /// The wait of a session with running jobs and no holder before it closes, from `sessionIdleMinutes`.
    session_idle: Duration,
}

impl Profile {
    /// The profile of `providers`, the folders of `plugins`, and the session wait of `config`.
    fn new(providers: Providers, plugins: &[yuke_js::Plugin], config: &Config) -> Self {
        Self {
            providers: Arc::new(providers),
            plugin_folders: plugins
                .iter()
                .filter_map(|plugin| match &plugin.origin {
                    Origin::Folder { root, .. } => Some(root.clone()),
                    Origin::Bundled { .. } | Origin::Given => None,
                })
                .collect(),
            session_idle: Duration::from_secs(
                60 * u64::from(config.session_idle_minutes.unwrap_or(SESSION_IDLE_MINUTES)),
            ),
        }
    }
}

/// The default of `sessionIdleMinutes`.
const SESSION_IDLE_MINUTES: u32 = 30;

impl Shared {
    /// Send `text` to the observer as a warning of yuke.
    fn warn(&self, text: &str) {
        self.observer.notify(ServerNotification::Notice(NoticeParams {
            session_id: None,
            level: NoticeLevel::Warn,
            source: SOURCE.to_owned(),
            message: text.to_owned(),
        }));
    }

    /// The providers now.
    fn providers(&self) -> Arc<Providers> {
        Arc::clone(&self.profile.read().unwrap_or_else(PoisonError::into_inner).providers)
    }

    /// The wait of a session with running jobs and no holder before it closes.
    fn session_idle(&self) -> Duration {
        self.profile.read().unwrap_or_else(PoisonError::into_inner).session_idle
    }

    /// The providers of the profile with their models: every provider with `all`, else only the ready ones.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Internal`] when `auth.json` does not read or holds no valid content.
    async fn catalog(&self, all: bool) -> Result<ListCatalogResult, AppError> {
        let stored = crate::auth::stored_kinds(self.machine.paths.data.clone())
            .await
            .map_err(|error| AppError::Internal(error.to_string()))?;
        let providers = self.providers();
        let logins = lock(&self.logins);
        let providers = providers
            .iter()
            .filter_map(|provider| {
                let kind = stored.get(provider.id.as_ref()).copied();
                let state = match &provider.auth {
                    Auth::ApiKey(None) => ProviderState::Ready,
                    Auth::ApiKey(Some(name)) => {
                        if kind == Some(StoredKind::ApiKey) || variable_key(self, name).is_some() {
                            ProviderState::Ready
                        } else {
                            ProviderState::NeedsApiKey {
                                variable: name.to_string(),
                            }
                        }
                    }
                    Auth::OAuth(_) => {
                        let pushed = logins.get(provider.id.as_ref()).is_some_and(LoginSource::has_pushed);
                        if pushed || kind == Some(StoredKind::Login) {
                            ProviderState::Ready
                        } else {
                            ProviderState::NeedsLogin
                        }
                    }
                };
                (all || state == ProviderState::Ready).then(|| catalog::provider_info(provider, state))
            })
            .collect();
        Ok(ListCatalogResult { providers })
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

/// The core of one mode of yuke: the store, the JavaScript runtime, the jobs, the logins, and the open sessions.
///
/// # Cancel safety
///
/// The methods are not cancel safe. A caller awaits each call to its end, as the request loop of `yuke --rpc` does.
pub(crate) struct App {
    shared: Arc<Shared>,
    runtime: Runtime,
    reporter: JoinHandle<()>,
    processes_folder: PathBuf,
    sessions: Arc<SessionService>,
}

impl App {
    /// Start the JavaScript runtime with the built-in tools, and load the bundled plugins and the plugins of
    /// `config.json`. The sessions keep their events in `store`. Before each retry of a model request, the app waits
    /// with `timer`. The app sends its notices, the updates of its sessions, and the plugin events to `observer`.
    ///
    /// # Errors
    ///
    /// Returns a text for the user when a part does not start.
    pub(crate) async fn start(
        machine: Machine,
        mode: Mode,
        observer: Arc<dyn Observer>,
        store: Arc<dyn Store>,
        timer: Arc<dyn Timer>,
    ) -> Result<App, String> {
        let (app, plugins) = Self::prepare(machine, mode, observer, store, timer).await?;
        app.load_plugins(&plugins).await;
        Ok(app)
    }

    /// [`App::start`] without the plugin load: the app, and the plugins for [`App::load_plugins`]. A caller that drops
    /// the load can still shut the app down.
    ///
    /// # Errors
    ///
    /// Returns a text for the user when a part does not start.
    pub(crate) async fn prepare(
        machine: Machine,
        mode: Mode,
        observer: Arc<dyn Observer>,
        store: Arc<dyn Store>,
        timer: Arc<dyn Timer>,
    ) -> Result<(App, Vec<yuke_js::Plugin>), String> {
        let providers = Providers::load(&machine.paths.config)?;
        let config: Config = read_json(&machine.paths.config.join("config.json"))?.unwrap_or_default();
        let mcp: yuke_mcp::Config = read_json(&machine.paths.config.join("mcp.json"))?.unwrap_or_default();
        let plugins = plugins::plugins(&machine.paths.config, &config, &machine.paths.data)?;
        // The full outputs of the commands and the logs of the jobs go to a folder of this process, which the shutdown
        // removes. A test keeps the folder in its own place.
        let processes_folder = match &machine.test {
            Some(test) => test.processes.clone(),
            None => std::env::temp_dir().join(format!(
                "yuke-{}-{:016x}",
                std::process::id(),
                RandomState::new().hash_one(0_u8)
            )),
        };
        let processes = Arc::new(match mode {
            Mode::Server => Processes::new(processes_folder.clone()),
            Mode::Print => Processes::without_jobs(processes_folder.clone()),
        });
        let shared = Arc::new(Shared {
            machine,
            profile: RwLock::new(Profile::new(providers, &plugins, &config)),
            store,
            timer,
            processes,
            observer,
            mode,
            mcp,
            last_question: Arc::default(),
            logins: Mutex::default(),
            pending_logins: Mutex::default(),
            last_login: AtomicU64::new(0),
        });
        let sessions = SessionService::new(Arc::clone(&shared));
        let (runtime, reporter) = match start_runtime(&shared, &sessions).await {
            Ok(started) => started,
            Err(error) => {
                if let Err(shutdown) = shared.processes.shutdown().await {
                    shared.warn(&format!("{}: {shutdown}", processes_folder.display()));
                }
                return Err(chain_text(&error));
            }
        };
        sessions.set_runtime(runtime.handle());
        let app = App {
            shared,
            runtime,
            reporter,
            processes_folder,
            sessions,
        };
        Ok((app, plugins))
    }

    /// Start the frame loop of the runtime on the display, with `snapshot` for its start event. The terminal interface
    /// calls it after the start and after each reload; without a display it does nothing.
    pub(crate) fn show(&mut self, snapshot: Option<String>) {
        self.runtime.show(snapshot);
    }

    /// Load `plugins`. Each plugin that does not load gives a notice, and the other plugins load.
    pub(crate) async fn load_plugins(&self, plugins: &[yuke_js::Plugin]) {
        self.report_failures(self.runtime.load_plugins(plugins).await);
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
    /// - Returns [`AppError::Changing`] while a call opens or closes a session.
    /// - Returns [`AppError::Invalid`] when yuke cannot read or check `config.json`, `providers.json`, or a plugin folder.
    /// - Returns [`AppError::Invalid`] when a plugin does not load.
    /// - Returns [`AppError::Internal`] when the new runtime does not start.
    ///
    /// Each error keeps the old plugins and providers.
    pub(crate) async fn reload(&mut self) -> Result<(), AppError> {
        let reload = self.sessions.start_reload()?;
        // A turn starts only under the session lock, so no turn starts while the reload holds each one.
        let mut held = Vec::with_capacity(reload.sessions.len());
        for live in &reload.sessions {
            held.push(live.try_hold().ok_or(AppError::TurnRuns)?);
        }
        let paths = &self.shared.machine.paths;
        let providers = Providers::load(&paths.config).map_err(AppError::Invalid)?;
        let config: Config = read_json(&paths.config.join("config.json"))
            .map_err(AppError::Invalid)?
            .unwrap_or_default();
        let plugins = plugins::plugins(&paths.config, &config, &paths.data).map_err(AppError::Invalid)?;
        // The new plugins use the new providers, for example in a model request of their `apply`.
        let profile = Profile::new(providers, &plugins, &config);
        let old_profile = std::mem::replace(
            &mut *self.shared.profile.write().unwrap_or_else(PoisonError::into_inner),
            profile,
        );
        // The new plugins load before the old plugins close. A runtime cannot load plugins after it closes its plugins.
        let (runtime, reporter) = match start_runtime(&self.shared, &self.sessions).await {
            Ok(started) => started,
            Err(error) => {
                *self.shared.profile.write().unwrap_or_else(PoisonError::into_inner) = old_profile;
                return Err(AppError::Internal(chain_text(&error)));
            }
        };
        let failures = runtime.load_plugins(&plugins).await;
        if !failures.is_empty() {
            // A plugin load failure rejects the reload. An edit with a fault keeps the old runtime.
            stop_runtime(&self.shared, runtime, reporter).await;
            *self.shared.profile.write().unwrap_or_else(PoisonError::into_inner) = old_profile;
            let texts: Vec<String> = failures.iter().map(|failure| chain_text(failure)).collect();
            return Err(AppError::Invalid(format!(
                "the reload keeps the old plugins, because a plugin did not load: {}",
                texts.join("; ")
            )));
        }
        let handle = runtime.handle();
        let mut opened = Vec::with_capacity(reload.sessions.len());
        for live in &reload.sessions {
            match live.open_plugins(&handle).await {
                Ok(script) => opened.push((live, script)),
                Err(error) => {
                    // Each cleanup ends before the runtime stops.
                    for (_, script) in opened {
                        live::close_plugins(&self.shared, &script).await;
                    }
                    stop_runtime(&self.shared, runtime, reporter).await;
                    *self.shared.profile.write().unwrap_or_else(PoisonError::into_inner) = old_profile;
                    return Err(error);
                }
            }
        }
        for (live, script) in opened {
            live.replace_plugins(script).await;
        }
        self.sessions.set_runtime(handle);
        let old_runtime = std::mem::replace(&mut self.runtime, runtime);
        let old_reporter = std::mem::replace(&mut self.reporter, reporter);
        stop_runtime(&self.shared, old_runtime, old_reporter).await;
        drop(held);
        drop(reload);
        Ok(())
    }

    /// The open sessions and the calls on them.
    pub(crate) fn sessions(&self) -> &Arc<SessionService> {
        &self.sessions
    }

    /// The store of the sessions.
    pub(crate) fn store(&self) -> &dyn Store {
        self.shared.store.as_ref()
    }

    /// The providers of the profile now.
    pub(crate) fn providers(&self) -> Arc<Providers> {
        self.shared.providers()
    }

    /// Start a device login of `provider`, and give its code. A login in progress of the provider ends as cancelled
    /// first. A task polls the provider, saves the login in `auth.json`, and sends `auth/login_finished`.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for a provider without a login flow, and [`AppError::Internal`] when the provider
    /// does not start the login.
    pub(crate) async fn login(&self, provider: String) -> Result<LoginResult, AppError> {
        let flow = self.shared.providers().login(&provider).map_err(AppError::Invalid)?.1;
        if let Some(earlier) = lock(&self.shared.pending_logins).remove(&provider) {
            earlier.stop.cancel();
        }
        let started = tokio::time::Instant::now();
        let pending = crate::auth::start_login(flow, &*self.shared.machine.exchange)
            .await
            .map_err(|error| AppError::Internal(error.to_string()))?;
        let login_id = LoginId(self.shared.last_login.fetch_add(1, Ordering::Relaxed) + 1);
        let stop = CancellationToken::new();
        let result = LoginResult {
            login_id,
            verification_url: pending.verification_url.clone(),
            user_code: pending.user_code.clone(),
        };
        let shared = Arc::clone(&self.shared);
        let task_provider = provider.clone();
        let task_stop = stop.clone();
        let task = tokio::spawn(async move {
            let (provider, stop) = (task_provider, task_stop);
            let exchange = Arc::clone(&shared.machine.exchange);
            // Only the polls stop at a cancel. A save that started ends, so the outcome tells what `auth.json` holds.
            let polled = tokio::select! {
                polled = crate::auth::poll_login(&pending, started, &*exchange) => Some(polled),
                () = stop.cancelled() => None,
            };
            let outcome = match polled {
                None => LoginOutcome::Cancelled,
                Some(Err(error)) => LoginOutcome::Failed {
                    message: error.to_string(),
                },
                Some(Ok(grant)) => {
                    match crate::auth::save_login(&provider, grant, shared.machine.paths.data.clone()).await {
                        Ok(()) => LoginOutcome::Succeeded,
                        Err(error) => LoginOutcome::Failed {
                            message: error.to_string(),
                        },
                    }
                }
            };
            {
                let mut pending = lock(&shared.pending_logins);
                // A newer login of the provider keeps its entry.
                if pending
                    .get(&provider)
                    .is_some_and(|in_progress| in_progress.id == login_id)
                {
                    pending.remove(&provider);
                }
            }
            shared
                .observer
                .notify(ServerNotification::LoginFinished(LoginFinishedParams {
                    login_id,
                    provider,
                    outcome,
                }));
        });
        // The first poll waits one interval, so the task cannot end before its entry is there.
        let in_progress = InProgress {
            id: login_id,
            stop,
            task,
        };
        lock(&self.shared.pending_logins).insert(provider, in_progress);
        Ok(result)
    }

    /// Ask the login `id` in progress to stop. Its `auth/login_finished` tells how it ended.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NoLogin`] when no login with this id is in progress.
    pub(crate) fn cancel_login(&self, id: LoginId) -> Result<(), AppError> {
        let pending = lock(&self.shared.pending_logins);
        let in_progress = pending
            .values()
            .find(|in_progress| in_progress.id == id)
            .ok_or(AppError::NoLogin(id))?;
        in_progress.stop.cancel();
        Ok(())
    }

    /// Remove what yuke stored for `provider`: its login or its API key in `auth.json`, and the token of
    /// `credential/update`. A login in progress of the provider ends first, and the removal comes after its task.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for an unknown provider, and [`AppError::Internal`] when yuke cannot update
    /// `auth.json`.
    pub(crate) async fn logout(&self, provider: &str) -> Result<(), AppError> {
        self.shared.providers().get(provider).map_err(AppError::Invalid)?;
        let earlier = lock(&self.shared.pending_logins).remove(provider);
        if let Some(earlier) = earlier {
            earlier.stop.cancel();
            // A save that started still ends, so the removal waits for the task and comes after the save.
            earlier
                .task
                .await
                .map_err(|error| AppError::Internal(format!("the login task failed: {error}")))?;
        }
        if let Some(source) = lock(&self.shared.logins).get(provider) {
            source.clear_push();
        }
        crate::auth::logout(provider, self.shared.machine.paths.data.clone())
            .await
            .map_err(|error| AppError::Internal(error.to_string()))
    }

    /// Store `api_key` in `auth.json` as the API key of `provider`. The variable of the provider wins when it is set and
    /// not empty.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for an unknown provider, a provider without an API key variable, or a bad key, and
    /// [`AppError::Internal`] when yuke cannot update `auth.json`.
    pub(crate) async fn set_api_key(&self, provider: &str, api_key: String) -> Result<(), AppError> {
        match &self.shared.providers().get(provider).map_err(AppError::Invalid)?.auth {
            Auth::ApiKey(Some(_)) => {}
            Auth::ApiKey(None) => return Err(AppError::Invalid(format!("{provider} takes no API key"))),
            Auth::OAuth(_) => {
                return Err(AppError::Invalid(format!(
                    "{provider} takes a login, not an API key: send auth/login"
                )));
            }
        }
        // A model request sends the key in a header, and a header holds no control character.
        if api_key.is_empty() || api_key.chars().any(char::is_control) {
            return Err(AppError::Invalid(
                "apiKey: send a value that is not empty and has no control character".to_owned(),
            ));
        }
        crate::auth::set_api_key(provider, api_key, self.shared.machine.paths.data.clone())
            .await
            .map_err(|error| AppError::Internal(error.to_string()))
    }

    /// The providers of the profile with their models: every provider with `all`, else only the ready ones.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Internal`] when `auth.json` does not read or holds no valid content.
    pub(crate) async fn catalog(&self, all: bool) -> Result<ListCatalogResult, AppError> {
        self.shared.catalog(all).await
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

    /// Close each session, close the plugins, stop the runtime, and stop the jobs.
    pub(crate) async fn shutdown(self) {
        let App {
            shared,
            runtime,
            reporter,
            processes_folder,
            sessions,
        } = self;
        sessions.close_all().await;
        stop_runtime(&shared, runtime, reporter).await;
        if let Err(error) = shared.processes.shutdown().await {
            shared.warn(&format!("{}: {error}", processes_folder.display()));
        }
    }
}

/// Why the app refused or failed a request.
#[derive(Debug)]
pub(crate) enum AppError {
    /// The session is not open.
    NotOpen(SessionId),
    /// The session is open, so the app cannot remove it.
    Open(SessionId),
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
    /// No login with this id is in progress.
    NoLogin(LoginId),
    /// The session has no blob with the requested digest.
    NoBlob,
    /// Another call opens or closes the session now.
    Changing(SessionId),
    /// A reload runs, so no session opens or closes.
    Reloading,
    /// The shutdown started, so no session opens.
    Stopped,
    /// The store failed.
    Store(StoreError),
    /// A part of yuke failed. The text tells why.
    Internal(String),
}

impl fmt::Display for AppError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AppError::NotOpen(id) => write!(f, "the session {id} is not open: create, fork, or load it first"),
            AppError::Open(id) => write!(f, "the session {id} is open: close it with session/close first"),
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
            AppError::NoLogin(id) => write!(f, "no login {} is in progress", id.0),
            AppError::NoBlob => f.write_str("the session has no blob with this digest"),
            AppError::Changing(id) => write!(
                f,
                "another call opens or closes the session {id}: try again when that call ends"
            ),
            AppError::Reloading => f.write_str("a reload runs: try again when the reload ends"),
            AppError::Stopped => f.write_str("yuke shuts down"),
            AppError::Store(error) => fmt::Display::fmt(error, f),
        }
    }
}

impl From<StoreError> for AppError {
    fn from(error: StoreError) -> Self {
        AppError::Store(error)
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
async fn start_runtime(
    shared: &Arc<Shared>,
    sessions: &Arc<SessionService>,
) -> Result<(Runtime, JoinHandle<()>), yuke_js::Error> {
    let test = shared.machine.test.as_ref();
    let (runtime, reports) = Runtime::start(Options {
        cache: test.map_or_else(|| shared.machine.paths.cache.join("js"), |test| test.cache.clone()),
        processes: Arc::clone(&shared.processes),
        models: Arc::new(PluginModels(Arc::clone(shared))),
        sessions: Arc::new(PluginSessions {
            service: Arc::downgrade(sessions),
            shared: Arc::clone(shared),
        }),
        http: Arc::clone(&shared.machine.fetch),
        interface: shared.machine.interface.clone(),
        internal_imports: test.is_some_and(|test| test.internal_imports),
        test_host: test.map(|test| Arc::clone(&test.host) as Arc<dyn yuke_js::TestHost>),
    })
    .await?;
    let copy = test.map(|test| test.reports.clone());
    let reporter = tokio::spawn(report(reports, Arc::clone(&shared.observer), copy));
    if let Err(error) = runtime.import("yuke:internal/builtins").await {
        stop_runtime(shared, runtime, reporter).await;
        return Err(error);
    }
    // The interface runs in the plugin runtime, so a plugin reaches it, and each reload draws it again.
    if shared.machine.interface.is_some()
        && let Err(error) = runtime.import("yuke:internal/tui").await
    {
        stop_runtime(shared, runtime, reporter).await;
        return Err(error);
    }
    Ok((runtime, reporter))
}

/// Close the plugins of `runtime`, and stop the runtime. Then wait for the end of `reporter`. The jobs go on, because
/// they belong to the processes.
async fn stop_runtime(shared: &Shared, runtime: Runtime, reporter: JoinHandle<()>) {
    if let Err(error) = runtime.close_plugins().await {
        shared.warn(&chain_text(&error));
    }
    if let Err(error) = runtime.shutdown().await {
        shared.warn(&chain_text(&error));
    }
    // The shutdown of the runtime closes the channel of the reports, so the reporter ends.
    if let Err(error) = reporter.await {
        shared.warn(&format!(
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
            let key = api_key(shared, &provider.id, name)?
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
            SessionError::Store(error) => error.into(),
            error => AppError::Internal(chain_text(&error)),
        })?;
    Ok(StoredEvent {
        event_number,
        event: SessionEvent::Settings(settings),
    })
}

/// The API key of the provider `id` with the variable `name`: the variable when it holds a key, else the key in
/// `auth.json`.
///
/// # Errors
///
/// Returns [`AppError::Internal`] when `auth.json` does not read or holds no valid content.
fn api_key(shared: &Shared, id: &str, name: &str) -> Result<Option<String>, AppError> {
    if let Some(key) = variable_key(shared, name) {
        return Ok(Some(key));
    }
    crate::auth::api_key(id, shared.machine.paths.data.clone()).map_err(|error| AppError::Internal(error.to_string()))
}

/// The API key in the environment variable `name`, when it is set, UTF-8, and not empty.
fn variable_key(shared: &Shared, name: &str) -> Option<String> {
    (shared.machine.variable)(name)
        .and_then(|key| key.into_string().ok())
        .filter(|key| !key.is_empty())
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

/// Send each report to `observer`. A script fault becomes a warning of yuke, and an entry of `console` becomes a notice
/// from the source `console`. A notice or an event of a plugin goes as it is. `copy`, the runner of a test, gets each
/// report first as it is.
async fn report(
    mut reports: mpsc::UnboundedReceiver<Report>,
    observer: Arc<dyn Observer>,
    copy: Option<mpsc::UnboundedSender<Report>>,
) {
    while let Some(report) = reports.recv().await {
        // The observer got each report before the barrier, so the test host can read what it recorded.
        if let Report::Barrier(barrier) = &report {
            barrier.release();
            continue;
        }
        if let Some(copy) = &copy
            && copy.send(report.clone()).is_err()
        {
            // The runner of the test has left.
        }
        let notification = match report {
            Report::Barrier(_) => continue,
            Report::Fault(fault) => ServerNotification::Notice(NoticeParams {
                session_id: None,
                level: NoticeLevel::Warn,
                source: SOURCE.to_owned(),
                message: format!("a script failed: {fault}"),
            }),
            Report::Notice(notice) => ServerNotification::Notice(notice),
            Report::Event(event) => ServerNotification::ExtensionEvent(event),
            Report::Console { level, text } => ServerNotification::Notice(NoticeParams {
                session_id: None,
                level,
                source: "console".to_owned(),
                message: text,
            }),
        };
        observer.notify(notification);
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

/// The store of the sessions in the data folder `data`.
///
/// # Errors
///
/// Returns a text for the user when the store does not open.
pub(crate) async fn open_store(data: &Path) -> Result<Arc<dyn Store>, String> {
    Ok(Arc::new(
        SqliteStore::open(data).await.map_err(|error| chain_text(&error))?,
    ))
}

/// Waits with the tokio timer.
pub(crate) struct TokioTimer;

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

    #[tokio::test]
    async fn a_console_entry_and_a_fault_become_notices() {
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

        report(receiver, Arc::clone(&recorder) as Arc<dyn Observer>, None).await;

        let notices: Vec<(NoticeLevel, String, String)> = lock(&recorder.0)
            .iter()
            .map(|notification| match notification {
                ServerNotification::Notice(notice) => (notice.level, notice.source.clone(), notice.message.clone()),
                other @ (ServerNotification::SessionUpdate(_)
                | ServerNotification::ExtensionEvent(_)
                | ServerNotification::ExtensionCancel(_)
                | ServerNotification::LoginFinished(_)) => {
                    panic!("expected a notice, got {other:?}")
                }
            })
            .collect();
        assert_eq!(
            notices,
            [
                (NoticeLevel::Error, "console".to_owned(), "for the operator".to_owned()),
                (
                    NoticeLevel::Warn,
                    "host:yuke".to_owned(),
                    "a script failed: lost".to_owned()
                ),
            ]
        );
    }
}
