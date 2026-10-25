//! The model catalog of `catalog/list`: the providers, whether each has its credential, and their models.

use serde::{Deserialize, Serialize};

/// The params of `catalog/list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ListCatalogParams {
    /// List every provider with its state. None or false lists only the providers that are ready now.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub all: Option<bool>,
}

/// The result of `catalog/list`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ListCatalogResult {
    /// The providers in catalog order: the built-in ones, then the additions of `providers.json`.
    pub providers: Vec<ProviderInfo>,
}

/// A provider and its models. The `id` of the provider and the `id` of a model make the
/// [`ModelReference`](crate::ModelReference) of a session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ProviderInfo {
    /// The provider half of a model reference.
    pub id: String,
    /// The display name.
    pub name: String,
    /// Whether the provider has its credential.
    pub state: ProviderState,
    /// The models in catalog order.
    pub models: Vec<ModelInfo>,
}

/// Whether a provider has its credential. The server checks that a key or a login is there. It does not test it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ProviderState {
    /// The provider needs no key, or its key, its login, or a pushed token is there.
    Ready,
    /// The environment variable of the API key is unset, not UTF-8, or empty.
    NeedsApiKey {
        /// The name of the environment variable.
        variable: String,
    },
    /// The provider has no login in `auth.json` and no token from `credential/update`.
    NeedsLogin,
}

/// A model of a provider.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ModelInfo {
    /// The model half of a model reference.
    pub id: String,
    /// The display name.
    pub name: String,
    /// The context window in tokens. None when the catalog does not know it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_window: Option<u64>,
    /// The output limit in tokens. None when the catalog does not know it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u64>,
    /// The reasoning choices of the model, each with the settings that a session sends for it.
    pub reasoning: Vec<ReasoningChoice>,
    /// The price bands in threshold order. The last band that the prompt reaches prices the whole request.
    pub cost: Vec<PriceBand>,
    /// Whether the model calls tools. None when the catalog does not know it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tools: Option<bool>,
    /// Whether the model takes deferred tools. None when the catalog does not know it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_search: Option<bool>,
    /// The kinds of content that the model reads. Empty when the catalog does not know them.
    pub input: Vec<Modality>,
}

/// A reasoning level that a user can pick for a model, and the reasoning settings that a session sends for it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ReasoningChoice {
    /// The level.
    pub level: ReasoningLevel,
    /// The reasoning settings that a session sends for this level, as the `reasoning` of its settings.
    pub settings: yuke_ai::ReasoningSettings,
}

/// A reasoning level of a model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum ReasoningLevel {
    /// No reasoning control, so the endpoint chooses.
    Default,
    /// No reasoning.
    Off,
    /// The effort `minimal`.
    Minimal,
    /// The effort `low`.
    Low,
    /// The effort `medium`.
    Medium,
    /// The effort `high`.
    High,
    /// The effort `xhigh`.
    Xhigh,
    /// The effort `max`.
    Max,
}

impl From<yuke_ai::Effort> for ReasoningLevel {
    fn from(effort: yuke_ai::Effort) -> Self {
        match effort {
            yuke_ai::Effort::Minimal => Self::Minimal,
            yuke_ai::Effort::Low => Self::Low,
            yuke_ai::Effort::Medium => Self::Medium,
            yuke_ai::Effort::High => Self::High,
            yuke_ai::Effort::Xhigh => Self::Xhigh,
            yuke_ai::Effort::Max => Self::Max,
        }
    }
}

/// The prices of one band, in US dollars per million tokens. A missing price is unknown, never zero.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct PriceBand {
    /// The smallest prompt that this band prices. The prompt counts every input token, the cached ones too.
    pub min_prompt_tokens: u64,
    /// The price of an input token.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<f64>,
    /// The price of an output token.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<f64>,
    /// The price of a reasoning token, which replaces the output price for it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<f64>,
    /// The price of a token that the prompt cache gives.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read: Option<f64>,
    /// The price of a token that the prompt cache keeps.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write: Option<f64>,
}

/// A kind of content that a model reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum Modality {
    /// Text.
    Text,
    /// An image.
    Image,
    /// Sound.
    Audio,
    /// A moving picture.
    Video,
    /// A PDF document.
    Pdf,
}
