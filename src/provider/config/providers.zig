//! Load and write the strict `providers.json` file. An omitted field stays null for the merge.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("proto");
const ai = @import("ai");

const Allocator = std.mem.Allocator;

/// Bound the whole file so one document cannot exhaust memory.
const max_file_bytes = 1 << 20;
/// Limit one literal key. A valid literal key is much shorter.
const max_literal_bytes = 8 << 10;

pub const Error = error{
    DuplicateProvider,
    DuplicateModel,
    DuplicateReasoningLevel,
    EmptyId,
    BadId,
    BadUrl,
    BadEnvName,
    BadLiteral,
    BadHeaderName,
    BadHeaderValue,
    BadReasoningLevel,
    HeaderConflict,
    /// Two endpoints name one protocol, so a model could not pick one.
    DuplicateEndpoint,
    /// A Responses dialect on a path that is not the Responses API.
    BadDialect,
    /// Tool search needs a compatible protocol and tool support.
    BadCapability,
    /// A key header on a grant, which is always a bearer.
    BadKeyHeader,
    /// A model names no endpoint the entry declares, or names none while the entry declares several.
    NoEndpoint,
    BadPath,
    AmbiguousCredential,
    /// An OAuth arm has no access token, so it cannot present a bearer.
    EmptyGrant,
    FileTooLarge,
    NotRegularFile,
    InsecurePermissions,
} || Allocator.Error || std.Uri.ParseError;

// The file schema is strict. The std.json parser rejects unknown fields, duplicate keys, and invalid union shapes.

/// Name where a local API key comes from. An absent source means the engine holds none.
pub const CredentialSource = union(enum) {
    env: []const u8,
    literal: []const u8,
};

/// How one model reads and writes, in the flat shape the file states it.
pub const FileFlags = struct {
    supports_vision: bool = false,
    supports_tools: bool = true,
    supports_tool_search: ?bool = null,
    reasoning_replay: ai.ir.ReasoningReplay = .none,
    thinking_format: ai.ir.ThinkingFormat = .none,
    anthropic_adaptive: bool = false,
    reasoning_budget_min: ?i64 = null,
    reasoning_budget_max: ?u64 = null,
    max_tokens_field: ai.ir.MaxTokensField = .max_tokens,
};

/// One model `providers.json` defines. The library owns the effective shape, so this projects onto it.
pub const FileModel = struct {
    id: []const u8,
    upstream_id: []const u8,
    /// The endpoint this model calls. Optional only while the provider serves one endpoint.
    protocol: ?ai.route.Protocol = null,
    /// A limit the file omits stays unknown, and the run falls back to its own ceiling.
    limits: ai.model.Limits = .{},
    /// A price the file omits stays unknown. A local endpoint publishes none.
    cost: ai.model.Cost = .{},
    /// A null level means the model takes no effort at all.
    reasoning_levels: []const ?[]const u8 = &.{},
    flags: FileFlags = .{},
};

/// Project one file model onto the library shape; `arena` owns its effort levels.
pub fn modelSpec(arena: Allocator, m: FileModel, endpoints: []const ai.route.Endpoint) !ai.model.ModelSpec {
    return .{
        .id = m.id,
        .upstream_id = m.upstream_id,
        .protocol = try modelProtocol(m, endpoints),
        // The file writes no display name, so the id names the model everywhere it is shown.
        .name = m.id,
        .limits = m.limits,
        .cost = m.cost,
        .caps = .{ .tools = m.flags.supports_tools, .vision = m.flags.supports_vision, .tool_search = m.flags.supports_tool_search },
        // The request builder gates each attachment on `modalities`, so the vision flag must reach it too.
        .modalities = .{
            .input = if (m.flags.supports_vision) &.{ .text, .image } else &.{.text},
            .output = &.{.text},
        },
        .reasoning_levels = try levels(arena, m.reasoning_levels),
        .dialect = .{
            .thinking_format = m.flags.thinking_format,
            .reasoning_replay = m.flags.reasoning_replay,
            .max_tokens_field = m.flags.max_tokens_field,
            .anthropic_adaptive = m.flags.anthropic_adaptive,
            .reasoning_budget = .from(m.flags.reasoning_budget_min, m.flags.reasoning_budget_max),
        },
    };
}

/// Name the endpoint one file model calls, or fail when the entry leaves the choice open.
fn modelProtocol(m: FileModel, endpoints: []const ai.route.Endpoint) error{ NoEndpoint, BadCapability }!ai.route.Protocol {
    const protocol = m.protocol orelse (if (endpoints.len == 1) endpoints[0].protocol else return error.NoEndpoint);
    try validateSearchCapability(m, protocol);
    if (ai.route.findEndpoint(endpoints, protocol) == null) return error.NoEndpoint;
    return protocol;
}

