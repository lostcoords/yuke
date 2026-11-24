//! The MCP config: `{ "mcpServers": { name: server } }`, as in a user `mcp.json` and a project `.mcp.json`.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tokio::process::Command;
use yuke_http::http::{HeaderName, HeaderValue};

use crate::oauth::canonical;

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
    // The file key stays `cwd`: other tools share the format of `mcp.json`.
    #[serde(default, rename = "cwd")]
    pub folder: Option<PathBuf>,
    /// The URL of an HTTP server.
    #[serde(default)]
    pub url: Option<String>,
    /// The headers that an HTTP server gets on each request.
    // An empty map stays out of the JSON, so the trust of a project without headers keeps its key.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub headers: BTreeMap<String, String>,
    /// The OAuth settings of an HTTP server.
    // `None` stays out of the JSON, so the trust of a project without OAuth keeps its key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oauth: Option<OAuthConfig>,
    /// `false` keeps the server off.
    #[serde(default = "enabled")]
    pub enabled: bool,
}

/// The OAuth settings of a remote server. A server that needs OAuth works without them.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OAuthConfig {
    /// The client id that the authorization server gave to yuke. Without it, yuke uses its own client id document, or
    /// it registers a client.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_id: Option<String>,
    /// The port of the login redirect on 127.0.0.1, for a client that the authorization server registered with a fixed
    /// redirect. Without it, the port is free.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub callback_port: Option<u16>,
}

fn enabled() -> bool {
    true
}

/// How a server starts: a program on this computer, or a connection to a URL.
pub(crate) enum Launch {
    Process(Command),
    Remote(Remote),
}

/// A connection to a URL.
#[derive(Clone)]
pub(crate) struct Remote {
    pub(crate) url: String,
    /// The canonical form of `url`.
    pub(crate) resource: String,
    pub(crate) headers: HashMap<HeaderName, HeaderValue>,
    pub(crate) oauth: OAuthConfig,
}

