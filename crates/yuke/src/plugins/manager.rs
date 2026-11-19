//! `yuke plugin`: list, sync, update, find, add, and remove the plugins of `config.json`. It runs no plugin code.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Map;
use yuke_protocol::{
    AddedPlugin, CheckPluginsResult, FailedPlugin, FoundPlugin, LockedPlugin, ManagedPlugin, PluginChange, PluginLoad,
    PluginLog, PluginOrigin, PluginSource, PluginState, PluginTarget, SyncPluginsResult,
};

use super::lock::Lock;
use super::{
    Failure, MANIFEST, Manifest, Outcome, PluginList, git, git_folder, git_label, manifest_plugin, repository_key,
    valid_name,
};
use crate::config::{
    Config, Source, add_plugin_item, git_source, read_json, remove_plugin_item, without_comments, write_text,
};
use crate::paths::Paths;

/// The plugins of `config.json`, with the state of each one on disk. `running` holds the outcomes of the last load, and
/// a plugin without one is pending. It uses no network and changes nothing.
///
/// # Errors
///
/// Returns a text for a bad `config.json` or `plugins.lock`.
pub(crate) fn list(paths: &Paths, running: &[Outcome]) -> Result<Vec<ManagedPlugin>, String> {
    Ok(outcomes(paths)?
        .into_iter()
        .map(|outcome| {
            let last = running.iter().find(|running| running.source == outcome.source);
            let (source, state) = match outcome.source {
                Source::Folder(folder) => (PluginOrigin::Folder(folder), PluginState::Local),
                Source::Git(source) => {
                    let state = match outcome.commit {
                        Some(commit) if !matches!(outcome.failure, Some(Failure::NotInstalled)) => {
                            PluginState::Installed { commit }
                        }
                        commit => PluginState::NotInstalled { commit },
                    };
                    (PluginOrigin::Git(source), state)
                }
            };
            // A problem on disk shows first, and a failure of the code shows until the next load.
            let load = match (&outcome.failure, last.map(|last| &last.failure)) {
                (Some(Failure::Invalid(error)), _) | (_, Some(Some(Failure::Invalid(error)))) => {
                    PluginLoad::Failed { error: error.clone() }
                }
                (None, Some(None)) => PluginLoad::Loaded,
                _ => PluginLoad::Pending,
            };
            ManagedPlugin {
                source,
                name: outcome.name,
                state,
                load,
            }
        })
        .collect())
}

/// The plugins of the repository `url` at the commit of `reference`, with no change of a file of the profile.
///
/// # Errors
///
/// Returns a text for a failed resolve or fetch.
pub(crate) async fn find(paths: &Paths, url: &str, reference: Option<&str>) -> Result<Vec<FoundPlugin>, String> {
    let _held = hold(&paths.data).await?;
    Ok(found(paths, url, reference).await?.1)
}

/// The commit of `reference` in the repository `url`, and each folder of that commit with a `plugin.json` whose name
/// reads. The commit goes into the cache.
async fn found(paths: &Paths, url: &str, reference: Option<&str>) -> Result<(String, Vec<FoundPlugin>), String> {
    let fail = |message: String| format!("{url}: {message}");
    let commit = git::resolve(url, reference).await.map_err(fail)?;
    let cache = cache(paths, url);
    git::fetch(&cache, url, &commit).await.map_err(fail)?;
    let mut plugins = Vec::new();
    for path in git::files_named(&cache, &commit, MANIFEST).await.map_err(fail)? {
        let text = git::show(&cache, &commit, &path).await.map_err(fail)?;
        if let Ok(manifest) = serde_json::from_str::<Manifest>(&without_comments(&text))
            && valid_name(&manifest.name).is_ok()
        {
            plugins.push(FoundPlugin {
                name: manifest.name,
                folder: path.rsplit_once('/').map(|(folder, _)| folder.to_owned()),
            });
        }
    }
    Ok((commit, plugins))
}

