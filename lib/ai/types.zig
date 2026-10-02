//! Provider-neutral types for AI model calls.

pub const Protocol = enum { anthropic_messages, openai_chat, openai_responses };

/// `pause` is an Anthropic server-tool loop that stopped at its iteration cap; the same content resumes it.
pub const FinishReason = enum { stop, length, content_filter, refusal, tool_calls, pause, unknown };

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

/// Where media bytes come from.
pub const MediaSource = union(enum) {
    /// Bytes in the caller's store. The serializer reads them through the request `BlobReader` only when it writes the element.
    blob: Blob,
    /// A URL the provider fetches for itself.
    url: []const u8,
    /// A handle the provider's own files endpoint returned.
    file_id: []const u8,
};

/// Bytes in the caller's store, named by the digest of their content. Equal digests name equal bytes, so a resumed history reads no kept blob.
pub const Blob = struct {
    /// The digest of the content, such as its SHA-256.
    digest: [32]u8,
    /// The byte count of the content. The request limits count it before a read.
    len: usize,
};

/// The caller's store of blob bytes. The serializer borrows each answer, so the bytes must stay valid until `serialize` returns.
pub const BlobReader = struct {
    ctx: *const anyopaque,
    /// Answer the bytes of `digest`, or `UnresolvedBlob` when the store lacks them.
    readFn: *const fn (ctx: *const anyopaque, digest: [32]u8) ReadError![]const u8,

    /// The store lacks the bytes, or the read fails.
    pub const ReadError = error{ OutOfMemory, Canceled, UnresolvedBlob };

    /// Answer the bytes of `blob`. Bytes of another length fail with `UnresolvedBlob`, because the request limits count `len`.
    pub fn read(self: BlobReader, blob: Blob) ReadError![]const u8 {
        const bytes = try self.readFn(self.ctx, blob.digest);
        if (bytes.len != blob.len) return error.UnresolvedBlob;
        return bytes;
    }
};

pub const limits = struct {
    pub const max_string_bytes: usize = 1 << 20;
    /// The ChatGPT host answers 400 for a longer cache key.
    pub const max_cache_key_bytes: usize = 64;
    pub const max_response_bytes: usize = 16 << 20;
    /// Bound the input bytes one request carries, before a serializer reads them.
    pub const max_request_bytes: usize = 64 << 20;
    pub const max_media_bytes: usize = 32 << 20;
};
