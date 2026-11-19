//! The plugins of yuke and of the profile: the bundled plugins, then the `plugins` list of `config.json` and the Agent
//! Plugins `plugin.json` of each folder. The checks run before any plugin code. A plugin that fails a check does not
//! load, and the other plugins load. A bad `config.json` or `plugins.lock` stops the whole list.

mod git;
mod lock;
pub(crate) mod manager;

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::{Map, Value};
use yuke_js::{Plugin, PluginCode};

use self::lock::Lock;
use crate::config::{Config, ConfigPlugin, Source, read_json, without_comments};

/// The name of the manifest in each plugin folder.
const MANIFEST: &str = "plugin.json";

/// The extension of yuke in a manifest (Agent Plugins 1.1.0, section 8).
const EXTENSION: &str = "sh.yuke";

/// The fields of `plugin.json` that yuke reads. It ignores the other portable fields.
#[derive(Deserialize)]
struct Manifest {
    name: String,
    #[serde(default)]
    extensions: Map<String, Value>,
}

/// The fields of yuke in `extensions["sh.yuke"]`. Another field, such as `activation`, is an error.
#[derive(Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
struct YukeFields {
    entry: Option<String>,
    uses: Vec<String>,
    provides: Vec<String>,
}

/// A plugin of the binary.
struct Bundled {
    name: &'static str,
    /// The `yuke:` name of its entry module.
    module: &'static str,
    uses: &'static [&'static str],
    provides: &'static [&'static str],
}

/// The plugins of the binary, in list order.
const BUNDLED: &[Bundled] = &[
    Bundled {
        name: "compaction",
        module: "yuke:internal/bundled/compaction",
        uses: &[],
        provides: &[],
    },
    // The saved theme comes before the plugins that draw, so their first frame has its look.
    Bundled {
        name: "themes",
        module: "yuke:internal/bundled/themes",
        uses: &[],
        provides: &[],
    },
    Bundled {
        name: "chat",
        module: "yuke:internal/bundled/chat",
        uses: &[],
        provides: &["chat"],
    },
    Bundled {
        name: "sessions",
        module: "yuke:internal/bundled/sessions",
        uses: &["chat"],
        provides: &[],
    },
    Bundled {
        name: "files",
        module: "yuke:internal/bundled/files",
        uses: &["chat"],
        provides: &[],
    },
    Bundled {
        name: "bar",
        module: "yuke:internal/bundled/bar",
        uses: &[],
        provides: &[],
    },
    Bundled {
        name: "toasts",
        module: "yuke:internal/bundled/toasts",
        uses: &[],
        provides: &[],
    },
    Bundled {
        name: "login",
        module: "yuke:internal/bundled/login",
        uses: &[],
        provides: &[],
    },
    Bundled {
        name: "plugins",
        module: "yuke:internal/bundled/plugins",
        uses: &[],
        provides: &[],
    },
];

/// The plugins of a profile: the plugins to load, and the outcome of each plugin of `config.json`.
#[derive(Debug, PartialEq)]
pub(crate) struct PluginList {
    /// The plugins to load, in load order.
    pub(crate) load: Vec<Plugin>,
    /// One outcome for each plugin of `config.json`, in its order.
    pub(crate) outcomes: Vec<Outcome>,
}

/// A plugin of `config.json` at a load.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Outcome {
    /// The plugin as `config.json` names it.
    pub(crate) source: Source,
    /// The name of its manifest, when the manifest reads.
    pub(crate) name: Option<String>,
    /// The commit of a Git plugin in `plugins.lock`, when the lock has one.
    pub(crate) commit: Option<String>,
    /// Why the plugin does not load. `None` for a plugin that loads.
    pub(crate) failure: Option<Failure>,
}

/// Why a plugin of `config.json` does not load.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Failure {
    /// A Git plugin without its commit in `plugins.lock` or on disk. A sync installs it.
    NotInstalled,
    /// The text of the problem, which names the plugin.
    Invalid(String),
}

