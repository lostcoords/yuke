//! Build a provider request from a round snapshot and apply its request hooks.

const std = @import("std");
const proto = @import("proto");
const ai = @import("ai");
const Engine = @import("Engine.zig");
const RunSlot = @import("run.zig").RunSlot;
const provider = @import("../provider/provider.zig");
const registry = @import("../provider/registry.zig");
const config = @import("request_config.zig");
const context = @import("context.zig");

/// The round arena owns the route, model, and hook result across compaction.
pub const Snapshot = struct {
    route: registry.Route,
    model: registry.ModelSpec,
    build: config.RequestBuild,
    budget: context.Budget,
};

/// Copy the provider state before the build hook can suspend the task.
pub fn snapshot(
    arena: std.mem.Allocator,
    engine: *Engine,
    slot: *RunSlot,
    r: registry.Match,
) !Snapshot {
    // A provider the merge could not complete has no route, so it cannot serve a turn.
    const live_route = switch (r.provider.availability) {
        .ready => |ready| ready,
        .unavailable => return error.UnknownModel,
    };
    // The registry and the tool table can rebuild while a build hook waits, so this round holds its own copies.
    const route = try proto.dupe(arena, live_route);
    const model = try proto.dupe(arena, r.model.*);
    slot.protocol = provider.protocolToProto(route.route.protocol);

    const build = try config.buildConfig(arena, engine, slot, &model);

    const budget = try context.Budget.forRequest(model.limits.context_window, build.max_output_tokens, build.system, build.tools);
    return .{ .route = route, .model = model, .build = build, .budget = budget };
}

/// Serialize the accepted context and apply the send hook.
pub fn prepare(arena: std.mem.Allocator, engine: *Engine, slot: *RunSlot, held: Snapshot, projected: context.Projection) !ai.PreparedRequest {
    const route = held.route;
    const model = held.model;
    const build = held.build;
    var blobs: BlobReader = .{ .arena = arena, .io = engine.deps.io, .store = engine.deps.blobs };
    const request_ir = try provider.request_builder.build(arena, projected.messages, .{
        .target = .{ .protocol = route.route.protocol, .model = slot.config.model },
        .modalities = model.modalities,
        .blobs = blobs.lookup(),
    });

    // Read the credential here, so a rotated key or a lapsed grant takes effect on the next round.
    const secret = registry.credential(route.credential, engine.deps.execution.env, engine.nowMillis()) orelse return error.MissingCredential;
    // The serializer and the header builder both copy this, so it only has to outlive `prepare`.
    const session_hex = std.fmt.bytesToHex(slot.sessionId().raw, .lower);
    var prepared = try ai.prepare(engine.deps.gpa, .{
        .id = build.model,
        .route = route.route,
        .credential = secret,
        .caps = model.caps,
        .dialect = model.dialect,
    }, .{
        .blocks = request_ir.blocks,
        .system = build.system,
        .tools = build.tools,
        .options = .{
            .max_output_tokens = build.max_output_tokens,
            // The budget shares the ceiling, so it follows whatever the chain left there.
            .reasoning = try config.reasoningFor(&model, slot.config.reasoning, build.max_output_tokens),
            // Every round of one session repeats a prefix, so the session id keeps them on one cache.
            .cache_key = &session_hex,
            // The ChatGPT backend reads the header, not the body key, so both carry the same id.
            .session_id = &session_hex,
        },
    });
    errdefer prepared.deinit();

    // The round arena outlives the prepared request, so a replaced field may live in it.
    switch (engine.deps.hooks.askIfHeld(arena, .@"request.send", RequestSend{
        .url = prepared.transport_request.url,
        .headers = prepared.transport_request.headers,
        .body = prepared.transport_request.body,
    })) {
        .proceed => {},
        .replace => |value| if (std.json.parseFromValueLeaky(RequestSend, arena, value, .{ .ignore_unknown_fields = true })) |sent| {
            prepared.transport_request = .{
                .url = sent.url,
                .headers = sent.headers,
                // An HTTP writer shifts the body it sends, so it needs bytes it may write to.
                .body = try arena.dupe(u8, sent.body),
            };
        } else |_| {},
        .block => |reason| {
            std.log.warn("run {d} stopped at request.send: {s}", .{ slot.runId(), reason });
            return error.HookBlocked;
        },
        .canceled => return error.Canceled,
    }
    return prepared;
}

/// The serialized request one round sends. A `request.send` handler may replace any field.
const RequestSend = struct {
    url: []const u8,
    headers: []const ai.instance.Header,
    body: []const u8,
};

/// Read admitted blobs into the round arena, so the bytes outlive serialization.
const BlobReader = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    store: @import("../store/store.zig").blob.Store,

    fn lookup(self: *const BlobReader) provider.request_builder.BlobLookup {
        return .{ .context = self, .getFn = get };
    }

    fn get(ctx: *const anyopaque, hash: proto.ids.BlobHash) error{ OutOfMemory, Canceled }!?[]const u8 {
        const self: *const BlobReader = @ptrCast(@alignCast(ctx));
        return self.store.read(self.io, self.arena, hash) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => |e| return e,
            // A missing blob after admission means the store is corrupt. The builder reports an unresolved blob.
            error.BlobMissing => null,
        };
    }
};
