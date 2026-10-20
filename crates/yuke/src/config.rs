//! `config.json`: the settings of the user. It and `providers.json` are JSON with `//` and `/* */` comments.

use std::io;
use std::path::Path;

use serde::Deserialize;
use serde::de::DeserializeOwned;

/// The settings of `config.json`. A missing key keeps its default, and an unknown key is an error.
#[derive(Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Config {
    /// The folders of the plugins, in load order. A relative folder starts in the folder of `config.json`.
    #[serde(default)]
    pub(crate) plugins: Vec<String>,
}

impl Config {
    /// The config in the file `path`. A missing file gives the defaults.
    pub(crate) fn load(path: &Path) -> Result<Config, String> {
        read_json(path)
    }
}

/// The JSON file `path`, with `//` and `/* */` comments. A missing file gives the default value.
pub(crate) fn read_json<T: DeserializeOwned + Default>(path: &Path) -> Result<T, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(T::default()),
        Err(error) => return Err(format!("{}: {error}", path.display())),
    };
    serde_json::from_str(&without_comments(&text)).map_err(|error| format!("{}: {error}", path.display()))
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
    use super::*;

    #[test]
    fn comments_become_spaces_and_strings_keep_their_slashes() {
        let text = "{\r\n  // the model\r\n  \"model\": \"a//b/*c*/\\\"d\", /* note\n */ \"x\": 1\n}";

        assert_eq!(
            without_comments(text),
            "{\r\n              \r\n  \"model\": \"a//b/*c*/\\\"d\",        \n    \"x\": 1\n}"
        );
    }
}