impl Outcome {
    /// The name of the plugin, else the last part of its folder or of its URL.
    pub(crate) fn label(&self) -> &str {
        if let Some(name) = &self.name {
            return name;
        }
        match &self.source {
            Source::Folder(folder) => last_part(folder),
            Source::Git(source) => last_part(source.folder.as_deref().unwrap_or(&source.git)),
        }
    }

    /// The text of the failure, which names the plugin. `None` for a plugin that loads.
    pub(crate) fn failure_text(&self) -> Option<String> {
        Some(match self.failure.as_ref()? {
            Failure::NotInstalled => format!(
                "plugin {} did not load: it is not installed: /plugins or `yuke plugin sync` installs it",
                self.label()
            ),
            Failure::Invalid(text) => text.clone(),
        })
    }
}

/// The last part of the folder or the URL `text`, without a `.git` end.
fn last_part(text: &str) -> &str {
    let last = text.trim_end_matches('/').rsplit(['/', ':']).next().unwrap_or_default();
    last.strip_suffix(".git").unwrap_or(last)
}

/// The plugins of the profile. The bundled plugins come first, without the ones that `config.disable` names. Each one
/// gets its options from `config.bundled`. Then the plugins of `config.plugins` follow in their order. [`load_order`]
/// moves each provider before the plugins that use it. A relative folder starts in `config_folder`. A Git plugin loads
/// from [`git_folder`] at its commit in `plugins.lock`, with no network. A plugin that is not installed, that has a bad
/// folder or manifest, or that fails [`check_conflicts`] does not load. The data folder of each plugin is
/// `<data>/plugins/<name>`. [`create_data_folders`] makes these folders.
///
/// # Errors
///
/// Returns a text for a `disable` or `bundled` name that no bundled plugin has, or for a bad `plugins.lock`.
pub(crate) fn plugins(config_folder: &Path, config: &Config, data: &Path) -> Result<PluginList, String> {
    with_bundled(BUNDLED, config_folder, config, data)
}

/// [`plugins`] with the bundled plugins `bundled`.
fn with_bundled(bundled: &[Bundled], config_folder: &Path, config: &Config, data: &Path) -> Result<PluginList, String> {
    let known = |name: &str| bundled.iter().any(|plugin| plugin.name == name);
    if let Some(name) = config.disable.iter().find(|name| !known(name)) {
        return Err(format!(
            "config.json: disable names '{name}', which is not a bundled plugin"
        ));
    }
    if let Some(name) = config.bundled.keys().find(|name| !known(name)) {
        return Err(format!(
            "config.json: bundled names '{name}', which is not a bundled plugin"
        ));
    }
    let mut plugins: Vec<Plugin> = bundled
        .iter()
        .filter(|plugin| !config.disable.iter().any(|disabled| disabled == plugin.name))
        .map(|plugin| Plugin {
            name: plugin.name.to_owned(),
            origin: PluginCode::Bundled {
                module: plugin.module.to_owned(),
            },
            data_dir: data.join("plugins").join(plugin.name),
            options: config.bundled.get(plugin.name).cloned().unwrap_or_default(),
            uses: plugin.uses.iter().map(|&service| service.to_owned()).collect(),
            provides: plugin.provides.iter().map(|&service| service.to_owned()).collect(),
        })
        .collect();
    let lock = Lock::read_for(config_folder, config)?;
    let mut outcomes = Vec::with_capacity(config.plugins.len());
    for ConfigPlugin { source, options } in &config.plugins {
        let (root, commit) = match source {
            Source::Folder(folder) => (Some(config_folder.join(folder)), None),
            Source::Git(git) => {
                let commit = lock.commits.get(git).cloned();
                let root = (commit.as_ref())
                    .map(|commit| git_folder(data, &git.git, commit))
                    .filter(|installed| installed.is_dir())
                    .map(|installed| installed.join(git.folder.as_deref().unwrap_or_default()));
                (root, commit)
            }
        };
        let read = root.map(|root| {
            let root = root.canonicalize().map_err(|error| error.to_string())?;
            read_manifest(&root).map(|manifest| (root, manifest))
        });
        // A plugin with bad fields still has a name, so the list and a remove can find it.
        let name = (read.as_ref())
            .and_then(|read| read.as_ref().ok())
            .map(|(_, manifest)| manifest.name.clone());
        let mut outcome = Outcome {
            source: source.clone(),
            name,
            commit,
            failure: None,
        };
        let checked = read.map(|read| {
            read.and_then(|(root, manifest)| plugin_of(&root, manifest, data, options.clone()))
                .and_then(|plugin| check_conflicts(&plugins, &plugin).map(|()| plugin))
        });
        outcome.failure = match checked {
            None => Some(Failure::NotInstalled),
            Some(Ok(plugin)) => {
                plugins.push(plugin);
                None
            }
            Some(Err(error)) => Some(Failure::Invalid(format!(
                "plugin {} did not load: {error}",
                outcome.label()
            ))),
        };
        outcomes.push(outcome);
    }
    Ok(PluginList {
        load: load_order(plugins),
        outcomes,
    })
}

