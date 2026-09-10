//! Assemble every provider the engine offers by composing one file layer over the baked table.

const std = @import("std");
const ai = @import("ai");
const proto = @import("proto");
const provider = @import("provider.zig");
const catalog = ai.catalog;

const instance = ai.instance;
const model = ai.model;
pub const ModelSpec = model.ModelSpec;

const EnvMap = std.process.Environ.Map;

/// This route holds every value that one request needs, and names its credential source.
pub const Route = struct {
    route: instance.Route,
    credential: CredentialSource,
};

/// A run reads the stored grant and its expiry, so it needs no catalog rebuild.
pub const OAuthSource = struct {
    grant: ai.resolve.Credential.OAuth,
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
pub fn credential(source: CredentialSource, env: *const EnvMap, now_ms: u64) ?ai.resolve.Credential {
    return switch (source) {
        .none => .none,
        .env => |name| blk: {
            // An empty value is no value, so a run reports a missing credential and sends no header.
            const value = env.get(name) orelse return null;
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
    /// No credential reached the engine. The entry names one that the environment does not hold.
    needs_credential,
    /// A routing field is missing, so the engine cannot build a request.
    needs_route,
    /// The grant expired. The user must authenticate again.
    expired,
};

/// A ready provider carries its route, so a state and a route can never disagree.
pub const Availability = union(enum) {
    ready: Route,
    unavailable: Reason,

    /// Project onto the wire, which reports the same reason under its own name.
    pub fn state(self: Availability) proto.enums.ProviderState {
        return switch (self) {
            .ready => .ready,
            .unavailable => |reason| switch (reason) {
                .needs_credential => .needs_credential,
                .needs_route => .needs_route,
                .expired => .expired,
            },
        };
    }
};

/// One provider the engine offers.
pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    models: []const ModelSpec,
    availability: Availability,
    /// The OAuth flow the catalog names for this provider. An API-key provider names none.
    login_flow: ?[]const u8 = null,
};

/// One model, and the provider that serves it.
pub const Match = struct {
    provider: *const Provider,
    model: *const ModelSpec,
};

/// The sources one merge reads. Each one is absent when its layer is not configured.
pub const Sources = struct {
    local: ?*const provider.config.Loaded = null,
    /// The baked table. A test names its own rows, so this is not always the whole catalog.
    catalog: []const catalog.Provider = &.{},
    env: *const EnvMap,
};

/// What one snapshot build needs. `load` always reads the whole baked table, so it names no catalog.
pub const Inputs = struct {
    local: ?*const provider.config.Loaded = null,
    env: *const EnvMap,
};

/// One provider snapshot. The arena owns the rows, and a route borrows the state-owned sources.
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const Provider = &.{},
    providers: []const proto.catalog.ProviderInfo = &.{},
    models: []const proto.catalog.ModelInfo = &.{},
    revision: proto.ids.CatalogRev = .bytes(@splat(0)),

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .arena = .init(gpa) };
    }

    /// Build one owned snapshot over the baked table.
    pub fn load(gpa: std.mem.Allocator, inputs: Inputs) !Registry {
        var self: Registry = .init(gpa);
        errdefer self.deinit();
        const arena = self.arena.allocator();

        self.rows = try resolve(arena, .{
            .local = inputs.local,
            .catalog = &catalog.providers,
            .env = inputs.env,
        });

        const providers = try arena.alloc(proto.catalog.ProviderInfo, self.rows.len);
        var models: std.ArrayList(proto.catalog.ModelInfo) = .empty;
        for (self.rows, 0..) |row, i| {
            providers[i] = .{ .id = row.id, .name = row.name, .state = row.availability.state() };
            for (row.models) |item| try models.append(arena, try modelInfo(arena, row.id, item));
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

/// Compose `providers.json` with the baked catalog. The file wins field by field.
/// The catalog leads, so the row order holds whatever the file names.
/// The result borrows `arena` and the sources.
pub fn resolve(arena: std.mem.Allocator, sources: Sources) ![]const Provider {
    var out: std.ArrayList(Provider) = .empty;
    for (sources.catalog) |*c| {
        const file = findLocal(sources.local, c.id);
        // A provider the file does not name is offered only when the process can already reach it.
        if (file == null and !offerable(c, sources.env)) continue;
        try out.append(arena, try providerRow(arena, file orelse .{ .id = c.id }, c, sources.env));
    }
    // An entry the catalog does not name is a local endpoint, such as Ollama.
    if (sources.local) |loaded| for (loaded.providers) |p| {
        if (findCatalog(sources.catalog, p.id) != null) continue;
        try out.append(arena, try providerRow(arena, p, null, sources.env));
    };
    return out.items;
}

/// Report whether the process can offer this provider with no `providers.json` entry.
fn offerable(c: *const catalog.Provider, env: *const EnvMap) bool {
    return switch (c.auth) {
        // A grant needs a login, so the provider stays visible for the user to start one.
        .oauth => true,
        .api_key => |named| envValue(env, named orelse return false) != null,
    };
}

/// Read a named variable. An empty value is no value, so a blank variable offers nothing.
fn envValue(env: *const EnvMap, name: []const u8) ?[]const u8 {
    const value = env.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

/// Build one row from the file entry and the catalog row, either of which may be absent.
fn providerRow(
    arena: std.mem.Allocator,
    p: provider.config.LocalProvider,
    from_catalog: ?*const catalog.Provider,
    env: *const EnvMap,
) !Provider {
    return .{
        .id = p.id,
        .login_flow = if (from_catalog) |c| loginFlow(c.auth) else null,
        .name = if (from_catalog) |c| c.name else p.id,
        .models = try mergedModels(arena, p, from_catalog),
        .availability = localAvailability(arena, p, from_catalog, env),
    };
}

fn findLocal(local: ?*const provider.config.Loaded, id: []const u8) ?provider.config.LocalProvider {
    const loaded = local orelse return null;
    for (loaded.providers) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

/// Union the baked models with the file's. The file wins on a repeated id and appends the rest.
fn mergedModels(
    arena: std.mem.Allocator,
    p: provider.config.LocalProvider,
    from_catalog: ?*const catalog.Provider,
) ![]const ModelSpec {
    const baked: []const ModelSpec = if (from_catalog) |c| c.models else &.{};
    // The baked models already hold the effective shape, so only a file entry allocates.
    if (p.models.len == 0) return baked;
    const extra = try provider.config.modelSpecs(arena, p.models);
    if (baked.len == 0) return extra;

    var out: std.ArrayList(ModelSpec) = .empty;
    try out.ensureTotalCapacityPrecise(arena, baked.len + extra.len);
    for (baked) |m| out.appendAssumeCapacity(findSpec(extra, m.id) orelse m);
    for (extra) |e| if (findSpec(baked, e.id) == null) out.appendAssumeCapacity(e);
    return out.items;
}

fn findSpec(specs: []const ModelSpec, id: []const u8) ?ModelSpec {
    for (specs) |m| if (std.mem.eql(u8, m.id, id)) return m;
    return null;
}

/// Resolve the local credential, then complete the route from the catalog template.
fn localAvailability(
    arena: std.mem.Allocator,
    p: provider.config.LocalProvider,
    from_catalog: ?*const catalog.Provider,
    env: *const EnvMap,
) Availability {
    const template: ?*const instance.Route = if (from_catalog) |c| &c.route else null;
    const base_url = p.base_url orelse (if (template) |t| t.base_url else null) orelse return .{ .unavailable = .needs_route };
    const protocol = p.protocol orelse (if (template) |t| t.protocol else null) orelse return .{ .unavailable = .needs_route };
    // Every baked row states an api-key header, and a grant presents a bearer under the same member.
    const catalog_header: ?instance.ApiKeyHeader = if (template) |t| switch (t.auth) {
        .api_key => |header| header,
        .none => null,
    } else null;
    const headers = p.headers orelse (if (template) |t| t.headers else &.{});

    var mechanism: instance.AuthMechanism = .none;
    var source: CredentialSource = .none;
    var dialect = p.responses_dialect orelse .standard;
    if (p.auth) |auth| switch (auth) {
        .api_key => |key| {
            const header = key.header orelse catalog_header orelse return .{ .unavailable = .needs_route };
            mechanism = .{ .api_key = header };
            // The entry names an API-key route and holds no value, so the user must supply one.
            const from_file = key.source orelse return .{ .unavailable = .needs_credential };
            switch (from_file) {
                .env => |name| {
                    // An empty value is no value, so it must not reach a request as a blank header.
                    if (envValue(env, name) == null) return .{ .unavailable = .needs_credential };
                    source = .{ .env = name };
                },
                .literal => |literal| source = .{ .literal = literal },
            }
        },
        .oauth => |grant| {
            // The catalog states how a provider authenticates. The file only stores the grant.
            const flow = (if (from_catalog) |c| loginFlow(c.auth) else null) orelse return .{ .unavailable = .needs_route };
            switch (oauthRoute(arena, flow, grant.access_token, grant.account_id, grant.expires_at_ms)) {
                .unavailable => |reason| return .{ .unavailable = reason },
                .ready => |route| {
                    mechanism = route.mechanism;
                    dialect = route.dialect;
                    source = route.source;
                },
            }
        },
    } else if (from_catalog) |c| switch (c.auth) {
        // The file names no credential, so the environment supplies the key the catalog names.
        .api_key => |named| {
            const name = named orelse return .{ .unavailable = .needs_credential };
            const value = envValue(env, name) orelse return .{ .unavailable = .needs_credential };
            std.debug.assert(value.len != 0); // `envValue` rejects a blank variable.
            mechanism = .{ .api_key = catalog_header orelse return .{ .unavailable = .needs_route } };
            source = .{ .env = name };
        },
        // No variable can hold a grant, so this provider waits for a login.
        .oauth => return .{ .unavailable = .needs_credential },
    };

    // The catalog can name the header, so check the composed set that the loader could not.
    // A grant pins its own identity header, and a run refuses the whole request when one collides.
    const pinned: []const instance.Header = switch (source) {
        .oauth => |stored| stored.grant.headers,
        else => &.{},
    };
    if (ai.resolve.headerConflict(mechanism.headerName(), pinned, headers)) {
        return .{ .unavailable = .needs_route };
    }

    return .{ .ready = .{
        .route = .{
            .base_url = base_url,
            .protocol = protocol,
            .auth = mechanism,
            .headers = headers,
            .cache = p.cache orelse (if (template) |t| t.cache else null),
            .responses_dialect = dialect,
        },
        .credential = source,
    } };
}

/// One grant becomes one route the same way from either origin. Every grant is a bearer, so the
/// flow selects only the identity header and the response dialect.
const OAuthRoute = union(enum) {
    ready: struct {
        mechanism: instance.AuthMechanism,
        dialect: instance.ResponsesDialect,
        source: CredentialSource,
    },
    unavailable: Reason,
};

fn oauthRoute(
    arena: std.mem.Allocator,
    flow: []const u8,
    access_token: []const u8,
    account_id: ?[]const u8,
    expires_at_ms: ?u64,
) OAuthRoute {
    const bearer: instance.AuthMechanism = .{ .api_key = .authorization_bearer };
    if (std.mem.eql(u8, flow, "codex")) {
        // Codex names the account on every request, so a grant without one is half a credential.
        const account = account_id orelse return .{ .unavailable = .needs_credential };
        const headers = arena.dupe(instance.Header, &.{.{ .name = "ChatGPT-Account-ID", .value = account }}) catch
            return .{ .unavailable = .needs_route };
        return .{ .ready = .{
            .mechanism = bearer,
            .dialect = .codex,
            .source = .{ .oauth = .{ .grant = .{ .access_token = access_token, .headers = headers }, .expires_at_ms = expires_at_ms } },
        } };
    }
    if (std.mem.eql(u8, flow, "xai")) return .{ .ready = .{
        .mechanism = bearer,
        .dialect = .standard,
        .source = .{ .oauth = .{ .grant = .{ .access_token = access_token }, .expires_at_ms = expires_at_ms } },
    } };
    return .{ .unavailable = .needs_route }; // The engine cannot build this flow.
}

/// Report the flow a provider logs in with. Only an OAuth provider names one.
fn loginFlow(auth: catalog.Auth) ?[]const u8 {
    return switch (auth) {
        .oauth => |flow| flow,
        .api_key => null,
    };
}

fn findCatalog(rows: []const catalog.Provider, id: []const u8) ?*const catalog.Provider {
    for (rows) |*c| if (std.mem.eql(u8, c.id, id)) return c;
    return null;
}

/// Build the canonical selector, which the engine owns and a client only echoes back.
pub fn selectorOf(arena: std.mem.Allocator, provider_id: []const u8, model_id: []const u8) ![]const u8 {
    // Every source validates its ids, so a bad half here is a bug in a producer, not peer input.
    std.debug.assert(proto.ids.isSelectorPart(provider_id));
    std.debug.assert(proto.ids.isSelectorTail(model_id));
    const out = try std.fmt.allocPrint(arena, "{s}/{s}", .{ provider_id, model_id });
    std.debug.assert(out.len <= proto.ids.max_selector_bytes);
    return out;
}

/// Find one provider row by id. A login addresses a provider this way.
pub fn find(rows: []const Provider, provider_id: []const u8) ?*const Provider {
    for (rows) |*row| if (std.mem.eql(u8, row.id, provider_id)) return row;
    return null;
}

/// Resolve a canonical selector against the merged list. A stale selector resolves to nothing.
pub fn findModel(rows: []const Provider, selector: []const u8) ?Match {
    // The library owns the selector grammar, so a model id may hold its own slash.
    const parts = catalog.split(selector) catch return null;
    for (rows) |*p| {
        if (!std.mem.eql(u8, p.id, parts.provider)) continue;
        for (p.models) |*m| if (std.mem.eql(u8, m.id, parts.model)) return .{ .provider = p, .model = m };
        return null; // The provider serves no model of that name.
    }
    return null;
}

// ── The wire projection. ──

/// Prefer `medium`, else the middle effort. `off` disables thinking, so it is never the default.
fn defaultReasoning(names: []const []const u8) []const u8 {
    var efforts: usize = 0;
    for (names) |level| {
        if (std.mem.eql(u8, level, "medium")) return level;
        if (!std.mem.eql(u8, level, "off")) efforts += 1;
    }
    if (efforts == 0) return ""; // A model that only disables thinking has no effort to prefer.

    var seen: usize = 0;
    for (names) |level| {
        if (std.mem.eql(u8, level, "off")) continue;
        if (seen == efforts / 2) return level;
        seen += 1;
    }
    unreachable; // The scan above counted this many efforts, so the midpoint is always reached.
}

/// Report whether a session can name `off`. A stated capability wins, and a null source level stands in for an absent one.
pub fn canDisableReasoning(spec: ModelSpec) bool {
    if (spec.caps.disable_reasoning) |stated| return stated;
    for (spec.reasoning_levels) |level| if (level == .none) return true;
    return false;
}

/// The levels a user can pick: each named effort, then `off` when the model can run with no reasoning.
pub fn levelNames(arena: std.mem.Allocator, spec: ModelSpec) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (spec.reasoning_levels) |level| switch (level) {
        .none => {},
        .named => |value| try names.append(arena, value),
    };
    if (canDisableReasoning(spec)) try names.append(arena, "off");
    return names.items;
}

/// The level a new session takes when the caller names none. Empty when the model has no effort to prefer.
pub fn defaultLevel(arena: std.mem.Allocator, spec: ModelSpec) ![]const u8 {
    return defaultReasoning(try levelNames(arena, spec));
}

/// Project one model onto the public wire shape. An unknown value becomes an absent field.
fn modelInfo(arena: std.mem.Allocator, provider_id: []const u8, spec: ModelSpec) !proto.catalog.ModelInfo {
    const names = try levelNames(arena, spec);

    return .{
        .id = spec.id,
        .provider = provider_id,
        .selector = try selectorOf(arena, provider_id, spec.id),
        .name = spec.name,
        .context_window = spec.limits.context_window,
        .max_output_tokens = spec.limits.max_output_tokens,
        .reasoning_levels = names,
        .default_reasoning = defaultReasoning(names),
        .supports_vision = spec.caps.vision,
        .supports_tools = spec.caps.tools,
        .cost = .{
            .input = spec.cost.input,
            .output = spec.cost.output,
            .cache_read = spec.cost.cache_read,
            .cache_write = spec.cost.cache_write,
        },
    };
}

/// Hash the public projection. An empty projection keeps the protocol's zero revision sentinel.
fn revisionOf(
    gpa: std.mem.Allocator,
    providers: []const proto.catalog.ProviderInfo,
    models: []const proto.catalog.ModelInfo,
) !proto.ids.CatalogRev {
    if (providers.len == 0 and models.len == 0) return .bytes(@splat(0));

    const public = .{ .providers = providers, .models = models };
    const bytes = try std.json.Stringify.valueAlloc(gpa, public, .{ .emit_null_optional_fields = false });
    defer gpa.free(bytes);
    var digest: [proto.ids.CatalogRev.byte_len]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(bytes, &digest, .{});
    return .bytes(digest);
}

test {
    _ = @import("registry_test.zig");
}

// The catalog lists `off` as a level, but it disables thinking rather than naming an effort.
test "off is offered after the efforts only while the model can stop, and the default stays an effort" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const high = [_]ai.model.ReasoningLevel{.{ .named = "high" }};
    const null_high = [_]ai.model.ReasoningLevel{ .none, .{ .named = "high" } };

    // A stated capability adds the sentinel behind the efforts.
    const stated: ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .caps = .{ .disable_reasoning = true }, .reasoning_levels = &high };
    try std.testing.expectEqualDeep(&[_][]const u8{ "high", "off" }, try levelNames(a, stated));
    try std.testing.expectEqualStrings("high", try defaultLevel(a, stated));
    // A null source level means the same, and a stated refusal beats it.
    const by_null: ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .reasoning_levels = &null_high };
    try std.testing.expectEqualDeep(&[_][]const u8{ "high", "off" }, try levelNames(a, by_null));
    const refused: ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .caps = .{ .disable_reasoning = false }, .reasoning_levels = &null_high };
    try std.testing.expectEqualDeep(&[_][]const u8{"high"}, try levelNames(a, refused));
    // A model with no effort keeps the vendor default, so `off` alone names no default.
    const only_off: ModelSpec = .{ .id = "m", .upstream_id = "m", .name = "m", .caps = .{ .disable_reasoning = true } };
    try std.testing.expectEqualDeep(&[_][]const u8{"off"}, try levelNames(a, only_off));
    try std.testing.expectEqualStrings("", try defaultLevel(a, only_off));
}

test "the default effort never lands on the disable sentinel" {
    const testing = std.testing;
    // The midpoint here is `high`, so only the preference rule can answer `medium`.
    try testing.expectEqualStrings("medium", defaultReasoning(&.{ "medium", "high", "xhigh" }));

    // This shape put the old midpoint at the least thinking the model offers.
    try testing.expectEqualStrings("high", defaultReasoning(&.{ "off", "minimal", "high" }));
    try testing.expectEqualStrings("xhigh", defaultReasoning(&.{ "high", "xhigh", "max" }));
    try testing.expectEqualStrings("", defaultReasoning(&.{}));
    try testing.expectEqualStrings("", defaultReasoning(&.{"off"}));
}
