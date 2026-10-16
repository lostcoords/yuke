//! The baked provider table, the model facts it states, and the selector lookup. The baked rows live in static
//! storage, and a caller can build its own rows from configuration with the same types.

#[expect(clippy::unreadable_literal, reason = "generated data keeps the digits of its source")]
mod generated;

use std::borrow::Cow;
use std::fmt;

use crate::request::{
    AnthropicWire, ChatDialect, ChatWire, Effort, MaxTokensField, Modality, Protocol, ReasoningReplayMode,
    ReasoningSettings, ResponsesDialect, ResponsesWire, Target, Thinking, ThinkingDisplay, ThinkingFormat, Wire,
};
use crate::route::{CredentialHeader, Route, SessionHeader};
use crate::transport::Header;

pub use generated::{PROVIDERS, REVISION};

/// One host and the models it serves. The source owns the referenced bytes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Provider<'a> {
    /// The provider half of a selector.
    pub id: &'a str,
    /// The display name.
    pub name: &'a str,
    /// The authentication scheme. It never carries a secret.
    pub auth: Auth<'a>,
    /// The base URL of every endpoint.
    pub base_url: &'a str,
    /// Pinned non-secret headers. A live grant adds identity headers at run time.
    pub headers: &'a [Header],
    /// The header that carries the session id.
    pub session_header: SessionHeader,
    /// One entry per served protocol. Every model names one of these endpoints.
    pub endpoints: &'a [Endpoint],
    /// The models of the host.
    pub models: &'a [Model<'a>],
}

/// One protocol a host serves. The credential header can differ for each path.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Endpoint {
    /// The protocol of the path.
    pub protocol: Protocol,
    /// The header that carries the credential on this path. `None` means that the path takes no credential.
    pub credential_header: Option<CredentialHeader>,
    /// The host caches a repeated prefix at an explicit breakpoint in the protocol's own shape on this path. When it
    /// is false, a request marks nothing. Chat Completions has no breakpoint.
    pub cache_breakpoint: bool,
    /// The Responses flavor the host speaks. Only a Responses endpoint reads it.
    pub responses_dialect: ResponsesDialect,
    /// The Chat Completions flavor the host speaks. Only a Chat endpoint reads it.
    pub chat_dialect: ChatDialect,
}

/// The authentication scheme of a provider. The source owns the referenced bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Auth<'a> {
    /// The environment variable name of the key, or `None` when none is known.
    ApiKey(Option<&'a str>),
    /// The login flow name. [`crate::oauth::Flow::named`] gives the flow, and the caller keeps its grant.
    OAuth(&'a str),
}

/// The kinds a model reads and writes. The generator keeps only the names of [`Modality`] that a model can list, so
/// `Other` never appears.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Modalities<'a> {
    /// The kinds the model reads.
    pub input: &'a [Modality],
    /// The kinds the model writes.
    pub output: &'a [Modality],
}

impl Modalities<'_> {
    /// Report whether the model takes this kind, or `None` when the source lists none.
    pub fn takes_input(&self, kind: Modality) -> Option<bool> {
        if self.input.is_empty() {
            None
        } else {
            Some(self.input.contains(&kind))
        }
    }
}

// What a source knows. `None` is unknown, and never zero, false, or an empty string.

/// A limit the source does not publish stays `None`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Limits {
    /// The context window in tokens.
    pub context_window: Option<u64>,
    /// The output limit in tokens.
    pub max_output_tokens: Option<u64>,
}

/// The prices of one band, in US dollars per million tokens. A `None` price is unknown, and never zero.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct PriceBand {
    /// The smallest prompt this band prices. The prompt counts every input token, the cached ones too.
    pub min_prompt_tokens: u64,
    /// The price of an input token.
    pub input: Option<f64>,
    /// The price of an output token.
    pub output: Option<f64>,
    /// A reasoning token is also an output token. This price replaces the output price for it.
    pub reasoning: Option<f64>,
    /// The price of a token read from the prompt cache.
    pub cache_read: Option<f64>,
    /// The price of a token written to the prompt cache.
    pub cache_write: Option<f64>,
}

/// The cost of a model that the source does not price: one band of unknown prices.
pub const UNKNOWN_COST: &[PriceBand] = &[PriceBand {
    min_prompt_tokens: 0,
    input: None,
    output: None,
    reasoning: None,
    cache_read: None,
    cache_write: None,
}];

