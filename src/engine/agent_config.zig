//! The profile model map uses a file lock and a content revision for edits.

const std = @import("std");
const proto = @import("proto");
const paths = @import("../paths.zig");
const provider = @import("../provider/provider.zig");
const model_config = @import("model_config.zig");
const Engine = @import("Engine.zig");
const Wire = proto.agents;
const max_file_bytes = 64 * 1024;

/// One edit at a time per engine; the file lock serializes other processes.
pub const Store = struct {
    mutex: std.Io.Mutex = .init,
};

pub fn get(engine: *Engine, arena: std.mem.Allocator) !Wire.AgentsGetResult {
    return read(engine, arena);
}

pub fn update(engine: *Engine, arena: std.mem.Allocator, params: Wire.AgentsUpdateParams) !Wire.AgentsGetResult {
    try engine.agents.mutex.lock(engine.deps.io);
    defer engine.agents.mutex.unlock(engine.deps.io);
    const path = (try configPath(arena, engine.deps.io, engine.deps.env)) orelse return error.AgentConfigDirectoryMissing;
    const parent = std.fs.path.dirname(path).?;
    std.Io.Dir.cwd().createDirPath(engine.deps.io, parent) catch return error.AgentConfigSaveFailed;
    const lock_path = try std.mem.concat(arena, u8, &.{ path, ".lock" });
    const lock = std.Io.Dir.createFileAbsolute(engine.deps.io, lock_path, .{ .truncate = false, .permissions = .fromMode(0o600) }) catch return error.AgentConfigSaveFailed;
    defer lock.close(engine.deps.io);
    try lock.lock(engine.deps.io, .exclusive);
    const current = try read(engine, arena);
    if (!std.mem.eql(u8, &current.revision.raw, &params.revision.raw)) return error.AgentConfigConflict;
    // A slot names no level, so the update validates each model with its own default level.
    for ([_]Wire.AgentModelSlot{ .small, .medium }) |slot| if (params.config.models.get(slot)) |entry| {
        _ = try model_config.validate(engine, arena, entry.model, .default);
    };
    const bytes = try std.json.Stringify.valueAlloc(arena, params.config, .{ .emit_null_optional_fields = false, .whitespace = .indent_2 });
    const result = try parse(arena, path, bytes);
    const old = engine.deps.io.swapCancelProtection(.blocked);
    defer _ = engine.deps.io.swapCancelProtection(old);
    provider.config.writeFileBytes(engine.deps.io, path, bytes) catch return error.AgentConfigSaveFailed;
    return result;
}

/// The model one slot names. A read refreshes the map from disk.
pub fn slotModel(engine: *Engine, arena: std.mem.Allocator, slot: Wire.AgentModelSlot) ![]const u8 {
    const current = try read(engine, arena);
    const entry = current.config.models.get(slot) orelse return error.AgentSetupRequired;
    return entry.model;
}

fn configPath(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !?[]const u8 {
    const directory = (try paths.configDir(arena, env)) orelse return null;
    const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(io, directory, arena) catch |err| switch (err) {
        error.FileNotFound => directory,
        else => return err,
    };
    return try std.fs.path.join(arena, &.{ canonical, "agents.json" });
}

fn read(engine: *Engine, arena: std.mem.Allocator) !Wire.AgentsGetResult {
    const path = try configPath(arena, engine.deps.io, engine.deps.env);
    const file = std.Io.Dir.openFileAbsolute(engine.deps.io, path orelse return parse(arena, null, "{}"), .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return parse(arena, path, "{}"),
        else => return error.AgentConfigReadFailed,
    };
    defer file.close(engine.deps.io);
    const stat = try file.stat(engine.deps.io);
    if (stat.kind != .file or stat.size > max_file_bytes) return error.BadAgentConfig;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(engine.deps.io, &buffer);
    const bytes = reader.interface.allocRemaining(arena, .limited(max_file_bytes)) catch return error.AgentConfigReadFailed;
    return parse(arena, path, bytes);
}

/// The revision is the SHA-256 of the file bytes, so a stale writer conflicts.
pub fn parse(arena: std.mem.Allocator, path: ?[]const u8, bytes: []const u8) !Wire.AgentsGetResult {
    if (bytes.len == 0 or bytes.len > max_file_bytes) return error.BadAgentConfig;
    const config = std.json.parseFromSliceLeaky(Wire.AgentsConfig, arena, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.BadAgentConfig,
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .path = path, .revision = .bytes(digest), .config = config };
}