fn validateSearchCapability(m: FileModel, protocol: ?ai.route.Protocol) error{BadCapability}!void {
    if (m.flags.supports_tool_search == true and
        (protocol == .openai_chat or !m.flags.supports_tools)) return error.BadCapability;
}

fn levels(arena: Allocator, patch: []const ?[]const u8) ![]const ai.model.ReasoningLevel {
    const out = try arena.alloc(ai.model.ReasoningLevel, patch.len);
    for (patch, 0..) |level, i| out[i] = .from(level);
    return out;
}

/// The file shape. Only `id` is required, and a catalog row can supply an absent routing field.
const FileProvider = struct {
    id: []const u8,
    base_url: ?[]const u8 = null,
    /// The long form names the source.
    auth: ?LocalAuth = null,
    /// The short form. It is a literal key, and the endpoints name the header.
    api_key: ?[]const u8 = null,
    session_header: ?ai.route.SessionHeader = null,
    /// The paths this host serves. A list here replaces the catalog list as a whole.
    endpoints: ?[]const ai.route.Endpoint = null,
    headers: ?[]const ai.route.Header = null,
    models: []const FileModel = &.{},
};

const FileDoc = struct {
    providers: []const FileProvider = &.{},
};

/// The writer omits an empty model list without broadening the strict input schema.
const WritableProvider = struct {
    id: []const u8,
    base_url: ?[]const u8 = null,
    auth: ?LocalAuth = null,
    session_header: ?ai.route.SessionHeader = null,
    endpoints: ?[]const ai.route.Endpoint = null,
    headers: ?[]const ai.route.Header = null,
    models: ?[]const FileModel = null,
};

const WritableDoc = struct {
    providers: []const WritableProvider = &.{},
};

/// The arena owns every value, including a literal key, so one teardown frees the whole layer.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    providers: []LocalProvider = &.{},

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Read and resolve the absolute `path`. An absent file gives an empty layer.
pub fn load(gpa: Allocator, io: std.Io, path: []const u8) !Loaded {
    const raw = readSecureFile(gpa, io, path) catch |err| switch (err) {
        error.FileNotFound => return empty(gpa),
        else => |e| return e,
    };
    defer gpa.free(raw);
    return loadBytes(gpa, raw);
}

/// Parse and resolve one document. `alloc_always` copies each value, so `bytes` is never aliased.
pub fn loadBytes(gpa: Allocator, bytes: []const u8) !Loaded {
    if (bytes.len > max_file_bytes) return error.FileTooLarge;

    var out: Loaded = empty(gpa);
    errdefer out.deinit();
    const arena = out.arena.allocator();

    const doc = try std.json.parseFromSliceLeaky(FileDoc, arena, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    });

    const providers = try arena.alloc(LocalProvider, doc.providers.len);
    for (doc.providers, 0..) |fp, i| {
        for (doc.providers[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, fp.id)) return error.DuplicateProvider;
        }
        providers[i] = try resolveProvider(fp);
    }
    out.providers = providers;
    return out;
}

fn empty(gpa: Allocator) Loaded {
    return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
}

/// Replace the absolute `path` with the document for `providers`, so no reader sees a partial file.
pub fn write(gpa: Allocator, io: std.Io, path: []const u8, providers: []const LocalProvider) !void {
    const bytes = try serialize(gpa, providers);
    defer gpa.free(bytes);
    try writeFileBytes(io, path, bytes);
}

/// Render the layer as one document. A caller parses it first, so a write cannot strand the file.
pub fn serialize(gpa: Allocator, providers: []const LocalProvider) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const doc: WritableDoc = .{ .providers = try fileProviders(arena.allocator(), providers) };
    return std.json.Stringify.valueAlloc(gpa, doc, .{ .emit_null_optional_fields = false, .whitespace = .indent_2 });
}

/// Replace the absolute `path` with `bytes` after the caller renders and validates the document; create the parent directory when absent so a first write on a clean machine works.
pub fn writeFileBytes(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.BadPath;
    const name = std.fs.path.basename(path);
    if (name.len == 0) return error.BadPath;

    const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
        .default_dir
    else
        .fromMode(0o700);
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, parent, .{ .permissions = permissions });
    defer dir.close(io);
    try writePrivateFile(io, dir, name, bytes);
}

/// Project the layer onto the file shape. The writer emits the long credential form only.
fn fileProviders(arena: Allocator, providers: []const LocalProvider) Allocator.Error![]const WritableProvider {
    const out = try arena.alloc(WritableProvider, providers.len);
    for (providers, 0..) |p, i| out[i] = .{
        .id = p.id,
        .base_url = p.base_url,
        .auth = p.auth,
        .session_header = p.session_header,
        .endpoints = p.endpoints,
        .headers = p.headers,
        .models = if (p.models.len == 0) null else p.models,
    };
    return out;
}

