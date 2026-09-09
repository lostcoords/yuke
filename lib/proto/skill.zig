//! Skills: instruction files a session lists at creation and loads by name.

const std = @import("std");
const ids = @import("ids.zig");
const instructions = @import("instructions.zig");

/// The session snapshots this catalog entry at creation. The loader reads the body at invocation.
pub const SkillInfo = struct {
    name: []const u8,
    description: []const u8,
    scope: instructions.InstructionScope,
    path: []const u8,
    canonical_path: []const u8,
};

/// These are the parameters for `skill.load`.
pub const SkillLoadParams = struct {
    session_id: ids.SessionId,
    name: []const u8,
};

/// This result carries the body of one skill without its frontmatter.
pub const SkillLoadResult = struct {
    body: []const u8,
    /// This directory holds SKILL.md. Relative paths in the body resolve against it.
    directory: []const u8,
    scope: instructions.InstructionScope,
    path: []const u8,
    /// The model sees this form: the body inside `skill_content` with the directory line.
    content: []const u8,
};

const testing = std.testing;

test "skill load parameters reject a missing name and an unknown scope" {
    const a = testing.allocator;
    try testing.expectError(error.MissingField, std.json.parseFromSlice(SkillLoadParams, a, "{\"session_id\":\"" ++ "ab" ** 16 ++ "\"}", .{}));
    const parsed = try std.json.parseFromSlice(SkillLoadParams, a, "{\"session_id\":\"" ++ "ab" ** 16 ++ "\",\"name\":\"pdf\"}", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("pdf", parsed.value.name);
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(SkillInfo, a, "{\"name\":\"a\",\"description\":\"b\",\"scope\":\"project\",\"path\":\"/p\",\"canonical_path\":\"/p\"}", .{}));
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(SkillLoadParams, a, "{\"session_id\":\"" ++ "ab" ** 16 ++ "\",\"name\":7}", .{}));
    try testing.expectError(error.MissingField, std.json.parseFromSlice(SkillLoadParams, a, "{\"name\":\"pdf\"}", .{}));
}