/// Add the plugins `names` of the repository `url` to `config.json`, install them, and lock them at the commit of
/// `reference`. Without `names`, the repository must have one plugin. The comments and the layout of `config.json`
/// stay. `progress` gets each install.
///
/// # Errors
///
/// Returns a text for a bad file, a name that the repository does not have, a plugin that `config.json` has already, or
/// a failed fetch or install.
pub(crate) async fn add(
    paths: &Paths,
    url: &str,
    names: &[String],
    reference: Option<&str>,
    progress: &dyn Fn(&str),
) -> Result<Vec<AddedPlugin>, String> {
    let _held = hold(&paths.data).await?;
    let known = outcomes(paths)?;
    let path = paths.config.join("config.json");
    let mut text = match fs::read_to_string(&path) {
        Ok(text) => Some(text),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(format!("{}: {error}", path.display())),
    };
    let mut lock = Lock::read(&paths.config)?;
    let (commit, found) = found(paths, url, reference).await?;
    let found_names = || {
        let names: Vec<&str> = found.iter().map(|plugin| plugin.name.as_str()).collect();
        names.join(", ")
    };
    let chosen: Vec<&FoundPlugin> = match (names, found.as_slice()) {
        (_, []) => return Err(format!("{url} has no {MANIFEST}")),
        ([], [plugin]) => vec![plugin],
        ([], _) => {
            return Err(format!(
                "{url} has {} plugins: {}: name the ones to add",
                found.len(),
                found_names()
            ));
        }
        (names, _) => names
            .iter()
            .map(|name| {
                found
                    .iter()
                    .find(|plugin| plugin.name == *name)
                    .ok_or_else(|| format!("{url} has no plugin '{name}': it has {}", found_names()))
            })
            .collect::<Result<_, _>>()?,
    };
    let mut added = Vec::with_capacity(chosen.len());
    for plugin in chosen {
        // A name that the command repeats adds the plugin once.
        if added.iter().any(|done: &AddedPlugin| done.name == plugin.name) {
            continue;
        }
        let source = git_source(url.to_owned(), plugin.folder.as_deref(), reference.map(str::to_owned));
        let fail = |message: String| format!("plugin {}: {message}", plugin.name);
        // The loader skips the second of two plugins of one name, so a clash would hide a plugin.
        if known
            .iter()
            .any(|outcome| outcome.name.as_deref() == Some(plugin.name.as_str()))
        {
            return Err(fail("config.json has a plugin of this name already".to_owned()));
        }
        install(paths, &source, &commit, progress).await.map_err(fail)?;
        let item = serde_json::to_string(&source).map_err(|error| error.to_string())?;
        text = Some(match text {
            Some(text) => add_plugin_item(&text, &item),
            None => format!("{{\n  \"plugins\": [\n    {item}\n  ]\n}}\n"),
        });
        lock.commits.insert(source.clone(), commit.clone());
        added.push(AddedPlugin {
            name: plugin.name.clone(),
            source,
            commit: commit.clone(),
        });
    }
    write_text(&path, text.as_deref().unwrap_or_default())?;
    lock.write(&paths.config)?;
    Ok(added)
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
    let mut lock = Lock::read(&paths.config)?;
    let index = resolve(paths, &config)?
        .outcomes
        .iter()
        .position(|outcome| outcome.name.as_deref() == Some(name))
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

/// The outcome of each plugin of `config.json` as a load sees it on disk now. It uses no network and changes nothing.
///
/// # Errors
///
/// Returns a text for a bad `config.json` or `plugins.lock`.
pub(crate) fn outcomes(paths: &Paths) -> Result<Vec<Outcome>, String> {
    Ok(resolve(paths, &read_config(paths)?)?.outcomes)
}

/// The plugins of `config` as a load sees them on disk now.
fn resolve(paths: &Paths, config: &Config) -> Result<PluginList, String> {
    super::plugins(&paths.config, config, &paths.data)
}

/// Install the commit of `plugins.lock` of each Git plugin, and lock each new Git plugin at the commit of its ref. The
/// lock keeps only the plugins of `config.json`. With `locked`, the lock must match `config.json`, and it stays as it
/// is. A plugin that does not install keeps its locked commit, and the others install. `progress` gets each install.
///
/// # Errors
///
/// Returns a text for a bad file or a lock that does not match with `locked`. After the write of the lock, it returns a
/// text that names each plugin that did not install.
pub(crate) async fn sync(paths: &Paths, locked: bool, progress: &dyn Fn(&str)) -> Result<SyncPluginsResult, String> {
    let _held = hold(&paths.data).await?;
    let config = read_config(paths)?;
    let lock = Lock::read(&paths.config)?;
    let sources = git_sources(&config);
    if locked
        && (lock.commits.len() != sources.len() || sources.iter().any(|source| !lock.commits.contains_key(*source)))
    {
        return Err("plugins.lock does not match the Git plugins of config.json: run `yuke plugin sync`".to_owned());
    }
    let mut plugins = Vec::with_capacity(sources.len());
    let mut failures = Vec::new();
    for source in sources {
        let locked_commit = lock.commits.get(source);
        let installed = async {
            let commit = match locked_commit {
                Some(commit) => commit.clone(),
                None => git::resolve(&source.git, source.reference.as_deref()).await?,
            };
            install(paths, source, &commit, progress).await?;
            Ok::<_, String>(commit)
        }
        .await;
        match (installed, locked_commit) {
            (Ok(commit), _) => plugins.push(LockedPlugin {
                source: source.clone(),
                commit,
            }),
            (Err(error), commit) => {
                failures.push(format!("plugin {}: {error}", git_label(source)));
                plugins.extend(commit.map(|commit| LockedPlugin {
                    source: source.clone(),
                    commit: commit.clone(),
                }));
            }
        }
    }
    let fresh = Lock {
        commits: (plugins.iter())
            .map(|plugin| (plugin.source.clone(), plugin.commit.clone()))
            .collect(),
    };
    let written = !locked && fresh.write(&paths.config)?;
    if !failures.is_empty() {
        return Err(failures.join("; "));
    }
    Ok(SyncPluginsResult { plugins, written })
}

/// The new commit of each installed Git plugin of `target` whose ref moved, with the log of the move. Each new commit is
/// installed, and `plugins.lock` stays as it is until [`apply`]. A plugin that does not check goes into `failed`, and
/// the others have their check. `progress` gets the check of each plugin.
///
/// # Errors
///
/// Returns a text for a bad file, or a name that no installed Git plugin has.
pub(crate) async fn check(
    paths: &Paths,
    target: &PluginTarget,
    progress: &dyn Fn(&str),
) -> Result<CheckPluginsResult, String> {
    let _held = hold(&paths.data).await?;
    // A plugin that is not installed has no name, so a sync comes before its update.
    let mut targets: Vec<(PluginSource, String, String)> = outcomes(paths)?
        .into_iter()
        .filter_map(|outcome| match (outcome.source, outcome.commit, outcome.name) {
            (Source::Git(source), Some(commit), Some(name)) => Some((source, commit, name)),
            _ => None,
        })
        .collect();
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
    let mut result = CheckPluginsResult {
        changes: Vec::new(),
        failed: Vec::new(),
    };
    for (source, old, name) in targets {
        progress(&format!("Checking {name}"));
        let checked = async {
            let new = git::resolve(&source.git, source.reference.as_deref()).await?;
            if new == old {
                return Ok(None);
            }
            let cache = cache(paths, &source.git);
            git::fetch(&cache, &source.git, &new).await?;
            // A new cache does not have the old commit yet.
            let log = async {
                git::fetch(&cache, &source.git, &old).await?;
                git::log(&cache, &old, &new, source.folder.as_deref()).await
            }
            .await;
            // The new commits of other folders of the repository change nothing of the plugin.
            if matches!(&log, Ok(commits) if commits.is_empty()) {
                return Ok(None);
            }
            install(paths, &source, &new, progress).await?;
            Ok::<_, String>(Some((new, log)))
        }
        .await;
        match checked {
            Ok(None) => {}
            Ok(Some((new, log))) => result.changes.push(PluginChange {
                name,
                source,
                old,
                new,
                log: match log {
                    Ok(commits) => PluginLog::Commits { commits },
                    Err(error) => PluginLog::Failed { error },
                },
            }),
            Err(error) => result.failed.push(FailedPlugin { name, error }),
        }
    }
    Ok(result)
}

/// Write the commit of each plugin of `plugins` into `plugins.lock`.
///
/// # Errors
///
/// Returns a text for a plugin that is not in the lock, a commit that is not a full id, or when the file does not read
/// or write.
pub(crate) async fn apply(paths: &Paths, plugins: &[LockedPlugin]) -> Result<(), String> {
    let _held = hold(&paths.data).await?;
    let mut lock = Lock::read(&paths.config)?;
    for plugin in plugins {
        let source = &plugin.source;
        // A commit can come from a client, so it gets the check of a lock entry.
        if !git::is_commit(&plugin.commit) {
            return Err(format!("plugin {source}: '{}' is not a full commit id", plugin.commit));
        }
        let commit = lock
            .commits
            .get_mut(source)
            .ok_or_else(|| format!("plugin {source} is not in plugins.lock"))?;
        commit.clone_from(&plugin.commit);
    }
    lock.write(&paths.config).map(|_| ())
}

/// Install the commit `commit` of `source` in `<data>/git`, unless it is there, and check the manifest of its folder. The
/// install becomes visible whole, with one rename. `progress` gets the start of a download.
async fn install(paths: &Paths, source: &PluginSource, commit: &str, progress: &dyn Fn(&str)) -> Result<(), String> {
    let installed = git_folder(&paths.data, &source.git, commit);
    let folder = source.folder.as_deref().unwrap_or_default();
    // A wrong folder is the usual fault, so its text names the file in the repository, not on disk. The whole manifest
    // gets its check here, so a plugin that cannot load fails now and not at the next reload.
    let check = |files: &Path| {
        let manifest = Path::new(folder).join(MANIFEST);
        if !files.join(&manifest).is_file() {
            return Err(format!("the commit has no {}", manifest.display()));
        }
        manifest_plugin(&files.join(folder), &paths.data, Map::new()).map(|_| ())
    };
    if installed.is_dir() {
        return check(&installed);
    }
    progress(&format!("Installing {}", git_label(source)));
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
    check(&staging)?;
    fs::rename(&staging, &installed).map_err(fail)
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
