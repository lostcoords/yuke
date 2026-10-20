//! The MCP client of yuke: the servers of one session from their config, and their tools for the engine. Each tool of
//! a server is a deferred engine tool named `mcp__<server>__<tool>`.

mod config;
mod names;
mod servers;

pub use config::{Config, ConfigError, Launch, ServerConfig};
pub use servers::{McpTool, MediaStore, ServerState, Servers};
