//! The plugins of yuke and of the profile: the bundled plugins, then the `plugins` list of `config.json` and the Agent
//! Plugins `plugin.json` of each folder. The checks run before any plugin code: a bad list stops the start.

mod git;
mod lock;
pub(crate) mod manager;

use std::collections::{HashMap, HashSet};
use std::path::{Component, Path, PathBuf};

use serde::Deserialize;
use serde_json::{Map, Value};
use yuke_js::{Origin, Plugin};

use self::lock::Lock;
use crate::config::{Config, ConfigPlugin, Source, read_json};

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
#[serde(deny_unknown_fields)]
struct YukeFields {
    #[serde(default)]
    entry: Option<String>,
    #[serde(default)]
    uses: Vec<String>,
    #[serde(default)]
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
];

/// The plugins to load, in load order. The list has the bundled plugins first, without the ones that `config.disable`
/// names. Each one gets its options from `config.bundled`. Then the plugins of `config.plugins` follow in their order.
/// [`load_order`] moves each provider before the plugins that use it. A relative folder starts in `config_folder`. A Git
/// plugin loads from [`git_folder`] at its commit in `plugins.lock`, with no network. The data folder of each plugin is
/// `<data>/plugins/<name>`. [`create_data_folders`] makes these folders.
///
/// # Errors
///
/// Returns a text that names the plugin or the file, and the problem. The problem is an unreadable folder or manifest, a
/// bad name or field, or a duplicate name. It can also be two providers of one service, a missing provider, or a cycle
/// of uses. A `disable` or `bundled` name that no bundled plugin has is an error too. So is a bad `plugins.lock`, or a
/// Git plugin without its commit in the lock or on disk.
pub(crate) fn plugins(config_folder: &Path, config: &Config, data: &Path) -> Result<Vec<Plugin>, String> {
    with_bundled(BUNDLED, config_folder, config, data)
}

/// [`plugins`] with the bundled plugins `bundled`.
fn with_bundled(
    bundled: &[Bundled],
    config_folder: &Path,
    config: &Config,
    data: &Path,
) -> Result<Vec<Plugin>, String> {
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
            origin: Origin::Bundled {
                module: plugin.module.to_owned(),
            },
            data_dir: data.join("plugins").join(plugin.name),
            options: config.bundled.get(plugin.name).cloned().unwrap_or_default(),
            uses: plugin.uses.iter().map(|&service| service.to_owned()).collect(),
            provides: plugin.provides.iter().map(|&service| service.to_owned()).collect(),
        })
        .collect();
    let lock = Lock::read(config_folder)?;
    for ConfigPlugin { source, options } in &config.plugins {
        let (label, root) = match source {
            Source::Folder(folder) => (format!("plugin folder {folder}"), config_folder.join(folder)),
            Source::Git(git) => {
                let label = format!("plugin {git}");
                let commit = lock.commits.get(git).ok_or_else(|| {
                    format!("{label}: plugins.lock has no commit for this plugin: run `yuke plugin sync`")
                })?;
                let installed = git_folder(data, &git.url, commit);
                if !installed.is_dir() {
                    return Err(format!(
                        "{label}: commit {commit} is not installed: run `yuke plugin sync`"
                    ));
                }
                (label, installed.join(git.folder.as_deref().unwrap_or_default()))
            }
        };
        let fail = |message: String| format!("{label}: {message}");
        let root = root.canonicalize().map_err(|error| fail(error.to_string()))?;
        plugins.push(manifest_plugin(&root, data, options.clone()).map_err(fail)?);
    }
    load_order(plugins)
}

