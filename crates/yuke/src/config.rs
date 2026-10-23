//! `config.json`: the settings of the user. It and `providers.json` are JSON with `//` and `/* */` comments.

use std::io;
use std::path::Path;

use serde::de::{DeserializeOwned, Error as _};
use serde::{Deserialize, Deserializer};
use serde_json::{Map, Value};

/// The settings of `config.json`. A missing key keeps its default, and an unknown key is an error.
#[derive(Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Config {
    /// The plugins of the profile, in load order.
    #[serde(default)]
    pub(crate) plugins: Vec<ConfigPlugin>,
    /// The bundled plugins that do not load, by name.
    #[serde(default)]
    pub(crate) disable: Vec<String>,
}

/// One item of `plugins`: a folder path, or an object with `path` and `options`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ConfigPlugin {
    /// The folder of the plugin. A relative folder starts in the folder of `config.json`.
    pub(crate) path: String,
    /// The options of the plugin. They are empty when the item gives none.
    pub(crate) options: Map<String, Value>,
}

impl<'de> Deserialize<'de> for ConfigPlugin {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Full {
            path: String,
            #[serde(default)]
            options: Map<String, Value>,
        }
        match Value::deserialize(deserializer)? {
            Value::String(path) => Ok(Self {
                path,
                options: Map::new(),
            }),
            // The error of serde names the bad field or the unknown field.
            value @ Value::Object(_) => {
                let Full { path, options } = Full::deserialize(value).map_err(D::Error::custom)?;
                Ok(Self { path, options })
            }
            _ => Err(D::Error::custom(
                "a plugin is a folder path or an object with \"path\" and \"options\"",
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
    fn a_plugin_item_is_a_folder_path_or_an_object_with_options() {
        let config: Config = serde_json::from_value(json!({
            "plugins": ["./plain", { "path": "./notes", "options": { "folder": "~/notes" } }, { "path": "./bare" }]
        }))
        .unwrap();

        let folder = |path: &str, options: Value| ConfigPlugin {
            path: path.to_owned(),
            options: options.as_object().unwrap().clone(),
        };
        assert_eq!(
            config.plugins,
            [
                folder("./plain", json!({})),
                folder("./notes", json!({ "folder": "~/notes" })),
                folder("./bare", json!({})),
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
            "a plugin is a folder path or an object with \"path\" and \"options\""
        );
        assert_eq!(
            error(json!({ "path": "./a", "options": null })),
            "invalid type: null, expected a map"
        );
        assert_eq!(
            error(json!({ "path": "./a", "option": {} })),
            "unknown field `option`, expected `path` or `options`"
        );
        assert_eq!(
            error(json!({ "path": "./a", "options": [] })),
            "invalid type: sequence, expected a map"
        );
        assert_eq!(error(json!({ "options": {} })), "missing field `path`");
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