/// Write a private file beside the target, then replace the target in one step.
fn writePrivateFile(io: std.Io, dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
        .default_file
    else
        .fromMode(0o600);

    var atomic = try dir.createFileAtomic(io, name, .{ .permissions = permissions, .replace = true });
    defer atomic.deinit(io);

    // The temporary file decides the final mode, so set it before the replacement.
    if (builtin.os.tag != .windows) try atomic.file.setPermissions(io, permissions);

    var buf: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();

    // `replace` renames without a flush, so sync first to put the contents on stable storage.
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// Read a size-limited regular file. Reject a target symlink, and on POSIX reject group and other access.
fn readSecureFile(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .follow_symlinks = false });
    defer file.close(io);

    const st = try file.stat(io);
    if (st.kind != .file) return error.NotRegularFile;
    const mode: u64 = @intCast(st.permissions.toMode());
    if ((mode & 0o077) != 0) return error.InsecurePermissions; // Keep a file that can hold a literal key private.
    if (st.size > max_file_bytes) return error.FileTooLarge;

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const raw = try gpa.alloc(u8, @intCast(st.size));
    errdefer gpa.free(raw);
    try reader.interface.readSliceAll(raw);
    return raw;
}

/// Validate one entry and project it onto the local provider layer. Every value borrows the arena.
fn resolveProvider(fp: FileProvider) Error!LocalProvider {
    if (fp.id.len == 0) return error.EmptyId;
    if (!proto.ids.isSelectorPart(fp.id)) return error.BadId;
    if (fp.base_url) |url| try checkUrl(url);
    // Two credential forms leave the entry ambiguous. Neither form means the route needs no credential.
    if (fp.auth != null and fp.api_key != null) return error.AmbiguousCredential;

    // An absent `auth` block means the route presents no credential. The short form is always literal.
    const auth: ?LocalAuth = if (fp.auth) |a| blk: {
        switch (a) {
            .api_key => |key| if (key.source) |source| switch (source) {
                .env => |name| if (!validEnvName(name)) return error.BadEnvName,
                .literal => |value| try checkLiteral(value),
            },
            // A grant reaches a request as a header value, so it obeys the literal rules.
            .oauth => |grant| {
                if (grant.access_token.len == 0) return error.EmptyGrant;
                try checkLiteral(grant.access_token);
                if (grant.refresh_token) |token| try checkLiteral(token);
                if (grant.account_id) |id| try checkLiteral(id);
            },
        }
        break :blk a;
    } else if (fp.api_key) |value| blk: {
        try checkLiteral(value);
        break :blk .{ .api_key = .{ .source = .{ .literal = value } } };
    } else null;

    if (fp.endpoints) |endpoints| for (endpoints, 0..) |e, i| {
        for (endpoints[0..i]) |prev| if (prev.protocol == e.protocol) return error.DuplicateEndpoint;
        // The dialect is a Responses body rule, so another path cannot carry it.
        if (e.responses_dialect != .standard and e.protocol != .openai_responses) return error.BadDialect;
        // A grant always presents a bearer, and a key needs a header to travel in.
        if (auth) |a| switch (a) {
            .oauth => if (e.key_header != null) return error.BadKeyHeader,
            .api_key => if (e.key_header == null) return error.BadKeyHeader,
        };
    };

    if (fp.headers) |file_headers| for (file_headers, 0..) |fh, i| {
        if (!ai.route.validHeaderName(fh.name)) return error.BadHeaderName;
        if (!ai.route.validHeaderValue(fh.value)) return error.BadHeaderValue;
        for (file_headers[0..i]) |prev| {
            if (std.ascii.eqlIgnoreCase(prev.name, fh.name)) return error.HeaderConflict;
        }
        // A pinned header must not collide with a header the credential or the session generates.
        if (fp.session_header) |sh| if (sh.name()) |generated| {
            if (std.ascii.eqlIgnoreCase(fh.name, generated)) return error.HeaderConflict;
        };
        if (fp.endpoints) |endpoints| for (endpoints) |e| if (e.mechanism().headerName()) |generated| {
            if (std.ascii.eqlIgnoreCase(fh.name, generated)) return error.HeaderConflict;
        };
    };

    for (fp.models, 0..) |fm, i| {
        if (fm.id.len == 0) return error.EmptyId;
        if (!proto.ids.isSelectorTail(fm.id)) return error.BadId;
        for (fp.models[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, fm.id)) return error.DuplicateModel;
        }
        // The catalog can name the endpoints, so only a declared list is checked here; the merge checks the rest.
        if (fp.endpoints) |endpoints| _ = try modelProtocol(fm, endpoints) else try validateSearchCapability(fm, fm.protocol);
        if (fm.reasoning_levels.len > proto.meta.limits.max_reasoning_levels) return error.BadReasoningLevel;
        for (fm.reasoning_levels, 0..) |level, level_i| {
            if (level) |name| {
                if (std.meta.stringToEnum(ai.ir.Effort, name) == null) return error.BadReasoningLevel;
            }
            for (fm.reasoning_levels[0..level_i]) |previous| {
                if (level == null and previous == null) return error.DuplicateReasoningLevel;
                if (level != null and previous != null and std.mem.eql(u8, level.?, previous.?))
                    return error.DuplicateReasoningLevel;
            }
        }
    }

    return .{
        .id = fp.id,
        .base_url = fp.base_url,
        .auth = auth,
        .session_header = fp.session_header,
        .endpoints = fp.endpoints,
        .headers = fp.headers,
        .models = fp.models,
    };
}