/// Report whether `bands` is a cost: the first band starts at 0, the thresholds rise, and no price is negative.
pub fn valid_cost(bands: &[PriceBand]) -> bool {
    let Some(first) = bands.first() else { return false };
    if first.min_prompt_tokens != 0 {
        return false;
    }
    let rises = bands
        .windows(2)
        .all(|pair| pair[1].min_prompt_tokens > pair[0].min_prompt_tokens);
    let priced = bands.iter().all(|band| {
        [
            band.input,
            band.output,
            band.reasoning,
            band.cache_read,
            band.cache_write,
        ]
        .into_iter()
        .flatten()
        .all(|price| price >= 0.0)
    });
    rises && priced
}

/// What a model can do. `None` is unknown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Caps {
    /// Whether the model calls tools.
    // @todo(xyaman): No request reads this yet. Leave out the tools for a model that cannot call them.
    pub tools: Option<bool>,
    /// Deferred tools and tool references need explicit support for the resolved model and endpoint.
    pub tool_search: Option<bool>,
    /// The source claim that this endpoint and model accept privileged instructions inside conversation history.
    pub system_updates: Option<bool>,
    /// Whether the model can stop reasoning. `None` is unknown, so a caller may still ask.
    pub disable_reasoning: Option<bool>,
    /// Whether the model accepts an explicit marker. MiniMax M3 caches and refuses one.
    pub cache_breakpoint: Option<bool>,
}

/// The request shape a named reasoning level takes on an Anthropic Messages model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum AnthropicThinking {
    /// No thinking control: the level is an effort.
    #[default]
    None,
    /// A compatible host: adaptive thinking, with no effort and no display.
    Toggle,
    /// Anthropic's adaptive thinking: the level is an effort, and the summary is displayed.
    Adaptive,
    /// A thinking-token budget within the bounds a source states. A published zero is a value. `None` is unknown.
    Budget {
        /// The smallest budget.
        min: Option<i64>,
        /// The largest budget.
        max: Option<u64>,
    },
}

/// How a request asks this model to reason, and which output-token member it takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Dialect {
    /// The Chat Completions settings of the model.
    pub chat: ChatFlags,
    /// The request shape of a reasoning level on Anthropic Messages.
    pub anthropic_thinking: AnthropicThinking,
}

/// The Chat Completions settings of a model: the reasoning control, the reasoning replay, and the output-limit
/// member. The endpoint adds the dialect of its host.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct ChatFlags {
    /// The reasoning control the model takes.
    pub thinking_format: ThinkingFormat,
    /// How a prior assistant turn returns its reasoning.
    pub reasoning_replay: ReasoningReplayMode,
    /// The output-token member the model takes.
    pub max_tokens_field: MaxTokensField,
}

/// One model in the shape every source shares. It holds no URL and no secret.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Model<'a> {
    /// The model half of a selector.
    pub id: &'a str,
    /// The model ID the host takes.
    pub upstream_id: &'a str,
    /// The display name.
    pub name: &'a str,
    /// Name the endpoint that serves this model. A host can serve several endpoints.
    pub protocol: Protocol,
    /// The token limits.
    pub limits: Limits,
    /// The price bands in threshold order. The last band that the prompt reaches prices the whole request.
    pub cost: &'a [PriceBand],
    /// What the model can do.
    pub caps: Caps,
    /// The efforts a user can pick. A `None` level means "no effort at all".
    pub reasoning_levels: &'a [Option<Effort>],
    /// How a request asks the model to reason.
    pub dialect: Dialect,
    /// The kinds the model reads and writes.
    // @todo(xyaman): No request reads this yet. Replace the media that a model cannot read with a note.
    pub modalities: Modalities<'a>,
}

/// A reasoning level that a user picks for a model: no reasoning, or an effort.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReasoningLevel {
    /// No reasoning.
    Off,
    /// The effort of the model.
    Effort(Effort),
}

/// The smallest thinking budget that an Anthropic-shaped endpoint takes.
const SMALLEST_THINKING_BUDGET: u64 = 1024;

/// The thinking budget of a level. Anthropic starts a complex task at this budget. A larger budget needs batch
/// processing.
const THINKING_BUDGET: u64 = 16_000;

