//! The core that the modes of yuke share: the store, the JavaScript runtime, the jobs, and the open sessions. `yuke -p`
//! and `yuke --rpc` drive their sessions through an [`App`], and the app tells them what happens with the notifications
//! of the protocol.

mod catalog;
mod facts;
mod live;
mod models;
mod plugin_sessions;
mod sessions;
mod test_host;
mod trust;

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::error::Error;
use std::ffi::OsString;
use std::fmt;
use std::hash::{BuildHasher, RandomState};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use async_trait::async_trait;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use yuke_agent::{Session, SessionError, Store, StoreError};
use yuke_ai::Credential;
use yuke_ai::catalog::Auth;
use yuke_ai::oauth::Flow;
use yuke_ai::transport::{Exchange, Transport};
use yuke_engine::{CancellationToken, CredentialSource, Model, Timer, chain_text};
use yuke_js::{Options, PluginCode, Processes, Report, Runtime};
use yuke_protocol::{
    ApplyPluginsParams, ApplyPluginsResult, CheckPluginsParams, CheckPluginsResult, ExtensionRequestParams,
    InteractionId, JobId, ListCatalogResult, ListPluginsResult, LoginFinishedParams, LoginId, LoginOutcome,
    LoginResult, ModelReference, NoticeLevel, NoticeParams, ProviderCredential, ProviderState, ResponseError,
    ServerNotification, SessionEvent, SessionId, SessionSettings, StoredEvent, SyncPluginsParams, SyncPluginsResult,
    UpdateCredentialParams,
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
pub(crate) type Variable = dyn Fn(&str) -> Option<OsString>;

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
    /// Every module can import the `yuke:internal/` modules, as in the tests of yuke. It is `false` in production.
    pub(crate) internal_imports: bool,
    /// What the app of a test needs beyond production, or `None` outside a test.
    pub(crate) test: Option<TestSetup>,
}

/// How the app runs: as a server that clients come to (`yuke --rpc`), or for one task with no client (`yuke -p`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RunMode {
    /// A background job runs until it ends, until a stop, or until the close of its session. A question waits for an
    /// answer, also while no client is connected.
    Server,
    /// A background job start fails, because the run ends with its turn. A job in a call runs. A question gets no answer.
    Print,
}

/// Receives the notifications of the app: the updates of each open session, and the notices. It also sends the
/// requests of the plugins to the client.
pub(crate) trait Observer {
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
pub(crate) struct Shared {
    machine: Machine,
    /// The parts of the profile that a reload replaces.
    profile: RefCell<Profile>,
    store: Arc<dyn Store>,
    /// Waits before each retry of a model request.
    timer: Rc<dyn Timer>,
    processes: Rc<Processes>,
    observer: Rc<dyn Observer>,
    mode: RunMode,
    /// The MCP servers of the user, from `mcp.json` in the config folder.
    mcp: yuke_mcp::Config,
    /// The id of the last question of any session.
    last_question: Rc<Cell<u64>>,
    /// The watches of `ctx.on`.
    facts: Rc<facts::Facts>,
    /// The credential of each provider with a login. One source serves each session, so one refresh serves all.
    logins: RefCell<HashMap<String, LoginSource>>,
    /// The login in progress of each provider, from `auth/login`.
    pending_logins: RefCell<HashMap<String, InProgress>>,
    /// The id of the last login of `auth/login`.
    last_login: Cell<u64>,
}

/// A login in progress: its id, the token that stops its polls, and its task.
struct InProgress {
    id: LoginId,
    stop: CancellationToken,
    task: JoinHandle<()>,
}

/// The profile data that a reload replaces. A reader clones it before an await.
struct Profile {
    /// The providers of `providers.json` and of the catalog.
    providers: Rc<Providers>,
    /// The folder of each plugin of the profile, in load order, also of a plugin that failed to load.
    plugin_folders: Rc<[PathBuf]>,
    /// The name of each plugin that the runtime loaded.
    loaded: Rc<[String]>,
    /// The wait of a session with running jobs and no holder before it closes, from `sessionIdleMinutes`.
    session_idle: Duration,
}

impl Profile {
    /// The profile of the config folder of `paths`, and its plugins in load order. It makes the data folder of each
    /// plugin. With `fallback`, a plugin list that does not load gives the bundled plugins alone and the error of the
    /// list.
    fn load(paths: &Paths, fallback: bool) -> Result<(Self, Vec<yuke_js::Plugin>, Option<String>), String> {
        let providers = Providers::load(&paths.config)?;
        let config: Config = read_json(&paths.config.join("config.json"))?.unwrap_or_default();
        let (plugins, failed) = match plugins::plugins(&paths.config, &config, &paths.data) {
            Ok(plugins) => (plugins, None),
            // The bundled plugins can fix the list, for example with a sync of the Git plugins and a reload.
            Err(error) if fallback => (plugins::bundled(&paths.config, &config, &paths.data)?, Some(error)),
            Err(error) => return Err(error),
        };
        plugins::create_data_folders(&plugins)?;
        let profile = Self {
            providers: Rc::new(providers),
            plugin_folders: Self::plugin_folders(&plugins),
            // A failure at the start leaves the list, and a failure of a reload keeps the old profile.
            loaded: plugins.iter().map(|plugin| plugin.name.clone()).collect(),
            session_idle: Duration::from_secs(
                60 * u64::from(config.session_idle_minutes.unwrap_or(SESSION_IDLE_MINUTES)),
            ),
        };
        Ok((profile, plugins, failed))
    }