impl ServerConfig {
    /// The start of the server, or why the entry gives none. A `command` starts a program, and a `url` connects to an
    /// HTTP server.
    ///
    /// `${NAME}` and `${NAME:-default}` take the value of the variable `NAME` from `variable`. They work in the
    /// command, the arguments, the environment values, the folder, the URL, and the header values. The program runs in
    /// `session_folder`, in a relative `folder` of the entry under `session_folder`, or in an absolute `folder` of the
    /// entry.
    pub(crate) fn launch(
        &self,
        variable: &dyn Fn(&str) -> Option<String>,
        session_folder: &Path,
    ) -> Result<Launch, String> {
        let expand = |text: &str| expand(text, variable);
        let program = match (&self.command, &self.url) {
            (Some(program), None) => program,
            (None, Some(url)) => {
                let mut headers = HashMap::new();
                for (name, value) in &self.headers {
                    let header = HeaderName::try_from(name).map_err(|_| format!("{name} is not a header name"))?;
                    let value = HeaderValue::try_from(expand(value)?)
                        .map_err(|_| format!("the value of the header {name} is not valid"))?;
                    headers.insert(header, value);
                }
                let url = expand(url)?;
                return Ok(Launch::Remote(Remote {
                    resource: canonical(&url)?,
                    url,
                    headers,
                    oauth: self.oauth.clone().unwrap_or_default(),
                }));
            }
            _ => return Err("the server needs exactly one of command and url".to_owned()),
        };
        let mut command = Command::new(expand(program)?);
        for arg in &self.args {
            command.arg(expand(arg)?);
        }
        for (name, value) in &self.env {
            command.env(name, expand(value)?);
        }
        let folder = match &self.folder {
            Some(folder) => PathBuf::from(expand(&folder.to_string_lossy())?),
            None => PathBuf::new(),
        };
        command.current_dir(session_folder.join(folder));
        Ok(Launch::Process(command))
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

    /// The command of the program entry `entry`, with `/work` as the session folder.
    fn command(entry: &ServerConfig) -> Command {
        match entry.launch(&variable, Path::new("/work")) {
            Ok(Launch::Process(command)) => command,
            Ok(Launch::Remote(remote)) => panic!("a remote server at {}", remote.url),
            Err(error) => panic!("{error}"),
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

        let relative = command(&config.servers["relative"]);
        let absolute = command(&config.servers["absolute"]);

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

        let git = command(&config.servers["git"]);
        let both = config.servers["both"].launch(&variable, Path::new("/work"));
        let none = config.servers["none"].launch(&variable, Path::new("/work"));

        let git = git.as_std();
        assert_eq!(git.get_program(), "uvx");
        assert_eq!(git.get_args().collect::<Vec<_>>(), ["mcp-server-git"]);
        assert_eq!(git.get_current_dir(), Some(Path::new("/work")));
        let transport = "the server needs exactly one of command and url";
        assert_eq!(both.err().as_deref(), Some(transport));
        assert_eq!(none.err().as_deref(), Some(transport));
        assert!(!config.servers["none"].enabled);
    }

    #[test]
    fn a_remote_entry_expands_its_url_and_header_values_and_checks_each_header() {
        let config: Config = serde_json::from_str(
            r#"{ "mcpServers": {
                 "docs": { "type": "http", "url": "https://${HOST:-docs.test}/mcp",
                           "headers": { "Authorization": "Bearer ${HOME}", "X-Plain": "a" } },
                 "bad name": { "url": "https://example.test", "headers": { "X Key": "a" } },
                 "bad value": { "url": "https://example.test", "headers": { "X-Key": "a\nb" } },
                 "unset": { "url": "https://example.test", "headers": { "X-Key": "${KEY}" } }
               } }"#,
        )
        .unwrap();
        let launch = |name: &str| config.servers[name].launch(&variable, Path::new("/work"));

        let Ok(Launch::Remote(remote)) = launch("docs") else {
            panic!("no remote launch");
        };

        assert_eq!(remote.url, "https://docs.test/mcp");
        let mut headers: Vec<_> = remote
            .headers
            .iter()
            .map(|(name, value)| (name.as_str(), value.to_str().unwrap()))
            .collect();
        headers.sort_unstable();
        assert_eq!(headers, [("authorization", "Bearer /home/me"), ("x-plain", "a")]);
        assert_eq!(launch("bad name").err().as_deref(), Some("X Key is not a header name"));
        assert_eq!(
            launch("bad value").err().as_deref(),
            Some("the value of the header X-Key is not valid")
        );
        assert_eq!(
            launch("unset").err().as_deref(),
            Some("the variable KEY has no value and no default")
        );
    }

    #[test]
    fn the_oauth_settings_of_a_remote_entry_read_in_camel_case_and_stay_out_of_the_json_when_absent() {
        let config: Config = serde_json::from_str(
            r#"{ "mcpServers": {
                 "linear": { "url": "https://linear.test/mcp", "oauth": { "clientId": "abc", "callbackPort": 19876 } },
                 "plain": { "url": "https://plain.test/mcp" }
               } }"#,
        )
        .unwrap();

        let Ok(Launch::Remote(linear)) = config.servers["linear"].launch(&variable, Path::new("/work")) else {
            panic!("no remote launch");
        };
        let Ok(Launch::Remote(plain)) = config.servers["plain"].launch(&variable, Path::new("/work")) else {
            panic!("no remote launch");
        };

        assert_eq!(linear.oauth.client_id.as_deref(), Some("abc"));
        assert_eq!(linear.oauth.callback_port, Some(19876));
        assert_eq!(plain.oauth, OAuthConfig::default());
        assert_eq!(
            serde_json::to_value(&config.servers["linear"]).unwrap()["oauth"],
            serde_json::json!({ "clientId": "abc", "callbackPort": 19876 })
        );
    }

    #[test]
    fn an_entry_without_headers_writes_the_json_of_before() {
        let entry: ServerConfig = serde_json::from_str(r#"{ "command": "x" }"#).unwrap();

        let json = serde_json::to_value(&entry).unwrap();

        assert_eq!(
            json,
            serde_json::json!({ "command": "x", "args": [], "env": {}, "cwd": null, "url": null, "enabled": true })
        );
    }
}
