//! The settings of a session, and its inputs that no commit consumed.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::InputId;

/// The current choice of a session: the model, the request settings, and the working folder. It holds no credential
/// and no route.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
#[serde(rename_all = "camelCase")]
pub struct ModelReference {
    /// The id of the provider.
    pub provider: String,
    /// The id of the model at the provider.
    pub model: String,
}

impl ModelReference {
    /// The model `model` of the provider `provider`.
    pub fn new(provider: impl Into<String>, model: impl Into<String>) -> Self {
        ModelReference {
            provider: provider.into(),
            model: model.into(),
        }
    }
}

/// An input that no commit consumed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingInput {
    /// The id that `Store::accept_input` of `yuke-agent` gave.
    pub id: InputId,
    /// The blocks of the input.
    pub blocks: Vec<yuke_ai::Block>,
}
