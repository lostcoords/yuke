//! A request validates the IR and writes it in the wire shape of one closed protocol.

const std = @import("std");
const ir = @import("request/ir.zig");
const anthropic = @import("request/anthropic.zig");
const openai_chat = @import("request/openai_chat.zig");
const openai_responses = @import("request/openai_responses.zig");

/// Validate and serialize one request into `arena`, which must outlive the returned body. The wire tag selects the protocol.
pub fn serialize(arena: std.mem.Allocator, request: ir.Request, blocks: []const ir.Block) ![]u8 {
    try ir.validate(arena, request, blocks);
    var body: std.Io.Writer.Allocating = .init(arena);
    const written = switch (request.wire) {
        .anthropic_messages => anthropic.serialize(&body.writer, request, blocks),
        .openai_chat => openai_chat.serialize(&body.writer, request, blocks),
        .openai_responses => openai_responses.serialize(&body.writer, request, blocks),
    };
    written catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    return body.written();
}
