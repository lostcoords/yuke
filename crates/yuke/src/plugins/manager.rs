//! `yuke plugin`: list, sync, and update the Git plugins of `config.json`. It runs no plugin code.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Map;

use super::lock::Lock;
use super::{git, git_folder, manifest_plugin, repository_key};
use crate::config::{Config, ConfigPlugin, GitSource, Source, read_json};
use crate::paths::Paths;

/// One plugin of `config.json` in [`list`].
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Listed {
    /// The folder of a local plugin, or the source of a Git plugin.
    pub(crate) item: String,
    /// The name of its manifest, when yuke can read it.
    pub(crate) name: Option<String>,
    pub(crate) state: State,
}

/// The state on disk of one plugin of [`list`].
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum State {
    /// A folder of the user.
    Local,
    /// A Git plugin with no commit in `plugins.lock`.
    NotLocked,
    /// A Git plugin whose locked commit is not on disk.
    NotInstalled(String),
    /// A Git plugin at its locked commit.
    Installed(String),
}

/// Which Git plugins an update moves.
pub(crate) enum Selection {
    All,
    Names(Vec<String>),
}

/// The new commit of one Git plugin, before [`apply`] writes it.
#[derive(Debug)]
pub(crate) struct Change {
    pub(crate) source: GitSource,
    pub(crate) name: String,
    pub(crate) old: String,
    pub(crate) new: String,
    /// The commits after `old` up to `new`, or the reason that the log is missing.
    pub(crate) log: Result<Vec<String>, String>,
}

/// The plugins of `config.json`, with the state of each one. It uses no network and changes nothing.
///
/// # Errors
///
/// Returns a text for a bad `config.json` or `plugins.lock`.
pub(crate) fn list(paths: &Paths) -> Result<Vec<Listed>, String> {
    let config = read_config(paths)?;
    let lock = Lock::read(&paths.config)?;
    let name = |root: &Path| {
        manifest_plugin(root, &paths.data, Map::new())
            .ok()
            .map(|plugin| plugin.name)
    };
    Ok(config
        .plugins
        .iter()
        .map(|ConfigPlugin { source, .. }| match source {
            Source::Folder(folder) => Listed {
                item: folder.clone(),
                name: name(&paths.config.join(folder)),
                state: State::Local,
            },
            Source::Git(git) => {
                let (name, state) = match lock.commits.get(git) {
                    None => (None, State::NotLocked),
                    Some(commit) => {
                        let root = root(paths, git, commit);
                        match name(&root) {
                            Some(name) => (Some(name), State::Installed(commit.clone())),
                            None => (None, State::NotInstalled(commit.clone())),
                        }
                    }
                };
                Listed {
                    item: git.to_string(),
                    name,
                    state,
                }
            }
        })
        .collect())
}

/// Install the commit of `plugins.lock` of each Git plugin, and lock each new Git plugin at the commit of its ref. The
/// lock keeps only the plugins of `config.json`. With `locked`, the lock must match `config.json`, and it stays as it
/// is. Gives the commit of each Git plugin in list order, and whether the lock changed.
///
/// # Errors
///
/// Returns a text for a bad file, a lock that does not match with `locked`, or a failed fetch or install.
pub(crate) async fn sync(paths: &Paths, locked: bool) -> Result<(Vec<(GitSource, String)>, bool), String> {
    let _held = hold(&paths.data)?;
    let config = read_config(paths)?;
    let lock = Lock::read(&paths.config)?;
    let sources = git_sources(&config);
    if locked && (lock.commits.len() != sources.len() || sources.iter().any(|git| !lock.commits.contains_key(*git))) {
        return Err("plugins.lock does not match the Git plugins of config.json: run `yuke plugin sync`".to_owned());
    }
    let mut commits = Vec::with_capacity(sources.len());
    for git in sources {
        let fail = |message: String| format!("plugin {git}: {message}");
        let commit = match lock.commits.get(git) {
            Some(commit) => commit.clone(),
            None => git::resolve(&git.url, git.reference.as_deref()).await.map_err(fail)?,
        };
        install(paths, git, &commit).await.map_err(fail)?;
        commits.push((git.clone(), commit));
    }
    let written = !locked
        && Lock {
            commits: commits.iter().cloned().collect(),
        }
        .write(&paths.config)?;
    Ok((commits, written))
}

