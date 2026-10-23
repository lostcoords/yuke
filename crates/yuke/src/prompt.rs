//! The system prompt of a new session. It has four sections: the base text, the `AGENTS.md` instructions, the skills,
//! and the facts of the environment. A session keeps the prompt of its creation.

use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use yuke_agent::PromptSection;

use crate::skills::{self, Catalog};

const BASE: &str = "\
You are yuke, a coding assistant. You help the user by reading files, running commands, editing code, and writing \
new files.

- Be concise in your responses.
- Show file paths clearly when working with files.";

const SKILLS_LEAD: &str = "Skills are specialized instructions for specific tasks. When a task matches a skill \
                           description, read its SKILL.md with the read tool. A relative path in a skill starts at the \
                           directory of its SKILL.md, so give each tool call the absolute path.";

const INSTRUCTIONS_LEAD: &str = "Project instructions follow. Explicit user instructions take precedence. Workspace \
                                 instructions override global instructions where they conflict.";

/// The facts of the machine that the prompt states.
#[derive(Debug)]
pub(crate) struct Environment<'a> {
    /// The folder of the session.
    pub(crate) workspace: &'a Path,
    /// The home folder of the user, which holds the global `~/.agents/AGENTS.md`.
    pub(crate) home: Option<&'a Path>,
    /// The folder of each plugin of the profile, in load order. Its `skills` folder holds skills.
    pub(crate) plugins: &'a [PathBuf],
    /// The shell of the commands.
    pub(crate) shell: &'a Path,
    /// The time of the session start.
    pub(crate) now: SystemTime,
}

/// The system prompt of a session, and the warnings of the skill scan for the user.
#[derive(Debug)]
pub(crate) struct Prompt {
    pub(crate) sections: Vec<PromptSection>,
    pub(crate) warnings: Vec<String>,
}

