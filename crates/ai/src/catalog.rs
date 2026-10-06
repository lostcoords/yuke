//! The baked provider table, the model facts it states, and the selector lookup. The baked rows live in static
//! storage, and a caller can build its own rows from configuration with the same types.

#[expect(clippy::unreadable_literal, reason = "generated data keeps the digits of its source")]
mod generated;

use std::borrow::Cow;
use std::fmt;

use crate::request::{
    AnthropicWire, ChatDialect, ChatWire, Effort, MaxTokensField, Modality, Protocol, ReasoningReplayMode,
    ResponsesDialect, ResponsesWire, Target, ThinkingFormat, Wire,
};
use crate::route::{Credential, CredentialHeader, Route, SessionHeader};
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
    /// How the host caches a repeated prefix on this path.
    pub cache: Cache,
    /// The Responses flavor the host speaks. Only a Responses endpoint reads it.
    pub responses_dialect: ResponsesDialect,
    /// The Chat Completions flavor the host speaks. Only a Chat endpoint reads it.
    pub chat_dialect: ChatDialect,
}

/// How an endpoint caches a repeated prefix.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Cache {
    /// Nobody verified a cache control for the host, so a request marks nothing.
    #[default]
    None,
    /// The host caches on its own, so a request marks nothing.
    Automatic,
    /// The host caches at an explicit breakpoint in the protocol's own shape. Chat Completions has none.
    Breakpoint,
}

/// The authentication scheme of a provider. The source owns the referenced bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Auth<'a> {
    /// The environment variable name of the key, or `None` when none is known.
    ApiKey(Option<&'a str>),
    /// The login flow name. The caller runs the flow.
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
    pub tools: Option<bool>,
    /// Deferred tools and tool references need explicit support for the resolved model and endpoint.
    pub tool_search: Option<bool>,
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
    pub modalities: Modalities<'a>,
}

/// The baked provider with this ID, or `None` when no row matches.
pub fn find(id: &str) -> Option<&'static Provider<'static>> {
    PROVIDERS.iter().find(|row| row.id == id)
}

