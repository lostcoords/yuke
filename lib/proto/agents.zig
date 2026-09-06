//! Explicit subagent model slots and revision-checked configuration.

const std = @import("std");
const ids = @import("ids.zig");

pub const AgentModelSlot = enum { small, medium };

pub const AgentModel = struct {
    model: []const u8,
    reasoning: ?[]const u8 = null,
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
            if (model.reasoning) |level| if (level.len > 256) return error.InvalidCharacter;
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

pub const AgentsResolveParams = struct { model: AgentModelSlot };

pub const AgentsResolveResult = struct {
    slot: AgentModelSlot,
    model: []const u8,
    reasoning: []const u8,
    revision: ids.AgentConfigRev,
};

pub const AgentsSetModelParams = struct {
    session_id: ids.SessionId,
    model: AgentModel,
};

test "slot resolution requires a closed explicit model" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "{}", "{\"model\":null}", "{\"model\":\"large\"}", "{\"model\":\"provider/model\"}" }) |json| {
        if (std.json.parseFromSlice(AgentsResolveParams, a, json, .{})) |parsed| {
            parsed.deinit();
            return error.AcceptedInvalidSlot;
        } else |_| {}
    }
    for ([_][]const u8{ "{\"model\":\"small\"}", "{\"model\":\"medium\"}" }) |json| {
        const parsed = try std.json.parseFromSlice(AgentsResolveParams, a, json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.model == .small or parsed.value.model == .medium);
    }
}
