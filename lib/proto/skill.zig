//! Skills: instruction files a session lists at creation. The model reads SKILL.md; `/skill:name` injects the body.

const instructions = @import("instructions.zig");

/// The session snapshots this catalog entry at creation. The loader reads the body at invocation.
pub const SkillInfo = struct {
    name: []const u8,
    description: []const u8,
    scope: instructions.InstructionScope,
    path: []const u8,
    canonical_path: []const u8,
};
