//! The system prompt of a new session: the base text, the `AGENTS.md` instructions, and the facts of the environment.
//! A session keeps the prompt of its creation.

use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const BASE: &str = "\
You are yuke, an assistant for software development.

Use the available tools to inspect files, run commands, and make changes.
Read the relevant code and project instructions before you edit.
Use evidence from the workspace to answer questions about the project.
Follow existing conventions and keep changes within the requested scope.
Preserve unrelated user changes.

Complete the requested work unless the user asks only for advice or a plan.
Ask for clarification when a required decision cannot be resolved from the available context.
Verify changes with the relevant checks. Report failures and any checks you could not run.
Never claim that an action succeeded without evidence.

Keep responses concise and direct.
Give brief progress updates during substantial work.
Explain the result, the verification, and any unresolved issues.";

const INSTRUCTIONS_LEAD: &str = "Project instructions follow. Explicit user instructions take precedence. Workspace \
                                 instructions override global instructions where they conflict.";

/// The facts of the machine that the prompt states.
#[derive(Debug)]
pub(crate) struct Environment<'a> {
    /// The folder of the session.
    pub(crate) workspace: &'a Path,
    /// The home folder of the user, which holds the global `~/.agents/AGENTS.md`.
    pub(crate) home: Option<&'a Path>,
    /// The shell of the commands.
    pub(crate) shell: &'a Path,
    /// The time of the session start.
    pub(crate) now: SystemTime,
}

/// The system prompt for a session in `environment`.
pub(crate) fn system_prompt(environment: &Environment<'_>) -> Result<String, String> {
    let mut sections = vec![BASE.to_owned()];
    let instructions = instructions(environment.workspace, environment.home)?;
    if !instructions.is_empty() {
        let blocks: Vec<String> = instructions
            .iter()
            .map(|source| {
                format!(
                    "## AGENTS.md ({})\nScope: {}.\n\n{}",
                    json_text(&source.path),
                    source.scope,
                    source.text
                )
            })
            .collect();
        sections.push(format!("{INSTRUCTIONS_LEAD}\n\n{}", blocks.join("\n\n")));
    }
    sections.push(format!(
        "<environment>\nworkspace: {}\noperating_system: {}\nshell: {}\nsession_start_date_utc: {}\n</environment>",
        escape(&environment.workspace.to_string_lossy()),
        std::env::consts::OS,
        escape(&environment.shell.to_string_lossy()),
        utc_date(environment.now),
    ));
    Ok(sections.join("\n\n"))
}

/// One `AGENTS.md` file.
#[derive(Debug, PartialEq, Eq)]
struct Instructions {
    path: PathBuf,
    scope: &'static str,
    text: String,
}

/// The global `~/.agents/AGENTS.md` and the `AGENTS.md` of the workspace, the files that exist. One file for both
/// counts once, as the workspace file.
fn instructions(workspace: &Path, home: Option<&Path>) -> Result<Vec<Instructions>, String> {
    let global = home.map(|home| home.join(".agents/AGENTS.md"));
    let candidates = [(global, "global"), (Some(workspace.join("AGENTS.md")), "workspace")];
    let mut found: Vec<(PathBuf, Instructions)> = Vec::new();
    for (path, scope) in candidates {
        let Some(path) = path else { continue };
        let refused = |error: io::Error| format!("Cannot load AGENTS.md at {}: {error}", path.display());
        let real = match std::fs::canonicalize(&path) {
            Ok(real) => real,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(refused(error)),
        };
        if let Some((_, same)) = found.iter_mut().find(|(earlier, _)| *earlier == real) {
            same.path = path;
            same.scope = scope;
            continue;
        }
        let text = std::fs::read_to_string(&real).map_err(refused)?;
        found.push((real, Instructions { path, scope, text }));
    }
    Ok(found.into_iter().map(|(_, instructions)| instructions).collect())
}

/// `path` as the inside of a JSON string, so a line break in a name cannot start a new line of the prompt.
fn json_text(path: &Path) -> String {
    let quoted = serde_json::Value::String(path.to_string_lossy().into_owned()).to_string();
    quoted[1..quoted.len() - 1].to_owned()
}

/// `text` with the characters that could close the block or start a line made into entities.
fn escape(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '\n' => escaped.push_str("&#10;"),
            '\r' => escaped.push_str("&#13;"),
            '\t' => escaped.push_str("&#9;"),
            other => escaped.push(other),
        }
    }
    escaped
}