/// The folder name of the repository `url` in `<data>/git` and `<cache>/git`. The name is the last part of the URL, and
/// the hash of the whole URL keeps two repositories of one name apart.
pub(crate) fn repository_key(url: &str) -> String {
    // The URL is not a safe folder name, so each other character becomes `-`.
    let name = last_part(url).replace(|c: char| !c.is_ascii_alphanumeric() && !"-_.".contains(c), "-");
    let hash = yuke_agent::blob_of(url.as_bytes()).digest.to_string();
    format!("{name}-{}", &hash[..16])
}

/// The install of the commit `commit` of the repository `url`: `<data>/git/<key>/<commit>`.
pub(crate) fn git_folder(data: &Path, url: &str, commit: &str) -> PathBuf {
    data.join("git").join(repository_key(url)).join(commit)
}

/// Make the data folder of each plugin of `plugins`.
///
/// # Errors
///
/// Returns a text that names the folder that yuke cannot make.
pub(crate) fn create_data_folders(plugins: &[Plugin]) -> Result<(), String> {
    for plugin in plugins {
        std::fs::create_dir_all(&plugin.data_dir).map_err(|error| format!("{}: {error}", plugin.data_dir.display()))?;
    }
    Ok(())
}

/// The services of yuke itself, as `HostService` of `yuke:plugins` names them.
const HOST_SERVICES: [&str; 3] = ["tui", "sessions", "catalog"];

/// Check `plugin` against `plugins`, the plugins before it. Its name and each service that it provides must be new,
/// and no plugin provides a service of yuke.
///
/// # Errors
///
/// Returns the text of the first rule that `plugin` breaks.
pub(crate) fn check_conflicts(plugins: &[Plugin], plugin: &Plugin) -> Result<(), String> {
    match plugins.iter().find(|other| other.name == plugin.name) {
        Some(Plugin {
            origin: PluginCode::Bundled { .. },
            ..
        }) => {
            return Err(format!(
                "a bundled plugin has this name: add \"{}\" to \"disable\" in config.json to replace it",
                plugin.name
            ));
        }
        Some(_) => return Err("another plugin of the list has this name".to_owned()),
        None => {}
    }
    for service in &plugin.provides {
        if HOST_SERVICES.contains(&service.as_str()) {
            return Err(format!("'{service}' is a service of yuke, and no plugin provides it"));
        }
        if let Some(provider) = plugins.iter().find(|other| other.provides.contains(service)) {
            return Err(format!("plugin {} provides '{service}' already", provider.name));
        }
    }
    Ok(())
}

