//! The trust of project MCP servers: an empty file in the data folder for each folder and list of servers that the
//! user confirmed. A changed list has another key, so the user confirms it again.

use std::fs::{DirBuilder, OpenOptions};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;

use yuke_protocol::{InteractionRequest, InteractionResponse, Question, QuestionOption};

/// The folder of the trust files in the data folder.
const FOLDER: &str = "mcp-trust";

/// The option of [`question`] that starts the servers.
const START: &str = "Start";

/// The key of the project servers `config` of `folder`: the hex SHA-256 of the real path of the folder, a NUL byte, and
/// the JSON of the servers.
pub(super) fn key(folder: &Path, config: &yuke_mcp::Config) -> Result<String, serde_json::Error> {
    // A link to the folder is the same folder, so the key uses the real path.
    let real = std::fs::canonicalize(folder).unwrap_or_else(|_| folder.to_owned());
    let mut bytes = real.as_os_str().as_bytes().to_vec();
    bytes.push(0);
    bytes.extend(serde_json::to_vec(config)?);
    Ok(yuke_agent::blob_of(&bytes).digest.to_string())
}

/// Whether the user confirmed the servers of `key`.
pub(super) fn trusted(data: &Path, key: &str) -> bool {
    data.join(FOLDER).join(key).is_file()
}

/// Keep the confirm of the servers of `key`. Only the user can read the folder.
pub(super) fn trust(data: &Path, key: &str) -> io::Result<()> {
    let folder = data.join(FOLDER);
    DirBuilder::new().recursive(true).mode(0o700).create(&folder)?;
    OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(folder.join(key))
        .map(drop)
}

/// The question that asks the user to start the servers `config` of `folder`: for each enabled server, its name, its
/// command line or URL, and its folder and environment variables when it sets them, as the file holds them.
pub(super) fn question(folder: &Path, config: &yuke_mcp::Config) -> InteractionRequest {
    let lines = config
        .servers
        .iter()
        .filter(|(_, server)| server.enabled)
        .map(|(name, server)| {
            let mut parts: Vec<String> = match (&server.command, &server.url) {
                (Some(command), _) => vec![
                    std::iter::once(command)
                        .chain(&server.args)
                        .cloned()
                        .collect::<Vec<_>>()
                        .join(" "),
                ],
                (None, Some(url)) => vec![url.clone()],
                (None, None) => Vec::new(),
            };
            if let Some(cwd) = &server.cwd {
                parts.push(format!("in {}", cwd.display()));
            }
            parts.extend(server.env.iter().map(|(name, value)| format!("{name}={value}")));
            format!("- {name}: {}", parts.join(", "))
        });
    let head = format!(
        "Start the MCP servers of this project?\n{} has these MCP servers. Each runs on this computer.",
        folder.display()
    );
    let option = |label: &str| QuestionOption {
        label: label.to_owned(),
        description: None,
    };
    InteractionRequest::Questions {
        questions: vec![Question {
            id: "start".to_owned(),
            header: "MCP servers".to_owned(),
            question: std::iter::once(head).chain(lines).collect::<Vec<_>>().join("\n"),
            options: vec![option(START), option("Don't start")],
            multiple: false,
            other: false,
            secret: false,
        }],
    }
}

/// The user chose to start the servers in `response` to [`question`].
pub(super) fn started(response: &InteractionResponse) -> bool {
    matches!(response, InteractionResponse::Questions { answers } if answers.iter().any(|answer| answer.values == [START]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_question_shows_each_enabled_server_with_its_folder_and_environment() {
        let config: yuke_mcp::Config = serde_json::from_str(
            r#"{ "mcpServers": {
                 "db": { "command": "node", "args": ["db.js"], "cwd": "tools", "env": { "NODE_OPTIONS": "--inspect" } },
                 "off": { "command": "rm", "enabled": false },
                 "web": { "command": "uvx", "args": ["web"] }
               } }"#,
        )
        .unwrap();

        let InteractionRequest::Questions { questions } = question(Path::new("/work"), &config);

        assert_eq!(
            questions[0].question,
            "Start the MCP servers of this project?\n/work has these MCP servers. Each runs on this computer.\n\
             - db: node db.js, in tools, NODE_OPTIONS=--inspect\n\
             - web: uvx web"
        );
    }
}