/// The new commit of each Git plugin of `selection` whose ref moved, with the log of the move. Each new commit is
/// installed, and `plugins.lock` stays as it is until [`apply`].
///
/// # Errors
///
/// Returns a text for a bad file, a name that no installed Git plugin has, a plugin that `sync` did not install, or a
/// failed fetch or install.
pub(crate) async fn check(paths: &Paths, selection: &Selection) -> Result<Vec<Change>, String> {
    let _held = hold(&paths.data)?;
    let config = read_config(paths)?;
    let lock = Lock::read(&paths.config)?;
    // The name of a Git plugin comes from the manifest of its locked commit. A plugin with no readable name cannot be one
    // of the named plugins, so only `--all` needs it.
    let mut targets = Vec::new();
    for git in git_sources(&config) {
        let fail = |message: String| format!("plugin {git}: {message}");
        let named = lock
            .commits
            .get(git)
            .ok_or_else(|| fail("plugins.lock has no commit for this plugin: run `yuke plugin sync`".to_owned()));
        let named = named.and_then(|old| {
            let plugin = manifest_plugin(&root(paths, git, old), &paths.data, Map::new())
                .map_err(|error| fail(format!("{error}: run `yuke plugin sync`")))?;
            Ok((old, plugin.name))
        });
        match (named, selection) {
            (Ok((old, name)), _) => targets.push((git, old, name)),
            (Err(error), Selection::All) => return Err(error),
            (Err(_), Selection::Names(_)) => {}
        }
    }
    if let Selection::Names(names) = selection {
        if let Some(missing) = names
            .iter()
            .find(|name| !targets.iter().any(|(_, _, found)| found == *name))
        {
            return Err(format!(
                "no installed Git plugin of config.json has the name '{missing}': see `yuke plugin list`"
            ));
        }
        targets.retain(|(_, _, name)| names.contains(name));
    }
    let mut changes = Vec::new();
    for (git, old, name) in targets {
        let fail = |message: String| format!("plugin {git}: {message}");
        let new = git::resolve(&git.url, git.reference.as_deref()).await.map_err(fail)?;
        if new == *old {
            continue;
        }
        install(paths, git, &new).await.map_err(fail)?;
        let cache = cache(paths, &git.url);
        // A new cache does not have the old commit yet.
        let log = match git::fetch(&cache, &git.url, old).await {
            Ok(()) => git::log(&cache, old, &new).await,
            Err(error) => Err(error),
        };
        changes.push(Change {
            source: git.clone(),
            name,
            old: old.clone(),
            new,
            log,
        });
    }
    Ok(changes)
}

/// Write the new commit of each change of `changes` into `plugins.lock`. A change whose plugin left the lock after
/// [`check`] writes nothing. Gives whether the lock changed.
///
/// # Errors
///
/// Returns a text when the file does not read or write.
pub(crate) fn apply(paths: &Paths, changes: &[Change]) -> Result<bool, String> {
    let _held = hold(&paths.data)?;
    let mut lock = Lock::read(&paths.config)?;
    for change in changes {
        if let Some(commit) = lock.commits.get_mut(&change.source) {
            commit.clone_from(&change.new);
        }
    }
    lock.write(&paths.config)
}

/// Install the commit `commit` of `git` in `<data>/git`, unless it is there, and check the manifest of its folder. The
/// install becomes visible whole, with one rename.
async fn install(paths: &Paths, git: &GitSource, commit: &str) -> Result<(), String> {
    let installed = git_folder(&paths.data, &git.url, commit);
    if !installed.is_dir() {
        let cache = cache(paths, &git.url);
        git::fetch(&cache, &git.url, commit).await?;
        let staging = installed.with_file_name(format!(".staging-{commit}"));
        let fail = |error: io::Error| format!("{}: {error}", staging.display());
        // A stopped install can leave its staging folder.
        match fs::remove_dir_all(&staging) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(fail(error)),
        }
        fs::create_dir_all(&staging).map_err(fail)?;
        git::export(&cache, commit, &staging).await?;
        manifest_plugin(
            &staging.join(git.folder.as_deref().unwrap_or_default()),
            &paths.data,
            Map::new(),
        )?;
        return fs::rename(&staging, &installed).map_err(fail);
    }
    manifest_plugin(&root(paths, git, commit), &paths.data, Map::new()).map(|_| ())
}

/// The plugin folder of `git` at the commit `commit`.
fn root(paths: &Paths, git: &GitSource, commit: &str) -> PathBuf {
    git_folder(&paths.data, &git.url, commit).join(git.folder.as_deref().unwrap_or_default())
}

/// The cache repository of `url`: `<cache>/git/<key>.git`.
fn cache(paths: &Paths, url: &str) -> PathBuf {
    paths.cache.join("git").join(format!("{}.git", repository_key(url)))
}

/// The settings of `config.json`. A missing file has no plugins.
fn read_config(paths: &Paths) -> Result<Config, String> {
    Ok(read_json::<Config>(&paths.config.join("config.json"))?.unwrap_or_default())
}

/// The Git plugins of `config`, in list order, each one once.
fn git_sources(config: &Config) -> Vec<&GitSource> {
    let mut sources: Vec<&GitSource> = Vec::new();
    for plugin in &config.plugins {
        if let Source::Git(git) = &plugin.source
            && !sources.contains(&git)
        {
            sources.push(git);
        }
    }
    sources
}

/// Hold the lock of the plugin manager in `<data>/git` until the file drops. A second `yuke plugin` waits for the first.
fn hold(data: &Path) -> Result<File, String> {
    let folder = data.join("git");
    let path = folder.join("manager.lock");
    let fail = |error: io::Error| format!("{}: {error}", path.display());
    fs::create_dir_all(&folder).map_err(fail)?;
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .map_err(fail)?;
    file.lock().map_err(fail)?;
    Ok(file)
}

#[cfg(test)]
mod tests;