/// The UTC date of `time` as `YYYY-MM-DD`.
fn utc_date(time: SystemTime) -> String {
    let days = time
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs() / 86_400);
    // The civil date of a day count: Howard Hinnant's `civil_from_days`, for days after 1970.
    let shifted = days + 719_468;
    let era = shifted / 146_097;
    let day_of_era = shifted - era * 146_097;
    let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + u64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    fn folder(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("yuke-prompt-test-{}/{name}", std::process::id()));
        if folder.exists() {
            std::fs::remove_dir_all(&folder).unwrap();
        }
        std::fs::create_dir_all(&folder).unwrap();
        folder.canonicalize().unwrap()
    }

    #[test]
    fn utc_dates_follow_the_calendar() {
        let date = |seconds: u64| utc_date(UNIX_EPOCH + Duration::from_secs(seconds));

        assert_eq!(date(0), "1970-01-01");
        assert_eq!(date(951_782_400), "2000-02-29");
        assert_eq!(date(951_868_800), "2000-03-01");
        assert_eq!(date(1_791_849_599), "2026-10-12");
        assert_eq!(date(4_107_542_400), "2100-03-01");
    }

    #[test]
    fn the_prompt_holds_the_base_the_instructions_and_the_environment_in_order() {
        let root = folder("order");
        let home = root.join("home");
        let workspace = root.join("work");
        std::fs::create_dir_all(home.join(".agents")).unwrap();
        std::fs::create_dir_all(&workspace).unwrap();
        std::fs::write(home.join(".agents/AGENTS.md"), "Global rule.").unwrap();
        std::fs::write(workspace.join("AGENTS.md"), "Workspace rule.").unwrap();

        let prompt = system_prompt(&Environment {
            workspace: &workspace,
            home: Some(&home),
            shell: Path::new("/bin/bash"),
            now: UNIX_EPOCH + Duration::from_secs(1_791_849_599),
        })
        .unwrap();

        assert_eq!(
            prompt,
            format!(
                "{BASE}\n\n{INSTRUCTIONS_LEAD}\n\n## AGENTS.md ({})\nScope: global.\n\nGlobal rule.\n\n## AGENTS.md ({})\nScope: \
                 workspace.\n\nWorkspace rule.\n\n<environment>\nworkspace: {}\noperating_system: {}\nshell: \
                 /bin/bash\nsession_start_date_utc: 2026-10-12\n</environment>",
                home.join(".agents/AGENTS.md").display(),
                workspace.join("AGENTS.md").display(),
                workspace.display(),
                std::env::consts::OS,
            )
        );
    }

    #[test]
    fn no_instruction_file_leaves_out_the_instructions() {
        let workspace = folder("none");

        let prompt = system_prompt(&Environment {
            workspace: &workspace,
            home: None,
            shell: Path::new("/bin/sh"),
            now: UNIX_EPOCH,
        })
        .unwrap();

        assert!(!prompt.contains(INSTRUCTIONS_LEAD));
        assert!(prompt.starts_with(&format!("{BASE}\n\n<environment>\n")));
    }

    #[test]
    fn one_file_for_both_scopes_counts_once_as_the_workspace_file() {
        let workspace = folder("same");
        std::fs::create_dir_all(workspace.join(".agents")).unwrap();
        std::fs::write(workspace.join("AGENTS.md"), "Shared rule.").unwrap();
        std::os::unix::fs::symlink(workspace.join("AGENTS.md"), workspace.join(".agents/AGENTS.md")).unwrap();

        assert_eq!(
            instructions(&workspace, Some(&workspace)),
            Ok(vec![Instructions {
                path: workspace.join("AGENTS.md"),
                scope: "workspace",
                text: "Shared rule.".to_owned(),
            }])
        );
    }

    #[test]
    fn an_unreadable_instruction_file_is_an_error_that_names_it() {
        let workspace = folder("unreadable");
        std::fs::create_dir_all(workspace.join("AGENTS.md")).unwrap();

        let error = instructions(&workspace, None).unwrap_err();

        assert!(
            error.starts_with(&format!(
                "Cannot load AGENTS.md at {}: ",
                workspace.join("AGENTS.md").display()
            )),
            "{error}"
        );
    }
}
