//! `yuke plugin`: list, sync, and update the Git plugins of `config.json`. It runs no plugin code.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Map;
use yuke_protocol::{
    ManagedPlugin, PluginChange, PluginLog, PluginSource, PluginState, PluginTarget, SyncPluginsResult, SyncedPlugin,
};

use super::lock::Lock;
use super::{git, git_folder, manifest_plugin, repository_key};
use crate::config::{Config, ConfigPlugin, Source, git_source, read_json};
use crate::paths::Paths;

/// The plugins of `config.json`, with the state of each one. A plugin is loaded when `loaded` has its name. It uses no
/// network and changes nothing.
///
/// # Errors
///
/// Returns a text for a bad `config.json` or `plugins.lock`.
pub(crate) fn list(paths: &Paths, loaded: &[String]) -> Result<Vec<ManagedPlugin>, String> {
    let config = read_config(paths)?;
    let lock = Lock::read_for(&paths.config, &config)?;
    let name = |root: &Path| {
        manifest_plugin(root, &paths.data, Map::new())
            .ok()
            .map(|plugin| plugin.name)
    };
    Ok(config
        .plugins
        .iter()
        .map(|ConfigPlugin { source, .. }| {
            let (item, name, state) = match source {
                Source::Folder(folder) => (folder.clone(), name(&paths.config.join(folder)), PluginState::Local),
                Source::Git(source) => {
                    let (name, state) = match lock.commits.get(source) {
                        None => (None, PluginState::NotLocked),
                        Some(commit) => match name(&root(paths, source, commit)) {
                            Some(name) => (Some(name), PluginState::Installed { commit: commit.clone() }),
                            None => (None, PluginState::NotInstalled { commit: commit.clone() }),
                        },
                    };
                    (source.to_string(), name, state)
                }
            };
            ManagedPlugin {
                item,
                loaded: name.as_ref().is_some_and(|name| loaded.contains(name)),
                name,
                state,
            }
        })
        .collect())
}

/// Install the commit of `plugins.lock` of each Git plugin, and lock each new Git plugin at the commit of its ref. The
/// lock keeps only the plugins of `config.json`. With `locked`, the lock must match `config.json`, and it stays as it
/// is.
///
/// # Errors
///
/// Returns a text for a bad file, a lock that does not match with `locked`, or a failed fetch or install.
pub(crate) async fn sync(paths: &Paths, locked: bool) -> Result<SyncPluginsResult, String> {
    let _held = hold(&paths.data).await?;
    let config = read_config(paths)?;
    let lock = Lock::read_for(&paths.config, &config)?;
    let sources = git_sources(&config);
    if locked
        && (lock.commits.len() != sources.len() || sources.iter().any(|source| !lock.commits.contains_key(*source)))
    {
        return Err("plugins.lock does not match the Git plugins of config.json: run `yuke plugin sync`".to_owned());
    }
    let mut commits = Lock::default();
    let mut plugins = Vec::with_capacity(sources.len());
    for source in sources {
        let fail = |message: String| format!("plugin {source}: {message}");
        let commit = match lock.commits.get(source) {
            Some(commit) => commit.clone(),
            None => git::resolve(&source.git, source.reference.as_deref())
                .await
                .map_err(fail)?,
        };
        install(paths, source, &commit).await.map_err(fail)?;
        commits.commits.insert(source.clone(), commit.clone());
        plugins.push(SyncedPlugin {
            source: source.clone(),
            commit,
        });
    }
    let written = !locked && commits.write(&paths.config)?;
    Ok(SyncPluginsResult { plugins, written })
}

