//! `config.json`: the settings of the user. It and `providers.json` are JSON with `//` and `/* */` comments.

use std::collections::BTreeMap;
use std::io::{self, Write};
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

/// Write `text` to the file `path`, unless the file has this text already. The file is whole or absent after a crash. A
/// link stays a link, also before its target exists, and its target gets the text, so a file in a dotfiles repository
/// stays linked. Gives whether it wrote.
///
/// # Errors
///
/// Returns a text that names the file that does not read or write.
pub(crate) fn write_text(path: &Path, text: &str) -> Result<bool, String> {
    let fail = |error: io::Error| format!("{}: {error}", path.display());
    let folder = path.parent().unwrap_or(Path::new("."));
    let target = match std::fs::read_link(path) {
        Ok(link) => folder.join(link),
        Err(error) if matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::InvalidInput) => path.to_owned(),
        Err(error) => return Err(fail(error)),
    };
    match std::fs::read_to_string(&target) {
        Ok(old) if old == text => return Ok(false),
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(fail(error)),
    }
    let target_folder = target.parent().unwrap_or(folder);
    std::fs::create_dir_all(target_folder).map_err(fail)?;
    let name = target
        .file_name()
        .map(|name| name.to_string_lossy())
        .unwrap_or_default();
    let temporary = target_folder.join(format!(".{name}.new"));
    let mut file = std::fs::File::create(&temporary).map_err(fail)?;
    file.write_all(text.as_bytes()).map_err(fail)?;
    file.sync_all().map_err(fail)?;
    std::fs::rename(&temporary, &target).map_err(fail)?;
    Ok(true)
}

