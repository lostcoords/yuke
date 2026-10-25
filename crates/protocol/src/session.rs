//! The settings of a session.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// The current choice of a session: the model, the request settings, and the working folder. It holds no credential
/// and no route.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SessionSettings {
    /// The model of the next turn.
    pub model: ModelReference,
    /// The request settings of the next turn.
    pub settings: yuke_ai::Settings,
    /// The folder that the tools of the session work in.
    pub cwd: PathBuf,
}

/// A model of a provider, by the ids of the config.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ModelReference {
    /// The id of the provider.
    pub provider: String,
    /// The id of the model at the provider.
    pub model: String,
}

/// The saved facts of a session, as `session/list` and `session/get` give them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    /// The session.
    pub session_id: crate::SessionId,
    /// The model of the newest settings.
    pub model: ModelReference,
    /// The working folder of the newest settings.
    pub cwd: PathBuf,
    /// The trimmed user text of the first message input with text, at most 200 characters. None before such an
    /// input.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    /// The creation time, in milliseconds since the Unix epoch.
    pub created_at: u64,
    /// The time of the newest event, in milliseconds since the Unix epoch. A fork starts at its creation time.
    pub updated_at: u64,
    /// The source of a fork. The source can be gone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_of: Option<crate::SessionId>,
}

/// Whether a session is open in the server, and whether a turn runs in it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum SessionActivity {
    /// The session is not open in this server.
    Closed,
    /// The session is open, and no turn runs.
    Idle,
    /// A turn runs.
    Running,
}

/// A saved session with its facts and its activity at the moment of the answer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SessionRow {
    /// The saved facts.
    pub session: SessionSummary,
    /// The activity.
    pub activity: SessionActivity,
}
