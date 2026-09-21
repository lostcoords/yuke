//! This table binds each closed wire protocol to its serializer and reducer.

const std = @import("std");
const ir = @import("request/ir.zig");
const types = @import("types.zig");
const request_anthropic = @import("request/anthropic.zig");
const request_openai_chat = @import("request/openai_chat.zig");
const request_openai_responses = @import("request/openai_responses.zig");
const stream_anthropic = @import("stream/anthropic.zig");
const stream_openai_chat = @import("stream/openai_chat.zig");
const stream_openai_responses = @import("stream/openai_responses.zig");

pub fn Adapter(comptime protocol: types.Protocol) type {
    return switch (protocol) {
        .anthropic_messages => struct {
            pub const serialize = request_anthropic.serialize;
            pub const Reducer = stream_anthropic.Reducer;
        },
        .openai_chat => struct {
            pub const serialize = request_openai_chat.serialize;
            pub const Reducer = stream_openai_chat.Reducer;
        },
        .openai_responses => struct {
            pub const serialize = request_openai_responses.serialize;
            pub const Reducer = stream_openai_responses.Reducer;
        },
    };
}

/// Validate and serialize one request into `arena`, which must outlive the returned body.
pub fn serialize(arena: std.mem.Allocator, protocol: types.Protocol, request: ir.Request, blocks: []const ir.Block) ![]u8 {
    try ir.validate(arena, request, blocks);
    var body: std.Io.Writer.Allocating = .init(arena);
    switch (protocol) {
        inline else => |value| Adapter(value).serialize(&body.writer, request, blocks) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        },
    }
    return body.written();
}
