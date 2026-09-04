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

/// Validate one request, then serialize it into the body `protocol` expects with `arena`.
pub fn serialize(arena: std.mem.Allocator, protocol: types.Protocol, request: ir.Request, request_ir: ir.RequestIr) ![]u8 {
    try ir.validate(arena, request, request_ir);
    var body: std.Io.Writer.Allocating = .init(arena);
    switch (protocol) {
        inline else => |value| try Adapter(value).serialize(&body.writer, request, request_ir),
    }
    return body.written();
}