/// A literal key holds no control byte, because a control byte breaks a header line.
fn checkLiteral(value: []const u8) Error!void {
    if (value.len == 0 or value.len > max_literal_bytes) return error.BadLiteral;
    for (value) |c| if (std.ascii.isControl(c)) return error.BadLiteral;
}

/// Accept an absolute HTTP or HTTPS URL with a host. Reject userinfo, a query, and a fragment.
fn checkUrl(text: []const u8) Error!void {
    const uri = try std.Uri.parse(text);
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.BadUrl;
    const host = uri.host orelse return error.BadUrl;
    if (host.isEmpty()) return error.BadUrl;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.BadUrl;
}

fn validEnvName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        const ok = c == '_' or std.ascii.isAlphabetic(c) or (i > 0 and std.ascii.isDigit(c));
        if (!ok) return false;
    }
    return true;
}

/// A local API-key credential. The endpoints name the header it travels in.
pub const LocalApiKey = struct {
    /// Null means the route wants an API key and the engine holds none.
    source: ?CredentialSource = null,
};

/// The file stores the result of one login and excludes device data, codes, and verifiers.
pub const Grant = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    /// The expiry uses Unix milliseconds, and a run at or past it reports a missing credential.
    expires_at_ms: u64,
    /// Codex uses this value in the `ChatGPT-Account-ID` header. The account id is not a secret.
    account_id: ?[]const u8 = null,
};

/// One route presents one credential, so these arms never coexist.
pub const LocalAuth = union(enum) {
    api_key: LocalApiKey,
    oauth: Grant,
};

/// One `providers.json` entry before the merge. A catalog row can fill a null route field.
pub const LocalProvider = struct {
    id: []const u8,
    base_url: ?[]const u8 = null,
    /// Null means the route presents no credential at all.
    auth: ?LocalAuth = null,
    session_header: ?ai.route.SessionHeader = null,
    /// A list here replaces the catalog list as a whole, so the credential header follows this list.
    endpoints: ?[]const ai.route.Endpoint = null,
    headers: ?[]const ai.route.Header = null,
    models: []const FileModel = &.{},
};

const testing = std.testing;

/// Build the absolute `providers.json` path inside a temporary directory.
fn tmpPath(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(testing.io, buf);
    const name = try std.fmt.bufPrint(buf[len..], "/providers.json", .{});
    return buf[0 .. len + name.len];
}

fn wrapProvider(comptime provider_json: []const u8) []const u8 {
    return "{\"providers\":[" ++ provider_json ++ "]}";
}

const messages_endpoint = "\"endpoints\":[{\"protocol\":\"anthropic_messages\",\"key_header\":\"x_api_key\"}]";
const keyed_entry = "{\"id\":\"x\",\"base_url\":\"https://x.example/v1\"," ++ messages_endpoint ++
    ",\"auth\":{\"api_key\":{\"source\":{\"env\":\"K\"}}}";

/// The one endpoint the test entries declare, so a model with no protocol has one to take.
const one_endpoint = [_]ai.route.Endpoint{.{ .protocol = .openai_chat, .key_header = .authorization_bearer }};

test "a grant round-trips through the writer" {
    var loaded = try loadBytes(testing.allocator, wrapProvider(
        \\{"id":"codex","auth":{"oauth":{"access_token":"tok","refresh_token":"ref",
        \\ "expires_at_ms":123,"account_id":"acct"}}}
    ));
    defer loaded.deinit();

    const bytes = try serialize(testing.allocator, loaded.providers);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"models\"") == null);
    var again = try loadBytes(testing.allocator, bytes);
    defer again.deinit();

    const grant = again.providers[0].auth.?.oauth;
    try testing.expectEqualStrings("tok", grant.access_token);
    try testing.expectEqualStrings("ref", grant.refresh_token.?);
    try testing.expectEqual(@as(?u64, 123), grant.expires_at_ms);
    try testing.expectEqualStrings("acct", grant.account_id.?);
}

