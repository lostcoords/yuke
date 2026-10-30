//! The plugins of yuke and of the profile: the bundled plugins, then the `plugins` list of `config.json` and the Agent
//! Plugins `plugin.json` of each folder. The checks run before any plugin code: a bad list stops the start.

use std::collections::{HashMap, HashSet};
use std::path::{Component, Path};

use serde::Deserialize;
use serde_json::{Map, Value};
use yuke_js::{Origin, Plugin};

use crate::config::{Config, ConfigPlugin, read_json};

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

/// The plugins of the binary, in load order: the name of each one and the `yuke:` name of its entry module. A bundled
/// plugin uses and provides no service.
const BUNDLED: &[(&str, &str)] = &[
    ("compaction", "yuke:internal/bundled/compaction"),
    ("chat", "yuke:internal/bundled/chat"),
    ("bar", "yuke:internal/bundled/bar"),
];

/// The plugins to load, in load order. The bundled plugins come first, without the ones that `config.disable` names.
/// Each one gets its options from `config.bundled`. Then the plugins of `config.plugins` follow in their order. A
/// relative folder starts in `config_folder`. The function makes the data folder `<data>/plugins/<name>` of each plugin.
///
/// # Errors
///
/// Returns a text that names the plugin and the problem. The problem is an unreadable folder or manifest, a bad name or
/// field, or a duplicate name. It can also be two providers of one service, or a missing or later provider. A `disable`
/// or `bundled` name that no bundled plugin has is an error too.
pub(crate) fn plugins(config_folder: &Path, config: &Config, data: &Path) -> Result<Vec<Plugin>, String> {
    with_bundled(BUNDLED, config_folder, config, data)
}

/// [`plugins`] with the bundled plugins `bundled`.
fn with_bundled(
    bundled: &[(&str, &str)],
    config_folder: &Path,
    config: &Config,
    data: &Path,
) -> Result<Vec<Plugin>, String> {
    let known = |name: &str| bundled.iter().any(|&(bundled, _)| bundled == name);
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
        .filter(|(name, _)| !config.disable.iter().any(|disabled| disabled == name))
        .map(|&(name, module)| Plugin {
            name: name.to_owned(),
            origin: Origin::Bundled {
                module: module.to_owned(),
            },
            data_dir: data.join("plugins").join(name),
            options: config.bundled.get(name).cloned().unwrap_or_default(),
            uses: Vec::new(),
            provides: Vec::new(),
        })
        .collect();
    let mut roots = HashSet::new();
    for ConfigPlugin { path: folder, options } in &config.plugins {
        let fail = |message: String| format!("plugin folder {folder}: {message}");
        let root = config_folder
            .join(folder)
            .canonicalize()
            .map_err(|error| fail(error.to_string()))?;
        if !roots.insert(root.clone()) {
            return Err(fail("the list names this folder twice".to_owned()));
        }
        plugins.push(manifest_plugin(&root, data, options.clone()).map_err(fail)?);
    }

    check_list(&plugins)?;
    for plugin in &plugins {
        std::fs::create_dir_all(&plugin.data_dir).map_err(|error| format!("{}: {error}", plugin.data_dir.display()))?;
    }
    Ok(plugins)
}

/// Check `plugins` as one load order: each name once, each service from one plugin, and each provider before each plugin
/// that uses it.
///
/// # Errors
///
/// Returns a text for the user that names the first plugin that breaks a rule.
pub(crate) fn check_list(plugins: &[Plugin]) -> Result<(), String> {
    // The order of the list is the load order, so each provider must come before each plugin that uses it.
    let mut providers: HashMap<&str, (usize, &str)> = HashMap::new();
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
            if let Some((_, provider)) = providers.insert(service, (index, &plugin.name)) {
                return Err(fail(format!("plugin {provider} provides '{service}' already")));
            }
        }
    }
    for (index, plugin) in plugins.iter().enumerate() {
        for service in &plugin.uses {
            let message = match providers.get(service.as_str()) {
                Some((at, _)) if *at < index => continue,
                Some((_, provider)) => {
                    format!("it uses '{service}', and plugin {provider} provides it later in the list")
                }
                None => format!("it uses '{service}', and no plugin of the list provides it"),
            };
            return Err(format!("plugin {}: {message}", plugin.name));
        }
    }
    Ok(())
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
