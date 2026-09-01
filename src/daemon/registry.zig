//! Assemble every provider the daemon offers, through two resolvers and no shared merge.

const std = @import("std");
const wire = @import("wire");
const provider = @import("../provider/provider.zig");
const bundle = @import("../cloud/bundle.zig");
const feed = @import("../catalog/feed.zig");
const store = @import("../catalog/store.zig");
const Database = @import("../database/database.zig").Database;

const instance = provider.instance;
const model = provider.model;
pub const ModelSpec = model.ModelSpec;

const EnvMap = std.process.Environ.Map;

/// Which resolver produced a row. The two origins are separate namespaces.
pub const Origin = wire.enums.ProviderSource;

/// This route holds every value that one request needs, and names its credential source.
pub const Route = struct {
    instance: instance.ProviderInstance,
    credential: CredentialSource,
};

/// A run reads the stored grant and its expiry, so it needs no catalog rebuild.
pub const OAuthSource = struct {
    grant: provider.resolve.Credential.OAuth,
    /// The expiry uses Unix milliseconds, and a run at or past it reports a missing credential.
    expires_at_ms: ?u64 = null,
};

/// Name where a run reads the credential. An environment key is read again for every run.
pub const CredentialSource = union(enum) {
    none,
    env: []const u8,
    literal: []const u8,
    oauth: OAuthSource,
};

/// Resolve the credential of one run. A named variable the process lost gives null.
pub fn credential(source: CredentialSource, env: ?*const EnvMap, now_ms: u64) ?provider.resolve.Credential {
    return switch (source) {
        .none => .none,
        .env => |name| blk: {
            // An empty value is no value, so a run reports a missing credential instead of sending a blank header.
            const value = (if (env) |e| e.get(name) else null) orelse return null;
            break :blk if (value.len == 0) null else .{ .api_key = value };
        },
        .literal => |key| .{ .api_key = key },
        .oauth => |stored| blk: {
            // A lapsed grant reports a missing credential, so no run sends a dead bearer.
            if (stored.expires_at_ms) |at| if (now_ms >= at) break :blk null;
            break :blk .{ .oauth = stored.grant };
        },
    };
}

/// Why a provider cannot serve a turn.
pub const Reason = enum {
    /// No credential reached the daemon. The entry names one that the environment does not hold.
    needs_credential,
    /// A routing field is missing, so the daemon cannot build a request.
    needs_route,
    /// The grant expired. The user must authenticate again.
    expired,
    /// The control plane revoked the grant.
    revoked,
};

/// A ready provider carries its route, so a state and a route can never disagree.
pub const Availability = union(enum) {
    ready: Route,
    unavailable: Reason,

    /// Project onto the wire, which reports the same reason under its own name.
    pub fn state(self: Availability) wire.enums.ProviderState {
        return switch (self) {
            .ready => .ready,
            .unavailable => |reason| switch (reason) {
                .needs_credential => .needs_credential,
                .needs_route => .needs_route,
                .expired => .expired,
                .revoked => .revoked,
            },
        };
    }
};

/// One provider the daemon offers.
pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    origin: Origin,
    models: []const ModelSpec,
    availability: Availability,
};

/// One model, and the provider that serves it.
pub const Match = struct {
    provider: *const Provider,
    model: *const ModelSpec,
};

/// The sources one merge reads. Each one is absent when its layer is not configured.
pub const Sources = struct {
    local: ?*const provider.config.Loaded = null,
    account: ?bundle.Document = null,
    catalog: []const feed.Provider = &.{},
    env: ?*const EnvMap = null,
};

/// What one snapshot build needs. `load` reads the stored catalog itself, so it is not a member.
pub const Inputs = struct {
    local: ?*const provider.config.Loaded = null,
    account: ?bundle.Document = null,
    env: ?*const EnvMap = null,
};

