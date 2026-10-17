//! The plugins of a runtime. Each plugin loads in the order of the list. A plugin whose provider failed does not run.

use std::collections::HashMap;
use std::fmt;
use std::path::PathBuf;

use rquickjs::{Ctx, Function, Module, Object, Promise};

use crate::Runtime;
use crate::error::{Error, caught};

/// The name of the internal module that loads a plugin.
const LOADER: &str = "yuke:internal/plugins";

/// One plugin of the list. The consumer checks the manifest, the names, and the order before the load.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plugin {
    /// The name of the plugin. It owns the tools of the plugin, and it is the source of its notices.
    pub name: String,
    /// The folder of the plugin.
    pub root: PathBuf,
    /// The data folder of the plugin. It must exist.
    pub data_dir: PathBuf,
    /// The entry module, or `None` for a plugin without code.
    pub entry: Option<PathBuf>,
    /// The services that the plugin gets from earlier plugins.
    pub uses: Vec<String>,
    /// The services that the plugin publishes.
    pub provides: Vec<String>,
}

/// A plugin that did not load.
#[derive(Debug)]
pub struct PluginFailure {
    /// The name of the plugin.
    pub name: String,
    /// Why the plugin did not load.
    pub reason: PluginError,
}

/// Why a plugin did not load.
#[derive(Debug)]
pub enum PluginError {
    /// The import of the entry or its `apply` failed.
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
    /// Load `plugins` in their order, and return each plugin that did not load. A failed plugin drops its tools. A
    /// plugin whose provider did not load does not run, and its own services fail with it.
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

    /// Load `plugin` on the JavaScript thread.
    async fn load_plugin(&self, plugin: &Plugin) -> Result<(), Error> {
        let plugin = plugin.clone();
        self.caller
            .run(async move |ctx: Ctx<'_>, _registry| {
                let promise = caught(&ctx, Module::import(&ctx, LOADER))?;
                let loader: Object<'_> = caught(&ctx, promise.into_future().await)?;
                let load: Function<'_> = caught(&ctx, loader.get("load"))?;
                let spec = caught(&ctx, crate::native::internal_record(&ctx))?;
                let path = |path: &PathBuf| path.to_string_lossy().into_owned();
                caught(&ctx, spec.set("name", plugin.name))?;
                caught(&ctx, spec.set("root", path(&plugin.root)))?;
                caught(&ctx, spec.set("dataDir", path(&plugin.data_dir)))?;
                caught(&ctx, spec.set("entry", plugin.entry.as_ref().map(path)))?;
                caught(&ctx, spec.set("uses", plugin.uses))?;
                caught(&ctx, spec.set("provides", plugin.provides))?;
                let promise: Promise<'_> = caught(&ctx, load.call((spec,)))?;
                caught(&ctx, promise.into_future::<()>().await)
            })
            .await
    }
}
