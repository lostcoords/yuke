package provider

// Why a generation ended, normalized across protocols. Protocol decoders are
// the real consumers; the engine only forwards it.
Stop_Reason :: enum {
    // Model finished its answer.
    End_Turn,

    // Model asked for tools. Completed calls arrive in their ordered
    // `Stream_Block_Stopped` events before the terminal event.
    Tool_Calls,

    // Output token budget ran out mid-answer.
    Max_Tokens,

    // A configured stop sequence matched.
    Stop_Sequence,

    // Provider-side content filter cut the generation.
    Content_Filter,

    // Provider reason has no faithful neutral mapping. This is distinct from a
    // natural end: callers must not infer successful completion semantics.
    Unknown,
}

// Token accounting for one turn, surfaced only on `Stream_Done`: providers
// deliver it in a chunk of its own, so decoders buffer it until the end.
//
// `input` is the billed input total *including* cached tokens (Anthropic folds
// `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`, with
// `cache_read` kept as a subset rather than an addition). `total` is
// `input + output` for Anthropic and `max(provider_total, input + output)` for
// OpenAI.
Usage :: struct {
    // Billed input tokens, cached tokens included.
    input:       u64,

    // Billed output tokens.
    output:      u64,

    // Output tokens spent on reasoning, a subset of `output`.
    reasoning:   u64,

    // Input tokens served from the prompt cache, a subset of `input`.
    cache_read:  u64,

    // Input tokens written into the prompt cache.
    cache_write: u64,

    // Billed total; see the folding rules above.
    total:       u64,
}

// Upper bound on tool calls assembled in one turn. A stream that exceeds it
// fails with `.Too_Many_Tool_Calls` rather than growing without limit.
MAX_TOOL_CALLS :: 64

// Upper bound on one tool call's accumulated argument JSON, in bytes. Exceeding
// it fails the turn with `.Tool_Call_Too_Large`.
MAX_TOOL_CALL_BYTES :: 4 * 1024 * 1024

// One tool invocation requested by the model.
Tool_Call :: struct {
    // Provider-issued call id, echoed back on the tool result.
    id:        string,

    // Required tool name from the provider block start.
    name:      string,

    // Raw JSON object text of the arguments, accumulated from fragments and
    // structurally validated without rewriting. Empty accumulations become
    // `{}`.
    arguments: string,
}

// Turn-local identity for one ordered assistant content block. It correlates
// deltas and completion with a prior start; it is not a provider id or a wire
// `Part_Id`.
Stream_Block_Id :: distinct u64

// Closed neutral set of assistant block shapes supported by the wire.
Stream_Block_Kind :: enum {
    Text,
    Reasoning,
    Redacted_Reasoning,
    Tool,
}

// Opens one assistant block. Starts arrive in content order; a consumer maps
// that order to its own part ordinals.
Stream_Block_Started :: struct {
    // Turn-local block identity.
    block_id: Stream_Block_Id,

    // Shape that the matching completion must carry.
    kind:     Stream_Block_Kind,
}

// A run of assistant text.
Stream_Text_Delta :: struct {
    // Open text block receiving these bytes.
    block_id: Stream_Block_Id,

    // Text to append to the active text part; never empty.
    text:     string,
}

// A run of reasoning text.
Stream_Reasoning_Delta :: struct {
    // Open reasoning block receiving these bytes.
    block_id: Stream_Block_Id,

    // Text to append to the active reasoning part; never empty.
    text:     string,
}

// A completed text block carries no terminal metadata.
Stream_Text_Block :: struct {}

// Terminal metadata for a visible reasoning block.
Stream_Reasoning_Block :: struct {
    // Opaque provider signature, empty when none was issued.
    signature: string,
}

// Terminal metadata for a safety-redacted reasoning block.
Stream_Redacted_Reasoning_Block :: struct {
    // Opaque encrypted provider data, preserved exactly.
    data: string,
}

// Terminal metadata for a tool-use block.
Stream_Tool_Block :: struct {
    // Complete call with structurally valid argument JSON.
    call: Tool_Call,
}

// Closed result shape for one completed block.
Stream_Block_Result :: union {
    // Text completion with no terminal metadata.
    Stream_Text_Block,

    // Visible reasoning completion and its provider signature.
    Stream_Reasoning_Block,

    // Opaque provider-redacted reasoning completion.
    Stream_Redacted_Reasoning_Block,

    // Complete tool invocation.
    Stream_Tool_Block,
}

// Closes one previously started block. Every retained string borrows the turn
// arena, like delta strings.
Stream_Block_Stopped :: struct {
    // Turn-local identity of the block being closed.
    block_id: Stream_Block_Id,

    // Result whose arm must match the start kind.
    result:   Stream_Block_Result,
}

// Terminal event of a turn, emitted at most once.
Stream_Done :: struct {
    // Normalized stop reason.
    reason: Stop_Reason,

    // Token accounting for the whole turn.
    usage:  Usage,
}

// One neutral step of a generation. A provider event or transport EOF maps to
// zero or more of these, and every string borrows the turn arena. Deltas are
// never empty — the engine derives time-to-first-token and its "discard the
// partial on retry" signal from the arrival of any non-empty delta.
Stream_Event :: union {
    // Establish one ordered block's identity and shape.
    Stream_Block_Started,

    // Append bytes to an open text block.
    Stream_Text_Delta,

    // Append bytes to an open visible-reasoning block.
    Stream_Reasoning_Delta,

    // Close one block with complete terminal metadata.
    Stream_Block_Stopped,

    // Complete the provider turn after all blocks have closed.
    Stream_Done,
}