/// One provider snapshot. The arena owns the rows, and a route borrows the state-owned sources.
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const Provider = &.{},
    providers: []const wire.catalog.ProviderInfo = &.{},
    models: []const wire.catalog.ModelInfo = &.{},
    revision: wire.ids.CatalogRev = .bytes(@splat(0)),

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .arena = .init(gpa) };
    }

    /// Read the stored catalog and build one owned snapshot.
    pub fn load(gpa: std.mem.Allocator, db: *Database, inputs: Inputs) !Registry {
        var self: Registry = .init(gpa);
        errdefer self.deinit();
        const arena = self.arena.allocator();

        self.rows = try resolve(arena, .{
            .local = inputs.local,
            .account = inputs.account,
            .catalog = try storedRows(db, arena, inputs.local),
            .env = inputs.env,
        });

        const providers = try arena.alloc(wire.catalog.ProviderInfo, self.rows.len);
        var models: std.ArrayList(wire.catalog.ModelInfo) = .empty;
        for (self.rows, 0..) |row, i| {
            providers[i] = .{ .id = row.id, .name = row.name, .source = row.origin, .state = row.availability.state() };
            for (row.models) |item| try models.append(arena, try modelInfo(arena, row.origin, row.id, item));
        }
        self.providers = providers;
        self.models = models.items;
        self.revision = try revisionOf(gpa, self.providers, self.models);
        return self;
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Resolve one selector against the same snapshot that `catalog.list` exposes.
    pub fn resolveModel(self: *const Registry, qualified: []const u8) ?Match {
        return findModel(self.rows, qualified);
    }
};

/// Build the provider list. The result borrows `arena` and the sources.
pub fn resolve(arena: std.mem.Allocator, sources: Sources) ![]const Provider {
    var out: std.ArrayList(Provider) = .empty;
    try appendLocal(arena, &out, sources);
    try appendAccount(arena, &out, sources.account);
    return out.items;
}

/// Compose `providers.json` with the open catalog. The file wins field by field.
fn appendLocal(arena: std.mem.Allocator, out: *std.ArrayList(Provider), sources: Sources) !void {
    const loaded = sources.local orelse return;
    for (loaded.providers) |p| {
        const from_catalog = findCatalog(sources.catalog, p.id);
        const availability = localAvailability(arena, p, from_catalog, sources.env);
        try out.append(arena, .{
            .id = p.id,
            .name = if (from_catalog) |c| c.name else p.id,
            .origin = .local,
            .models = if (p.models.len != 0)
                try localModels(arena, p.models)
            else
                try catalogModels(arena, from_catalog),
            .availability = availability,
        });
    }
}

/// Pass the account bundle through. Nothing completes it, and no local id can hide it.
fn appendAccount(arena: std.mem.Allocator, out: *std.ArrayList(Provider), document: ?bundle.Document) !void {
    const doc = document orelse return;
    for (doc.providers) |p| {
        try out.append(arena, .{
            .id = p.id,
            .name = p.name,
            .origin = .cloud,
            // The bundle owns its model list. An empty list means the cloud has not synced yet.
            .models = try accountModels(arena, p.models),
            .availability = try accountAvailability(arena, p),
        });
    }
}

/// Resolve the local credential, then complete the route from the catalog template.
fn localAvailability(
    arena: std.mem.Allocator,
    p: provider.config.LocalProvider,
    from_catalog: ?feed.Provider,
    env: ?*const EnvMap,
) Availability {
    const base_url = p.base_url orelse (if (from_catalog) |c| c.base_url else null) orelse return .{ .unavailable = .needs_route };
    const protocol = p.protocol orelse (if (from_catalog) |c| c.protocol else null) orelse return .{ .unavailable = .needs_route };
    const catalog_auth: ?feed.Auth = if (from_catalog) |c| c.auth else null;
    const headers = p.headers orelse (if (from_catalog) |c| c.headers else &.{});

    var mechanism: instance.AuthMechanism = .none;
    var source: CredentialSource = .none;
    var dialect = p.responses_dialect orelse .standard;
    if (p.auth) |auth| switch (auth) {
        .api_key => |key| {
            const header = key.header orelse (if (catalog_auth) |a| a.header else null) orelse return .{ .unavailable = .needs_route };
            mechanism = .{ .api_key = header };
            // The entry names an API-key route and holds no value, so the user must supply one.
            const from_file = key.source orelse return .{ .unavailable = .needs_credential };
            switch (from_file) {
                .env => |name| {
                    // An empty value is no value, so it must not reach a request as a blank header.
                    const value = (if (env) |e| e.get(name) else null) orelse return .{ .unavailable = .needs_credential };
                    if (value.len == 0) return .{ .unavailable = .needs_credential };
                    source = .{ .env = name };
                },
                .literal => |literal| source = .{ .literal = literal },
            }
        },
        .oauth => |grant| {
            // The catalog states how a provider authenticates. The file only stores the grant.
            const flow = (if (catalog_auth) |a| a.flow else null) orelse return .{ .unavailable = .needs_route };
            // Every grant is a bearer, so the flow selects only the identity header and the dialect.
            mechanism = .{ .api_key = .authorization_bearer };
            if (std.mem.eql(u8, flow, "codex")) {
                const account = grant.account_id orelse return .{ .unavailable = .needs_credential };
                const pinned = arena.dupe(instance.Header, &.{.{ .name = "ChatGPT-Account-ID", .value = account }}) catch return .{ .unavailable = .needs_route };
                dialect = .codex;
                source = .{ .oauth = .{ .grant = .{ .access_token = grant.access_token, .headers = pinned }, .expires_at_ms = grant.expires_at_ms } };
            } else if (std.mem.eql(u8, flow, "xai")) {
                source = .{ .oauth = .{ .grant = .{ .access_token = grant.access_token }, .expires_at_ms = grant.expires_at_ms } };
            } else return .{ .unavailable = .needs_route }; // The daemon cannot build this flow.
        },
    } else if (catalog_auth != null) {
        // The file names no credential and the catalog says the provider needs one.
        return .{ .unavailable = .needs_credential };
    }

    // The catalog can name the header, so check the composed pair that the loader could not.
    if (mechanism.headerName()) |name| {
        for (headers) |h| if (std.ascii.eqlIgnoreCase(name, h.name)) return .{ .unavailable = .needs_route };
    }

    return .{ .ready = .{
        .instance = .{
            .id = p.id,
            .base_url = base_url,
            .protocol = protocol,
            .auth = mechanism,
            .headers = headers,
            .cache = p.cache orelse (if (from_catalog) |c| c.cache else .unsupported),
            .responses_dialect = dialect,
        },
        .credential = source,
    } };
}