test "an oauth arm with no access token is refused" {
    try testing.expectError(error.EmptyGrant, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"codex","auth":{"oauth":{"access_token":"","expires_at_ms":1}}}
    )));
}

test "load a provider with an env api key and one model" {
    const json = wrapProvider(
        \\{"id":"minimax","base_url":"https://api.minimax.io/anthropic",
        \\ "endpoints":[{"protocol":"anthropic_messages","key_header":"x_api_key","cache":"anthropic_breakpoint"}],
        \\ "auth":{"api_key":{"source":{"env":"MINIMAX_API_KEY"}}},
        \\ "headers":[{"name":"anthropic-version","value":"2023-06-01"}],
        \\ "models":[{"id":"local","upstream_id":"MiniMax-Text","limits":{"context_window":200000,"max_output_tokens":8192},
        \\ "reasoning_levels":[null,"high"]}]}
    );
    var loaded = try loadBytes(testing.allocator, json);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 1), loaded.providers.len);
    const p = loaded.providers[0];
    try testing.expectEqualStrings("minimax", p.id);
    try testing.expectEqual(ai.route.Protocol.anthropic_messages, p.endpoints.?[0].protocol);
    try testing.expectEqual(@as(?ai.route.CachePolicy, .anthropic_breakpoint), p.endpoints.?[0].cache);
    try testing.expectEqualStrings("MINIMAX_API_KEY", p.auth.?.api_key.source.?.env);
    try testing.expectEqualStrings("anthropic-version", p.headers.?[0].name);
    try testing.expectEqualStrings("local", p.models[0].id);
    try testing.expectEqual(@as(u64, 8192), p.models[0].limits.max_output_tokens);
    try testing.expectEqual(@as(usize, 2), p.models[0].reasoning_levels.len);
    try testing.expect(p.models[0].reasoning_levels[0] == null);
    try testing.expectEqualStrings("high", p.models[0].reasoning_levels[1].?);
}

test "the strict schema rejects an unknown field" {
    try testing.expectError(error.UnknownField, loadBytes(testing.allocator, wrapProvider(keyed_entry ++ ",\"surprise\":true}")));
    // The old route fields are gone, so a stale file fails instead of routing nothing.
    try testing.expectError(error.UnknownField, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic_messages"}
    )));
    try testing.expectError(error.UnknownField, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}}}
    )));
}

test "the strict schema rejects a duplicate object key" {
    try testing.expectError(error.DuplicateField, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","id":"y","base_url":"https://x.example/v1"}
    )));
}

test "duplicate provider and model ids are rejected" {
    try testing.expectError(error.DuplicateProvider, loadBytes(testing.allocator, "{\"providers\":[" ++ keyed_entry ++ "}," ++ keyed_entry ++ "}]}"));
    try testing.expectError(error.DuplicateModel, loadBytes(testing.allocator, wrapProvider(keyed_entry ++
        \\,"models":[{"id":"m","upstream_id":"a","limits":{"context_window":1,"max_output_tokens":1}},
        \\           {"id":"m","upstream_id":"b","limits":{"context_window":1,"max_output_tokens":1}}]}
    )));
}

test "the endpoint list names each path once, and a model must name one of them" {
    try testing.expectError(error.DuplicateEndpoint, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","endpoints":[{"protocol":"openai_chat"},{"protocol":"openai_chat","key_header":"x_api_key"}]}
    )));
    // The dialect is a Responses body rule.
    try testing.expectError(error.BadDialect, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","endpoints":[{"protocol":"openai_chat","responses_dialect":"codex"}]}
    )));
    // A grant is always a bearer, so a header beside it states a second scheme.
    try testing.expectError(error.BadKeyHeader, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","endpoints":[{"protocol":"openai_responses","key_header":"x_api_key"}],
        \\ "auth":{"oauth":{"access_token":"tok","expires_at_ms":1}}}
    )));
    // A key with no header to travel in would load an entry that can never be ready.
    try testing.expectError(error.BadKeyHeader, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","endpoints":[{"protocol":"openai_chat"}],"api_key":"k"}
    )));
    try testing.expectError(error.BadKeyHeader, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","endpoints":[{"protocol":"openai_chat"}],"auth":{"api_key":{}}}
    )));
    // Two paths leave the choice open, so a model must state its own.
    try testing.expectError(error.NoEndpoint, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","endpoints":[{"protocol":"openai_chat"},{"protocol":"anthropic_messages"}],
        \\ "models":[{"id":"m","upstream_id":"m"}]}
    )));
    // A model on a path the entry does not serve could never be called.
    try testing.expectError(error.NoEndpoint, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","endpoints":[{"protocol":"openai_chat"}],
        \\ "models":[{"id":"m","upstream_id":"m","protocol":"anthropic_messages"}]}
    )));

    // One path serves a model that names none, and a stated path is kept.
    var loaded = try loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","endpoints":[{"protocol":"openai_chat"},{"protocol":"anthropic_messages"}],
        \\ "models":[{"id":"a","upstream_id":"a","protocol":"anthropic_messages"}]}
    ));
    defer loaded.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spec = try modelSpec(arena.allocator(), loaded.providers[0].models[0], loaded.providers[0].endpoints.?);
    try testing.expectEqual(ai.route.Protocol.anthropic_messages, spec.protocol);
    const filled = try modelSpec(arena.allocator(), .{ .id = "m", .upstream_id = "m" }, &one_endpoint);
    try testing.expectEqual(ai.route.Protocol.openai_chat, filled.protocol);
    // The catalog can serve several paths, so the merge refuses a model that names none.
    try testing.expectError(error.NoEndpoint, modelSpec(arena.allocator(), .{ .id = "m", .upstream_id = "m" }, &.{
        .{ .protocol = .openai_chat }, .{ .protocol = .anthropic_messages },
    }));
}