/// The folder name of the repository `url` in `<data>/git` and `<cache>/git`. The name is the last part of the URL, and
/// the hash of the whole URL keeps two repositories of one name apart.
pub(crate) fn repository_key(url: &str) -> String {
    let last = url.trim_end_matches('/').rsplit(['/', ':']).next().unwrap_or_default();
    let last = last.strip_suffix(".git").unwrap_or(last);
    // The URL is not a safe folder name, so each other character becomes `-`.
    let name = last.replace(|c: char| !c.is_ascii_alphanumeric() && !"-_.".contains(c), "-");
    let hash = yuke_ai::hex(&yuke_agent::blob_of(url.as_bytes()).digest);
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

/// Check `plugins` and give their load order: each provider before each plugin that uses it, else the order of the
/// list. Each name comes once, and each service has one provider.
///
/// # Errors
///
/// Returns a text for the user that names the first plugin that breaks a rule, or the plugins of a cycle of uses.
pub(crate) fn load_order(plugins: Vec<Plugin>) -> Result<Vec<Plugin>, String> {
    let mut providers: HashMap<&str, &str> = HashMap::new();
    for (index, plugin) in plugins.iter().enumerate() {
        let fail = |message: String| format!("plugin {}: {message}", plugin.name);
        match plugins[..index].iter().find(|other| other.name == plugin.name) {
            Some(Plugin {
                origin: Origin::Bundled { .. },
                ..
            }) => {
                return Err(fail(format!(
                    "a bundled plugin has this name: add \"{}\" to \"disable\" in config.json to replace it",
                    plugin.name
                )));
            }
            Some(_) => return Err(fail("another plugin of the list has this name".to_owned())),
            None => {}
        }
        for service in &plugin.provides {
            if let Some(provider) = providers.insert(service, &plugin.name) {
                return Err(fail(format!("plugin {provider} provides '{service}' already")));
            }
        }
    }
    for plugin in &plugins {
        if let Some(service) = plugin
            .uses
            .iter()
            .find(|service| !providers.contains_key(service.as_str()))
        {
            return Err(format!(
                "plugin {}: it uses '{service}', and no plugin of the list provides it",
                plugin.name
            ));
        }
    }
    // Each step takes the first plugin of the list whose services loaded. A plugin moves only for its providers.
    let mut waiting = plugins;
    let mut loaded: HashSet<String> = HashSet::new();
    let mut order = Vec::with_capacity(waiting.len());
    while !waiting.is_empty() {
        let Some(index) = waiting
            .iter()
            .position(|plugin| plugin.uses.iter().all(|service| loaded.contains(service)))
        else {
            let names: Vec<&str> = waiting.iter().map(|plugin| plugin.name.as_str()).collect();
            return Err(format!(
                "plugins {}: a cycle of uses keeps them from loading",
                names.join(", ")
            ));
        };
        let plugin = waiting.remove(index);
        loaded.extend(plugin.provides.iter().cloned());
        order.push(plugin);
    }
    Ok(order)
}

/// The plugin of the folder `root`, from its manifest, with the `options` of `config.json`.
pub(crate) fn manifest_plugin(root: &Path, data: &Path, options: Map<String, Value>) -> Result<Plugin, String> {
    let path = root.join(MANIFEST);
    let manifest: Manifest = read_json(&path)?.ok_or_else(|| format!("{}: the file does not exist", path.display()))?;
    valid_name(&manifest.name)?;
    let fields: YukeFields = match manifest.extensions.get(EXTENSION) {
        Some(value) => YukeFields::deserialize(value)
            .map_err(|error| format!("{}: extensions.\"{EXTENSION}\": {error}", path.display()))?,
        None => YukeFields::default(),
    };
    let entry = match fields.entry {
        None => None,
        Some(entry) => {
            let path = Path::new(&entry);
            // Agent Plugins keeps each package path inside the plugin folder.
            if !path
                .components()
                .all(|component| matches!(component, Component::Normal(_) | Component::CurDir))
            {
                return Err(format!(
                    "entry: '{entry}' is not a relative path inside the plugin folder"
                ));
            }
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
    for (field, names) in [("uses", &fields.uses), ("provides", &fields.provides)] {
        let mut seen = HashSet::new();
        for name in names {
            if name.is_empty() {
                return Err(format!("{field}: a service name is empty"));
            }
            if !seen.insert(name) {
                return Err(format!("{field}: '{name}' is in the list twice"));
            }
        }
    }
    if let Some(name) = fields.uses.iter().find(|name| fields.provides.contains(name)) {
        return Err(format!("'{name}' is in uses and in provides"));
    }
    if entry.is_none() && !fields.provides.is_empty() {
        return Err("provides: a plugin without an entry cannot provide a service".to_owned());
    }
    Ok(Plugin {
        data_dir: data.join("plugins").join(&manifest.name),
        name: manifest.name,
        origin: Origin::Folder {
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