/// Read the account route. A bundle that omits a required field gives `needs_route` instead.
fn accountAvailability(arena: std.mem.Allocator, p: bundle.Provider) !Availability {
    switch (p.auth.status) {
        .active => {},
        .reauth_required => return .{ .unavailable = .expired },
        .revoked => return .{ .unavailable = .revoked },
    }
    const base_url = p.base_url orelse return .{ .unavailable = .needs_route };
    const protocol = p.protocol orelse return .{ .unavailable = .needs_route };

    var mechanism: instance.AuthMechanism = undefined;
    var source: CredentialSource = undefined;
    var dialect: instance.ResponsesDialect = .standard;
    switch (p.auth.kind) {
        .api_key => {
            const key = p.auth.api_key orelse return .{ .unavailable = .needs_credential };
            mechanism = .{ .api_key = p.auth.header orelse return .{ .unavailable = .needs_route } };
            source = .{ .literal = key };
        },
        .oauth => {
            const token = p.auth.access_token orelse return .{ .unavailable = .needs_credential };
            const flow = p.auth.flow orelse return .{ .unavailable = .needs_route };
            // Every grant is a bearer, so the flow selects only the identity header and the dialect.
            mechanism = .{ .api_key = .authorization_bearer };
            if (std.mem.eql(u8, flow, "codex")) {
                const account = p.auth.account_id orelse return .{ .unavailable = .needs_route };
                const headers = try arena.dupe(instance.Header, &.{.{ .name = "ChatGPT-Account-ID", .value = account }});
                dialect = .codex;
                source = .{ .oauth = .{ .grant = .{ .access_token = token, .headers = headers }, .expires_at_ms = p.auth.expires_at_ms } };
            } else if (std.mem.eql(u8, flow, "xai")) {
                source = .{ .oauth = .{ .grant = .{ .access_token = token }, .expires_at_ms = p.auth.expires_at_ms } };
            } else return .{ .unavailable = .needs_route }; // The daemon cannot build this flow.
        },
    }

    return .{ .ready = .{
        .instance = .{
            .id = p.id,
            .base_url = base_url,
            .protocol = protocol,
            .auth = mechanism,
            .headers = p.headers,
            .cache = p.cache,
            .responses_dialect = dialect,
        },
        .credential = source,
    } };
}

/// Read the catalog row of each configured provider. The catalog never adds a provider by itself.
fn storedRows(db: *Database, arena: std.mem.Allocator, local: ?*const provider.config.Loaded) ![]const feed.Provider {
    const loaded = local orelse return &.{};
    var out: std.ArrayList(feed.Provider) = .empty;
    try out.ensureTotalCapacityPrecise(arena, loaded.providers.len);
    for (loaded.providers) |p| {
        if (try store.provider(db, arena, p.id)) |row| out.appendAssumeCapacity(row);
    }
    return out.items;
}

