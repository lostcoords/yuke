//! The skills of a new session: each folder with a `SKILL.md` in the skill folders, by its name and its description.

use std::collections::HashSet;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

const MAX_NAME_BYTES: usize = 64;

const MAX_DESCRIPTION_CHARS: usize = 1024;

/// One skill.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Skill {
    pub(crate) name: String,
    pub(crate) description: String,
    /// The path of its `SKILL.md` below its skill folder.
    pub(crate) location: PathBuf,
}

/// The skills of the skill folders, sorted by name, and the warnings of the scan for the user.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Catalog {
    pub(crate) skills: Vec<Skill>,
    pub(crate) warnings: Vec<String>,
}

/// The skills of `roots`, in order: a skill of an earlier root hides a later skill with the same name. A skill is a
/// direct subfolder with a `SKILL.md`. A missing root has no skills.
pub(crate) fn catalog(roots: &[PathBuf]) -> Catalog {
    let mut catalog = Catalog::default();
    let mut seen = HashSet::new();
    for root in roots {
        let entries = match std::fs::read_dir(root) {
            Ok(entries) => entries,
            Err(error) if matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::NotADirectory) => continue,
            Err(error) => {
                catalog
                    .warnings
                    .push(format!("yuke cannot read the skill folder {}: {error}", root.display()));
                continue;
            }
        };
        let mut folders = Vec::new();
        for entry in entries {
            let entry = match entry {
                Ok(entry) => entry,
                Err(error) => {
                    catalog
                        .warnings
                        .push(format!("yuke cannot read the skill folder {}: {error}", root.display()));
                    continue;
                }
            };
            let folder = entry.path();
            let location = folder.join("SKILL.md");
            match std::fs::metadata(&location) {
                Ok(_) => {}
                // A broken link is a skill that does not read. Another missing file is no skill.
                Err(error) if matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::NotADirectory) => {
                    if std::fs::symlink_metadata(&location).is_ok() {
                        catalog.warnings.push(skipped(&location, &error.to_string()));
                    }
                    continue;
                }
                Err(error) => {
                    catalog.warnings.push(skipped(&location, &error.to_string()));
                    continue;
                }
            }
            match entry.file_name().into_string() {
                Ok(name) => folders.push((name, folder)),
                Err(_) => catalog
                    .warnings
                    .push(skipped(&location, "the folder name is not valid UTF-8")),
            }
        }
        // The order of a folder listing is not stable, so the first folder of a name is the first in byte order.
        folders.sort();
        for (folder_name, folder) in folders {
            let location = folder.join("SKILL.md");
            // Two links to one file give one skill.
            match std::fs::canonicalize(&location) {
                Ok(real) => {
                    if !seen.insert(real) {
                        continue;
                    }
                }
                Err(error) => {
                    catalog.warnings.push(skipped(&location, &error.to_string()));
                    continue;
                }
            }
            match skill(&folder_name, &location) {
                Ok(skill) if catalog.skills.iter().any(|known| known.name == skill.name) => {
                    catalog
                        .warnings
                        .push(skipped(&location, "another skill already holds this name"));
                }
                Ok(skill) => {
                    if skill.name != folder_name {
                        catalog.warnings.push(format!(
                            "The skill at {} has the name '{}', which is not the name of its folder",
                            location.display(),
                            skill.name
                        ));
                    }
                    catalog.skills.push(skill);
                }
                Err(reason) => catalog.warnings.push(skipped(&location, &reason)),
            }
        }
    }
    catalog.skills.sort_by(|left, right| left.name.cmp(&right.name));
    catalog
}

fn skipped(location: &Path, reason: &str) -> String {
    format!("yuke skipped the skill at {}: {reason}", location.display())
}

/// The skill of the `SKILL.md` at `location` in the folder `folder_name`, or why it is no skill.
fn skill(folder_name: &str, location: &Path) -> Result<Skill, String> {
    let mut file = std::fs::File::open(location).map_err(|error| error.to_string())?;
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    if !metadata.is_file() {
        return Err("the source is not a regular file".to_owned());
    }
    let mut text = String::new();
    file.read_to_string(&mut text).map_err(|error| error.to_string())?;
    let fields = frontmatter(&text).ok_or("the file has no frontmatter")?;
    let name = fields.name.unwrap_or_else(|| folder_name.to_owned());
    check_name(&name)?;
    let description = fields.description.unwrap_or_default();
    check_description(&description)?;
    Ok(Skill {
        name,
        description,
        location: location.to_owned(),
    })
}

/// The name rules of the Agent Skills specification.
fn check_name(name: &str) -> Result<(), String> {
    if name.is_empty() || name.len() > MAX_NAME_BYTES {
        return Err(format!("the name '{name}' is not 1 to {MAX_NAME_BYTES} characters"));
    }
    if !name
        .bytes()
        .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        return Err(format!("the name '{name}' has a character other than a-z, 0-9, and -"));
    }
    if name.starts_with('-') || name.ends_with('-') || name.contains("--") {
        return Err(format!("the name '{name}' starts or ends with -, or holds --"));
    }
    Ok(())
}

fn check_description(description: &str) -> Result<(), String> {
    if description.trim().is_empty() {
        return Err("the description is missing".to_owned());
    }
    if description.chars().count() > MAX_DESCRIPTION_CHARS {
        return Err(format!("the description exceeds {MAX_DESCRIPTION_CHARS} characters"));
    }
    if description
        .chars()
        .any(|character| character.is_control() && !matches!(character, '\t' | '\n' | '\r'))
    {
        return Err("the description holds a control character".to_owned());
    }
    Ok(())
}

