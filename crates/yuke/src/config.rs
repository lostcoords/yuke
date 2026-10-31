//! `config.json`: the settings of the user. It and `providers.json` are JSON with `//` and `/* */` comments.

use std::collections::BTreeMap;
use std::io;
use std::path::Path;

use serde::de::{DeserializeOwned, Error as _};
use serde::{Deserialize, Deserializer};
use serde_json::{Map, Value};
use yuke_protocol::PluginSource;

/// The settings of `config.json`. A missing key keeps its default, and an unknown key is an error.
#[derive(Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Config {
    /// The plugins of the profile, in load order. A provider loads before the plugins that use it.
    #[serde(default)]
    pub(crate) plugins: Vec<ConfigPlugin>,
    /// The bundled plugins that do not load, by name.
    #[serde(default)]
    pub(crate) disable: Vec<String>,
    /// The options of bundled plugins, by name. A bundled plugin that the map does not name gets no options.
    #[serde(default)]
    pub(crate) bundled: BTreeMap<String, Map<String, Value>>,
    /// The minutes that a session with running jobs and no holder waits before it closes and stops the jobs. The
    /// default is 30.
    #[serde(default, rename = "sessionIdleMinutes")]
    pub(crate) session_idle_minutes: Option<u32>,
}

/// One item of `plugins`: a folder path, or an object with `path` or `git` and optional `options`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ConfigPlugin {
    /// Where the plugin comes from.
    pub(crate) source: Source,
    /// The options of the plugin. They are empty when the item gives none.
    pub(crate) options: Map<String, Value>,
}

/// Where a plugin of `plugins` comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Source {
    /// A folder. A relative folder starts in the folder of `config.json`.
    Folder(String),
    /// A folder of a Git repository, at the commit of `plugins.lock`.
    Git(PluginSource),
}

/// The source of the Git plugin `url`, `folder`, and `reference`, in the form that keys `plugins.lock`. The folders `./a/`
/// and `a` are the same, and `.` is the root.
///
/// # Errors
///
/// Returns a text when `folder` is absolute or has a `..` part.
pub(crate) fn git_source(url: String, folder: Option<&str>, reference: Option<String>) -> Result<PluginSource, String> {
    let folder = match folder {
        None => None,
        Some(text) => {
            let parts: Vec<&str> = text.split('/').filter(|part| !matches!(*part, "" | ".")).collect();
            if text.starts_with('/') || parts.contains(&"..") {
                return Err(format!("folder: '{text}' is not a relative path inside the repository"));
            }
            (!parts.is_empty()).then(|| parts.join("/"))
        }
    };
    Ok(PluginSource {
        git: url,
        folder,
        reference,
    })
}

impl<'de> Deserialize<'de> for ConfigPlugin {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Full {
            path: Option<String>,
            git: Option<String>,
            folder: Option<String>,
            #[serde(rename = "ref")]
            reference: Option<String>,
            #[serde(default)]
            options: Map<String, Value>,
        }
        match Value::deserialize(deserializer)? {
            Value::String(path) => Ok(Self {
                source: Source::Folder(path),
                options: Map::new(),
            }),
            // The error of serde names the bad field or the unknown field.
            value @ Value::Object(_) => {
                let full = Full::deserialize(value).map_err(D::Error::custom)?;
                let source = match (full.path, full.git) {
                    (Some(_), Some(_)) => return Err(D::Error::custom("a plugin has \"path\" or \"git\", not both")),
                    (None, None) => return Err(D::Error::custom("a plugin needs \"path\" or \"git\"")),
                    (Some(_), None) if full.folder.is_some() || full.reference.is_some() => {
                        return Err(D::Error::custom(
                            "\"folder\" and \"ref\" go with \"git\", not with \"path\"",
                        ));
                    }
                    (Some(path), None) => Source::Folder(path),
                    (None, Some(url)) => {
                        Source::Git(git_source(url, full.folder.as_deref(), full.reference).map_err(D::Error::custom)?)
                    }
                };
                Ok(Self {
                    source,
                    options: full.options,
                })
            }
            _ => Err(D::Error::custom(
                "a plugin is a folder path or an object with \"path\" or \"git\"",
            )),
        }
    }
}

/// Read the JSON file `path`, with `//` and `/* */` comments. A missing file gives `Ok(None)`. An error names the path.
pub(crate) fn read_json<T: DeserializeOwned>(path: &Path) -> Result<Option<T>, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("{}: {error}", path.display())),
    };
    serde_json::from_str(&without_comments(&text))
        .map(Some)
        .map_err(|error| format!("{}: {error}", path.display()))
}

