//! Provider-neutral types for AI model calls.

pub const Protocol = enum { anthropic_messages, openai_chat, openai_responses };

pub const FinishReason = enum { stop, length, content_filter, refusal, tool_calls, unknown };

pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    reasoning: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
};

pub const ModelIdentity = struct {
    protocol: Protocol,
    model: []const u8,
};

pub const MediaSource = union(enum) {
    blob: Blob,

    pub const Blob = struct {
        hash: [64]u8,
        mime: []const u8,
        bytes: u64,
    };
};

pub const limits = struct {
    pub const max_blocks: usize = 1024;
    pub const max_string_bytes: usize = 1 << 20;
    pub const max_response_bytes: usize = 16 << 20;
};
