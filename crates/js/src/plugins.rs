//! The plugins of a runtime. Each plugin loads in the order of the list. A plugin whose provider failed does not run.

use std::collections::HashMap;
use std::fmt;
use std::path::PathBuf;

use rquickjs::{Ctx, Function, IntoJs, Module, Object, Promise};

use crate::Runtime;
use crate::error::{Error, caught};

/// The name of the internal module that loads a plugin.
const LOADER: &str = "yuke:internal/plugins";

/// One plugin of the list. The consumer checks the names and the order before the load, and the manifest of a folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plugin {
    /// The name of the plugin. It is the source of its notices.
    pub name: String,
    /// Where the code of the plugin comes from.
    pub origin: Origin,
    /// The data folder of the plugin. It must exist.
    pub data_dir: PathBuf,
    /// The services that the plugin gets from earlier plugins.
    pub uses: Vec<String>,
    /// The services that the plugin publishes.
    pub provides: Vec<String>,
}

/// Where the code of a plugin comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Origin {
    /// A folder of the profile.
    Folder {
        /// The folder of the plugin.
        root: PathBuf,
        /// The entry module, or `None` for a plugin without code.
        entry: Option<PathBuf>,
    },
    /// A module of the consumer, for example a `yuke:` name. The plugin has no folder, so its context has no `root`.
    Bundled {
        /// The name of the entry module.
        module: String,
    },
}

/// A plugin that did not load. Its text names the plugin and the reason.
#[derive(Debug)]
pub struct PluginFailure {
    /// The name of the plugin.
    pub(crate) name: String,
    /// Why the plugin did not load.
    pub(crate) reason: PluginError,
}

/// Why a plugin did not load.
#[derive(Debug)]
pub(crate) enum PluginError {
    /// The import of the entry, the check of its exports, or its `apply` failed.
    Load(Error),
    /// The plugin uses `service`, and its provider `provider` did not load. The plugin did not run.
    Provider {
        /// The service that the plugin uses.
        service: String,
        /// The plugin that provides the service.
        provider: String,
    },
}

impl fmt::Display for PluginFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.reason {
            PluginError::Load(error) => write!(f, "plugin {} did not load: {error}", self.name),
            PluginError::Provider { service, provider } => write!(
                f,
                "plugin {} did not load: it uses '{service}', and plugin {provider} that provides it did not load",
                self.name
            ),
        }
    }
}

impl std::error::Error for PluginFailure {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match &self.reason {
            // The text holds the text of the error, so the source is the source of the error.
            PluginError::Load(error) => std::error::Error::source(error),
            PluginError::Provider { .. } => None,
        }
    }
}

impl Runtime {
    /// Load `plugins` in their order. Run each `apply`, and keep each `session` for the sessions that open later.
    /// Return each plugin that did not load. A failed plugin runs no `session`. A plugin whose provider did not load does
    /// not run, and its own services fail with it.
    pub async fn load_plugins(&self, plugins: &[Plugin]) -> Vec<PluginFailure> {
        let mut failed: HashMap<&str, &str> = HashMap::new();
        let mut failures = Vec::new();
        for plugin in plugins {
            let lost = plugin
                .uses
                .iter()
                .find_map(|service| failed.get(service.as_str()).map(|provider| (service, *provider)));
            let reason = match lost {
                Some((service, provider)) => PluginError::Provider {
                    service: service.clone(),
                    provider: provider.to_owned(),
                },
                None => match self.load_plugin(plugin).await {
                    Ok(()) => continue,
                    Err(error) => PluginError::Load(error),
                },
            };
            for service in &plugin.provides {
                failed.insert(service, &plugin.name);
            }
            failures.push(PluginFailure {
                name: plugin.name.clone(),
                reason,
            });
        }
        failures
    }

    /// Close the loaded plugins: abort the signal of each one, then await the cleanup of each `apply`, newest plugin
    /// first, with no time limit. A failed cleanup is a notice. Call it after each session closed, before
    /// [`Runtime::shutdown`]; a second call does nothing.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Stopped`] when the thread has ended or ends during the close.
    pub async fn close_plugins(&self) -> Result<(), Error> {
        self.caller
            .run(async move |ctx: Ctx<'_>, _registry| {
                let close: Function<'_> = caught(&ctx, loader(&ctx).await?.get("closePlugins"))?;
                let promise: Promise<'_> = caught(&ctx, close.call(()))?;
                caught(&ctx, promise.into_future::<()>().await)
            })
            .await
    }

    /// Load `plugin` on the JavaScript thread.
    async fn load_plugin(&self, plugin: &Plugin) -> Result<(), Error> {
        let plugin = plugin.clone();
        self.caller
            .run(async move |ctx: Ctx<'_>, _registry| {
                let load: Function<'_> = caught(&ctx, loader(&ctx).await?.get("load"))?;
                let path = |path: &PathBuf| path.to_string_lossy().into_owned();
                let (root, entry) = match &plugin.origin {
                    Origin::Folder { root, entry } => (Some(path(root)), entry.as_ref().map(path)),
                    Origin::Bundled { module } => (None, Some(module.clone())),
                };
                let spec = PluginSpec {
                    name: plugin.name,
                    root,
                    data_dir: path(&plugin.data_dir),
                    entry,
                    uses: plugin.uses,
                    provides: plugin.provides,
                };
                let promise: Promise<'_> = caught(&ctx, load.call((spec,)))?;
                caught(&ctx, promise.into_future::<()>().await)
            })
            .await
    }
}

/// One plugin as `load` of the loader gets it.
#[derive(IntoJs)]
#[qjs(rename_all = "camelCase")]
struct PluginSpec {
    name: String,
    /// The folder of the plugin, or `None` for a bundled plugin.
    root: Option<String>,
    data_dir: String,
    entry: Option<String>,
    uses: Vec<String>,
    provides: Vec<String>,
}

/// The internal module that loads the plugins and opens their sessions.
pub(crate) async fn loader<'js>(ctx: &Ctx<'js>) -> Result<Object<'js>, Error> {
    let promise = caught(ctx, Module::import(ctx, LOADER))?;
    caught(ctx, promise.into_future().await)
}
