//! `yuke plugin`: list, sync, update, add, and remove the plugins of `config.json`. It runs no plugin code.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};
use yuke_protocol::{
    AddPluginResult, ManagedPlugin, PluginChange, PluginLog, PluginOrigin, PluginSource, PluginState, PluginTarget,
    SyncPluginsResult, SyncedPlugin,
};

use super::lock::Lock;
use super::{git, git_folder, manifest_plugin, read_manifest, repository_key};
use crate::config::{Config, Source, add_plugin_item, git_source, read_json, remove_plugin_item, write_text};
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
    Ok(config
        .plugins
        .iter()
        .map(|plugin| {
            let name = name_of(paths, &lock, &plugin.source);
            let (source, state) = match &plugin.source {
                Source::Folder(folder) => (PluginOrigin::Folder(folder.clone()), PluginState::Local),
                Source::Git(source) => {
                    let state = match (lock.commits.get(source), &name) {
                        (None, _) => PluginState::NotLocked,
                        (Some(commit), Some(_)) => PluginState::Installed { commit: commit.clone() },
                        (Some(commit), None) => PluginState::NotInstalled { commit: commit.clone() },
                    };
                    (PluginOrigin::Git(source.clone()), state)
                }
            };
            ManagedPlugin {
                source,
                loaded: name.as_ref().is_some_and(|name| loaded.contains(name)),
                name,
                state,
            }
        })
        .collect())
}

/// Add the Git plugin `source` with `options` to `config.json`, install it, and lock it at the commit of its ref. The
/// comments and the layout of `config.json` stay. A stop after the write of `config.json` leaves the plugin unlocked,
/// and a sync locks it.
///
/// # Errors
///
/// Returns a text for a bad file, a plugin that `config.json` has already, or a failed fetch or install.
pub(crate) async fn add(
    paths: &Paths,
    source: PluginSource,
    options: Map<String, Value>,
) -> Result<AddPluginResult, String> {
    let _held = hold(&paths.data).await?;
    let source = git_source(source.git, source.folder.as_deref(), source.reference);
    let fail = |message: String| format!("plugin {source}: {message}");
    let config = read_config(paths)?;
    if git_sources(&config).contains(&&source) {
        return Err(fail("config.json has this plugin already".to_owned()));
    }
    let commit = git::resolve(&source.git, source.reference.as_deref())
        .await
        .map_err(fail)?;
    install(paths, &source, &commit).await.map_err(fail)?;
    let name = read_manifest(&root(paths, &source, &commit)).map_err(fail)?.name;
    // The loader refuses two plugins of one name, so a clash would stop the next reload.
    let lock = Lock::read_for(&paths.config, &config)?;
    if config
        .plugins
        .iter()
        .any(|plugin| name_of(paths, &lock, &plugin.source).as_deref() == Some(name.as_str()))
    {
        return Err(fail(format!("config.json has a plugin of the name '{name}' already")));
    }
    let path = paths.config.join("config.json");
    let mut fields = vec![format!("\"git\": {}", Value::from(source.git.as_str()))];
    if let Some(folder) = &source.folder {
        fields.push(format!("\"folder\": {}", Value::from(folder.as_str())));
    }
    if let Some(reference) = &source.reference {
        fields.push(format!("\"ref\": {}", Value::from(reference.as_str())));
    }
    if !options.is_empty() {
        fields.push(format!("\"options\": {}", Value::Object(options)));
    }
    let item = format!("{{ {} }}", fields.join(", "));
    let text = match fs::read_to_string(&path) {
        Ok(text) => add_plugin_item(&text, &item),
        Err(error) if error.kind() == io::ErrorKind::NotFound => format!("{{\n  \"plugins\": [{item}]\n}}\n"),
        Err(error) => return Err(format!("{}: {error}", path.display())),
    };
    // Read the lock before the config write, so a bad lock changes no file.
    let mut lock = Lock::read(&paths.config)?;
    let sources = git_sources(&config);
    lock.commits.retain(|locked, _| sources.contains(&locked));
    lock.commits.insert(source.clone(), commit.clone());
    write_text(&path, &text)?;
    lock.write(&paths.config)?;
    Ok(AddPluginResult { name, source, commit })
}

/// Remove the plugin `name` from `config.json`, and its entry from `plugins.lock`. The comments and the layout of
/// `config.json` stay, and the install of a Git plugin stays on disk.
///
/// # Errors
///
/// Returns a text for a bad file, or when no plugin of `config.json` has the name.
pub(crate) async fn remove(paths: &Paths, name: &str) -> Result<(), String> {
    let _held = hold(&paths.data).await?;
    let config = read_config(paths)?;
    let mut lock = Lock::read_for(&paths.config, &config)?;
    let index = config
        .plugins
        .iter()
        .position(|plugin| name_of(paths, &lock, &plugin.source).as_deref() == Some(name))
        .ok_or_else(|| format!("no plugin of config.json has the name '{name}': see `yuke plugin list`"))?;
    let path = paths.config.join("config.json");
    let text = fs::read_to_string(&path).map_err(|error| format!("{}: {error}", path.display()))?;
    let text = remove_plugin_item(&text, index)
        .ok_or_else(|| format!("{}: the edit did not find the plugin", path.display()))?;
    write_text(&path, &text)?;
    if let Source::Git(source) = &config.plugins[index].source {
        lock.commits.remove(source);
        lock.write(&paths.config)?;
    }
    Ok(())
}

/// The name of the manifest of the plugin of `source`: of its folder, or of its locked and installed commit.
fn name_of(paths: &Paths, lock: &Lock, source: &Source) -> Option<String> {
    let root = match source {
        Source::Folder(folder) => paths.config.join(folder),
        Source::Git(source) => root(paths, source, lock.commits.get(source)?),
    };
    read_manifest(&root).ok().map(|manifest| manifest.name)
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
            let manifest = read_manifest(&root(paths, source, old))
                .map_err(|error| fail(format!("{error}: run `yuke plugin sync`")))?;
            Ok((old, manifest.name))
        });
        match (named, target) {
            (Ok((old, name)), _) => targets.push((source, old, name)),
            (Err(error), PluginTarget::All) => return Err(error),
            (Err(_), PluginTarget::Names { .. }) => {}
        }
    }
    if let PluginTarget::Names { names } = target {
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
            log: match log {
                Ok(commits) => PluginLog::Commits { commits },
                Err(error) => PluginLog::Failed { error },
            },
        });
    }
    Ok(changes)
}

/// Write the new commit of each change of `changes` into `plugins.lock`. A change whose plugin is not in the lock writes
/// nothing. Gives whether the lock changed.
///
/// # Errors
///
/// Returns a text for a bad commit of a change, or when the file does not read or write.
pub(crate) async fn apply(paths: &Paths, changes: &[PluginChange]) -> Result<bool, String> {
    let _held = hold(&paths.data).await?;
    let mut lock = Lock::read(&paths.config)?;
    for change in changes {
        // A change can come from a client, so its commit gets the check of a lock entry.
        let source = git_source(
            change.source.git.clone(),
            change.source.folder.as_deref(),
            change.source.reference.clone(),
        );
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
        // An install checks the whole manifest, so a plugin that cannot load fails here and not at the next reload.
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
