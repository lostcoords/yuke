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