test "reasoning levels use the closed effort set without duplicates" {
    try testing.expectError(error.BadReasoningLevel, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"p","models":[{"id":"m","upstream_id":"m","limits":{"context_window":1,"max_output_tokens":1},
        \\ "reasoning_levels":["turbo"]}]}
    )));
    try testing.expectError(error.DuplicateReasoningLevel, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"p","models":[{"id":"m","upstream_id":"m","limits":{"context_window":1,"max_output_tokens":1},
        \\ "reasoning_levels":["high","high"]}]}
    )));
    try testing.expectError(error.DuplicateReasoningLevel, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"p","models":[{"id":"m","upstream_id":"m","limits":{"context_window":1,"max_output_tokens":1},
        \\ "reasoning_levels":[null,null]}]}
    )));
}

test "selector ids reject a slash or whitespace" {
    try testing.expectError(error.BadId, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"bad/provider","api_key":"k"}
    )));
    try testing.expectError(error.BadId, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"provider","api_key":"k","models":[{"id":"bad model","upstream_id":"upstream/model",
        \\ "limits":{"context_window":1,"max_output_tokens":1}}]}
    )));
}

test "url validation rejects scheme, host, userinfo, query, and fragment" {
    const cases = [_][]const u8{
        "ftp://a.example/v1", // The URL uses the wrong scheme.
        "https:///v1", // The URL has no host.
        "https://user:pw@a.example/v1", // The URL includes userinfo.
        "https://a.example/v1?k=v", // The URL includes a query.
        "https://a.example/v1#frag", // The URL includes a fragment.
    };
    for (cases) |url| {
        var buf: [256]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"providers\":[{{\"id\":\"x\",\"base_url\":\"{s}\"}}]}}", .{url});
        try testing.expectError(error.BadUrl, loadBytes(testing.allocator, json));
    }
}

test "a bad env name is rejected" {
    try testing.expectError(error.BadEnvName, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","auth":{"api_key":{"source":{"env":"9BAD-NAME"}}}}
    )));
}

test "a literal with a control byte is rejected" {
    try testing.expectError(error.BadLiteral, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","auth":{"api_key":{"source":{"literal":"line\none"}}}}
    )));
}

test "bad header names, values, and generated-header collisions are rejected" {
    try testing.expectError(error.BadHeaderName, loadBytes(testing.allocator, wrapProvider(keyed_entry ++ ",\"headers\":[{\"name\":\"bad name\",\"value\":\"v\"}]}")));
    try testing.expectError(error.BadHeaderValue, loadBytes(testing.allocator, wrapProvider(keyed_entry ++ ",\"headers\":[{\"name\":\"x-note\",\"value\":\"a\\r\\nb\"}]}")));
    // The endpoint names the key header, so a pinned copy of it is a collision whatever its case.
    try testing.expectError(error.HeaderConflict, loadBytes(testing.allocator, wrapProvider(keyed_entry ++ ",\"headers\":[{\"name\":\"X-Api-Key\",\"value\":\"injected\"}]}")));
    // The engine owns the session header, so a source that pins it would send every session to one cache.
    try testing.expectError(error.HeaderConflict, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","session_header":"x_opencode_session","headers":[{"name":"X-OpenCode-Session","value":"one"}]}
    )));
}

test "a keyless entry and an empty credential write back differently" {
    var loaded = try loadBytes(testing.allocator,
        \\{"providers":[
        \\ {"id":"ollama","base_url":"http://127.0.0.1:11434/v1","endpoints":[{"protocol":"openai_chat"}]},
        \\ {"id":"anthropic","auth":{"api_key":{}}}]}
    );
    defer loaded.deinit();

    const bytes = try serialize(testing.allocator, loaded.providers);
    defer testing.allocator.free(bytes);
    var again = try loadBytes(testing.allocator, bytes);
    defer again.deinit();

    try testing.expect(again.providers[0].auth == null); // The route presents no credential.
    try testing.expect(again.providers[1].auth != null); // The route wants a key.
    try testing.expect(again.providers[1].auth.?.api_key.source == null);
}

