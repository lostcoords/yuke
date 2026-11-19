//! The plugin manager of `plugin/list`, `plugin/sync`, `plugin/check`, `plugin/apply`, `plugin/find`, `plugin/add`, and
//! `plugin/remove`: the plugins of `config.json` and the commits of the Git plugins in `plugins.lock`.

use std::fmt;

use serde::{Deserialize, Serialize};

/// A Git plugin of `config.json`, as `plugins.lock` keys it.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct PluginSource {
    /// The URL of the repository, as `git` takes it.
    pub git: String,
    /// The plugin folder in the repository. Without it, the plugin is the root.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    /// The branch, tag, or commit that an update follows. Without it, an update follows the default branch.
    #[serde(default, rename = "ref", skip_serializing_if = "Option::is_none")]
    pub reference: Option<String>,
}

impl fmt::Display for PluginSource {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.git)?;
        match (&self.folder, &self.reference) {
            (None, None) => Ok(()),
            (Some(folder), None) => write!(f, " (folder {folder})"),
            (None, Some(reference)) => write!(f, " (ref {reference})"),
            (Some(folder), Some(reference)) => write!(f, " (folder {folder}, ref {reference})"),
        }
    }
}

/// Where a plugin of `config.json` comes from: a local folder, or a Git plugin. JSON holds a folder as a string, and a
/// Git plugin as its `PluginSource` object.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(untagged)]
pub enum PluginOrigin {
    /// The folder as `config.json` writes it. A relative folder starts in the folder of `config.json`.
    Folder(String),
    /// A folder of a Git repository.
    Git(PluginSource),
}

impl fmt::Display for PluginOrigin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Folder(folder) => f.write_str(folder),
            Self::Git(source) => fmt::Display::fmt(source, f),
        }
    }
}

/// One plugin of `config.json` in `plugin/list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct ManagedPlugin {
    /// The folder of a local plugin, or the source of a Git plugin.
    pub source: PluginOrigin,
    /// The name of its `plugin.json`, when the server can read it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Its state on disk.
    pub state: PluginState,
    /// Whether the running plugins hold it.
    pub load: PluginLoad,
}

/// The state on disk of one plugin of `plugin/list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum PluginState {
    /// A folder of the user.
    Local,
    /// A Git plugin that is not on disk. `plugin/sync` installs it.
    NotInstalled {
        /// The full commit id of the lock. Without it, `plugin/sync` locks the plugin at the commit of its ref.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        commit: Option<String>,
    },
    /// A Git plugin at its locked commit.
    Installed {
        /// The full commit id of the lock.
        commit: String,
    },
}

/// Whether the running plugins hold one plugin of `plugin/list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PluginLoad {
    /// The plugin runs. It runs the commit of the last load until `profile/reload`.
    Loaded,
    /// The plugin does not run yet, for example after `plugin/add` or a sync. `profile/reload` loads it.
    Pending,
    /// The plugin does not load.
    Failed {
        /// Why, with the name of the plugin.
        error: String,
    },
}

/// The result of `plugin/list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ListPluginsResult {
    /// The plugins in the order of `config.json`.
    pub plugins: Vec<ManagedPlugin>,
}

/// A Git plugin and its commit in `plugins.lock`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct LockedPlugin {
    /// The plugin.
    pub source: PluginSource,
    /// The full commit id.
    pub commit: String,
}

/// The result of `plugin/sync`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SyncPluginsResult {
    /// Each Git plugin of `config.json` with its commit, in list order.
    pub plugins: Vec<LockedPlugin>,
    /// Whether `plugins.lock` changed.
    pub written: bool,
}

/// Which Git plugins `plugin/check` checks: each one, or the ones with these names in their `plugin.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PluginTarget {
    /// Each Git plugin.
    All,
    /// The Git plugins of these names.
    Names {
        /// The names.
        names: Vec<String>,
    },
}

/// The params of `plugin/check`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct CheckPluginsParams {
    /// The plugins to check.
    pub target: PluginTarget,
}

/// The commits between the locked commit and the new one, or why the server cannot read them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PluginLog {
    /// The commits.
    Commits {
        /// Newest first, as a short id and a subject each.
        commits: Vec<String>,
    },
    /// The server cannot read the commits.
    Failed {
        /// Why.
        error: String,
    },
}

/// The new commit of one Git plugin whose ref moved.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct PluginChange {
    /// The name of its `plugin.json`.
    pub name: String,
    /// The plugin.
    pub source: PluginSource,
    /// The commit of the lock.
    pub old: String,
    /// The commit that its ref names now. It is installed.
    pub new: String,
    /// The commits of the move.
    pub log: PluginLog,
}

/// The result of `plugin/check`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct CheckPluginsResult {
    /// Each checked plugin whose ref moved. An empty list means that each one is at the newest commit of its ref.
    pub changes: Vec<PluginChange>,
}

/// The params of `plugin/apply`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ApplyPluginsParams {
    /// The new commits to write, as the `changes` of `plugin/check` give them. Each plugin must be in the lock.
    pub plugins: Vec<LockedPlugin>,
}

/// The params of `plugin/find`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct FindPluginsParams {
    /// The URL of the repository, as `git` takes it.
    pub git: String,
    /// The branch, tag, or commit to look at. Without it, the default branch.
    #[serde(default, rename = "ref", skip_serializing_if = "Option::is_none")]
    pub reference: Option<String>,
}

/// One plugin of a repository: a folder with a `plugin.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct FoundPlugin {
    /// The name of its `plugin.json`.
    pub name: String,
    /// The folder in the repository. Without it, the plugin is the root.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
}

/// The result of `plugin/find`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct FindPluginsResult {
    /// The plugins of the repository, in the order of their folders.
    pub plugins: Vec<FoundPlugin>,
}

/// The params of `plugin/add`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct AddPluginsParams {
    /// The URL of the repository, as `git` takes it.
    pub git: String,
    /// The names of the plugins to add, as `plugin/find` gives them. Without them, the repository must have one plugin.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    #[cfg_attr(test, ts(as = "Option<Vec<String>>"))]
    pub names: Vec<String>,
    /// The branch, tag, or commit that an update follows. Without it, an update follows the default branch.
    #[serde(default, rename = "ref", skip_serializing_if = "Option::is_none")]
    pub reference: Option<String>,
}

/// One plugin that `plugin/add` added.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct AddedPlugin {
    /// The name of its `plugin.json`.
    pub name: String,
    /// The plugin, as `config.json` and `plugins.lock` hold it now.
    pub source: PluginSource,
    /// The full commit id in the lock.
    pub commit: String,
}

/// The result of `plugin/add`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct AddPluginsResult {
    /// The added plugins, in the order of the names.
    pub plugins: Vec<AddedPlugin>,
}

/// The params of `plugin/remove`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct RemovePluginParams {
    /// The name of the `plugin.json` of the plugin, a Git plugin or a local one.
    pub name: String,
}
