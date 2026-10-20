//! The MCP servers of a session: their states and their list.

use serde::{Deserialize, Serialize};

use crate::SessionId;

/// The state of one MCP server of a session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "state", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum McpServerState {
    /// The server starts.
    Connecting,
    /// The server runs, with this many tools.
    Connected {
        /// The number of its tools.
        tools: usize,
    },
    /// The server did not start, or it stopped.
    Failed {
        /// Why.
        error: String,
    },
    /// The config turns the server off.
    Disabled,
    /// A project server that the user did not confirm. It does not start.
    Untrusted,
}

/// The config file of an MCP server.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum McpServerSource {
    /// `mcp.json` in the config folder of the user.
    User,
    /// `.mcp.json` in the folder of the session. It starts only after the user confirms it.
    Project,
}

/// One MCP server of a session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct McpServer {
    /// The name of the server in its config.
    pub name: String,
    /// The config file of the server.
    pub source: McpServerSource,
    /// Its state.
    #[serde(flatten)]
    pub state: McpServerState,
}

/// The params of `mcp/list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ListMcpServersParams {
    /// The open session.
    pub session_id: SessionId,
}

/// The result of `mcp/list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ListMcpServersResult {
    /// The MCP servers of the session, in config order.
    pub servers: Vec<McpServer>,
}