/// The system prompt for a session in `environment`: the sections `base`, `instructions`, `skills`, and `environment`.
/// The `instructions` section exists only when at least one `AGENTS.md` file exists, and the `skills` section only
/// with at least one skill.
pub(crate) fn system_prompt(environment: &Environment<'_>) -> Result<Prompt, String> {
    let mut sections = vec![PromptSection::new(PromptSection::BASE, BASE)];
    let instructions = instructions(environment.workspace, environment.home)?;
    if !instructions.is_empty() {
        let blocks: Vec<String> = instructions
            .iter()
            .map(|source| {
                format!(
                    "<agents_md path=\"{}\" scope=\"{}\">\n{}\n</agents_md>",
                    source.path.display(),
                    source.scope,
                    source.text
                )
            })
            .collect();
        sections.push(PromptSection::new(
            "instructions",
            format!("{INSTRUCTIONS_LEAD}\n\n{}", blocks.join("\n\n")),
        ));
    }
    // The workspace comes first, so a skill of the workspace hides a skill of the user or of a plugin.
    let mut roots = vec![environment.workspace.join(".agents/skills")];
    roots.extend(environment.home.map(|home| home.join(".agents/skills")));
    roots.extend(environment.plugins.iter().map(|plugin| plugin.join("skills")));
    let Catalog { skills, warnings } = skills::catalog(&roots);
    if !skills.is_empty() {
        let entries: Vec<String> = skills
            .iter()
            .map(|skill| {
                format!(
                    "<skill>\n  <name>{}</name>\n  <description>{}</description>\n  <location>{}</location>\n</skill>",
                    skill.name,
                    escape(&skill.description),
                    escape(&skill.location.to_string_lossy())
                )
            })
            .collect();
        sections.push(PromptSection::new(
            "skills",
            format!("{SKILLS_LEAD}\n\n{}", entries.join("\n")),
        ));
    }
    let environment = format!(
        "workspace: {}\noperating_system: {}\nshell: {}\nsession_start_date_utc: {}",
        escape(&environment.workspace.to_string_lossy()),
        std::env::consts::OS,
        escape(&environment.shell.to_string_lossy()),
        utc_date(environment.now),
    );
    sections.push(PromptSection::new("environment", environment));
    Ok(Prompt { sections, warnings })
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
        yuke_testing::folder("prompt", name)
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

    // Each turn joins the sections. The test pins the joined text, so a change of the sections cannot change the text
    // that the model reads.
    #[test]
    fn the_prompt_holds_the_base_the_instructions_the_skills_and_the_environment_in_order() {
        let root = folder("order");
        let home = root.join("home");
        let workspace = root.join("work");
        let plugin = root.join("plugin");
        std::fs::create_dir_all(home.join(".agents")).unwrap();
        std::fs::create_dir_all(workspace.join(".agents/skills/pdf")).unwrap();
        std::fs::create_dir_all(plugin.join("skills/charts")).unwrap();
        std::fs::write(home.join(".agents/AGENTS.md"), "Global rule.").unwrap();
        std::fs::write(workspace.join("AGENTS.md"), "Workspace rule.").unwrap();
        let pdf = workspace.join(".agents/skills/pdf/SKILL.md");
        std::fs::write(
            &pdf,
            "---\nname: pdf\ndescription: Read & fill <PDF> forms.\n---\nThe body.",
        )
        .unwrap();
        let charts = plugin.join("skills/charts/SKILL.md");
        std::fs::write(&charts, "---\nname: charts\ndescription: Draw charts.\n---\n").unwrap();

        let prompt = system_prompt(&Environment {
            workspace: &workspace,
            home: Some(&home),
            plugins: std::slice::from_ref(&plugin),
            shell: Path::new("/bin/bash"),
            now: UNIX_EPOCH + Duration::from_secs(1_791_849_599),
        })
        .unwrap();

        let keys: Vec<&str> = prompt.sections.iter().map(|section| section.key.as_str()).collect();
        assert_eq!(keys, ["base", "instructions", "skills", "environment"]);
        // The session saves the sections, so their text has no tag. The model reads the tags of `prompt_text`.
        assert!(prompt.sections.iter().all(|section| !section.text.starts_with('<')));
        assert_eq!(
            yuke_agent::prompt_text(&prompt.sections),
            format!(
                "{BASE}\n\n<instructions>\n{INSTRUCTIONS_LEAD}\n\n<agents_md path=\"{}\" scope=\"global\">\nGlobal \
                 rule.\n</agents_md>\n\n<agents_md path=\"{}\" scope=\"workspace\">\nWorkspace rule.\n</agents_md>\n\
                 </instructions>\n\n<skills>\n{SKILLS_LEAD}\n\n<skill>\n  <name>charts</name>\n  <description>Draw \
                 charts.</description>\n  <location>{}</location>\n</skill>\n<skill>\n  <name>pdf</name>\n  \
                 <description>Read &amp; fill &lt;PDF&gt; forms.</description>\n  <location>{}</location>\n</skill>\n\
                 </skills>\n\n<environment>\nworkspace: {}\noperating_system: {}\nshell: \
                 /bin/bash\nsession_start_date_utc: 2026-10-12\n</environment>",
                home.join(".agents/AGENTS.md").display(),
                workspace.join("AGENTS.md").display(),
                charts.display(),
                pdf.display(),
                workspace.display(),
                std::env::consts::OS,
            )
        );
        assert_eq!(prompt.warnings, Vec::<String>::new());
    }

    #[test]
    fn no_instruction_file_and_no_skill_leave_out_their_sections() {
        let workspace = folder("none");

        let prompt = system_prompt(&Environment {
            workspace: &workspace,
            home: None,
            plugins: &[],
            shell: Path::new("/bin/sh"),
            now: UNIX_EPOCH,
        })
        .unwrap();

        // No skill folder exists either, so no skills section.
        let keys: Vec<&str> = prompt.sections.iter().map(|section| section.key.as_str()).collect();
        assert_eq!(keys, ["base", "environment"]);
        assert!(yuke_agent::prompt_text(&prompt.sections).starts_with(&format!("{BASE}\n\n<environment>\n")));
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