/// The new commit of each Git plugin of `target` whose ref moved, with the log of the move. Each new commit is installed,
/// and `plugins.lock` stays as it is until [`apply`].
///
/// # Errors
///
/// Returns a text for a bad file, a name that no installed Git plugin has, a plugin that `sync` did not install, or a
/// failed fetch or install.
pub(crate) async fn check(paths: &Paths, target: &PluginTarget) -> Result<Vec<PluginChange>, String> {
    let _held = hold(&paths.data).await?;
    let config = read_config(paths)?;
    let lock = Lock::read_for(&paths.config, &config)?;
    // The name of a Git plugin comes from the manifest of its locked commit. A plugin with no readable name cannot be one
    // of the named plugins, so only `all` needs it.
    let mut targets = Vec::new();
    for source in git_sources(&config) {
        let fail = |message: String| format!("plugin {source}: {message}");
        let named = lock
            .commits
            .get(source)
            .ok_or_else(|| fail("plugins.lock has no commit for this plugin: run `yuke plugin sync`".to_owned()));
        let named = named.and_then(|old| {
            let plugin = manifest_plugin(&root(paths, source, old), &paths.data, Map::new())
                .map_err(|error| fail(format!("{error}: run `yuke plugin sync`")))?;
            Ok((old, plugin.name))
        });
        match (named, target) {
            (Ok((old, name)), _) => targets.push((source, old, name)),
            (Err(error), PluginTarget::All) => return Err(error),
            (Err(_), PluginTarget::Names(_)) => {}
        }
    }
    if let PluginTarget::Names(names) = target {
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
    for (source, old, name) in targets {
        let fail = |message: String| format!("plugin {source}: {message}");
        let new = git::resolve(&source.git, source.reference.as_deref())
            .await
            .map_err(fail)?;
        if new == *old {
            continue;
        }
        install(paths, source, &new).await.map_err(fail)?;
        let cache = cache(paths, &source.git);
        // A new cache does not have the old commit yet.
        let log = match git::fetch(&cache, &source.git, old).await {
            Ok(()) => git::log(&cache, old, &new).await,
            Err(error) => Err(error),
        };
        changes.push(PluginChange {
            name,
            source: source.clone(),
            old: old.clone(),
            new,
            log: log.map_or_else(PluginLog::Error, PluginLog::Commits),
        });
    }
    Ok(changes)
}

/// Write the new commit of each change of `changes` into `plugins.lock`. A change whose plugin is not in the lock writes
/// nothing. Gives whether the lock changed.
///
/// # Errors
///
/// Returns a text for a bad source or commit of a change, or when the file does not read or write.
pub(crate) async fn apply(paths: &Paths, changes: &[PluginChange]) -> Result<bool, String> {
    let _held = hold(&paths.data).await?;
    let mut lock = Lock::read(&paths.config)?;
    for change in changes {
        // A change can come from a client, so its source and commit get the checks of a lock entry.
        let source = git_source(
            change.source.git.clone(),
            change.source.folder.as_deref(),
            change.source.reference.clone(),
        )?;
        if !git::is_commit(&change.new) {
            return Err(format!("plugin {source}: '{}' is not a full commit id", change.new));
        }
        if let Some(commit) = lock.commits.get_mut(&source) {
            commit.clone_from(&change.new);
        }
    }
    lock.write(&paths.config)
}

/// Install the commit `commit` of `source` in `<data>/git`, unless it is there, and check the manifest of its folder. The
/// install becomes visible whole, with one rename.
async fn install(paths: &Paths, source: &PluginSource, commit: &str) -> Result<(), String> {
    let installed = git_folder(&paths.data, &source.git, commit);
    if !installed.is_dir() {
        let cache = cache(paths, &source.git);
        git::fetch(&cache, &source.git, commit).await?;
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
            &staging.join(source.folder.as_deref().unwrap_or_default()),
            &paths.data,
            Map::new(),
        )?;
        return fs::rename(&staging, &installed).map_err(fail);
    }
    manifest_plugin(&root(paths, source, commit), &paths.data, Map::new()).map(|_| ())
}

/// The plugin folder of `source` at the commit `commit`.
fn root(paths: &Paths, source: &PluginSource, commit: &str) -> PathBuf {
    git_folder(&paths.data, &source.git, commit).join(source.folder.as_deref().unwrap_or_default())
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
fn git_sources(config: &Config) -> Vec<&PluginSource> {
    let mut sources: Vec<&PluginSource> = Vec::new();
    for plugin in &config.plugins {
        if let Source::Git(source) = &plugin.source
            && !sources.contains(&source)
        {
            sources.push(source);
        }
    }
    sources
}

/// Hold the lock of the plugin manager in `<data>/git` until the file drops. A second call waits for the first.
async fn hold(data: &Path) -> Result<File, String> {
    let folder = data.join("git");
    let path = folder.join("manager.lock");
    // The wait blocks a thread, so it runs off the one thread of the app, where the first call still runs.
    tokio::task::spawn_blocking(move || {
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
    })
    .await
    .map_err(|error| format!("the lock of the plugin manager: {error}"))?
}

#[cfg(test)]
mod tests;
