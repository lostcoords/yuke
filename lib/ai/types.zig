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

/// One kind a model reads or writes. The reader drops a source name outside this set.
pub const Modality = enum { text, image, audio, video, pdf };

/// What a model takes and what it returns.
pub const Modalities = struct {
    input: []const Modality = &.{},
    output: []const Modality = &.{},

    /// Report whether the model takes this kind, or null when the source lists none.
    pub fn takesInput(self: Modalities, kind: Modality) ?bool {
        if (self.input.len == 0) return null;
        for (self.input) |item| if (item == kind) return true;
        return false;
    }
};

/// Which cache marker a request writes. A host that caches on its own needs none.
pub const CacheMarker = enum { none, anthropic, openai };

/// Where media bytes come from. A caller resolves its own storage before it serializes.
pub const MediaSource = union(enum) {
    /// Raw bytes. The serializer encodes them, and the caller owns them through serialization.
    bytes: []const u8,
    /// A URL the provider fetches for itself.
    url: []const u8,
    /// A handle the provider's own files endpoint returned.
    file_id: []const u8,
};

pub const limits = struct {
    pub const max_blocks: usize = 1024;
    pub const max_string_bytes: usize = 1 << 20;
    pub const max_response_bytes: usize = 16 << 20;
    /// Bound the input bytes one request carries, before a serializer reads them.
    pub const max_request_bytes: usize = 64 << 20;
    pub const max_media_bytes: usize = 32 << 20;
};
