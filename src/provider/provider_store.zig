//! One type owns the local `providers.json` file and the merged view it produces.

const std = @import("std");
const ai = @import("ai");
const provider = @import("provider.zig");
const provider_registry = @import("registry.zig");

gpa: std.mem.Allocator,
io: std.Io,
env: *const std.process.Environ.Map,
/// The engine owns this path and frees it. Null means no config directory exists.
path: ?[]u8 = null,
/// The refresh lock in the data directory. Set together with `path`; null means no lock.
lock_path: ?[]u8 = null,
/// The `providers.json` layer. Replace it only through `edit`.
local: ?provider.config.Loaded = null,
/// One merged snapshot serves catalog reads and provider requests.
merged: provider_registry.Registry,
/// One credential edit at a time. The file write yields, so a second edit would lose an update.
edit_lock: std.Io.Mutex = .init,

pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) @This() {
    return .{ .gpa = gpa, .io = io, .env = env, .merged = .init(gpa) };
}

pub fn deinit(self: *@This()) void {
    self.merged.deinit();
    if (self.local) |*loaded| loaded.deinit();
    if (self.path) |owned| self.gpa.free(owned);
    if (self.lock_path) |owned| self.gpa.free(owned);
    self.* = undefined;
}

/// One change to one provider entry. The engine performs no other credential mutation.
pub const Edit = union(enum) {
    set_api_key: []const u8,
    set_grant: provider.config.Grant,
    remove_credential,
};

/// Apply one edit and install the result, so no caller builds a layer from a stale read.
pub fn edit(self: *@This(), arena: std.mem.Allocator, provider_id: []const u8, change: Edit) !bool {
    const path = self.path orelse return error.NoConfigDirectory;
    // Two clients can edit at once, so the read, the write, and the install are one critical section.
    try self.edit_lock.lock(self.io);
    defer self.edit_lock.unlock(self.io);

    var next: std.ArrayList(provider.config.LocalProvider) = .empty;
    var found = false;
    if (self.local) |loaded| for (loaded.providers) |p| {
        if (!std.mem.eql(u8, p.id, provider_id)) {
            try next.append(arena, p);
            continue;
        }
        found = true;
        if (applyTo(p, change)) |kept| try next.append(arena, kept);
    };
    if (!found) {
        if (change == .remove_credential) return error.UnknownProvider;
        // The catalog completes an entry the file does not name yet.
        try next.append(arena, applyTo(.{ .id = provider_id }, change).?);
    }

    return self.install(next.items, path);
}

/// Return the entry one edit produces, or null to drop it entirely.
fn applyTo(p: provider.config.LocalProvider, change: Edit) ?provider.config.LocalProvider {
    var out = p;
    switch (change) {
        .set_api_key => |key| out.auth = .{ .api_key = .{ .source = .{ .literal = key } } },
        .set_grant => |grant| out.auth = .{ .oauth = grant },
        .remove_credential => {
            // The entry holds nothing else, so it goes with its credential.
            if (onlyCredential(p)) return null;
            // An API-key entry still states that the route wants a key; a grant leaves nothing to state.
            out.auth = if (p.auth) |a| switch (a) {
                .api_key => .{ .api_key = .{} },
                .oauth => null,
            } else null;
        },
    }
    return out;
}

/// Report whether an entry carries only its credential, so removing that leaves nothing to keep.
fn onlyCredential(p: provider.config.LocalProvider) bool {
    if (p.base_url != null or p.session_header != null or p.endpoints != null) return false;
    if (p.headers != null or p.models.len != 0) return false;
    // A keyless entry states that the route needs nothing, so it is configuration.
    return switch (p.auth orelse return false) {
        .api_key => |key| key.source != null,
        .oauth => true,
    };
}