/// A selector that names nothing, or an entry that cannot bind. Every baked entry binds, so only an entry built from
/// caller configuration can fail to bind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
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
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::MalformedSelector => "the model selector is malformed",
            Self::UnknownProvider => "the catalog holds no provider with that name",
            Self::UnknownModel => "the catalog holds no model with that name",
            Self::MissingEndpoint => "the catalog provider declares no endpoint for the model protocol",
            Self::MissingOutputLimit => "the catalog model names no output limit, which its protocol requires",
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

    /// The wire settings of this model on its endpoint. The caller may change any of them before a call.
    ///
    /// # Errors
    ///
    /// Returns [`Error::MissingEndpoint`] if the provider declares no endpoint for the model. Returns
    /// [`Error::MissingOutputLimit`] if an Anthropic model has no output limit.
    pub fn wire(&self) -> Result<Wire, Error> {
        let served = self.endpoint()?;
        // MiniMax M3 caches but refuses a marker, so only a model that states it takes one gets one.
        let cache = served.cache == Cache::Breakpoint && self.model.caps.cache_breakpoint == Some(true);
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

    /// Build the route of this model from the host fields and the credential header of its endpoint. The route copies
    /// the strings once. A `'static` header keeps its borrowed text.
    fn route(&self) -> Result<Route, Error> {
        Ok(Route {
            base_url: Cow::Owned(self.provider.base_url.to_owned()),
            credential_header: self.endpoint()?.credential_header,
            headers: Cow::Owned(self.provider.headers.to_vec()),
            session_header: self.provider.session_header,
        })
    }

    /// Bind this model to a target that presents `credential`. The target owns its configuration, so it outlives this
    /// entry.
    ///
    /// # Errors
    ///
    /// Returns the [`Entry::wire`] errors.
    pub fn bind(&self, credential: Credential) -> Result<Target, Error> {
        Ok(Target {
            model: Cow::Owned(self.model.upstream_id.to_owned()),
            route: self.route()?,
            credential,
            wire: self.wire()?,
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
    let provider = find(provider_id).ok_or(Error::UnknownProvider)?;
    let model = provider
        .models
        .iter()
        .find(|spec| spec.id == model_id)
        .ok_or(Error::UnknownModel)?;
    Ok(Entry { provider, model })
}

/// Resolve `provider/model` into a call target that presents `credential`.
///
/// # Errors
///
/// Returns the [`lookup`] and [`Entry::bind`] errors.
pub fn resolve(selector: &str, credential: Credential) -> Result<Target, Error> {
    lookup(selector)?.bind(credential)
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

    fn endpoint(protocol: Protocol, credential_header: CredentialHeader, cache: Cache) -> Endpoint {
        Endpoint {
            protocol,
            credential_header: Some(credential_header),
            cache,
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
        let resolved = resolve(&selector, Credential::ApiKey("sk-test".into())).unwrap();
        assert_eq!(resolved.model, row.models[0].upstream_id);
        assert_eq!(resolved.credential, Credential::ApiKey("sk-test".into()));

        assert_eq!(resolve("nope/model", Credential::None), Err(Error::UnknownProvider));
        assert_eq!(resolve("anthropic/nope", Credential::None), Err(Error::UnknownModel));
        // An OpenRouter model id holds its own slash, so only the first one divides the selector.
        let nova = resolve("openrouter/amazon/nova-2-lite-v1", Credential::None).unwrap();
        assert_eq!(nova.model, "amazon/nova-2-lite-v1");
        for malformed in ["anthropic", "/claude", "anthropic/"] {
            assert_eq!(
                resolve(malformed, Credential::None),
                Err(Error::MalformedSelector),
                "{malformed}"
            );
        }
    }

    #[test]
    fn bind_takes_host_fields_and_endpoint_settings() {
        let headers = [Header::from_static("x-pinned", "1")];
        let mut endpoints = [
            endpoint(
                Protocol::AnthropicMessages,
                CredentialHeader::XApiKey,
                Cache::Breakpoint,
            ),
            endpoint(
                Protocol::OpenaiChat,
                CredentialHeader::AuthorizationBearer,
                Cache::Automatic,
            ),
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
                .bind(Credential::ApiKey("k".into()))
                .unwrap()
            };
            let (messages, chat) = (bind(0), bind(1));
            assert_eq!(messages.route.credential_header, Some(CredentialHeader::XApiKey));
            assert_eq!(
                chat.route.credential_header,
                Some(CredentialHeader::AuthorizationBearer)
            );
            assert_eq!(chat.model, "wire-id");
            assert_eq!(chat.credential, Credential::ApiKey("k".into()));
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
                Cache::None,
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
            entry.bind(Credential::ApiKey("k".into())).unwrap()
        };
        assert_eq!(target.model, "m");
        assert_eq!(target.route.base_url, "https://runtime.test/v1");
    }

    #[test]
    fn binding_checks_endpoint_and_anthropic_output_limit() {
        let endpoints = [endpoint(
            Protocol::AnthropicMessages,
            CredentialHeader::XApiKey,
            Cache::None,
        )];
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
        assert_eq!(chat.bind(Credential::None), Err(Error::MissingEndpoint));
        let bare = Entry {
            provider: &host,
            model: &host.models[1],
        };
        assert_eq!(
            bare.bind(Credential::ApiKey("k".into())),
            Err(Error::MissingOutputLimit)
        );
        let big = Entry {
            provider: &host,
            model: &host.models[2],
        };
        assert_eq!(
            big.wire(),
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
                assert!(entry.bind(Credential::None).is_ok(), "{}/{}", provider.id, model.id);
                assert!(valid_cost(model.cost), "{}/{}", provider.id, model.id);
            }
        }
    }
}
