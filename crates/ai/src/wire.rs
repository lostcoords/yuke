//! The request serializers of the three protocols. Each writes the head of a request up to its open context array,
//! and the groups of blocks that make the elements of that array.

mod anthropic;
pub(crate) mod json;
mod openai_chat;
mod openai_responses;
pub(crate) mod outgoing;
#[cfg(test)]
pub(crate) mod testing;

use crate::encoder::EncodeError;
use crate::request::{Block, Request, Target, ToolDefinition, Wire};
use json::JsonWriter;

/// Tell whether the protocol of `target` writes `block`. It writes a reasoning block only when
/// [`Reasoning::replay_to`](crate::request::Reasoning::replay_to) gives state for `target`.
fn writes(target: &Target, block: &Block) -> bool {
    match block {
        Block::Reasoning(reasoning) => reasoning.replay_to(target).is_some(),
        Block::UserText(_) | Block::AssistantText(_) | Block::Media(_) | Block::ToolCall(_) | Block::ToolResult(_) => {
            true
        }
    }
}

/// Write the request up to its open context array. Return whether that array already holds an element, as the
/// Chat system message is one.
pub(crate) fn write_head(out: &mut Vec<u8>, target: &Target, request: &Request<'_>) -> bool {
    match &target.wire {
        Wire::AnthropicMessages(wire) => {
            anthropic::write_head(out, target, *wire, request);
            false
        }
        Wire::OpenaiChat(wire) => openai_chat::write_head(out, target, *wire, request),
        Wire::OpenaiResponses(wire) => {
            openai_responses::write_head(out, target, *wire, request);
            false
        }
    }
}

/// Write the element of the group of blocks that starts at `start`, and return the end of the group. Write
/// nothing when the protocol drops the group. `marker` is the block that carries the cache marker.
pub(crate) fn write_group(
    jw: &mut JsonWriter<'_>,
    target: &Target,
    request: &Request<'_>,
    start: usize,
    marker: Option<usize>,
) -> Result<usize, EncodeError> {
    match &target.wire {
        Wire::AnthropicMessages(_) => anthropic::write_group(jw, target, request, start, marker),
        Wire::OpenaiChat(wire) => openai_chat::write_group(jw, target, *wire, request, start),
        Wire::OpenaiResponses(_) => openai_responses::write_group(jw, target, request, start, marker),
    }
}

/// The block that carries the cache marker: the last one the protocol can mark. Chat Completions writes none.
pub(crate) fn cache_index(wire: Wire, blocks: &[Block]) -> Option<usize> {
    let cacheable: fn(&Block) -> bool = match wire {
        Wire::AnthropicMessages(facts) if facts.cache => anthropic::cacheable,
        Wire::OpenaiResponses(facts) if facts.cache => openai_responses::cacheable,
        _ => return None,
    };
    blocks.iter().rposition(cacheable)
}

/// Report whether a request declares a deferred tool. The elements read it, so a change encodes them again.
pub(crate) fn defers_tools(tools: &[ToolDefinition]) -> bool {
    tools.iter().any(|tool| tool.defer_loading)
}
