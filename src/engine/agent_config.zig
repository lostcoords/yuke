//! The profile model map uses a file lock and a content revision for edits.

const std = @import("std");
const proto = @import("proto");
const paths = @import("../paths.zig");
const provider = @import("../provider/provider.zig");
const registry = @import("../provider/registry.zig");
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
    for ([_]Wire.AgentModelSlot{ .small, .medium }) |slot| if (params.config.models.get(slot)) |entry| {
        _ = try validate(engine, arena, entry);
    };
    const bytes = try std.json.Stringify.valueAlloc(arena, params.config, .{ .emit_null_optional_fields = false, .whitespace = .indent_2 });
    const result = try parse(arena, path, bytes);
    const old = engine.deps.io.swapCancelProtection(.blocked);
    defer _ = engine.deps.io.swapCancelProtection(old);
    provider.config.writeFileBytes(engine.deps.io, path, bytes) catch return error.AgentConfigSaveFailed;
    return result;
}

/// A read refreshes the map; a model check uses the current provider snapshot.
pub fn resolve(engine: *Engine, arena: std.mem.Allocator, params: Wire.AgentsResolveParams) !Wire.AgentsResolveResult {
    const current = try read(engine, arena);
    const entry = current.config.models.get(params.model) orelse return error.AgentSetupRequired;
    const reasoning = try validate(engine, arena, entry);
    return .{ .slot = params.model, .model = entry.model, .reasoning = reasoning, .revision = current.revision };
}

fn validate(engine: *Engine, arena: std.mem.Allocator, entry: Wire.AgentModel) ![]const u8 {
    const match = engine.deps.providers.merged.resolveModel(entry.model) orelse return error.AgentUnknownModel;
    if (match.provider.availability == .unavailable) return switch (match.provider.availability.unavailable) {
        .needs_route => error.AgentRouteUnavailable,
        .needs_credential, .expired => error.AgentProviderUnavailable,
    };
    if (registry.credential(match.provider.availability.ready.credential, engine.deps.env, engine.nowMillis()) == null) return error.AgentProviderUnavailable;
    if (match.model.caps.tools != true) return error.AgentToolsUnsupported;
    const normal = try registry.defaultLevel(arena, match.model.*);
    const level = entry.reasoning orelse normal;
    if (level.len > 0) {
        for (try registry.levelNames(arena, match.model.*)) |candidate| if (std.mem.eql(u8, level, candidate)) return arena.dupe(u8, level);
        return error.AgentReasoningUnsupported;
    }
    if (normal.len != 0) return error.AgentReasoningUnsupported;
    return "";
}

fn configPath(arena: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) !?[]const u8 {
    const directory = (try paths.configDir(arena, env orelse return null)) orelse return null;
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

/// A saved slot edit affects future children; an explicit edit changes one idle child.
pub fn setModel(engine: *Engine, arena: std.mem.Allocator, params: Wire.AgentsSetModelParams) !proto.session.SessionConfigResult {
    try engine.own(params.session_id);
    const store = @import("../store/store.zig");
    const row = (try store.session.snapshot(engine.deps.db, arena, params.session_id.raw)) orelse return error.UnknownSession;
    if (row.parent_id == null) return error.BadChild;
    if (engine.sessions.get(params.session_id)) |resident| if (resident.active_run != null) return error.SessionBusy;
    const reasoning = try validate(engine, arena, params.model);
    const marks = (try store.event.highWater(engine.deps.db, arena, params.session_id.raw)).?;
    const config: proto.run.RunConfig = .{ .config_rev = marks.config_rev_high + 1, .model = params.model.model, .reasoning = reasoning };
    var tx = try engine.deps.db.begin();
    defer tx.deinit();
    const seq = try store.config.appendConfig(engine.deps.db, arena, params.session_id.raw, engine.newId(), engine.nowMillis(), config);
    try tx.commit();
    const note: proto.rpc.Notification = .{ .method = .@"config.changed", .params = .{ .config_changed_data = .{ .session_id = params.session_id, .seq = seq, .config = config } } };
    const events = @import("events.zig");
    if (engine.sessions.get(params.session_id)) |resident| events.emitDurable(engine, resident, note) else engine.sinks.emit(note);
    events.announceSummary(engine, params.session_id);
    return .{ .config = config };
}