    /// The root folder of each folder plugin of `plugins`, in their order.
    fn plugin_folders(plugins: &[yuke_js::Plugin]) -> Rc<[PathBuf]> {
        plugins
            .iter()
            .filter_map(|plugin| match &plugin.origin {
                PluginCode::Folder { root, .. } => Some(root.clone()),
                PluginCode::Bundled { .. } | PluginCode::Given => None,
            })
            .collect()
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
            text: text.to_owned(),
        }));
    }

    /// The providers now.
    fn providers(&self) -> Rc<Providers> {
        Rc::clone(&self.profile.borrow().providers)
    }

    /// The wait of a session with running jobs and no holder before it closes.
    fn session_idle(&self) -> Duration {
        self.profile.borrow().session_idle
    }

    /// The providers of the profile with their models: every provider with `all`, else only the ready ones. Only a ready
    /// provider has models.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Internal`] when `auth.json` does not read or holds no valid content.
    pub(crate) async fn catalog(&self, all: bool) -> Result<ListCatalogResult, AppError> {
        let stored = crate::auth::stored_kinds(self.machine.paths.data.clone())
            .await
            .map_err(|error| AppError::Internal(error.to_string()))?;
        let providers = self.providers();
        let logins = self.logins.borrow();
        let providers = providers
            .iter()
            .filter_map(|provider| {
                let kind = stored.get(provider.id.as_ref()).copied();
                let state = match &provider.auth {
                    Auth::ApiKey(None) => ProviderState::Ready {
                        credential: ProviderCredential::None,
                    },
                    // The order is the order of `api_key`, so the state names the key that a request uses.
                    Auth::ApiKey(Some(_)) if kind == Some(StoredKind::ApiKey) => ProviderState::Ready {
                        credential: ProviderCredential::StoredApiKey,
                    },
                    Auth::ApiKey(Some(name)) => {
                        if variable_key(self, name).is_some() {
                            ProviderState::Ready {
                                credential: ProviderCredential::Variable { name: name.to_string() },
                            }
                        } else {
                            ProviderState::NeedsApiKey {
                                variable: name.to_string(),
                            }
                        }
                    }
                    Auth::OAuth(_) => {
                        let pushed = logins.get(provider.id.as_ref()).is_some_and(LoginSource::has_pushed);
                        if pushed || kind == Some(StoredKind::Login) {
                            ProviderState::Ready {
                                credential: ProviderCredential::Login,
                            }
                        } else {
                            ProviderState::NeedsLogin
                        }
                    }
                };
                (all || matches!(state, ProviderState::Ready { .. })).then(|| catalog::provider_info(provider, state))
            })
            .collect();
        Ok(ListCatalogResult { providers })
    }

    /// Start a device login of `provider`, and give its code and a receiver of its end. A login in progress of the
    /// provider ends as cancelled first. A task polls the provider, saves the login in `auth.json`, and sends
    /// `auth/login_finished`.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for a provider without a login flow, and [`AppError::Internal`] when the provider
    /// does not start the login.
    pub(crate) async fn login(
        self: &Rc<Self>,
        provider: String,
    ) -> Result<(LoginResult, oneshot::Receiver<LoginOutcome>), AppError> {
        let flow = self.providers().login(&provider).map_err(AppError::Invalid)?.1;
        if let Some(earlier) = self.pending_logins.borrow_mut().remove(&provider) {
            earlier.stop.cancel();
        }
        let pending = crate::auth::start_login(flow, &*self.machine.exchange)
            .await
            .map_err(|error| AppError::Internal(error.to_string()))?;
        let login_id = LoginId(self.last_login.get() + 1);
        self.last_login.set(login_id.0);
        let stop = CancellationToken::new();
        let result = LoginResult {
            login_id,
            verification_url: pending.verification_url.clone(),
            user_code: pending.user_code.clone(),
        };
        let shared = Rc::clone(self);
        let task_provider = provider.clone();
        let task_stop = stop.clone();
        let (end, ended) = oneshot::channel();
        let task = tokio::task::spawn_local(async move {
            let (provider, stop) = (task_provider, task_stop);
            let exchange = Arc::clone(&shared.machine.exchange);
            // Only the polls stop at a cancel. A save that started ends, so the outcome tells what `auth.json` holds.
            let polled = tokio::select! {
                polled = crate::auth::poll_login(&pending, &*exchange) => Some(polled),
                () = stop.cancelled() => None,
            };
            let outcome = match polled {
                None => LoginOutcome::Cancelled,
                Some(Err(error)) => LoginOutcome::Failed {
                    error: error.to_string(),
                },
                Some(Ok(grant)) => {
                    match crate::auth::save_login(&provider, grant, shared.machine.paths.data.clone()).await {
                        Ok(()) => {
                            shared.facts.catalog_changed();
                            LoginOutcome::Succeeded
                        }
                        Err(error) => LoginOutcome::Failed {
                            error: error.to_string(),
                        },
                    }
                }
            };
            if end.send(outcome.clone()).is_err() {
                // A client of `auth/login` learns the end from the notification.
            }
            {
                let mut pending = shared.pending_logins.borrow_mut();
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
        self.pending_logins.borrow_mut().insert(provider, in_progress);
        Ok((result, ended))
    }

    /// Ask the login `id` in progress to stop. Its `auth/login_finished` tells how it ended.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::NoLogin`] when no login with this id is in progress.
    pub(crate) fn cancel_login(&self, id: LoginId) -> Result<(), AppError> {
        let pending = self.pending_logins.borrow();
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
        self.providers().get(provider).map_err(AppError::Invalid)?;
        let earlier = self.pending_logins.borrow_mut().remove(provider);
        if let Some(earlier) = earlier {
            earlier.stop.cancel();
            // A save that started still ends, so the removal waits for the task and comes after the save.
            earlier
                .task
                .await
                .map_err(|error| AppError::Internal(format!("the login task failed: {error}")))?;
        }
        if let Some(source) = self.logins.borrow().get(provider) {
            source.clear_push();
        }
        crate::auth::logout(provider, self.machine.paths.data.clone())
            .await
            .map_err(|error| AppError::Internal(error.to_string()))?;
        self.facts.catalog_changed();
        Ok(())
    }

    /// Store `api_key` in `auth.json` as the API key of `provider`. The new key replaces the stored key and wins over
    /// the variable of the provider.
    ///
    /// # Errors
    ///
    /// Returns [`AppError::Invalid`] for an unknown provider, a provider without an API key variable, or a bad key, and
    /// [`AppError::Internal`] when yuke cannot update `auth.json`.
    pub(crate) async fn set_api_key(&self, provider: &str, api_key: String) -> Result<(), AppError> {
        match &self.providers().get(provider).map_err(AppError::Invalid)?.auth {
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
        crate::auth::set_api_key(provider, api_key, self.machine.paths.data.clone())
            .await
            .map_err(|error| AppError::Internal(error.to_string()))?;
        self.facts.catalog_changed();
        Ok(())
    }

    /// The plugins of `config.json` with their state, for `plugin/list`.
    pub(crate) fn list_plugins(&self) -> Result<ListPluginsResult, AppError> {
        let loaded = Rc::clone(&self.profile.borrow().loaded);
        let plugins = plugins::manager::list(&self.machine.paths, &loaded).map_err(AppError::Invalid)?;
        Ok(ListPluginsResult { plugins })
    }

    /// Install the locked commits and lock the new Git plugins, for `plugin/sync`.
    pub(crate) async fn sync_plugins(&self, params: SyncPluginsParams) -> Result<SyncPluginsResult, AppError> {
        plugins::manager::sync(&self.machine.paths, params.locked)
            .await
            .map_err(AppError::Invalid)
    }

    /// The new commits of the Git plugins of the target, for `plugin/check`.
    pub(crate) async fn check_plugins(&self, params: CheckPluginsParams) -> Result<CheckPluginsResult, AppError> {
        let changes = plugins::manager::check(&self.machine.paths, &params.target)
            .await
            .map_err(AppError::Invalid)?;
        Ok(CheckPluginsResult { changes })
    }

    /// Write the new commits of changes into `plugins.lock`, for `plugin/apply`.
    pub(crate) async fn apply_plugins(&self, params: ApplyPluginsParams) -> Result<ApplyPluginsResult, AppError> {
        let written = plugins::manager::apply(&self.machine.paths, &params.changes)
            .await
            .map_err(AppError::Invalid)?;
        Ok(ApplyPluginsResult { written })
    }

    /// Add a Git plugin to `config.json`, and install and lock it, for `plugin/add`.
    pub(crate) async fn add_plugin(
        &self,
        params: yuke_protocol::AddPluginParams,
    ) -> Result<yuke_protocol::AddPluginResult, AppError> {
        let options = params.options.unwrap_or_default();
        plugins::manager::add(&self.machine.paths, params.source, options)
            .await
            .map_err(AppError::Invalid)
    }

    /// Remove a plugin from `config.json` and `plugins.lock`, for `plugin/remove`.
    pub(crate) async fn remove_plugin(&self, params: yuke_protocol::RemovePluginParams) -> Result<(), AppError> {
        plugins::manager::remove(&self.machine.paths, &params.name)
            .await
            .map_err(AppError::Invalid)
    }

    /// The plugin folders now.
    fn plugin_folders(&self) -> Rc<[PathBuf]> {
        Rc::clone(&self.profile.borrow().plugin_folders)
    }
}

/// The core of one mode of yuke: the store, the JavaScript runtime, the jobs, the logins, and the open sessions.
///
/// # Cancel safety
///
/// The methods are not cancel safe. A caller awaits each call to its end, as the request loop of `yuke --rpc` does.
pub(crate) struct App {
    shared: Rc<Shared>,
    runtime: Runtime,
    reporter: JoinHandle<()>,
    processes_folder: PathBuf,
    sessions: Rc<SessionService>,
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
        mode: RunMode,
        observer: Rc<dyn Observer>,
        store: Arc<dyn Store>,
        timer: Rc<dyn Timer>,
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
        mode: RunMode,
        observer: Rc<dyn Observer>,
        store: Arc<dyn Store>,
        timer: Rc<dyn Timer>,
    ) -> Result<(App, Vec<yuke_js::Plugin>), String> {
        let mcp: yuke_mcp::Config = read_json(&machine.paths.config.join("mcp.json"))?.unwrap_or_default();
        let facts = Rc::new(facts::Facts::default());
        let observer: Rc<dyn Observer> = Rc::new(facts::Noticed {
            observer,
            facts: Rc::clone(&facts),
        });
        // A one-task run without the plugins of the user is a wrong run, so it fails instead.
        let (profile, plugins, failed) = Profile::load(&machine.paths, mode == RunMode::Server)?;
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
        let processes = Rc::new(match mode {
            RunMode::Server => Processes::new(processes_folder.clone()),
            RunMode::Print => Processes::without_jobs(processes_folder.clone()),
        });
        let shared = Rc::new(Shared {
            machine,
            profile: RefCell::new(profile),
            store,
            timer,
            processes,
            observer,
            mode,
            mcp,
            last_question: Rc::default(),
            facts,
            logins: RefCell::default(),
            pending_logins: RefCell::default(),
            last_login: Cell::new(0),
        });
        if let Some(error) = failed {
            shared.observer.notify(ServerNotification::Notice(NoticeParams {
                session_id: None,
                level: NoticeLevel::Error,
                source: SOURCE.to_owned(),
                text: format!("only the bundled plugins run, because the plugin list did not load: {error}"),
            }));
        }
        let sessions = SessionService::new(Rc::clone(&shared));
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
        if !failures.is_empty() {
            let mut profile = self.shared.profile.borrow_mut();
            let loaded = profile
                .loaded
                .iter()
                .filter(|name| !failures.iter().any(|failure| failure.name() == *name));
            profile.loaded = loaded.cloned().collect();
        }
        for failure in failures {
            self.shared.observer.notify(ServerNotification::Notice(NoticeParams {
                session_id: None,
                level: NoticeLevel::Error,
                source: SOURCE.to_owned(),
                text: chain_text(&failure),
            }));
        }
    }

    /// Load the plugins of `config.json` and the providers of `providers.json` again. Each open session stays open. Its
    /// process jobs go on, and its plugin jobs stop. Its next turn takes the tools and hooks of the new plugins. A new
    /// session scans the skill folders of the new plugin list.
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
        // The new plugins use the new providers, for example in a model request of their `apply`.
        let (profile, plugins, _) = Profile::load(&self.shared.machine.paths, false).map_err(AppError::Invalid)?;
        let old_profile = std::mem::replace(&mut *self.shared.profile.borrow_mut(), profile);
        // The new plugins load before the old plugins close. A runtime cannot load plugins after it closes its plugins.
        let (runtime, reporter) = match start_runtime(&self.shared, &self.sessions).await {
            Ok(started) => started,
            Err(error) => {
                *self.shared.profile.borrow_mut() = old_profile;
                return Err(AppError::Internal(chain_text(&error)));
            }
        };
        let failures = runtime.load_plugins(&plugins).await;
        if !failures.is_empty() {
            // A plugin load failure rejects the reload. An edit with a fault keeps the old runtime.
            stop_runtime(&self.shared, runtime, reporter).await;
            *self.shared.profile.borrow_mut() = old_profile;
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
                    *self.shared.profile.borrow_mut() = old_profile;
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
    pub(crate) fn sessions(&self) -> &Rc<SessionService> {
        &self.sessions
    }

    /// The store of the sessions.
    pub(crate) fn store(&self) -> &dyn Store {
        self.shared.store.as_ref()
    }

    /// The providers of the profile now.
    pub(crate) fn providers(&self) -> Rc<Providers> {
        self.shared.providers()
    }

    /// The parts that the open sessions share: the logins, the credentials, and the plugin manager calls.
    pub(crate) fn shared(&self) -> &Rc<Shared> {
        &self.shared
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
        self.shared.facts.catalog_changed();
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
    /// The session runs no job with this id.
    NoJob(JobId),
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
    shared: &Rc<Shared>,
    sessions: &Rc<SessionService>,
) -> Result<(Runtime, JoinHandle<()>), yuke_js::Error> {
    let test = shared.machine.test.as_ref();
    let (runtime, reports) = Runtime::start(Options {
        cache: test.map_or_else(|| shared.machine.paths.cache.join("js"), |test| test.cache.clone()),
        processes: Rc::clone(&shared.processes),
        models: Rc::new(PluginModels(Rc::clone(shared))),
        sessions: Rc::new(PluginSessions {
            login_ends: RefCell::default(),
            service: Rc::downgrade(sessions),
            shared: Rc::clone(shared),
        }),
        http: Arc::clone(&shared.machine.fetch),
        interface: shared.machine.interface.clone(),
        internal_imports: shared.machine.internal_imports,
        test_host: test.map(|test| Rc::clone(&test.host) as Rc<dyn yuke_js::TestHost>),
    })
    .await?;
    let copy = test.map(|test| test.reports.clone());
    let reporter = tokio::task::spawn_local(report(reports, Rc::clone(&shared.observer), copy));
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

/// Close the plugins of `runtime`, and stop the runtime. Then wait for the end of `reporter`. The process jobs go on,
/// because they belong to the processes.
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
            let key = api_key(shared, &provider.id, name)?.ok_or_else(|| {
                AppError::Invalid(format!(
                    "no API key for {}: run /login {} or set {name}",
                    provider.name, provider.id
                ))
            })?;
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

/// The API key of the provider `id` with the variable `name`: the key in `auth.json`, else the variable when it holds a
/// key.
///
/// # Errors
///
/// Returns [`AppError::Internal`] when `auth.json` does not read or holds no valid content.
fn api_key(shared: &Shared, id: &str, name: &str) -> Result<Option<String>, AppError> {
    let stored = crate::auth::api_key(id, shared.machine.paths.data.clone())
        .map_err(|error| AppError::Internal(error.to_string()))?;
    Ok(stored.or_else(|| variable_key(shared, name)))
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
    let mut logins = shared.logins.borrow_mut();
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
    observer: Rc<dyn Observer>,
    copy: Option<mpsc::UnboundedSender<Report>>,
) {
    while let Some(report) = reports.recv().await {
        if let Some(copy) = &copy
            && copy.send(report.clone()).is_err()
        {
            // The runner of the test has left.
        }
        let notification = match report {
            Report::Fault(fault) => ServerNotification::Notice(NoticeParams {
                session_id: None,
                level: NoticeLevel::Warn,
                source: SOURCE.to_owned(),
                text: format!("a script failed: {fault}"),
            }),
            Report::Notice(notice) => ServerNotification::Notice(notice),
            Report::Event(event) => ServerNotification::ExtensionEvent(event),
            Report::Console { level, text } => ServerNotification::Notice(NoticeParams {
                session_id: None,
                level,
                source: "console".to_owned(),
                text,
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

#[async_trait(?Send)]
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
    struct Recorder(RefCell<Vec<ServerNotification>>);

    impl Observer for Recorder {
        fn notify(&self, notification: ServerNotification) {
            self.0.borrow_mut().push(notification);
        }
    }

    #[tokio::test(flavor = "local")]
    async fn a_console_entry_and_a_fault_become_notices() {
        let (reports, receiver) = mpsc::unbounded_channel();
        let recorder = Rc::new(Recorder::default());
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

        report(receiver, Rc::clone(&recorder) as Rc<dyn Observer>, None).await;

        let notices: Vec<(NoticeLevel, String, String)> = recorder
            .0
            .borrow_mut()
            .iter()
            .map(|notification| match notification {
                ServerNotification::Notice(notice) => (notice.level, notice.source.clone(), notice.text.clone()),
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