test "removing a credential keeps every route field and drops an entry that held nothing else" {
    const key: provider.config.LocalAuth = .{ .api_key = .{ .source = .{ .literal = "k" } } };
    // An entry that holds only its credential goes with it.
    try std.testing.expect(applyTo(.{ .id = "p", .auth = key }, .remove_credential) == null);
    try std.testing.expect(applyTo(.{ .id = "p", .auth = .{ .oauth = .{ .access_token = "t", .expires_at_ms = 1 } } }, .remove_credential) == null);

    // Each route field is configuration the user wrote, so the entry stays and only the value goes.
    const endpoints = [_]ai.route.Endpoint{.{ .protocol = .openai_chat }};
    const kept = [_]provider.config.LocalProvider{
        .{ .id = "p", .auth = key, .base_url = "https://p.example/v1" },
        .{ .id = "p", .auth = key, .session_header = .x_opencode_session },
        .{ .id = "p", .auth = key, .endpoints = &endpoints },
        .{ .id = "p", .auth = key, .endpoints = &.{} },
        .{ .id = "p", .auth = key, .headers = &.{} },
    };
    for (kept) |entry| {
        const out = applyTo(entry, .remove_credential).?;
        try std.testing.expect(out.auth.?.api_key.source == null); // The route still wants a key.
    }
    // A key that replaces a grant keeps the entry shape the user wrote.
    const swapped = applyTo(.{ .id = "p", .auth = key, .base_url = "https://p.example/v1" }, .{ .set_api_key = "k2" }).?;
    try std.testing.expectEqualStrings("k2", swapped.auth.?.api_key.source.?.literal);
}

/// Drop one grant from the layer in memory without a write; a rotation whose result cannot reach disk still spent its refresh token, so the engine must never send it again, while the file keeps the old grant until a restart reads it back.
pub fn forgetGrant(self: *@This(), provider_id: []const u8) void {
    const loaded = if (self.local) |*local| local else return;
    for (loaded.providers) |*p| {
        if (!std.mem.eql(u8, p.id, provider_id)) continue;
        if (p.auth) |*auth| switch (auth.*) {
            // The strings belong to the layer arena, so dropping them frees nothing here.
            .oauth => |*grant| {
                grant.refresh_token = null;
                grant.expires_at_ms = 0;
            },
            .api_key => {},
        };
        return;
    }
}

/// Render the layer, parse it, write it, then install it. A document that cannot load never lands.
fn install(self: *@This(), providers: []const provider.config.LocalProvider, path: []const u8) !bool {
    const bytes = try provider.config.serialize(self.gpa, providers);
    defer self.gpa.free(bytes);

    var next = try provider.config.loadBytes(self.gpa, bytes);
    errdefer next.deinit();
    // Build the replacement before the write; a later failure would leave the file ahead of memory, and the next edit would then serialize the stale layer back over the file.
    var next_merged = try self.load(&next);
    errdefer next_merged.deinit();
    try provider.config.writeFileBytes(self.io, path, bytes);

    var previous = self.local;
    self.local = next;
    defer if (previous) |*loaded| loaded.deinit();
    return self.swap(next_merged);
}

/// Install a layer the caller already built and wrote. Startup and a test seed use this.
pub fn installLocal(self: *@This(), next: *provider.config.Loaded) !bool {
    const next_merged = try self.load(next);
    var previous = self.local;
    self.local = next.*;
    next.* = undefined;
    defer if (previous) |*loaded| loaded.deinit();
    return self.swap(next_merged);
}

/// Read `providers.json` again and install it under the edit lock, so a local edit cannot interleave.
pub fn reload(self: *@This()) !bool {
    const path = self.path orelse return false;
    try self.edit_lock.lock(self.io);
    defer self.edit_lock.unlock(self.io);

    var next = try provider.config.load(self.gpa, self.io, path);
    errdefer next.deinit();
    return self.installLocal(&next);
}

/// Rebuild the merged view from the layers the store already holds.
pub fn rebuild(self: *@This()) !bool {
    const next = try self.load(if (self.local) |*loaded| loaded else null);
    return self.swap(next);
}

fn load(self: *@This(), local: ?*provider.config.Loaded) !provider_registry.Registry {
    return provider_registry.Registry.load(self.gpa, .{ .local = local, .env = self.env });
}

/// Take the replacement and free the live view, because a direct assignment frees live routes.
fn swap(self: *@This(), next: provider_registry.Registry) bool {
    const changed = !std.mem.eql(u8, &self.merged.revision.raw, &next.revision.raw);
    var previous = self.merged;
    self.merged = next;
    previous.deinit();
    return changed;
}
