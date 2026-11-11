//! The folders of yuke: the config, the data, and the cache, under the XDG roots.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// The folder name under each root.
const APP_NAME: &str = "yuke";

/// The variable that replaces the folder name, so a second profile lives beside the first.
const APP_NAME_VARIABLE: &str = "YUKE_APPNAME";

/// The folders of one profile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Paths {
    /// The folder of `config.json`.
    pub(crate) config: PathBuf,
    /// The folder of the session store.
    pub(crate) data: PathBuf,
    /// The folder of the files that yuke can make again, such as the JavaScript of each TypeScript file.
    pub(crate) cache: PathBuf,
}

impl Paths {
    /// The folders that the environment names. `variable` reads one environment variable, and `home` is the home
    /// folder of the user. An empty or relative root variable counts as unset, as the XDG specification says.
    pub(crate) fn of(variable: &dyn Fn(&str) -> Option<OsString>, home: Option<&Path>) -> Result<Paths, String> {
        let name = variable(APP_NAME_VARIABLE)
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| OsString::from(APP_NAME));
        let folder = |root_variable: &str, under_home: &str| {
            let root = variable(root_variable)
                .map(PathBuf::from)
                .filter(|root| root.is_absolute())
                .or_else(|| home.map(|home| home.join(under_home)))
                .ok_or_else(|| format!("no home folder: set HOME or {root_variable}"))?;
            Ok::<_, String>(root.join(&name))
        };
        Ok(Paths {
            config: folder("XDG_CONFIG_HOME", ".config")?,
            data: folder("XDG_DATA_HOME", ".local/share")?,
            cache: folder("XDG_CACHE_HOME", ".cache")?,
        })
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    fn paths(variables: &[(&str, &str)], home: Option<&str>) -> Result<Paths, String> {
        let variables: HashMap<&str, &str> = variables.iter().copied().collect();
        Paths::of(&|name| variables.get(name).map(OsString::from), home.map(Path::new))
    }

    #[test]
    fn the_folders_are_under_the_home_folder_by_default() {
        assert_eq!(
            paths(&[], Some("/home/me")),
            Ok(Paths {
                config: PathBuf::from("/home/me/.config/yuke"),
                data: PathBuf::from("/home/me/.local/share/yuke"),
                cache: PathBuf::from("/home/me/.cache/yuke"),
            })
        );
    }

    #[test]
    fn an_absolute_root_variable_replaces_its_default_and_an_empty_or_relative_one_does_not() {
        let rooted = paths(
            &[
                ("XDG_CONFIG_HOME", "/config"),
                ("XDG_DATA_HOME", ""),
                ("XDG_CACHE_HOME", "cache"),
            ],
            Some("/home/me"),
        )
        .unwrap();

        assert_eq!(rooted.config, PathBuf::from("/config/yuke"));
        assert_eq!(rooted.data, PathBuf::from("/home/me/.local/share/yuke"));
        assert_eq!(rooted.cache, PathBuf::from("/home/me/.cache/yuke"));
    }

    #[test]
    fn yuke_appname_replaces_the_folder_name() {
        let named = paths(&[("YUKE_APPNAME", "work")], Some("/home/me")).unwrap();
        let empty = paths(&[("YUKE_APPNAME", "")], Some("/home/me")).unwrap();

        assert_eq!(named.config, PathBuf::from("/home/me/.config/work"));
        assert_eq!(named.data, PathBuf::from("/home/me/.local/share/work"));
        assert_eq!(named.cache, PathBuf::from("/home/me/.cache/work"));
        assert_eq!(empty.data, PathBuf::from("/home/me/.local/share/yuke"));
    }

    #[test]
    fn no_home_folder_and_no_root_variable_is_an_error() {
        assert_eq!(
            paths(&[], None),
            Err("no home folder: set HOME or XDG_CONFIG_HOME".to_owned())
        );
    }
}