test "two credential forms are ambiguous" {
    try testing.expectError(error.AmbiguousCredential, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","api_key":"k",
        \\ "auth":{"api_key":{"source":{"env":"K"}}}}
    )));
}

test "a missing providers array yields an empty layer" {
    var loaded = try loadBytes(testing.allocator, "{}");
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 0), loaded.providers.len);
}

test "a missing file yields an empty layer" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var loaded = try load(testing.allocator, threaded.io(), "/nonexistent/yuke-test/providers.json");
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 0), loaded.providers.len);
}

test "the writer round-trips the layer through the file schema" {
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var loaded = try loadBytes(testing.allocator,
        \\{"providers":[
        \\ {"id":"minimax","base_url":"https://api.minimax.io/anthropic",
        \\  "endpoints":[{"protocol":"anthropic_messages","key_header":"x_api_key","cache":"anthropic_breakpoint"}],
        \\  "auth":{"api_key":{"source":{"env":"MINIMAX_API_KEY"}}},
        \\  "headers":[{"name":"anthropic-version","value":"2023-06-01"}],
        \\  "models":[{"id":"m","upstream_id":"MiniMax-Text","limits":{"context_window":200000,"max_output_tokens":8192}}]},
        \\ {"id":"ollama","base_url":"http://127.0.0.1:11434/v1","endpoints":[{"protocol":"openai_chat"}]},
        \\ {"id":"codex","base_url":"https://chatgpt.com/backend-api/codex","session_header":"session_id",
        \\  "endpoints":[{"protocol":"openai_responses","key_header":"authorization_bearer","responses_dialect":"codex"}],"api_key":"sk-literal"}]}
    );
    defer loaded.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &path_buf);
    try write(testing.allocator, io, path, loaded.providers);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const bytes = try tmp.dir.readFileAlloc(io, "providers.json", arena.allocator(), .limited(max_file_bytes));

    var again = try loadBytes(testing.allocator, bytes);
    defer again.deinit();

    try testing.expectEqual(loaded.providers.len, again.providers.len);
    try testing.expectEqualStrings("MINIMAX_API_KEY", again.providers[0].auth.?.api_key.source.?.env);
    try testing.expectEqual(@as(?ai.route.ApiKeyHeader, .x_api_key), again.providers[0].endpoints.?[0].key_header);
    try testing.expectEqual(@as(?ai.route.CachePolicy, .anthropic_breakpoint), again.providers[0].endpoints.?[0].cache);
    try testing.expectEqualStrings("anthropic-version", again.providers[0].headers.?[0].name);
    try testing.expectEqualStrings("m", again.providers[0].models[0].id);
    // A keyless entry survives the round trip, so the writer never invents a credential.
    try testing.expect(again.providers[1].auth == null);
    try testing.expect(again.providers[1].endpoints.?[0].key_header == null);
    // The short form is read once and written back in the long form.
    try testing.expectEqualStrings("sk-literal", again.providers[2].auth.?.api_key.source.?.literal);
    try testing.expectEqual(ai.route.ResponsesDialect.codex, again.providers[2].endpoints.?[0].responses_dialect);
    try testing.expectEqual(@as(?ai.route.SessionHeader, .session_id), again.providers[2].session_header);
}

test "the written file is private" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try write(testing.allocator, io, try tmpPath(&tmp, &path_buf), &.{});
    const file = try tmp.dir.openFile(io, "providers.json", .{});
    defer file.close(io);
    const st = try file.stat(io);
    const mode: u64 = @intCast(st.permissions.toMode());
    try testing.expectEqual(@as(u64, 0), mode & 0o077);
}

