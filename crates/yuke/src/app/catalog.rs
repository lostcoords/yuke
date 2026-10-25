//! The answer of `catalog/list`: the providers of the profile with their state, and their models.

use yuke_ai::catalog::{Model, Provider, ReasoningLevel};
use yuke_ai::{Modality as AiModality, ReasoningSettings};
use yuke_protocol::{
    Modality, ModelInfo, PriceBand, ProviderInfo, ProviderState, ReasoningChoice, ReasoningLevel as Level,
};

/// The info of `provider` in `state`.
pub(super) fn provider_info(provider: &Provider, state: ProviderState) -> ProviderInfo {
    ProviderInfo {
        id: provider.id.to_string(),
        name: provider.name.to_string(),
        state,
        models: provider.models.iter().map(model_info).collect(),
    }
}

/// The info of `model`.
fn model_info(model: &Model) -> ModelInfo {
    ModelInfo {
        id: model.id.to_string(),
        name: model.name.to_string(),
        context_window: model.limits.context_window,
        max_output_tokens: model.limits.max_output_tokens,
        reasoning: reasoning_choices(model),
        cost: model
            .cost
            .iter()
            .map(|band| PriceBand {
                min_prompt_tokens: band.min_prompt_tokens,
                input: band.input,
                output: band.output,
                reasoning: band.reasoning,
                cache_read: band.cache_read,
                cache_write: band.cache_write,
            })
            .collect(),
        tools: model.caps.tools,
        tool_search: model.caps.tool_search,
        input: model
            .modalities
            .input
            .iter()
            .filter_map(|kind| modality(*kind))
            .collect(),
    }
}

/// The reasoning choices of `model`: the endpoint default, then off and each effort of the catalog that the model
/// takes, each once. An effort that the catalog does not list is not a choice.
fn reasoning_choices(model: &Model) -> Vec<ReasoningChoice> {
    let mut choices = vec![ReasoningChoice {
        level: Level::Default,
        settings: ReasoningSettings::default(),
    }];
    let efforts = model.reasoning_levels.iter().filter_map(|level| *level);
    let levels = std::iter::once(ReasoningLevel::Off).chain(efforts.map(ReasoningLevel::Effort));
    for level in levels {
        if let Ok(settings) = model.reasoning(level) {
            let level = match level {
                ReasoningLevel::Off => Level::Off,
                ReasoningLevel::Effort(effort) => Level::from(effort),
            };
            // `providers.json` can list a level twice, and a client keys the choices by level.
            if choices.iter().all(|choice| choice.level != level) {
                choices.push(ReasoningChoice { level, settings });
            }
        }
    }
    choices
}

/// The protocol kind of `kind`. The catalog never lists `Other`.
fn modality(kind: AiModality) -> Option<Modality> {
    match kind {
        AiModality::Text => Some(Modality::Text),
        AiModality::Image => Some(Modality::Image),
        AiModality::Audio => Some(Modality::Audio),
        AiModality::Video => Some(Modality::Video),
        AiModality::Pdf => Some(Modality::Pdf),
        AiModality::Other => None,
    }
}