fn findCatalog(rows: []const feed.Provider, id: []const u8) ?feed.Provider {
    for (rows) |c| if (std.mem.eql(u8, c.id, id)) return c;
    return null;
}

/// Build the canonical selector, which the daemon owns and a client only echoes back.
pub fn selectorOf(arena: std.mem.Allocator, origin: Origin, provider_id: []const u8, model_id: []const u8) ![]const u8 {
    // Every source validates its ids, so a bad half here is a bug in a producer, not peer input.
    std.debug.assert(wire.ids.isSelectorPart(provider_id));
    std.debug.assert(wire.ids.isSelectorTail(model_id));
    const out = try std.fmt.allocPrint(arena, "{t}:{s}/{s}", .{ origin, provider_id, model_id });
    std.debug.assert(out.len <= wire.ids.max_selector_bytes);
    return out;
}

/// Resolve a canonical selector against the merged list. A stale selector resolves to nothing.
pub fn findModel(rows: []const Provider, selector: []const u8) ?Match {
    const colon = std.mem.indexOfScalar(u8, selector, ':') orelse return null;
    const origin = std.meta.stringToEnum(Origin, selector[0..colon]) orelse return null;
    const rest = selector[colon + 1 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const provider_id = rest[0..slash];
    const model_id = rest[slash + 1 ..];
    for (rows) |*p| {
        if (p.origin != origin or !std.mem.eql(u8, p.id, provider_id)) continue;
        for (p.models) |*m| if (std.mem.eql(u8, m.id, model_id)) return .{ .provider = p, .model = m };
        return null; // The provider serves no model of that name.
    }
    return null;
}

// ── Model conversion. Each source states what it knows; the spec states the effective value. ──

fn levels(arena: std.mem.Allocator, patch: []const ?[]const u8) ![]const model.ReasoningLevel {
    const out = try arena.alloc(model.ReasoningLevel, patch.len);
    for (patch, 0..) |level, i| out[i] = .from(level);
    return out;
}

fn limitsOf(patch: model.LimitsPatch) model.Limits {
    return .{
        .context_window = .from(patch.context_window),
        .max_output_tokens = .from(patch.max_output_tokens),
    };
}

fn costOf(patch: model.CostPatch) model.Cost {
    return .{
        .input = .from(patch.input),
        .output = .from(patch.output),
        .cache_read = .from(patch.cache_read),
        .cache_write = .from(patch.cache_write),
    };
}

/// Read a dialect name. An unknown name degrades, because the source set is open.
fn named(comptime T: type, name: ?[]const u8, fallback: T) T {
    const value = name orelse return fallback;
    return std.meta.stringToEnum(T, value) orelse fallback;
}

fn catalogModels(arena: std.mem.Allocator, row: ?feed.Provider) ![]const ModelSpec {
    const p = row orelse return &.{};
    const out = try arena.alloc(ModelSpec, p.models.len);
    for (p.models, 0..) |m, i| out[i] = .{
        .id = m.id,
        .upstream_id = m.upstream_id,
        .name = m.name,
        .limits = limitsOf(m.limits),
        .cost = costOf(m.cost),
        .caps = .{ .tools = .{ .value = m.flags.supports_tools }, .vision = .{ .value = m.flags.supports_vision } },
        .reasoning_levels = try levels(arena, m.reasoning_levels),
        .dialect = dialectOf(m.flags.thinking_format, m.flags.reasoning_replay, m.flags.max_tokens_field, m.flags.anthropic_adaptive, m.flags.reasoning_budget_min, m.flags.reasoning_budget_max),
    };
    return out;
}

fn accountModels(arena: std.mem.Allocator, models: []const bundle.Model) ![]const ModelSpec {
    const out = try arena.alloc(ModelSpec, models.len);
    for (models, 0..) |m, i| out[i] = .{
        .id = m.id,
        .upstream_id = m.upstream_id,
        .name = m.name,
        .limits = limitsOf(m.limits),
        .cost = costOf(m.cost),
        .caps = .{ .tools = .from(m.flags.supports_tools), .vision = .from(m.flags.supports_vision) },
        .reasoning_levels = try levels(arena, m.reasoning_levels),
        .dialect = dialectOf(m.flags.thinking_format, m.flags.reasoning_replay, m.flags.max_tokens_field, m.flags.anthropic_adaptive, m.flags.reasoning_budget_min, m.flags.reasoning_budget_max),
    };
    return out;
}

/// Convert a local binding, which holds closed enums and no display name.
fn localModels(arena: std.mem.Allocator, models: []const instance.ModelBinding) ![]const ModelSpec {
    const out = try arena.alloc(ModelSpec, models.len);
    for (models, 0..) |m, i| out[i] = .{
        .id = m.id,
        .upstream_id = m.upstream_id,
        .name = m.id,
        .limits = .{ .context_window = .{ .value = m.limits.context_window }, .max_output_tokens = .{ .value = m.limits.max_output_tokens } },
        .cost = .{ .input = .{ .value = m.cost.input }, .output = .{ .value = m.cost.output }, .cache_read = .{ .value = m.cost.cache_read }, .cache_write = .{ .value = m.cost.cache_write } },
        .caps = .{ .tools = .{ .value = m.flags.supports_tools }, .vision = .{ .value = m.flags.supports_vision } },
        .dialect = .{
            .thinking_format = m.flags.thinking_format,
            .reasoning_replay = m.flags.reasoning_replay,
            .max_tokens_field = m.flags.max_tokens_field,
            .anthropic_adaptive = m.flags.anthropic_adaptive,
            .reasoning_budget = .from(m.flags.reasoning_budget_min, m.flags.reasoning_budget_max),
        },
    };
    return out;
}

fn dialectOf(
    thinking: ?[]const u8,
    replay: ?[]const u8,
    max_tokens: ?[]const u8,
    adaptive: ?bool,
    budget_min: ?i64,
    budget_max: ?u64,
) model.Dialect {
    return .{
        .thinking_format = named(model.ThinkingFormat, thinking, .none),
        .reasoning_replay = named(model.ReasoningReplay, replay, .none),
        .max_tokens_field = named(model.MaxTokensField, max_tokens, .@"max-tokens"),
        .anthropic_adaptive = adaptive orelse false,
        .reasoning_budget = .from(budget_min, budget_max),
    };
}

// ── The wire projection. ──

/// Choose the effort a client uses when the user picks none. Prefer `medium`, else the middle level.
fn defaultReasoning(names: []const []const u8) []const u8 {
    for (names) |level| if (std.mem.eql(u8, level, "medium")) return level;
    return if (names.len != 0) names[names.len / 2] else "";
}

/// Project one model onto the public wire shape. An unknown value becomes an absent field.
fn modelInfo(arena: std.mem.Allocator, origin: Origin, provider_id: []const u8, spec: ModelSpec) !wire.catalog.ModelInfo {
    var names: std.ArrayList([]const u8) = .empty;
    for (spec.reasoning_levels) |level| switch (level) {
        .none => {},
        .named => |value| try names.append(arena, value),
    };

    return .{
        .id = spec.id,
        .provider = provider_id,
        .selector = try selectorOf(arena, origin, provider_id, spec.id),
        .name = spec.name,
        .context_window = spec.limits.context_window.optional(),
        .max_output_tokens = spec.limits.max_output_tokens.optional(),
        .reasoning_levels = names.items,
        .default_reasoning = defaultReasoning(names.items),
        .supports_vision = spec.caps.vision.optional(),
        .supports_tools = spec.caps.tools.optional(),
        .cost = .{
            .input = spec.cost.input.optional(),
            .output = spec.cost.output.optional(),
            .cache_read = spec.cost.cache_read.optional(),
            .cache_write = spec.cost.cache_write.optional(),
        },
    };
}

/// Hash the public projection. An empty projection keeps the protocol's zero revision sentinel.
fn revisionOf(
    gpa: std.mem.Allocator,
    providers: []const wire.catalog.ProviderInfo,
    models: []const wire.catalog.ModelInfo,
) !wire.ids.CatalogRev {
    if (providers.len == 0 and models.len == 0) return .bytes(@splat(0));

    const public = .{ .providers = providers, .models = models };
    const bytes = try std.json.Stringify.valueAlloc(gpa, public, .{ .emit_null_optional_fields = false });
    defer gpa.free(bytes);
    var digest: [wire.ids.CatalogRev.byte_len]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(bytes, &digest, .{});
    return .bytes(digest);
}

test {
    _ = @import("registry_test.zig");
}
