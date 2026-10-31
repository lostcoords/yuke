//! The plugin manager of `plugin/list`, `plugin/sync`, `plugin/check`, and `plugin/apply`: the plugins of `config.json`
//! and the commits of the Git plugins in `plugins.lock`.

use std::fmt;

use serde::{Deserialize, Serialize};

/// A Git plugin of `config.json`, as `plugins.lock` keys it.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct PluginSource {
    /// The URL of the repository, as `git` takes it.
    pub git: String,
    /// The plugin folder in the repository. None is the root.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    /// The branch, tag, or commit that an update follows. None is the default branch.
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

/// One plugin of `config.json` in `plugin/list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ManagedPlugin {
    /// The folder of a local plugin, or the URL, folder, and ref of a Git plugin.
    pub item: String,
    /// The name of its `plugin.json`, when the server can read it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Whether the running plugins hold a plugin of this name. A plugin can be installed and not loaded, or loaded
    /// from an older commit until `profile/reload`.
    pub loaded: bool,
    /// Its state on disk.
    #[serde(flatten)]
    pub state: PluginState,
}

/// The state on disk of one plugin of `plugin/list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "state", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum PluginState {
    /// A folder of the user.
    Local,
    /// A Git plugin with no commit in `plugins.lock`. `plugin/sync` locks it.
    NotLocked,
    /// A Git plugin whose locked commit is not on disk. `plugin/sync` installs it.
    NotInstalled {
        /// The full commit id of the lock.
        commit: String,
    },
    /// A Git plugin at its locked commit.
    Installed {
        /// The full commit id of the lock.
        commit: String,
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

/// The params of `plugin/sync`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SyncPluginsParams {
    /// Fail when `plugins.lock` does not match `config.json`, and never write it. None or false syncs normally.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub locked: Option<bool>,
}

/// The commit of one Git plugin after `plugin/sync`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SyncedPlugin {
    /// The plugin.
    pub source: PluginSource,
    /// The full commit id in the lock.
    pub commit: String,
}

/// The result of `plugin/sync`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SyncPluginsResult {
    /// Each Git plugin of `config.json` with its commit, in list order.
    pub plugins: Vec<SyncedPlugin>,
    /// Whether `plugins.lock` changed.
    pub written: bool,
}

/// Which Git plugins `plugin/check` checks: `"all"`, or `{ "names": [...] }` by the name of their `plugin.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum PluginTarget {
    /// Each Git plugin.
    All,
    /// The Git plugins of these names.
    Names(Vec<String>),
}

/// The params of `plugin/check`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct CheckPluginsParams {
    /// The plugins to check.
    pub target: PluginTarget,
}

/// The commits between the locked commit and the new one: `{ "commits": [...] }`, newest first as a short id and a
/// subject each, or `{ "error": text }` when the server cannot read them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum PluginLog {
    /// The commits.
    Commits(Vec<String>),
    /// Why the log is missing.
    Error(String),
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
    /// Changes of `plugin/check`. The server writes the `new` commit of each one whose source is in the lock.
    pub changes: Vec<PluginChange>,
}

/// The result of `plugin/apply`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ApplyPluginsResult {
    /// Whether `plugins.lock` changed.
    pub written: bool,
}
