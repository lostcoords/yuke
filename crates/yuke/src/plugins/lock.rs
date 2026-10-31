//! `plugins.lock` in the config folder: the commit of each Git plugin. `yuke plugin sync` writes it, and the user keeps it
//! with the dotfiles.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::git::is_commit;
use yuke_protocol::PluginSource;

use crate::config::{Config, Source, git_source, read_json};

/// The name of the lock file in the config folder.
pub(crate) const LOCK: &str = "plugins.lock";

/// The version of the lock file that this yuke reads and writes.
const VERSION: u32 = 1;

/// The commits of `plugins.lock`, by source.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Lock {
    pub(crate) commits: HashMap<PluginSource, String>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct FileText {
    version: u32,
    plugins: Vec<Entry>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    git: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    folder: Option<String>,
    #[serde(rename = "ref", skip_serializing_if = "Option::is_none")]
    reference: Option<String>,
    commit: String,
}

impl Lock {
    /// Read `plugins.lock` of `config_folder`. A missing file is an empty lock.
    ///
    /// # Errors
    ///
    /// Returns a text that names the file, for an unreadable file, another version, a bad folder, or a commit that is not
    /// a full commit id.
    pub(crate) fn read(config_folder: &Path) -> Result<Self, String> {
        let path = config_folder.join(LOCK);
        let Some(file) = read_json::<FileText>(&path)? else {
            return Ok(Self::default());
        };
        let fail = |message: String| format!("{}: {message}", path.display());
        if file.version != VERSION {
            return Err(fail(format!(
                "this yuke reads version {VERSION}, not version {}",
                file.version
            )));
        }
        let mut commits = HashMap::with_capacity(file.plugins.len());
        for entry in file.plugins {
            // A commit id is a folder name of the install.
            if !is_commit(&entry.commit) {
                return Err(fail(format!("'{}' is not a full commit id", entry.commit)));
            }
            let source = git_source(entry.git, entry.folder.as_deref(), entry.reference).map_err(fail)?;
            commits.insert(source, entry.commit);
        }
        Ok(Self { commits })
    }

    /// [`Lock::read`] when `config` has a Git plugin, else an empty lock, so a bad lock does not stop a profile of local
    /// plugins.
    ///
    /// # Errors
    ///
    /// Returns the errors of [`Lock::read`].
    pub(crate) fn read_for(config_folder: &Path, config: &Config) -> Result<Self, String> {
        if config
            .plugins
            .iter()
            .any(|plugin| matches!(plugin.source, Source::Git(_)))
        {
            Self::read(config_folder)
        } else {
            Ok(Self::default())
        }
    }

    /// Write the lock to `plugins.lock` of `config_folder`, sorted by source, unless the file has this text already. A
    /// link stays a link, and its target gets the text. Gives whether it wrote.
    ///
    /// # Errors
    ///
    /// Returns a text that names the file that does not read or write.
    pub(crate) fn write(&self, config_folder: &Path) -> Result<bool, String> {
        let mut entries: Vec<(&PluginSource, &String)> = self.commits.iter().collect();
        entries.sort();
        let file = FileText {
            version: VERSION,
            plugins: entries
                .into_iter()
                .map(|(source, commit)| Entry {
                    git: source.git.clone(),
                    folder: source.folder.clone(),
                    reference: source.reference.clone(),
                    commit: commit.clone(),
                })
                .collect(),
        };
        let path = config_folder.join(LOCK);
        let fail = |error: io::Error| format!("{}: {error}", path.display());
        let mut text = serde_json::to_string_pretty(&file).map_err(|error| format!("{}: {error}", path.display()))?;
        text.push('\n');
        // The rename replaces the target of a link, so a lock in a dotfiles repository stays linked, also before its
        // target exists.
        let target = match fs::read_link(&path) {
            Ok(link) => config_folder.join(link),
            Err(error) if matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::InvalidInput) => path.clone(),
            Err(error) => return Err(fail(error)),
        };
        match fs::read_to_string(&target) {
            Ok(old) if old == text => return Ok(false),
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(fail(error)),
        }
        let folder = target.parent().unwrap_or(config_folder);
        fs::create_dir_all(folder).map_err(fail)?;
        let temporary = folder.join(format!(".{LOCK}.new"));
        let mut new = File::create(&temporary).map_err(fail)?;
        new.write_all(text.as_bytes()).map_err(fail)?;
        new.sync_all().map_err(fail)?;
        fs::rename(&temporary, &target).map_err(fail)?;
        Ok(true)
    }
}
