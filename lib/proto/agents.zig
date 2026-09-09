//! Explicit subagent model slots and revision-checked configuration.

const std = @import("std");
const ids = @import("ids.zig");

pub const AgentModelSlot = enum { small, medium };

/// A child inherits its reasoning level from its parent session.
pub const AgentModel = struct {
    model: []const u8,
};

pub const AgentModels = struct {
    small: ?AgentModel = null,
    medium: ?AgentModel = null,

    pub fn get(self: @This(), slot: AgentModelSlot) ?AgentModel {
        return switch (slot) {
            .small => self.small,
            .medium => self.medium,
        };
    }
};

pub const AgentsConfig = struct {
    models: AgentModels = .{},

    pub fn jsonParse(a: std.mem.Allocator, s: anytype, o: std.json.ParseOptions) !@This() {
        return jsonParseFromValue(a, try std.json.Value.jsonParse(a, s, o), o);
    }

    /// A config file is strict, unlike the lenient wire: an unknown field is a typo.
    pub fn jsonParseFromValue(a: std.mem.Allocator, value: std.json.Value, o: std.json.ParseOptions) !@This() {
        var strict = o;
        strict.ignore_unknown_fields = false;
        const parsed = try std.json.parseFromValueLeaky(struct { models: AgentModels = .{} }, a, value, strict);
        for ([_]?AgentModel{ parsed.models.small, parsed.models.medium }) |entry| if (entry) |model| {
            if (model.model.len == 0 or model.model.len > 4096) return error.InvalidCharacter;
        };
        return .{ .models = parsed.models };
    }
};

pub const AgentsGetResult = struct {
    path: ?[]const u8 = null,
    revision: ids.AgentConfigRev,
    config: AgentsConfig,
};

pub const AgentsUpdateParams = struct {
    revision: ids.AgentConfigRev,
    config: AgentsConfig,
};