impl Model<'_> {
    /// The reasoning settings that ask this model for `level`. A thinking budget stays below the output limit of the
    /// model, and a budget that does not fit falls back to the effort.
    ///
    /// # Errors
    ///
    /// Returns [`Error::UnsupportedReasoning`] for [`ReasoningLevel::Off`] on a model that states it cannot stop
    /// reasoning, and for an effort that the levels of the model do not list.
    pub fn reasoning(&self, level: ReasoningLevel) -> Result<ReasoningSettings, Error> {
        let effort = match level {
            // A model that states it cannot stop would refuse the control, so the refusal comes before a request.
            ReasoningLevel::Off if self.caps.disable_reasoning == Some(false) => {
                return Err(Error::UnsupportedReasoning);
            }
            ReasoningLevel::Off => {
                return Ok(ReasoningSettings {
                    thinking: Some(Thinking::Off),
                    effort: None,
                });
            }
            ReasoningLevel::Effort(effort) => effort,
        };
        if !self.reasoning_levels.is_empty() && !self.reasoning_levels.contains(&Some(effort)) {
            return Err(Error::UnsupportedReasoning);
        }
        let effort_only = ReasoningSettings {
            thinking: None,
            effort: Some(effort),
        };
        Ok(match self.dialect.anthropic_thinking {
            AnthropicThinking::None => effort_only,
            AnthropicThinking::Toggle => ReasoningSettings {
                thinking: Some(Thinking::Adaptive(None)),
                effort: None,
            },
            AnthropicThinking::Adaptive => ReasoningSettings {
                thinking: Some(Thinking::Adaptive(Some(ThinkingDisplay::Summarized))),
                effort: Some(effort),
            },
            AnthropicThinking::Budget { min, max } => {
                let smallest = min.and_then(|min| u64::try_from(min).ok()).unwrap_or(0);
                let budget = THINKING_BUDGET
                    .min(max.unwrap_or(u64::MAX))
                    .max(smallest)
                    .max(SMALLEST_THINKING_BUDGET);
                if self.limits.max_output_tokens.is_some_and(|limit| budget < limit) {
                    ReasoningSettings {
                        thinking: Some(Thinking::Budget(budget)),
                        effort: None,
                    }
                } else {
                    effort_only
                }
            }
        })
    }
}

/// A selector that names nothing, an entry that cannot bind, or a reasoning level that a model does not support.
/// Every baked entry binds, so only an entry built from caller configuration can fail to bind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Error {
    /// The selector is not `provider/model`.
    MalformedSelector,
    /// The catalog holds no provider with that name.
    UnknownProvider,
    /// The catalog holds no model with that name.
    UnknownModel,
    /// The provider declares no endpoint for the model protocol.
    MissingEndpoint,
    /// The model names no output limit, which its protocol requires.
    MissingOutputLimit,
    /// The model does not support the reasoning level.
    UnsupportedReasoning,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::MalformedSelector => "the model selector is malformed",
            Self::UnknownProvider => "the catalog holds no provider with that name",
            Self::UnknownModel => "the catalog holds no model with that name",
            Self::MissingEndpoint => "the catalog provider declares no endpoint for the model protocol",
            Self::MissingOutputLimit => "the catalog model names no output limit, which its protocol requires",
            Self::UnsupportedReasoning => "the model does not support that reasoning level",
        })
    }
}

impl std::error::Error for Error {}

/// Split `provider/model` on the first slash, because a model id may hold further slashes.
fn split(selector: &str) -> Result<(&str, &str), Error> {
    match selector.split_once('/') {
        Some((provider, model)) if !provider.is_empty() && !model.is_empty() => Ok((provider, model)),
        _ => Err(Error::MalformedSelector),
    }
}

/// One catalog model and the provider that serves it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Entry<'a> {
    /// The provider of the model.
    pub provider: &'a Provider<'a>,
    /// The model.
    pub model: &'a Model<'a>,
}

