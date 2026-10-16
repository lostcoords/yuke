//! `providers.json`: the providers of the profile. The file changes a built-in provider, or adds one. It is JSON with
//! `//` and `/* */` comments, and an unknown field is an error.

use std::borrow::Cow;
use std::collections::HashSet;
use std::io;
use std::path::Path;

use serde::{Deserialize, Deserializer};
use yuke_ai::catalog::{
    self, AnthropicThinking, Auth, Caps, ChatFlags, Dialect, Endpoint, Entry, Limits, Model, PriceBand, Provider,
};
use yuke_ai::oauth::Flow;
use yuke_ai::route::{self, CredentialHeader, SessionHeader};
use yuke_ai::transport::Header;
use yuke_ai::{ChatDialect, Effort, MaxTokensField, Protocol, ReasoningReplayMode, ResponsesDialect, ThinkingFormat};

use crate::config::without_comments;

/// The name of the file in the config folder.
const FILE: &str = "providers.json";

/// The built-in providers with the changes and the additions of `providers.json`.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Providers(Vec<Provider>);

impl Providers {
    /// The providers with the file in the config folder `folder`. A missing file gives the built-in providers.
    ///
    /// # Errors
    ///
    /// Returns a text that names the file, the entry, and the field of the first bad value.
    pub(crate) fn load(folder: &Path) -> Result<Providers, String> {
        let path = folder.join(FILE);
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Providers(catalog::PROVIDERS.to_vec())),
            Err(error) => return Err(format!("{}: {error}", path.display())),
        };
        Providers::parse(&text).map_err(|error| format!("{}: {error}", path.display()))
    }

    /// The built-in providers changed by the file text `text`.
    fn parse(text: &str) -> Result<Providers, String> {
        let file: File = serde_json::from_str(&without_comments(text)).map_err(|error| error.to_string())?;
        let mut providers = catalog::PROVIDERS.to_vec();
        let mut ids = HashSet::new();
        for patch in file.providers {
            let id = patch.id.clone();
            if !ids.insert(id.clone()) {
                return Err(format!("provider {id}: the file has this id twice"));
            }
            patch
                .apply(&mut providers)
                .map_err(|error| format!("provider {id}: {error}"))?;
        }
        Ok(Providers(providers))
    }

    /// Find the model that a `provider/model` selector names.
    ///
    /// # Errors
    ///
    /// Returns the errors of [`catalog::lookup_in`].
    pub(crate) fn lookup(&self, selector: &str) -> Result<Entry<'_>, catalog::Error> {
        catalog::lookup_in(&self.0, selector)
    }

    /// The provider `id` and its login flow.
    ///
    /// # Errors
    ///
    /// Returns a text for the user when the provider has no login flow of yuke.
    pub(crate) fn login(&self, id: &str) -> Result<(&Provider, Flow), String> {
        let provider = self.0.iter().find(|provider| provider.id == id);
        match provider.map(|provider| (provider, &provider.auth)) {
            Some((provider, Auth::OAuth(flow_name))) => {
                if let Some(flow) = Flow::named(flow_name) {
                    return Ok((provider, flow));
                }
            }
            Some((_, Auth::ApiKey(Some(variable)))) => {
                return Err(format!(
                    "{id} takes an API key: set {variable}. {}",
                    self.login_providers()
                ));
            }
            Some((_, Auth::ApiKey(None))) | None => {}
        }
        Err(format!("yuke has no login for {id}. {}", self.login_providers()))
    }

    /// The sentence that names the providers with a login flow of yuke.
    fn login_providers(&self) -> String {
        let ids: Vec<_> = self
            .0
            .iter()
            .filter(|provider| matches!(&provider.auth, Auth::OAuth(flow_name) if Flow::named(flow_name).is_some()))
            .map(|provider| &*provider.id)
            .collect();
        format!("The providers that support a login: {}.", ids.join(", "))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct File {
    #[serde(default)]
    providers: Vec<ProviderPatch>,
}

/// One provider entry. A field that the entry omits keeps the built-in value, and a written `null` is an error.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderPatch {
    id: String,
    #[serde(default, deserialize_with = "written")]
    name: Option<String>,
    #[serde(default, deserialize_with = "written")]
    api_key_env: Option<String>,
    #[serde(default, deserialize_with = "written")]
    base_url: Option<String>,
    #[serde(default, deserialize_with = "written")]
    headers: Option<Vec<HeaderEntry>>,
    #[serde(default, deserialize_with = "written")]
    session_header: Option<SessionHeader>,
    #[serde(default, deserialize_with = "written")]
    endpoints: Option<Vec<EndpointEntry>>,
    #[serde(default, deserialize_with = "written")]
    models: Option<Vec<ModelEntry>>,
}

