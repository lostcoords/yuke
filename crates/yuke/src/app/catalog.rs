//! The answer of `catalog/list`: the providers of the profile with their state, and their models.

use yuke_ai::catalog::{Model, Provider, ReasoningLevel};
use yuke_ai::{Modality, ReasoningSettings};
use yuke_protocol::{ModelInfo, ProviderInfo, ProviderState, ReasoningChoice, ReasoningSelection};

/// The info of `provider` in `state`. A provider that is not ready has no models.
pub(super) fn provider_info(provider: &Provider, state: ProviderState) -> ProviderInfo {
    let models = match state {
        ProviderState::Ready { .. } => provider.models.iter().map(model_info).collect(),
        ProviderState::NeedsApiKey { .. } | ProviderState::NeedsLogin => Vec::new(),
    };
    ProviderInfo {
        id: provider.id.to_string(),
        name: provider.name.to_string(),
        state,
        models,
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
        cost: model.cost.to_vec(),
        tools: model.caps.tools,
        tool_search: model.caps.tool_search,
        input: model
            .modalities
            .input
            .iter()
            .copied()
            // The catalog never lists `Other`, and the protocol does not name it.
            .filter(|kind| *kind != Modality::Other)
            .collect(),
    }
}

/// The reasoning choices of `model`: the endpoint default, then off and each effort of the catalog that the model
/// takes, each once. An effort that the catalog does not list is not a choice.
pub(super) fn reasoning_choices(model: &Model) -> Vec<ReasoningChoice> {
    let mut choices = vec![ReasoningChoice {
        level: ReasoningSelection::Default,
        settings: ReasoningSettings::default(),
    }];
    let efforts = model.reasoning_levels.iter().filter_map(|level| *level);
    let levels = std::iter::once(ReasoningLevel::Off).chain(efforts.map(ReasoningLevel::Effort));
    for level in levels {
        if let Ok(settings) = model.reasoning(level) {
            let level = match level {
                ReasoningLevel::Off => ReasoningSelection::Off,
                ReasoningLevel::Effort(effort) => ReasoningSelection::Effort(effort),
            };
            // `providers.json` can list a level twice, and a client keys the choices by level.
            if choices.iter().all(|choice| choice.level != level) {
                choices.push(ReasoningChoice { level, settings });
            }
        }
    }
    choices
}