test "a file model decodes its flags and projects onto the library shape" {
    var loaded = try loadBytes(testing.allocator, wrapProvider(
        \\{"id":"deepseek","base_url":"https://api.deepseek.com/v1","endpoints":[{"protocol":"openai_chat","key_header":"authorization_bearer"}],
        \\ "models":[{"id":"r1","upstream_id":"deepseek-reasoner",
        \\ "limits":{"context_window":65536,"max_output_tokens":8192},
        \\ "reasoning_levels":[null,"high"],
        \\ "flags":{"reasoning_replay":"reasoning_content","thinking_format":"deepseek",
        \\ "max_tokens_field":"max_completion_tokens","supports_vision":true,"reasoning_budget_max":32000}},
        \\ {"id":"plain","upstream_id":"plain"}]}
    ));
    defer loaded.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const row = loaded.providers[0];
    const spec = try modelSpec(arena.allocator(), row.models[0], row.endpoints.?);
    const plain = try modelSpec(arena.allocator(), row.models[1], row.endpoints.?);

    // The request builder reads `modalities`, so the vision flag must reach it and not only `caps`.
    try testing.expect(spec.modalities.takesInput(.image).?);
    try testing.expect(!plain.modalities.takesInput(.image).?);
    try testing.expect(plain.modalities.takesInput(.text).?);

    try testing.expectEqualStrings("deepseek-reasoner", spec.upstream_id);
    try testing.expectEqualStrings("r1", spec.name); // The file writes no display name.
    try testing.expectEqual(ai.route.Protocol.openai_chat, spec.protocol); // The sole endpoint names the path.
    try testing.expectEqual(@as(?u64, 65536), spec.limits.context_window);
    try testing.expectEqual(ai.ir.ThinkingFormat.deepseek, spec.dialect.thinking_format);
    try testing.expectEqual(ai.ir.ReasoningReplay.reasoning_content, spec.dialect.reasoning_replay);
    try testing.expectEqual(ai.ir.MaxTokensField.max_completion_tokens, spec.dialect.max_tokens_field);
    try testing.expectEqual(@as(?u64, 32000), spec.dialect.reasoning_budget.range.max);
    try testing.expect(spec.caps.vision.? and spec.caps.tools.?); // `supports_tools` defaults true.
    try testing.expect(spec.reasoning_levels[0] == .none);
    try testing.expectEqualStrings("high", spec.reasoning_levels[1].named);

    // A price the file omits is unknown, not zero. A local endpoint publishes none.
    try testing.expect(spec.cost.input == null);
}

test "a file model may omit its limits entirely" {
    var loaded = try loadBytes(testing.allocator, wrapProvider(
        \\{"id":"ollama","base_url":"http://127.0.0.1:11434/v1","endpoints":[{"protocol":"openai_chat"}],
        \\ "models":[{"id":"qwen3","upstream_id":"qwen3:8b"}]}
    ));
    defer loaded.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spec = try modelSpec(arena.allocator(), loaded.providers[0].models[0], loaded.providers[0].endpoints.?);
    // The run falls back to its own ceiling, so a local endpoint needs no invented number.
    try testing.expect(spec.limits.max_output_tokens == null);
}

test "the shipped sample document still loads" {
    // The sample is documentation, so a schema change must not leave it silently unparseable.
    var loaded = try loadBytes(testing.allocator, @embedFile("providers.sample.json"));
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 3), loaded.providers.len);
    try testing.expectEqualStrings("minimax", loaded.providers[0].id);
    try testing.expect(loaded.providers[0].models[0].flags.anthropic_adaptive);
    try testing.expect(loaded.providers[1].auth == null); // The local server needs no key.
    // A gateway entry states its own paths, and its models name theirs.
    try testing.expectEqual(@as(usize, 3), loaded.providers[2].endpoints.?.len);
    try testing.expectEqual(@as(?ai.route.Protocol, .anthropic_messages), loaded.providers[2].models[0].protocol);
}

test "local tool search capability survives projection and a file round trip" {
    const document =
        \\{"providers":[{"id":"local","base_url":"https://example.test/v1","endpoints":[{"protocol":"openai_responses"}],"models":[{"id":"m","upstream_id":"m","flags":{"supports_tool_search":STATE}}]}]}
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    inline for (.{ "true", "false", "null" }, .{ @as(?bool, true), @as(?bool, false), @as(?bool, null) }) |value, expected| {
        const bytes = try std.mem.replaceOwned(u8, arena.allocator(), document, "STATE", value);
        var loaded = try loadBytes(testing.allocator, bytes);
        defer loaded.deinit();
        const row = loaded.providers[0];
        const spec = try modelSpec(arena.allocator(), row.models[0], row.endpoints.?);
        try testing.expectEqual(expected, spec.caps.tool_search);
        const encoded = try serialize(arena.allocator(), loaded.providers);
        var restored = try loadBytes(testing.allocator, encoded);
        defer restored.deinit();
        try testing.expectEqual(expected, restored.providers[0].models[0].flags.supports_tool_search);
    }
    const supported = try std.mem.replaceOwned(u8, arena.allocator(), document, "STATE", "true");
    const chat = try std.mem.replaceOwned(u8, arena.allocator(), supported, "openai_responses", "openai_chat");
    try testing.expectError(error.BadCapability, loadBytes(testing.allocator, chat));
    const no_tools = try std.mem.replaceOwned(u8, arena.allocator(), supported, "\"supports_tool_search\":true", "\"supports_tool_search\":true,\"supports_tools\":false");
    try testing.expectError(error.BadCapability, loadBytes(testing.allocator, no_tools));
}