/// `text` with each comment outside a string made into spaces. A line end stays, so an error keeps its line and column.
pub(crate) fn without_comments(text: &str) -> String {
    enum State {
        Code,
        Text { escaped: bool },
        LineComment,
        BlockComment { star: bool },
    }
    let mut state = State::Code;
    let mut out = String::with_capacity(text.len());
    let mut characters = text.chars().peekable();
    while let Some(character) = characters.next() {
        let blank = |character: char| {
            if matches!(character, '\n' | '\r') {
                character
            } else {
                ' '
            }
        };
        state = match state {
            State::Code => match (character, characters.peek()) {
                ('"', _) => {
                    out.push(character);
                    State::Text { escaped: false }
                }
                ('/', Some('/')) => {
                    characters.next();
                    out.push_str("  ");
                    State::LineComment
                }
                ('/', Some('*')) => {
                    characters.next();
                    out.push_str("  ");
                    State::BlockComment { star: false }
                }
                _ => {
                    out.push(character);
                    State::Code
                }
            },
            State::Text { escaped } => {
                out.push(character);
                match character {
                    '"' if !escaped => State::Code,
                    '\\' => State::Text { escaped: !escaped },
                    _ => State::Text { escaped: false },
                }
            }
            State::LineComment => {
                out.push(blank(character));
                if character == '\n' {
                    State::Code
                } else {
                    State::LineComment
                }
            }
            State::BlockComment { star } => {
                out.push(blank(character));
                match character {
                    '/' if star => State::Code,
                    '*' => State::BlockComment { star: true },
                    _ => State::BlockComment { star: false },
                }
            }
        };
    }
    out
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn a_plugin_item_is_a_folder_path_or_an_object_with_a_folder_or_a_git_repository() {
        let config: Config = serde_json::from_value(json!({
            "plugins": [
                "./plain",
                { "path": "./notes", "options": { "folder": "~/notes" } },
                { "git": "https://host/repo", "folder": "./plugins//clock/", "ref": "main", "options": { "a": 1 } },
                { "git": "https://host/repo", "folder": "." },
            ]
        }))
        .unwrap();

        let item = |source: Source, options: Value| ConfigPlugin {
            source,
            options: options.as_object().unwrap().clone(),
        };
        let git = |folder: Option<&str>, reference: Option<&str>| {
            Source::Git(PluginSource {
                git: "https://host/repo".to_owned(),
                folder: folder.map(str::to_owned),
                reference: reference.map(str::to_owned),
            })
        };
        assert_eq!(
            config.plugins,
            [
                item(Source::Folder("./plain".to_owned()), json!({})),
                item(Source::Folder("./notes".to_owned()), json!({ "folder": "~/notes" })),
                item(git(Some("plugins/clock"), Some("main")), json!({ "a": 1 })),
                item(git(None, None), json!({})),
            ]
        );
    }

    #[test]
    fn a_plugin_item_of_another_form_fails_with_the_reason() {
        let error = |plugin: Value| {
            serde_json::from_value::<Config>(json!({ "plugins": [plugin] }))
                .unwrap_err()
                .to_string()
        };

        assert_eq!(
            error(json!(1)),
            "a plugin is a folder path or an object with \"path\" or \"git\""
        );
        assert_eq!(
            error(json!({ "path": "./a", "options": null })),
            "invalid type: null, expected a map"
        );
        assert!(error(json!({ "path": "./a", "option": {} })).starts_with("unknown field `option`"));
        assert_eq!(error(json!({ "options": {} })), "a plugin needs \"path\" or \"git\"");
        assert_eq!(
            error(json!({ "path": "./a", "git": "https://host/repo" })),
            "a plugin has \"path\" or \"git\", not both"
        );
        assert_eq!(
            error(json!({ "path": "./a", "ref": "main" })),
            "\"folder\" and \"ref\" go with \"git\", not with \"path\""
        );
        for folder in ["../up", "a/../../up", "/abs"] {
            assert_eq!(
                error(json!({ "git": "https://host/repo", "folder": folder })),
                format!("folder: '{folder}' is not a relative path inside the repository")
            );
        }
    }

    #[test]
    fn a_missing_file_reads_as_none_and_a_bad_file_fails_with_its_path() {
        let folder = std::env::temp_dir().join(format!("yuke-config-tests-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let good = folder.join("good.json");
        std::fs::write(&good, "{\n  // a comment\n  \"plugins\": [\"./a\"]\n}").unwrap();
        let bad = folder.join("bad.json");
        std::fs::write(&bad, "{ \"plugins\": ").unwrap();

        let read = read_json::<Config>(&good).unwrap();
        let missing = read_json::<Config>(&folder.join("absent.json"));
        let error = read_json::<Config>(&bad).unwrap_err();

        assert_eq!(read.map(|config| config.plugins.len()), Some(1));
        assert_eq!(missing, Ok(None));
        assert!(error.starts_with(&format!("{}: ", bad.display())), "{error}");
    }

    #[test]
    fn comments_become_spaces_and_strings_keep_their_slashes() {
        let text = "{\r\n  // the model\r\n  \"model\": \"a//b/*c*/\\\"d\", /* note\n */ \"x\": 1\n}";

        assert_eq!(
            without_comments(text),
            "{\r\n              \r\n  \"model\": \"a//b/*c*/\\\"d\",        \n    \"x\": 1\n}"
        );
    }
}
