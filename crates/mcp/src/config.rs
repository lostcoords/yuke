//! The MCP config: `{ "mcpServers": { name: server } }`, as in a user `mcp.json` and a project `.mcp.json`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tokio::process::Command;

/// The servers of one MCP config file, by name.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Config {
    /// Each server by its name.
    #[serde(rename = "mcpServers", default)]
    pub servers: BTreeMap<String, ServerConfig>,
}

/// One server entry as the file holds it. A file of another tool can hold more fields; the parse ignores them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerConfig {
    /// The program of a stdio server.
    #[serde(default)]
    pub command: Option<String>,
    /// The arguments of the program.
    #[serde(default)]
    pub args: Vec<String>,
    /// The environment variables that the program gets beside the environment of yuke.
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    /// The folder of the program. A relative folder starts in the session folder.
    #[serde(default)]
    pub cwd: Option<PathBuf>,
    /// The URL of an HTTP server.
    #[serde(default)]
    pub url: Option<String>,
    /// `false` keeps the server off.
    #[serde(default = "enabled")]
    pub enabled: bool,
}

fn enabled() -> bool {
    true
}

impl ServerConfig {
    /// The command that starts the server, or why the entry gives none. The command runs in `folder`, in a relative
    /// `cwd` under `folder`, or in an absolute `cwd`.
    /// `${NAME}` and `${NAME:-default}` in the command, the arguments, the environment values, and the folder take the
    /// value of the variable `NAME` from `variable`.
    pub(crate) fn command(&self, variable: &dyn Fn(&str) -> Option<String>, folder: &Path) -> Result<Command, String> {
        let expand = |text: &str| expand(text, variable);
        let program = match (&self.command, &self.url) {
            (Some(program), None) => program,
            (None, Some(_)) => return Err("yuke cannot reach an HTTP server yet".to_owned()),
            _ => return Err("the server needs exactly one of command and url".to_owned()),
        };
        let mut command = Command::new(expand(program)?);
        for arg in &self.args {
            command.arg(expand(arg)?);
        }
        for (name, value) in &self.env {
            command.env(name, expand(value)?);
        }
        let cwd = match &self.cwd {
            Some(cwd) => PathBuf::from(expand(&cwd.to_string_lossy())?),
            None => PathBuf::new(),
        };
        command.current_dir(folder.join(cwd));
        Ok(command)
    }
}

/// `text` with each `${NAME}` and `${NAME:-default}` replaced. A `$` without `{` stays.
fn expand(text: &str, variable: &dyn Fn(&str) -> Option<String>) -> Result<String, String> {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("${") {
        let Some(length) = rest[start + 2..].find('}') else {
            break;
        };
        out.push_str(&rest[..start]);
        let inner = &rest[start + 2..start + 2 + length];
        let (name, default) = match inner.split_once(":-") {
            Some((name, default)) => (name, Some(default)),
            None => (inner, None),
        };
        // As in a shell, `:-` takes the default also for an empty value.
        let value = variable(name).filter(|value| default.is_none() || !value.is_empty());
        match value.or_else(|| default.map(str::to_owned)) {
            Some(value) => out.push_str(&value),
            None => return Err(format!("the variable {name} has no value and no default")),
        }
        rest = &rest[start + 3 + length..];
    }
    out.push_str(rest);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn variable(name: &str) -> Option<String> {
        match name {
            "HOME" => Some("/home/me".to_owned()),
            "EMPTY" => Some(String::new()),
            _ => None,
        }
    }

    #[test]
    fn a_variable_takes_its_value_or_its_default_and_other_text_stays() {
        assert_eq!(expand("${HOME}/bin", &variable), Ok("/home/me/bin".to_owned()));
        assert_eq!(expand("${PORT:-8080}", &variable), Ok("8080".to_owned()));
        assert_eq!(
            expand("$HOME ${HOME:-x} ${", &variable),
            Ok("$HOME /home/me ${".to_owned())
        );
        assert_eq!(
            expand("${PORT}", &variable),
            Err("the variable PORT has no value and no default".to_owned())
        );
        assert_eq!(
            expand("[${EMPTY}] ${EMPTY:-default}", &variable),
            Ok("[] default".to_owned())
        );
    }

    #[test]
    fn a_command_expands_each_field_and_starts_in_its_folder_under_the_session_folder() {
        let config: Config = serde_json::from_str(
            r#"{ "mcpServers": {
                 "relative": { "command": "${HOME}/bin/x", "args": ["${PORT:-1}"], "env": { "TOKEN": "${HOME}" },
                               "cwd": "sub" },
                 "absolute": { "command": "x", "cwd": "${HOME}" }
               } }"#,
        )
        .unwrap();

        let relative = config.servers["relative"]
            .command(&variable, Path::new("/work"))
            .unwrap();
        let absolute = config.servers["absolute"]
            .command(&variable, Path::new("/work"))
            .unwrap();

        let relative = relative.as_std();
        assert_eq!(relative.get_program(), "/home/me/bin/x");
        assert_eq!(relative.get_args().collect::<Vec<_>>(), ["1"]);
        let token = std::ffi::OsStr::new("/home/me");
        assert_eq!(
            relative.get_envs().collect::<Vec<_>>(),
            [(std::ffi::OsStr::new("TOKEN"), Some(token))]
        );
        assert_eq!(relative.get_current_dir(), Some(Path::new("/work/sub")));
        assert_eq!(absolute.as_std().get_current_dir(), Some(Path::new("/home/me")));
    }

    #[test]
    fn an_entry_reads_from_the_file_format_and_needs_one_transport() {
        let config: Config = serde_json::from_str(
            r#"{ "mcpServers": {
                 "git": { "command": "uvx", "args": ["mcp-server-git"], "type": "stdio" },
                 "both": { "command": "x", "url": "https://example.test" },
                 "none": { "enabled": false }
               } }"#,
        )
        .unwrap();

        let git = config.servers["git"].command(&variable, Path::new("/work")).unwrap();
        let both = config.servers["both"].command(&variable, Path::new("/work"));
        let none = config.servers["none"].command(&variable, Path::new("/work"));

        let git = git.as_std();
        assert_eq!(git.get_program(), "uvx");
        assert_eq!(git.get_args().collect::<Vec<_>>(), ["mcp-server-git"]);
        assert_eq!(git.get_current_dir(), Some(Path::new("/work")));
        let transport = "the server needs exactly one of command and url";
        assert_eq!(both.err().as_deref(), Some(transport));
        assert_eq!(none.err().as_deref(), Some(transport));
        assert!(!config.servers["none"].enabled);
    }
}
