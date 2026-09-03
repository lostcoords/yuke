//! Skills: reusable prompts a session can invoke by name.

const enums = @import("enums.zig");

/// This type records discovered skill metadata.
pub const SkillInfo = struct {
    name: []const u8,
    description: []const u8,
    /// This scope identifies a project or personal skill.
    scope: enums.SkillScope,
    argument_hint: []const u8,
};

/// This type names a skill and holds its rendered arguments.
pub const SkillRef = struct {
    name: []const u8,
    arguments: []const u8,
};

/// This result lists discovered skills.
pub const SkillsResult = struct {
    /// This field lists discovered skills.
    skills: []const SkillInfo,
};