/// The load order of `plugins`: each provider before each plugin that uses it, else the order of the list. The plugins
/// whose services no plugin can give first go last, and the runtime does not run them.
pub(crate) fn load_order(plugins: Vec<Plugin>) -> Vec<Plugin> {
    // Each step takes the first plugin of the list whose services loaded. A plugin moves only for its providers.
    let mut waiting = plugins;
    let mut loaded: HashSet<String> = HashSet::new();
    let mut order = Vec::with_capacity(waiting.len());
    while let Some(index) = waiting
        .iter()
        .position(|plugin| plugin.uses.iter().all(|service| loaded.contains(service)))
    {
        let plugin = waiting.remove(index);
        loaded.extend(plugin.provides.iter().cloned());
        order.push(plugin);
    }
    order.extend(waiting);
    order
}

/// Read the manifest of `root` and check its name.
fn read_manifest(root: &Path) -> Result<Manifest, String> {
    let path = root.join(MANIFEST);
    let manifest: Manifest = read_json(&path)?.ok_or_else(|| format!("{}: the file does not exist", path.display()))?;
    valid_name(&manifest.name)?;
    Ok(manifest)
}

/// The manifest of the text `text` of a `plugin.json`, with its name checked.
fn parse_manifest(text: &str) -> Result<Manifest, String> {
    let manifest: Manifest = serde_json::from_str(&without_comments(text)).map_err(|error| error.to_string())?;
    valid_name(&manifest.name)?;
    Ok(manifest)
}

/// The plugin of the folder `root`, from its manifest, with the `options` of `config.json`.
pub(crate) fn manifest_plugin(root: &Path, data: &Path, options: Map<String, Value>) -> Result<Plugin, String> {
    plugin_of(root, read_manifest(root)?, data, options)
}

/// The plugin of the folder `root` with the manifest `manifest` and the `options` of `config.json`.
fn plugin_of(root: &Path, manifest: Manifest, data: &Path, options: Map<String, Value>) -> Result<Plugin, String> {
    let path = root.join(MANIFEST);
    let fields: YukeFields = match manifest.extensions.get(EXTENSION) {
        Some(value) => YukeFields::deserialize(value)
            .map_err(|error| format!("{}: extensions.\"{EXTENSION}\": {error}", path.display()))?,
        None => YukeFields::default(),
    };
    let entry = match fields.entry {
        None => None,
        Some(entry) => {
            let path = Path::new(&entry);
            // The loader reads a module by these two extensions.
            if !path
                .extension()
                .is_some_and(|extension| extension == "ts" || extension == "js")
            {
                return Err(format!("entry: '{entry}' is not a .ts or a .js file"));
            }
            Some(root.join(path))
        }
    };
    if entry.is_none() && !fields.provides.is_empty() {
        return Err("provides: a plugin without an entry cannot provide a service".to_owned());
    }
    Ok(Plugin {
        data_dir: data.join("plugins").join(&manifest.name),
        name: manifest.name,
        origin: PluginCode::Folder {
            root: root.to_owned(),
            entry,
        },
        options,
        uses: fields.uses,
        provides: fields.provides,
    })
}

/// Check the Agent Plugins name rule: 1 to 64 lowercase letters, digits, `-`, and `.`, a letter or a digit at each end,
/// and no `--` or `..`.
pub(crate) fn valid_name(name: &str) -> Result<(), String> {
    let allowed = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '.';
    let ends = |c: Option<char>| c.is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    let valid = (1..=64).contains(&name.len())
        && name.chars().all(allowed)
        && ends(name.chars().next())
        && ends(name.chars().last())
        && !name.contains("--")
        && !name.contains("..");
    if valid {
        Ok(())
    } else {
        Err(format!(
            "name: '{name}' must be 1 to 64 lowercase letters, digits, '-', or '.', start and end with a letter or a \
             digit, and have no '--' or '..'"
        ))
    }
}

#[cfg(test)]
mod tests;