impl Entry<'_> {
    /// The endpoint that serves the model's protocol.
    ///
    /// # Errors
    ///
    /// Returns [`Error::MissingEndpoint`] if the provider declares none.
    pub fn endpoint(&self) -> Result<Endpoint, Error> {
        self.provider
            .endpoints
            .iter()
            .find(|served| served.protocol == self.model.protocol)
            .copied()
            .ok_or(Error::MissingEndpoint)
    }

    /// The wire settings for this model at endpoint `served`. An Anthropic model needs an output limit.
    fn wire(&self, served: Endpoint) -> Result<Wire, Error> {
        // MiniMax M3 caches but refuses a marker, so only a model that states it takes one gets one.
        let cache = served.cache_breakpoint && self.model.caps.cache_breakpoint == Some(true);
        Ok(match served.protocol {
            Protocol::AnthropicMessages => {
                // This API has no default output limit, so the model must name one.
                let limit = self.model.limits.max_output_tokens.ok_or(Error::MissingOutputLimit)?;
                Wire::AnthropicMessages(AnthropicWire {
                    max_tokens: u32::try_from(limit).unwrap_or(u32::MAX),
                    cache,
                })
            }
            Protocol::OpenaiChat => {
                let chat = self.model.dialect.chat;
                Wire::OpenaiChat(ChatWire {
                    dialect: served.chat_dialect,
                    thinking_format: chat.thinking_format,
                    reasoning_replay: chat.reasoning_replay,
                    max_tokens_field: chat.max_tokens_field,
                })
            }
            Protocol::OpenaiResponses => Wire::OpenaiResponses(ResponsesWire {
                dialect: served.responses_dialect,
                cache,
            }),
        })
    }

    /// Bind this model to a target. The target owns its configuration and can outlive this entry. The caller may
    /// change any of the wire settings before a call.
    ///
    /// # Errors
    ///
    /// Returns [`Error::MissingEndpoint`] if the provider declares no endpoint for the model. Returns
    /// [`Error::MissingOutputLimit`] if an Anthropic model has no output limit.
    pub fn bind(&self) -> Result<Target, Error> {
        let served = self.endpoint()?;
        Ok(Target {
            model: Cow::Owned(self.model.upstream_id.to_owned()),
            // The route copies the strings once. A `'static` header keeps its borrowed text.
            route: Route {
                base_url: Cow::Owned(self.provider.base_url.to_owned()),
                credential_header: served.credential_header,
                headers: Cow::Owned(self.provider.headers.to_vec()),
                session_header: self.provider.session_header,
            },
            wire: self.wire(served)?,
            // Chat Completions has no native search of deferred tools, whatever the model can do elsewhere.
            tool_search: self.model.caps.tool_search == Some(true) && self.model.protocol != Protocol::OpenaiChat,
        })
    }
}

/// Find the baked entry a `provider/model` selector names.
///
/// # Errors
///
/// Returns [`Error::MalformedSelector`], [`Error::UnknownProvider`], or [`Error::UnknownModel`] if the selector names
/// no catalog model.
pub fn lookup(selector: &str) -> Result<Entry<'static>, Error> {
    let (provider_id, model_id) = split(selector)?;
    let provider = PROVIDERS
        .iter()
        .find(|provider| provider.id == provider_id)
        .ok_or(Error::UnknownProvider)?;
    let model = provider
        .models
        .iter()
        .find(|spec| spec.id == model_id)
        .ok_or(Error::UnknownModel)?;
    Ok(Entry { provider, model })
}

