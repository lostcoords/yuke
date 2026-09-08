//! Instruction source metadata for session inspection.

const ids = @import("ids.zig");

pub const InstructionScope = enum { global, workspace };

pub const InstructionSource = struct {
    scope: InstructionScope,
    path: []const u8,
    canonical_path: []const u8,
    content_hash: ids.InstructionHash,
};

test "instruction sources reject unknown scope and invalid hashes" {
    const std = @import("std");
    const a = std.testing.allocator;
    const valid = "{\"scope\":\"workspace\",\"path\":\"/work/AGENTS.md\",\"canonical_path\":\"/work/AGENTS.md\",\"content_hash\":\"" ++ "ab" ** 32 ++ "\"}";
    const parsed = try std.json.parseFromSlice(InstructionSource, a, valid, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(InstructionScope.workspace, parsed.value.scope);
    const bad_scope = "{\"scope\":\"nested\",\"path\":\"/work/AGENTS.md\",\"canonical_path\":\"/work/AGENTS.md\",\"content_hash\":\"" ++ "ab" ** 32 ++ "\"}";
    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(InstructionSource, a, bad_scope, .{}));
    const bad_hash = "{\"scope\":\"global\",\"path\":\"/a\",\"canonical_path\":\"/a\",\"content_hash\":\"" ++ "AB" ** 32 ++ "\"}";
    try std.testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(InstructionSource, a, bad_hash, .{}));
}
