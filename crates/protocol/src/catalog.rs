//! The model catalog of `catalog/list`: the providers, whether each has its credential, and their models.

use serde::{Deserialize, Serialize};

/// The params of `catalog/list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ListCatalogParams {
    /// List every provider with its state. A missing flag is `false`: the list holds only the providers that are
    /// ready now.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    #[cfg_attr(test, ts(as = "Option<bool>", optional))]
    pub all: bool,
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
    /// Whether the provider can serve a request.
    pub state: ProviderState,
    /// The models in catalog order. Empty when the provider is not ready.
    pub models: Vec<ModelInfo>,
}

/// Whether a provider can serve a request. The server checks that the credential is there. It does not test the
/// credential.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ProviderState {
    /// The provider can serve a request.
    Ready {
        /// The credential that a request uses.
        credential: ProviderCredential,
    },
    /// `auth.json` holds no key, and the environment variable of the API key is unset, not UTF-8, or empty.
    NeedsApiKey {
        /// The name of the environment variable.
        variable: String,
    },
    /// The provider has no login in `auth.json` and no token from `credential/update`.
    NeedsLogin,
}

/// The credential that a ready provider uses.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ProviderCredential {
    /// The provider takes no credential.
    None,
    /// The API key in the environment variable. `auth.json` holds no key for the provider.
    Variable {
        /// The name of the environment variable.
        name: String,
    },
    /// The API key in `auth.json`. It wins over the environment variable.
    StoredApiKey,
    /// The login in `auth.json`, or the token from `credential/update`.
    Login,
}

/// A model of a provider.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
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

/// A reasoning level of a model. JSON holds each level as its name: `default`, `off`, or the name of the effort.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub enum ReasoningLevel {
    /// No reasoning control, so the endpoint chooses.
    Default,
    /// No reasoning.
    Off,
    /// A reasoning effort.
    #[serde(untagged)]
    Effort(yuke_ai::Effort),
}

/// Parse the name of a level, as JSON holds it.
impl std::str::FromStr for ReasoningLevel {
    type Err = yuke_ai::ParseError;

    fn from_str(text: &str) -> Result<Self, yuke_ai::ParseError> {
        match text {
            "default" => Ok(Self::Default),
            "off" => Ok(Self::Off),
            _ => text
                .parse()
                .map(Self::Effort)
                .map_err(|_| yuke_ai::ParseError::new("a reasoning level", text)),
        }
    }
}

/// The prices of one band, in US dollars per million tokens. A missing price is unknown, never zero.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
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
#[serde(rename_all = "camelCase")]
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