/// Resolve `provider/model` into a call target.
///
/// # Errors
///
/// Returns the [`lookup`] and [`Entry::bind`] errors.
pub fn resolve(selector: &str) -> Result<Target, Error> {
    lookup(selector)?.bind()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model(id: &'static str, protocol: Protocol) -> Model<'static> {
        Model {
            id,
            upstream_id: id,
            name: id,
            protocol,
            limits: Limits::default(),
            cost: UNKNOWN_COST,
            caps: Caps::default(),
            reasoning_levels: &[],
            dialect: Dialect::default(),
            modalities: Modalities::default(),
        }
    }

    fn endpoint(protocol: Protocol, credential_header: CredentialHeader, cache_breakpoint: bool) -> Endpoint {
        Endpoint {
            protocol,
            credential_header: Some(credential_header),
            cache_breakpoint,
            responses_dialect: ResponsesDialect::Standard,
            chat_dialect: ChatDialect::Standard,
        }
    }

    fn provider<'a>(endpoints: &'a [Endpoint], models: &'a [Model<'a>]) -> Provider<'a> {
        Provider {
            id: "host",
            name: "Host",
            auth: Auth::ApiKey(None),
            base_url: "https://host.test/v1",
            headers: &[],
            session_header: SessionHeader::None,
            endpoints,
            models,
        }
    }

    fn band(min_prompt_tokens: u64) -> PriceBand {
        PriceBand {
            min_prompt_tokens,
            ..PriceBand::default()
        }
    }

    #[test]
    fn resolve_parses_selectors_and_reports_lookup_errors() {
        let row = &PROVIDERS[0];
        let selector = format!("{}/{}", row.id, row.models[0].id);
        let resolved = resolve(&selector).unwrap();
        assert_eq!(resolved.model, row.models[0].upstream_id);

        assert_eq!(resolve("nope/model"), Err(Error::UnknownProvider));
        assert_eq!(resolve("anthropic/nope"), Err(Error::UnknownModel));
        // An OpenRouter model id holds its own slash, so only the first one divides the selector.
        let nova = resolve("openrouter/amazon/nova-2-lite-v1").unwrap();
        assert_eq!(nova.model, "amazon/nova-2-lite-v1");
        for malformed in ["anthropic", "/claude", "anthropic/"] {
            assert_eq!(resolve(malformed), Err(Error::MalformedSelector), "{malformed}");
        }
    }

    #[test]
    fn bind_marks_native_tool_search_only_for_a_capable_model_off_chat_completions() {
        let endpoints = [
            endpoint(Protocol::AnthropicMessages, CredentialHeader::XApiKey, true),
            endpoint(Protocol::OpenaiChat, CredentialHeader::AuthorizationBearer, false),
        ];
        let searching = Caps {
            tool_search: Some(true),
            ..Caps::default()
        };
        let limits = Limits {
            max_output_tokens: Some(64),
            ..Limits::default()
        };
        let models = [
            Model {
                caps: searching,
                limits,
                ..model("capable", Protocol::AnthropicMessages)
            },
            Model {
                limits,
                ..model("unknown", Protocol::AnthropicMessages)
            },
            Model {
                caps: searching,
                ..model("chat", Protocol::OpenaiChat)
            },
        ];
        let host = provider(&endpoints, &models);
        let tool_search = |index: usize| {
            Entry {
                provider: &host,
                model: &models[index],
            }
            .bind()
            .unwrap()
            .tool_search
        };
        assert!(tool_search(0));
        assert!(!tool_search(1));
        assert!(!tool_search(2));
    }

    #[test]
    fn bind_takes_host_fields_and_endpoint_settings() {
        let headers = [Header::from_static("x-pinned", "1")];
        let mut endpoints = [
            endpoint(Protocol::AnthropicMessages, CredentialHeader::XApiKey, true),
            endpoint(Protocol::OpenaiChat, CredentialHeader::AuthorizationBearer, false),
        ];
        let flags = ChatFlags {
            thinking_format: ThinkingFormat::Deepseek,
            reasoning_replay: ReasoningReplayMode::ReasoningContent,
            max_tokens_field: MaxTokensField::MaxCompletionTokens,
        };
        let models = [
            Model {
                limits: Limits {
                    max_output_tokens: Some(64),
                    ..Limits::default()
                },
                caps: Caps {
                    cache_breakpoint: Some(true),
                    ..Caps::default()
                },
                ..model("a", Protocol::AnthropicMessages)
            },
            Model {
                upstream_id: "wire-id",
                dialect: Dialect {
                    chat: flags,
                    ..Dialect::default()
                },
                ..model("selector-id", Protocol::OpenaiChat)
            },
            Model {
                limits: Limits {
                    max_output_tokens: Some(64),
                    ..Limits::default()
                },
                ..model("u", Protocol::AnthropicMessages)
            },
        ];
        for dialect in [ChatDialect::Mistral, ChatDialect::Standard] {
            endpoints[1].chat_dialect = dialect;
            let gateway = Provider {
                base_url: "https://gateway.test/v1",
                headers: &headers,
                session_header: SessionHeader::XOpencodeSession,
                ..provider(&endpoints, &models)
            };
            let bind = |model: usize| {
                Entry {
                    provider: &gateway,
                    model: &gateway.models[model],
                }
                .bind()
                .unwrap()
            };
            let (messages, chat) = (bind(0), bind(1));
            assert_eq!(messages.route.credential_header, Some(CredentialHeader::XApiKey));
            assert_eq!(
                chat.route.credential_header,
                Some(CredentialHeader::AuthorizationBearer)
            );
            assert_eq!(chat.model, "wire-id");
            assert_eq!(
                chat.wire,
                Wire::OpenaiChat(ChatWire {
                    dialect,
                    thinking_format: ThinkingFormat::Deepseek,
                    reasoning_replay: ReasoningReplayMode::ReasoningContent,
                    max_tokens_field: MaxTokensField::MaxCompletionTokens,
                })
            );
            let breakpoint = |cache| Wire::AnthropicMessages(AnthropicWire { max_tokens: 64, cache });
            assert_eq!(messages.wire, breakpoint(true));
            assert_eq!(bind(2).wire, breakpoint(false));
            assert_eq!(chat.route.base_url, "https://gateway.test/v1");
            assert_eq!(chat.route.session_header, SessionHeader::XOpencodeSession);
            assert_eq!(chat.route.headers.as_ref(), &[Header::from_static("x-pinned", "1")]);
        }
    }

    // Configuration can build a provider at run time. Its target owns the strings, so it outlives the provider.
    #[test]
    fn runtime_provider_binds_to_an_owned_target() {
        let target = {
            let base_url = String::from("https://runtime.test/v1");
            let endpoints = [endpoint(
                Protocol::OpenaiChat,
                CredentialHeader::AuthorizationBearer,
                false,
            )];
            let models = [model("m", Protocol::OpenaiChat)];
            let provider = Provider {
                base_url: &base_url,
                ..provider(&endpoints, &models)
            };
            let entry = Entry {
                provider: &provider,
                model: &provider.models[0],
            };
            entry.bind().unwrap()
        };
        assert_eq!(target.model, "m");
        assert_eq!(target.route.base_url, "https://runtime.test/v1");
    }

    #[test]
    fn binding_checks_endpoint_and_anthropic_output_limit() {
        let endpoints = [endpoint(Protocol::AnthropicMessages, CredentialHeader::XApiKey, false)];
        let models = [
            model("chat", Protocol::OpenaiChat),
            model("bare", Protocol::AnthropicMessages),
            Model {
                limits: Limits {
                    max_output_tokens: Some(u64::MAX),
                    ..Limits::default()
                },
                ..model("big", Protocol::AnthropicMessages)
            },
        ];
        let host = provider(&endpoints, &models);
        let chat = Entry {
            provider: &host,
            model: &host.models[0],
        };
        assert_eq!(chat.bind(), Err(Error::MissingEndpoint));
        let bare = Entry {
            provider: &host,
            model: &host.models[1],
        };
        assert_eq!(bare.bind(), Err(Error::MissingOutputLimit));
        let big = Entry {
            provider: &host,
            model: &host.models[2],
        };
        assert_eq!(
            big.bind().map(|target| target.wire),
            Ok(Wire::AnthropicMessages(AnthropicWire {
                max_tokens: u32::MAX,
                cache: false
            }))
        );
    }

    #[test]
    fn input_kind_is_unknown_until_listed() {
        let none = Modalities::default();
        assert_eq!(none.takes_input(Modality::Image), None); // A source that lists nothing blocks nothing.

        let text_only = Modalities {
            input: &[Modality::Text],
            output: &[Modality::Text],
        };
        assert_eq!(text_only.takes_input(Modality::Image), Some(false));
        assert_eq!(text_only.takes_input(Modality::Text), Some(true));

        let media = Modalities {
            input: &[Modality::Text, Modality::Image, Modality::Pdf],
            output: &[],
        };
        assert_eq!(media.takes_input(Modality::Pdf), Some(true));
        assert_eq!(media.takes_input(Modality::Audio), Some(false));
    }

    #[test]
    fn cost_starts_at_zero_and_never_goes_negative() {
        assert!(valid_cost(UNKNOWN_COST));
        assert!(valid_cost(&[
            PriceBand {
                input: Some(4.0),
                ..band(0)
            },
            PriceBand {
                input: Some(8.0),
                ..band(272_001)
            },
        ]));
        assert!(!valid_cost(&[]));
        assert!(!valid_cost(&[band(1)]));
        assert!(!valid_cost(&[band(0), band(9), band(9)]));
        assert!(!valid_cost(&[band(0), band(9), band(5)]));
        assert!(!valid_cost(&[
            band(0),
            PriceBand {
                cache_write: Some(-1.0),
                ..band(9)
            }
        ]));
        // A price that is no number is no cost either.
        assert!(!valid_cost(&[PriceBand {
            input: Some(f64::NAN),
            ..band(0)
        }]));
    }

    // A generated table that fails here must not ship: a model on no endpoint, an Anthropic model with no output
    // limit, or a malformed cost.
    #[test]
    fn baked_entries_bind_with_valid_costs() {
        for provider in PROVIDERS {
            for model in provider.models {
                let entry = Entry { provider, model };
                assert!(entry.bind().is_ok(), "{}/{}", provider.id, model.id);
                assert!(valid_cost(model.cost), "{}/{}", provider.id, model.id);
            }
        }
    }

    /// An Anthropic model with the thinking shape `anthropic_thinking`, the effort `high`, and an output limit of
    /// 32,000 tokens.
    fn thinking_model(anthropic_thinking: AnthropicThinking) -> Model<'static> {
        Model {
            limits: Limits {
                context_window: None,
                max_output_tokens: Some(32_000),
            },
            reasoning_levels: &[Some(Effort::High)],
            dialect: Dialect {
                anthropic_thinking,
                ..Dialect::default()
            },
            ..model("m", Protocol::AnthropicMessages)
        }
    }

    const HIGH: ReasoningLevel = ReasoningLevel::Effort(Effort::High);

    fn budget(min: Option<i64>, max: Option<u64>) -> AnthropicThinking {
        AnthropicThinking::Budget { min, max }
    }

    #[test]
    fn a_level_takes_the_thinking_shape_of_the_model() {
        let effort = ReasoningSettings {
            thinking: None,
            effort: Some(Effort::High),
        };
        let cases = [
            (AnthropicThinking::None, effort),
            (
                AnthropicThinking::Toggle,
                ReasoningSettings {
                    thinking: Some(Thinking::Adaptive(None)),
                    effort: None,
                },
            ),
            (
                AnthropicThinking::Adaptive,
                ReasoningSettings {
                    thinking: Some(Thinking::Adaptive(Some(ThinkingDisplay::Summarized))),
                    effort: Some(Effort::High),
                },
            ),
            (
                budget(Some(1024), Some(32_000)),
                ReasoningSettings {
                    thinking: Some(Thinking::Budget(16_000)),
                    effort: None,
                },
            ),
        ];
        for (anthropic_thinking, settings) in cases {
            assert_eq!(
                thinking_model(anthropic_thinking).reasoning(HIGH),
                Ok(settings),
                "{anthropic_thinking:?}"
            );
        }
    }

    #[test]
    fn a_thinking_budget_stays_within_the_bounds_of_the_model() {
        let budget_of = |anthropic_thinking| thinking_model(anthropic_thinking).reasoning(HIGH).unwrap().thinking;

        assert_eq!(budget_of(budget(None, Some(2000))), Some(Thinking::Budget(2000)));
        assert_eq!(budget_of(budget(Some(20_000), None)), Some(Thinking::Budget(20_000)));
        assert_eq!(budget_of(budget(None, Some(10))), Some(Thinking::Budget(1024)));
        assert_eq!(budget_of(budget(Some(-5), None)), Some(Thinking::Budget(16_000)));
    }

    #[test]
    fn a_thinking_budget_that_does_not_fit_the_output_falls_back_to_the_effort() {
        let small_output = Model {
            limits: Limits {
                context_window: None,
                max_output_tokens: Some(16_000),
            },
            ..thinking_model(budget(None, None))
        };

        assert_eq!(
            small_output.reasoning(HIGH),
            Ok(ReasoningSettings {
                thinking: None,
                effort: Some(Effort::High),
            })
        );
    }

    #[test]
    fn off_asks_for_no_thinking_unless_the_model_cannot_stop() {
        let mut model = thinking_model(AnthropicThinking::Adaptive);
        assert_eq!(
            model.reasoning(ReasoningLevel::Off),
            Ok(ReasoningSettings {
                thinking: Some(Thinking::Off),
                effort: None,
            })
        );

        model.caps.disable_reasoning = Some(false);
        assert_eq!(model.reasoning(ReasoningLevel::Off), Err(Error::UnsupportedReasoning));
    }

    #[test]
    fn an_effort_that_the_model_does_not_list_is_unsupported() {
        let model = thinking_model(AnthropicThinking::None);
        assert_eq!(
            model.reasoning(ReasoningLevel::Effort(Effort::Low)),
            Err(Error::UnsupportedReasoning)
        );

        let unlisted = Model {
            reasoning_levels: &[],
            ..model
        };
        assert!(unlisted.reasoning(ReasoningLevel::Effort(Effort::Low)).is_ok());
    }
}