/// The fields of a frontmatter that the catalog reads.
#[derive(Debug, Default, PartialEq, Eq)]
struct Fields {
    name: Option<String>,
    description: Option<String>,
}

/// The `name` and `description` of the frontmatter at the start of `text`, or `None` without a frontmatter. The parser
/// reads a subset of YAML: top-level `key: value` lines with plain, quoted, or block values. It skips other lines.
fn frontmatter(text: &str) -> Option<Fields> {
    let lines: Vec<&str> = text.strip_prefix('\u{feff}').unwrap_or(text).lines().collect();
    if lines.first()?.trim_end() != "---" {
        return None;
    }
    let end = lines[1..].iter().position(|line| line.trim_end() == "---")? + 1;
    let body = &lines[1..end];
    let mut fields = Fields::default();
    let mut index = 0;
    while index < body.len() {
        let line = body[index];
        index += 1;
        if line.trim().is_empty() || line.starts_with([' ', '\t', '#']) {
            continue;
        }
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let raw = value.trim();
        let value = scalar(raw);
        // A block value and a plain value on the next lines both take the indented lines that follow.
        let block = raw.starts_with(['|', '>']);
        let value = if block || value.is_empty() {
            let lines: Vec<&str> = body[index..]
                .iter()
                .take_while(|line| line.trim().is_empty() || line.starts_with(' '))
                .copied()
                .collect();
            index += lines.len();
            block_value(&lines, !block || raw.starts_with('>'))
        } else {
            value
        };
        match key.trim() {
            "name" => fields.name = Some(value),
            "description" => fields.description = Some(value),
            _ => {}
        }
    }
    Some(fields)
}

/// The text of the indented `lines` of a block value. A folded value joins two lines with a space. An empty line gives
/// a line break, and a more indented line keeps the line breaks around it.
fn block_value(lines: &[&str], folded: bool) -> String {
    let indent = lines
        .iter()
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.len() - line.trim_start_matches(' ').len())
        .min()
        .unwrap_or(0);
    let lines: Vec<&str> = lines
        .iter()
        .map(|line| line.get(indent..).unwrap_or("").trim_end())
        .collect();
    if !folded {
        return lines.join("\n").trim().to_owned();
    }
    let mut text = String::new();
    let mut previous_kept = false;
    for line in lines {
        let kept = line.starts_with(' ');
        if line.is_empty() {
            text.push('\n');
        } else {
            if !text.is_empty() && !text.ends_with('\n') {
                text.push(if kept || previous_kept { '\n' } else { ' ' });
            }
            text.push_str(line);
        }
        previous_kept = kept;
    }
    text.trim().to_owned()
}

/// The text of a plain or quoted value. A comment after the value does not count. An unclosed quote keeps the raw text.
fn scalar(value: &str) -> String {
    if value.starts_with('#') {
        return String::new();
    }
    if let Some(rest) = value.strip_prefix('"') {
        // A backslash escapes the next character, so a quote after one does not close the value.
        let mut escaped = false;
        let end = rest.char_indices().find_map(|(index, character)| {
            let closes = character == '"' && !escaped;
            escaped = character == '\\' && !escaped;
            closes.then_some(index)
        });
        if let Some(end) = end
            && is_comment(&rest[end + 1..])
            && let Some(text) = unescape(&rest[..end])
        {
            return text;
        }
        return value.to_owned();
    }
    if let Some(rest) = value.strip_prefix('\'') {
        // Two quotes stand for one quote, so the value ends at a quote that no quote follows.
        let mut index = 0;
        while let Some(offset) = rest[index..].find('\'') {
            let at = index + offset;
            if rest[at + 1..].starts_with('\'') {
                index = at + 2;
                continue;
            }
            if is_comment(&rest[at + 1..]) {
                return rest[..at].replace("''", "'");
            }
            break;
        }
        return value.to_owned();
    }
    let plain = value.split_once(" #").map_or(value, |(text, _)| text);
    plain.trim_end().to_owned()
}

/// Whether `rest`, the text after a closing quote, holds nothing or a comment only.
fn is_comment(rest: &str) -> bool {
    let rest = rest.trim();
    rest.is_empty() || rest.starts_with('#')
}

/// The text of a double-quoted value, or `None` for a malformed escape.
fn unescape(inner: &str) -> Option<String> {
    let mut text = String::with_capacity(inner.len());
    let mut characters = inner.chars();
    while let Some(character) = characters.next() {
        if character != '\\' {
            text.push(character);
            continue;
        }
        let escaped = characters.next()?;
        let digits = match escaped {
            'n' => {
                text.push('\n');
                continue;
            }
            't' => {
                text.push('\t');
                continue;
            }
            'r' => {
                text.push('\r');
                continue;
            }
            '0' | 'a' | 'b' | 'e' | 'f' | 'v' => {
                let code: u8 = match escaped {
                    '0' => 0,
                    'a' => 7,
                    'b' => 8,
                    'e' => 0x1b,
                    'f' => 0x0c,
                    _ => 0x0b,
                };
                text.push(char::from(code));
                continue;
            }
            'x' => 2,
            'u' => 4,
            'U' => 8,
            other => {
                text.push(other);
                continue;
            }
        };
        let hex: String = characters.by_ref().take(digits).collect();
        text.push(char::from_u32(u32::from_str_radix(&hex, 16).ok()?)?);
    }
    Some(text)
}

#[cfg(test)]
mod tests;