/// A written field. Serde reads `null` as `None`, which would keep the built-in value without a word.
fn written<'de, D: Deserializer<'de>, T: Deserialize<'de>>(deserializer: D) -> Result<Option<T>, D::Error> {
    T::deserialize(deserializer).map(Some)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HeaderEntry {
    name: String,
    value: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EndpointEntry {
    protocol: Protocol,
    credential_header: Option<CredentialHeader>,
    #[serde(default)]
    cache_breakpoint: bool,
    responses_dialect: Option<ResponsesDialect>,
    chat_dialect: Option<ChatDialect>,
}

/// One model entry. It replaces the built-in model with its id as a whole.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelEntry {
    id: String,
    upstream_id: Option<String>,
    name: Option<String>,
    protocol: Option<Protocol>,
    #[serde(default)]
    limits: Limits,
    cost: Option<Vec<PriceBand>>,
    #[serde(default)]
    reasoning_levels: Vec<Option<Effort>>,
    #[serde(default)]
    flags: Flags,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Flags {
    supports_tool_search: Option<bool>,
    can_disable_reasoning: Option<bool>,
    supports_cache_breakpoint: Option<bool>,
    thinking_format: Option<ThinkingFormat>,
    reasoning_replay: Option<ReasoningReplayMode>,
    max_tokens_field: Option<MaxTokensField>,
    anthropic_thinking: Option<ThinkingShape>,
    reasoning_budget_min: Option<i64>,
    reasoning_budget_max: Option<u64>,
}

/// The names of [`AnthropicThinking`] in the file. The budget bounds are flags of their own.
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ThinkingShape {
    Toggle,
    Adaptive,
    Budget,
}

impl ProviderPatch {
    /// Change the provider with this id in `providers`, or add it.
    fn apply(self, providers: &mut Vec<Provider>) -> Result<(), String> {
        valid_id(&self.id, "/")?;
        let position = providers.iter().position(|provider| provider.id == self.id);
        let index = if let Some(index) = position {
            index
        } else {
            providers.push(self.new_provider()?);
            providers.len() - 1
        };
        self.change(&mut providers[index])
    }

    /// An empty provider of a new id. The change gives it the fields that it needs.
    fn new_provider(&self) -> Result<Provider, String> {
        let missing = [
            ("base_url", self.base_url.is_none()),
            ("endpoints", self.endpoints.is_none()),
            ("models", self.models.is_none()),
        ];
        if let Some((field, _)) = missing.iter().find(|(_, missing)| *missing) {
            return Err(format!("{field}: a new provider needs it"));
        }
        Ok(Provider {
            id: self.id.clone().into(),
            name: self.id.clone().into(),
            auth: Auth::ApiKey(None),
            base_url: Cow::Borrowed(""),
            headers: Cow::Borrowed(&[]),
            session_header: SessionHeader::None,
            endpoints: Cow::Borrowed(&[]),
            models: Cow::Borrowed(&[]),
        })
    }

    /// Write each field of the entry into `provider`, and check the result.
    fn change(self, provider: &mut Provider) -> Result<(), String> {
        if let Some(name) = self.name {
            provider.name = name.into();
        }
        if let Some(variable) = self.api_key_env {
            if matches!(provider.auth, Auth::OAuth(_)) {
                return Err("api_key_env: the provider uses a login of `yuke login`".to_owned());
            }
            if variable.is_empty() || variable.contains(['=', '\0']) {
                return Err(format!(
                    "api_key_env: {variable:?} is not a variable name: write a name with no '=' and no NUL"
                ));
            }
            provider.auth = Auth::ApiKey(Some(variable.into()));
        }
        if let Some(base_url) = self.base_url {
            valid_base_url(&base_url).map_err(|error| format!("base_url: {error}"))?;
            provider.base_url = base_url.into();
        }
        if let Some(headers) = self.headers {
            provider.headers = headers
                .into_iter()
                .map(|header| Header::new(header.name, header.value))
                .collect::<Vec<_>>()
                .into();
        }
        if let Some(session_header) = self.session_header {
            provider.session_header = session_header;
        }
        if let Some(entries) = self.endpoints {
            provider.endpoints = endpoints(entries)?.into();
        }
        if let Some(entries) = self.models {
            let mut ids = HashSet::new();
            for entry in entries {
                let id = entry.id.clone();
                if !ids.insert(id.clone()) {
                    return Err(format!("model {id}: the provider has this id twice"));
                }
                let model = entry
                    .model(&provider.endpoints)
                    .map_err(|error| format!("model {id}: {error}"))?;
                let models = provider.models.to_mut();
                match models.iter_mut().find(|built_in| built_in.id == model.id) {
                    Some(built_in) => *built_in = model,
                    None => models.push(model),
                }
            }
        }
        check(provider)
    }
}

/// The endpoints of `entries`. Each protocol has one endpoint at most.
fn endpoints(entries: Vec<EndpointEntry>) -> Result<Vec<Endpoint>, String> {
    if entries.is_empty() {
        return Err("endpoints: the list is empty".to_owned());
    }
    let mut endpoints: Vec<Endpoint> = Vec::with_capacity(entries.len());
    for (index, entry) in entries.into_iter().enumerate() {
        let protocol = entry.protocol;
        let field = |name: &str| format!("endpoints[{index}].{name}");
        if endpoints.iter().any(|endpoint| endpoint.protocol == protocol) {
            return Err(format!("{}: another endpoint has this protocol", field("protocol")));
        }
        if entry.cache_breakpoint && protocol == Protocol::OpenaiChat {
            return Err(format!(
                "{}: Chat Completions has no breakpoint",
                field("cache_breakpoint")
            ));
        }
        if entry.responses_dialect.is_some() && protocol != Protocol::OpenaiResponses {
            return Err(format!(
                "{}: only an openai_responses endpoint takes it",
                field("responses_dialect")
            ));
        }
        if entry.chat_dialect.is_some() && protocol != Protocol::OpenaiChat {
            return Err(format!(
                "{}: only an openai_chat endpoint takes it",
                field("chat_dialect")
            ));
        }
        endpoints.push(Endpoint {
            protocol,
            credential_header: entry.credential_header,
            cache_breakpoint: entry.cache_breakpoint,
            responses_dialect: entry.responses_dialect.unwrap_or_default(),
            chat_dialect: entry.chat_dialect.unwrap_or_default(),
        });
    }
    Ok(endpoints)
}

impl ModelEntry {
    /// The model of the entry on a provider with `endpoints`.
    fn model(self, endpoints: &[Endpoint]) -> Result<Model, String> {
        valid_id(&self.id, "")?;
        let protocol = match (self.protocol, endpoints) {
            (Some(protocol), _) => protocol,
            (None, [only]) => only.protocol,
            (None, _) => return Err("protocol: the provider has more than one endpoint, so name one".to_owned()),
        };
        let cost = match self.cost {
            None => Cow::Borrowed(catalog::UNKNOWN_COST),
            Some(bands) if catalog::valid_cost(&bands) => Cow::Owned(bands),
            Some(_) => {
                return Err(
                    "cost: the first band starts at 0, each next band starts higher, and no price is negative"
                        .to_owned(),
                );
            }
        };
        let flags = self.flags;
        let chat_flags = [
            flags.thinking_format.is_some(),
            flags.reasoning_replay.is_some(),
            flags.max_tokens_field.is_some(),
        ];
        if chat_flags.contains(&true) && protocol != Protocol::OpenaiChat {
            return Err(
                "flags: thinking_format, reasoning_replay, and max_tokens_field need the openai_chat protocol"
                    .to_owned(),
            );
        }
        if flags.anthropic_thinking.is_some() && protocol != Protocol::AnthropicMessages {
            return Err("flags.anthropic_thinking: it needs the anthropic_messages protocol".to_owned());
        }
        let anthropic_thinking = match flags.anthropic_thinking {
            Some(ThinkingShape::Budget) => AnthropicThinking::Budget {
                min: flags.reasoning_budget_min,
                max: flags.reasoning_budget_max,
            },
            _ if flags.reasoning_budget_min.is_some() || flags.reasoning_budget_max.is_some() => {
                return Err("flags: the reasoning budget needs \"anthropic_thinking\": \"budget\"".to_owned());
            }
            Some(ThinkingShape::Toggle) => AnthropicThinking::Toggle,
            Some(ThinkingShape::Adaptive) => AnthropicThinking::Adaptive,
            None => AnthropicThinking::None,
        };
        Ok(Model {
            upstream_id: self.upstream_id.unwrap_or_else(|| self.id.clone()).into(),
            name: self.name.unwrap_or_else(|| self.id.clone()).into(),
            id: self.id.into(),
            protocol,
            limits: self.limits,
            cost,
            caps: Caps {
                tool_search: flags.supports_tool_search,
                disable_reasoning: flags.can_disable_reasoning,
                cache_breakpoint: flags.supports_cache_breakpoint,
                ..Caps::default()
            },
            reasoning_levels: self.reasoning_levels.into(),
            dialect: Dialect {
                chat: ChatFlags {
                    thinking_format: flags.thinking_format.unwrap_or_default(),
                    reasoning_replay: flags.reasoning_replay.unwrap_or_default(),
                    max_tokens_field: flags.max_tokens_field.unwrap_or_default(),
                },
                anthropic_thinking,
            },
            modalities: catalog::Modalities::default(),
        })
    }
}

/// Check a changed provider as a whole: the credential headers match the auth, the headers are valid, and each model
/// binds.
fn check(provider: &Provider) -> Result<(), String> {
    let sends_credential = !matches!(provider.auth, Auth::ApiKey(None));
    for (index, endpoint) in provider.endpoints.iter().enumerate() {
        match (sends_credential, endpoint.credential_header) {
            (true, None) => {
                return Err(format!(
                    "endpoints[{index}].credential_header: the provider sends a credential, so name its header"
                ));
            }
            (false, Some(_)) => {
                return Err(format!(
                    "endpoints[{index}].credential_header: the provider sends no credential: set api_key_env, or \
                     remove the header"
                ));
            }
            _ => {}
        }
    }
    let written: Vec<&str> = provider
        .endpoints
        .iter()
        .filter_map(|endpoint| endpoint.credential_header.map(CredentialHeader::name))
        .chain(provider.session_header.name())
        .collect();
    if let Some(name) = route::invalid_header(&provider.headers, &written) {
        return Err(format!(
            "headers: '{name}' is not a valid header name or value, or yuke writes this header itself"
        ));
    }
    for model in provider.models.iter() {
        Entry { provider, model }
            .bind()
            .map_err(|error| format!("model {}: {error}", model.id))?;
    }
    Ok(())
}

/// Check that `id` is not empty, and holds no white space, no control character, and none of `refused`.
fn valid_id(id: &str, refused: &str) -> Result<(), String> {
    if id.is_empty()
        || id
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || refused.contains(c))
    {
        let slash = if refused.is_empty() { "" } else { ", and no slash" };
        return Err(format!(
            "id: {id:?} must not be empty, and must have no white space, no control character{slash}"
        ));
    }
    Ok(())
}

/// Check that `url` is an `http` or `https` URL with a host, and with no user, query, or fragment.
fn valid_base_url(url: &str) -> Result<(), &'static str> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .ok_or("the URL must start with http:// or https://")?;
    let host = rest.split('/').next().unwrap_or_default();
    if host.is_empty() {
        return Err("the URL has no host");
    }
    if host.contains('@') {
        return Err("the URL must have no user");
    }
    // The HTTP parser keeps a port that is no number, and then sends to the default port.
    let port = host.rsplit_once(']').map_or(host, |(_, after)| after).split_once(':');
    if port.is_some_and(|(_, port)| port.parse::<u16>().is_err()) {
        return Err("the URL port must be a number from 0 to 65535");
    }
    if url.contains(['?', '#']) {
        return Err("the URL must have no query and no fragment");
    }
    if url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("the URL must have no white space and no control character");
    }
    Ok(())
}

#[cfg(test)]
mod tests;
