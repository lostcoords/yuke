//! A request validates the IR and writes it in the wire shape of one closed protocol.

const std = @import("std");
const ir = @import("request/ir.zig");
const anthropic = @import("request/anthropic.zig");
const openai_chat = @import("request/openai_chat.zig");
const openai_responses = @import("request/openai_responses.zig");

/// Validate one request with scratch from `arena`, then serialize it into a body that the caller frees with `gpa`. The wire tag selects the protocol.
/// It fails on a request that breaks the IR, on content the endpoint cannot carry, and on `OutOfMemory`.
pub fn serialize(gpa: std.mem.Allocator, arena: std.mem.Allocator, request: ir.Request, blocks: []const ir.Block) (ir.ValidateError || ir.Unsupported)!std.ArrayList(u8) {
    try ir.validate(arena, request, blocks);
    var body: std.Io.Writer.Allocating = try .initCapacity(gpa, min_body_capacity);
    errdefer body.deinit();
    const written = switch (request.wire) {
        .anthropic_messages => anthropic.serialize(&body.writer, request, blocks),
        .openai_chat => openai_chat.serialize(&body.writer, request, blocks),
        .openai_responses => openai_responses.serialize(&body.writer, request, blocks),
    };
    written catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return body.toArrayList();
}

/// The first capacity of a body. It is larger than the largest `std.heap.SmpAllocator` class (32 KiB), so the page allocator serves it and mremap grows it with no copy.
const min_body_capacity = 64 * 1024;
