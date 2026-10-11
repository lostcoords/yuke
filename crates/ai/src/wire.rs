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
use crate::request::{Block, Request, Target, Wire};
use json::Elements;

/// Write the request up to its open context array. Return whether that array already holds an element, as the
/// Chat system message is one.
pub(crate) fn write_head(out: &mut Vec<u8>, target: &Target, request: &Request<'_>) -> Result<bool, EncodeError> {
    match &target.wire {
        Wire::AnthropicMessages(wire) => Ok(anthropic::write_head(out, target, *wire, request)),
        Wire::OpenaiChat(wire) => openai_chat::write_head(out, target, *wire, request),
        Wire::OpenaiResponses(wire) => Ok(openai_responses::write_head(out, target, *wire, request)),
    }
}

/// Write the element of the group of blocks that starts at `start`, and return the end of the group. Write
/// nothing when the protocol drops the group. `marker` is the block that carries the cache marker.
pub(crate) fn write_group(
    elements: &mut Elements<'_>,
    target: &Target,
    request: &Request<'_>,
    start: usize,
    marker: Option<usize>,
) -> Result<usize, EncodeError> {
    match &target.wire {
        Wire::AnthropicMessages(_) => anthropic::write_group(elements, target, request, start, marker),
        Wire::OpenaiChat(wire) => openai_chat::write_group(elements, target, *wire, request, start),
        Wire::OpenaiResponses(_) => openai_responses::write_group(elements, target, request, start, marker),
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

/// Report whether a Responses request declares a deferred tool. The elements read it, so a change encodes them
/// again.
pub(crate) fn defers_tools(request: &Request<'_>) -> bool {
    openai_responses::defers_tools(request.tools)
}
