//! The MCP servers of a session: their states and their list.

use serde::{Deserialize, Serialize};

use crate::{LoginId, LoginOutcome, SessionId};

/// The state of one MCP server of a session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
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
    /// The server needs a login, or its login ended.
    NeedsLogin,
}

/// The config file of an MCP server.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
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
    pub state: McpServerState,
}

/// The result of `mcp/list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ListMcpServersResult {
    /// The MCP servers of the session, in config order.
    pub servers: Vec<McpServer>,
}

/// The params of `mcp/login`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct McpLoginParams {
    /// The open session.
    pub session_id: SessionId,
    /// The name of an MCP server of the session, as `mcp/list` gives it. The server is in the state `needsLogin`.
    pub server: String,
}

/// The result of `mcp/login`: the page where the user approves the login.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct McpLoginResult {
    /// The login. Its `mcp/loginFinished` names it.
    pub login_id: LoginId,
    /// The page where the user approves the login. The browser then goes to a redirect address on 127.0.0.1.
    pub url: String,
}

/// The params of `mcp/completeLogin`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct McpCompleteLoginParams {
    /// The login in progress.
    pub login_id: LoginId,
    /// The address that the browser ended on after the approval, for a browser that cannot reach the server.
    pub redirect_url: String,
}

/// The params of `mcp/logout`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct McpLogoutParams {
    /// The open session.
    pub session_id: SessionId,
    /// The name of a remote MCP server of the session, as `mcp/list` gives it.
    pub server: String,
}

/// The params of `mcp/loginFinished`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct McpLoginFinishedParams {
    /// The login.
    pub login_id: LoginId,
    /// The session of the login.
    pub session_id: SessionId,
    /// The MCP server of the login.
    pub server: String,
    /// How the login ended.
    pub outcome: LoginOutcome,
}
