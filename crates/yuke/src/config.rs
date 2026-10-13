//! `config.json`: the settings of the user. The file is JSON with `//` and `/* */` comments.

use std::io;
use std::path::Path;

use serde::Deserialize;

/// The settings of `config.json`. A missing key keeps its default, and an unknown key is an error.
#[derive(Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Config {
    /// The model of a new session, as `provider/model`, when the command line names none.
    pub(crate) model: Option<String>,
}

impl Config {
    /// The config in the file `path`. A missing file gives the defaults.
    pub(crate) fn load(path: &Path) -> Result<Config, String> {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Config::default()),
            Err(error) => return Err(format!("{}: {error}", path.display())),
        };
        serde_json::from_str(&without_comments(&text)).map_err(|error| format!("{}: {error}", path.display()))
    }
}

/// `text` with each comment outside a string made into spaces. A line end stays, so an error keeps its line and column.
fn without_comments(text: &str) -> String {
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

    #[test]
    fn a_parse_error_names_the_file_and_the_line_of_the_text_with_comments() {
        let folder = std::env::temp_dir().join(format!("yuke-config-test-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let path = folder.join("config.json");
        std::fs::write(&path, "{\n  // one\n  /* two\n  three */\n  \"model\": 5\n}\n").unwrap();

        let error = Config::load(&path).unwrap_err();

        assert_eq!(
            error,
            format!(
                "{}: invalid type: integer `5`, expected a string at line 5 column 12",
                path.display()
            )
        );
    }

    #[test]
    fn a_missing_file_gives_the_defaults_and_an_unknown_key_is_an_error() {
        let folder = std::env::temp_dir().join(format!("yuke-config-test-keys-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let path = folder.join("config.json");

        assert_eq!(Config::load(&folder.join("missing.json")), Ok(Config::default()));
        std::fs::write(&path, r#"{ "model": "minimax/MiniMax-M3" }"#).unwrap();
        assert_eq!(
            Config::load(&path),
            Ok(Config {
                model: Some("minimax/MiniMax-M3".to_owned())
            })
        );
        std::fs::write(&path, r#"{ "modle": "x" }"#).unwrap();
        assert!(Config::load(&path).unwrap_err().contains("unknown field `modle`"));
    }
}
