//! The MCP config: `{ "mcpServers": { name: server } }`, as in a user `mcp.json` and a project `.mcp.json`.

use std::collections::BTreeMap;
use std::fmt;
use std::path::PathBuf;

use serde::Deserialize;

/// The servers of one MCP config file, by name.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct Config {
    /// Each server by its name.
    #[serde(rename = "mcpServers", default)]
    pub servers: BTreeMap<String, ServerConfig>,
}

/// One server entry as the file holds it. A file of another tool can hold more fields; the parse ignores them.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
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
    /// The HTTP header fields of each request.
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    /// `false` keeps the server off.
    #[serde(default = "enabled")]
    pub enabled: bool,
}

fn enabled() -> bool {
    true
}

/// How yuke reaches a server, after the expansion of the variables.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Launch {
    /// A program that speaks MCP on stdin and stdout.
    Stdio {
        /// The program.
        command: String,
        /// Its arguments.
        args: Vec<String>,
        /// The environment variables beside the environment of yuke.
        env: BTreeMap<String, String>,
        /// Its folder, or `None` for the session folder.
        cwd: Option<PathBuf>,
    },
    /// A server at a URL.
    Http {
        /// The URL.
        url: String,
        /// The header fields of each request.
        headers: BTreeMap<String, String>,
    },
}

impl ServerConfig {
    /// How to reach the server. `${NAME}` and `${NAME:-default}` in the command, the arguments, the environment values,
    /// the folder, the URL, and the header values take the value of the variable `NAME` from `variable`.
    ///
    /// # Errors
    ///
    /// Returns [`ConfigError`] when the entry has both or neither of `command` and `url`, or names a variable that has
    /// no value and no default.
    pub fn launch(&self, variable: &dyn Fn(&str) -> Option<String>) -> Result<Launch, ConfigError> {
        let expand = |text: &str| expand(text, variable);
        match (&self.command, &self.url) {
            (Some(command), None) => Ok(Launch::Stdio {
                command: expand(command)?,
                args: self.args.iter().map(|arg| expand(arg)).collect::<Result<_, _>>()?,
                env: self
                    .env
                    .iter()
                    .map(|(name, value)| Ok((name.clone(), expand(value)?)))
                    .collect::<Result<_, ConfigError>>()?,
                cwd: self
                    .cwd
                    .as_ref()
                    .map(|cwd| expand(&cwd.to_string_lossy()).map(PathBuf::from))
                    .transpose()?,
            }),
            (None, Some(url)) => Ok(Launch::Http {
                url: expand(url)?,
                headers: self
                    .headers
                    .iter()
                    .map(|(name, value)| Ok((name.clone(), expand(value)?)))
                    .collect::<Result<_, ConfigError>>()?,
            }),
            _ => Err(ConfigError::Transport),
        }
    }
}

/// Why a server entry cannot start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigError {
    /// The entry has both or neither of `command` and `url`.
    Transport,
    /// The entry names a variable that has no value and no default.
    Variable(String),
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Transport => f.write_str("the server needs exactly one of command and url"),
            Self::Variable(name) => write!(f, "the variable {name} has no value and no default"),
        }
    }
}

impl std::error::Error for ConfigError {}

/// `text` with each `${NAME}` and `${NAME:-default}` replaced. A `$` without `{` stays.
fn expand(text: &str, variable: &dyn Fn(&str) -> Option<String>) -> Result<String, ConfigError> {
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
            None => return Err(ConfigError::Variable(name.to_owned())),
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
            Err(ConfigError::Variable("PORT".to_owned()))
        );
        assert_eq!(
            expand("[${EMPTY}] ${EMPTY:-default}", &variable),
            Ok("[] default".to_owned())
        );
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

        let git = config.servers["git"].launch(&variable);
        let both = config.servers["both"].launch(&variable);
        let none = config.servers["none"].launch(&variable);

        assert_eq!(
            git,
            Ok(Launch::Stdio {
                command: "uvx".to_owned(),
                args: vec!["mcp-server-git".to_owned()],
                env: BTreeMap::new(),
                cwd: None,
            })
        );
        assert_eq!(both, Err(ConfigError::Transport));
        assert_eq!(none, Err(ConfigError::Transport));
        assert!(!config.servers["none"].enabled);
    }
}