/// `text` with each comment outside a string made into spaces of the same byte length. A line end stays, so an error
/// keeps its line and column, and each byte offset of the result is the same offset in `text`.
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
        let blank = |out: &mut String, character: char| {
            if matches!(character, '\n' | '\r') {
                out.push(character);
            } else {
                out.extend(std::iter::repeat_n(' ', character.len_utf8()));
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
                blank(&mut out, character);
                if character == '\n' {
                    State::Code
                } else {
                    State::LineComment
                }
            }
            State::BlockComment { star } => {
                blank(&mut out, character);
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

/// The places of the top-level object of `config.json` that an edit of `plugins` needs, as byte offsets.
struct Places {
    /// The offset after the `{` of the top-level object.
    object: usize,
    /// Whether the object has a member.
    members: bool,
    /// The offset after the `[` of `plugins`, and the span of each item, when the object has `plugins`.
    plugins: Option<(usize, Vec<std::ops::Range<usize>>)>,
}

/// The [`Places`] of `blank`, a JSON text without comments that [`Config`] reads.
fn places(blank: &str) -> Places {
    let bytes = blank.as_bytes();
    let space = |mut at: usize| {
        while bytes.get(at).is_some_and(u8::is_ascii_whitespace) {
            at += 1;
        }
        at
    };
    // The end of the string at `at`, after its closing quote.
    let string_end = |mut at: usize| {
        at += 1;
        while bytes.get(at).is_some_and(|byte| *byte != b'"') {
            at += if bytes[at] == b'\\' { 2 } else { 1 };
        }
        at + 1
    };
    // The end of the value at `at`. The text is valid JSON, so a bracket closes where the depth comes back to zero.
    let value_end = |mut at: usize| {
        let mut depth = 0_usize;
        while let Some(&byte) = bytes.get(at) {
            match byte {
                b'"' => {
                    at = string_end(at);
                    if depth == 0 {
                        return at;
                    }
                    continue;
                }
                b'{' | b'[' => depth += 1,
                b'}' | b']' if depth > 0 => {
                    depth -= 1;
                    if depth == 0 {
                        return at + 1;
                    }
                }
                b',' | b'}' | b']' if depth == 0 => return at,
                byte if depth == 0 && byte.is_ascii_whitespace() => return at,
                _ => {}
            }
            at += 1;
        }
        at
    };
    let object = space(0) + 1;
    let mut places = Places {
        object,
        members: false,
        plugins: None,
    };
    let mut at = space(object);
    while bytes.get(at) == Some(&b'"') {
        places.members = true;
        let key_end = string_end(at);
        let key = &blank[at..key_end];
        let value = space(space(key_end) + 1);
        if key == "\"plugins\"" {
            let open = value + 1;
            let mut items = Vec::new();
            let mut item = space(open);
            while bytes.get(item).is_some_and(|byte| *byte != b']') {
                let end = value_end(item);
                items.push(item..end);
                item = space(end);
                if bytes.get(item) == Some(&b',') {
                    item = space(item + 1);
                }
            }
            places.plugins = Some((open, items));
        }
        at = space(value_end(value));
        if bytes.get(at) == Some(&b',') {
            at = space(at + 1);
        }
    }
    places
}

/// The offset of the start of the line of `at` in `text`.
fn line_start(text: &str, at: usize) -> usize {
    text[..at].rfind('\n').map_or(0, |offset| offset + 1)
}

/// The offset after the end of the line of `at` in `text`, with its line end.
fn line_end(text: &str, at: usize) -> usize {
    text[at..].find('\n').map_or(text.len(), |offset| at + offset + 1)
}

/// `text`, the text of `config.json`, with `item` as the last item of `plugins`. The comments and the layout of `text`
/// stay. On a list of one item per line, the new item takes its own line with the indent of the last item.
pub(crate) fn add_plugin_item(text: &str, item: &str) -> String {
    let blank = without_comments(text);
    let places = places(&blank);
    match &places.plugins {
        Some((_, items)) if let Some(last) = items.last() => {
            let indent = &text[line_start(text, last.start)..last.start];
            let end = line_end(text, last.end);
            // A comment after the last item stays on its line, so the new item goes after that line.
            if indent.trim().is_empty() && blank[last.end..end].trim().is_empty() && blank[..end].ends_with('\n') {
                format!(
                    "{},{}{indent}{item}\n{}",
                    &text[..last.end],
                    &text[last.end..end],
                    &text[end..]
                )
            } else {
                format!("{}, {item}{}", &text[..last.end], &text[last.end..])
            }
        }
        Some((open, _)) => format!("{}{item}{}", &text[..*open], &text[*open..]),
        None => {
            let member = format!("\n  \"plugins\": [{item}]{}", if places.members { "," } else { "\n" });
            format!("{}{member}{}", &text[..places.object], &text[places.object..])
        }
    }
}

/// `text`, the text of `config.json`, without the item `index` of `plugins` and one comma beside it. An item on lines of
/// its own goes with those lines and with a comment after it on its last line. The other comments and the layout stay.
/// `None` when `plugins` has no such item.
pub(crate) fn remove_plugin_item(text: &str, index: usize) -> Option<String> {
    let blank = without_comments(text);
    let (_, items) = places(&blank).plugins?;
    let item = items.get(index)?.clone();
    // The comma after the item, else the comma before the last item.
    let comma = match items.get(index + 1) {
        Some(next) => blank[item.end..next.start].find(',').map(|at| item.end + at),
        None => index.checked_sub(1).and_then(|before| {
            let before = &items[before];
            blank[before.end..item.start].find(',').map(|at| before.end + at)
        }),
    };
    let after = comma.filter(|at| *at >= item.end).map_or(item.end, |at| at + 1);
    let (start, end) = (line_start(text, item.start), line_end(text, after));
    let own_lines = text[start..item.start].trim().is_empty() && blank[after..end].trim().is_empty();
    let mut cuts = vec![if own_lines { start..end } else { item.start..after }];
    if let Some(at) = comma.filter(|at| *at < item.start) {
        cuts.push(at..at + 1);
    }
    cuts.sort_by_key(|cut| std::cmp::Reverse(cut.start));
    let mut text = text.to_owned();
    for cut in cuts {
        text.replace_range(cut, "");
    }
    Some(text)
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
    fn an_added_plugin_item_follows_the_last_item_with_its_indent_and_the_comments_stay() {
        let item = r#"{"git":"https://h/r"}"#;
        let lines = "{\n  // the plugins ]\n  \"plugins\": [\n    \"./a\", // first\n    { \"path\": \"./b]\\\"c\" }\n  ],\n  \"disable\": []\n}\n";
        let edits = [
            (
                lines,
                "{\n  // the plugins ]\n  \"plugins\": [\n    \"./a\", // first\n    { \"path\": \"./b]\\\"c\" },\n    {\"git\":\"https://h/r\"}\n  ],\n  \"disable\": []\n}\n",
            ),
            (
                r#"{ "plugins": ["./a"] }"#,
                r#"{ "plugins": ["./a", {"git":"https://h/r"}] }"#,
            ),
            (
                r#"{ "plugins": [ /* none */ ] }"#,
                r#"{ "plugins": [{"git":"https://h/r"} /* none */ ] }"#,
            ),
            (
                "{\n  \"disable\": []\n}",
                "{\n  \"plugins\": [{\"git\":\"https://h/r\"}],\n  \"disable\": []\n}",
            ),
            ("{}", "{\n  \"plugins\": [{\"git\":\"https://h/r\"}]\n}"),
        ];

        for (text, expected) in edits {
            assert_eq!(add_plugin_item(text, item), expected, "{text}");
        }
    }

    #[test]
    fn a_comment_on_the_line_of_an_item_stays_with_it_and_a_comment_line_stays_in_place() {
        let item = r#"{"git":"https://h/r"}"#;
        let text = "{ \"plugins\": [\n    \"./a\", // the a plugin\n    // the b plugin\n    \"./b\" // last\n  ] }";

        assert_eq!(
            add_plugin_item(text, item),
            "{ \"plugins\": [\n    \"./a\", // the a plugin\n    // the b plugin\n    \"./b\", // last\n    {\"git\":\"https://h/r\"}\n  ] }"
        );
        assert_eq!(
            remove_plugin_item(text, 0).as_deref(),
            Some("{ \"plugins\": [\n    // the b plugin\n    \"./b\" // last\n  ] }")
        );
        assert_eq!(
            remove_plugin_item(text, 1).as_deref(),
            Some("{ \"plugins\": [\n    \"./a\" // the a plugin\n    // the b plugin\n  ] }")
        );
    }

    #[test]
    fn a_removed_plugin_item_takes_one_comma_and_the_other_items_and_comments_stay() {
        let text = "{ \"plugins\": [\n    \"./a\", // first\n    \"./b\",\n    \"./c\"\n  ] }";

        assert_eq!(
            remove_plugin_item(text, 1).as_deref(),
            Some("{ \"plugins\": [\n    \"./a\", // first\n    \"./c\"\n  ] }")
        );
        assert_eq!(
            remove_plugin_item(text, 2).as_deref(),
            Some("{ \"plugins\": [\n    \"./a\", // first\n    \"./b\"\n  ] }")
        );
        assert_eq!(
            remove_plugin_item(r#"{ "plugins": ["./a"] }"#, 0).as_deref(),
            Some(r#"{ "plugins": [] }"#)
        );
        assert_eq!(remove_plugin_item(text, 3), None);
        assert_eq!(remove_plugin_item("{}", 0), None);
    }

    #[test]
    fn a_comment_keeps_the_byte_length_of_each_character() {
        let text = "{ // café ☕\n \"a\": 1 /* ü */ }";

        let blank = without_comments(text);

        assert_eq!(blank.len(), text.len());
        assert_eq!(blank.find("\"a\""), text.find("\"a\""));
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
