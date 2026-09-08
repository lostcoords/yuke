//! Load and write the strict `providers.json` file. An omitted field stays null for the merge.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("proto");
const ai = @import("ai");
const instance = ai.instance;
const request_ir = ai.ir;

const Allocator = std.mem.Allocator;

/// Bound the whole file so one document cannot exhaust memory.
const max_file_bytes = 1 << 20;
/// Limit one literal key. A valid literal key is much shorter.
const max_literal_bytes = 8 << 10;

pub const Error = error{
    BadVersion,
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

/// A `union(enum)` renders as one tagged key, so an api_key entry keeps the shape it always had.
const FileAuth = LocalAuth;

/// The file writes a header in the shape the provider layer already defines.
const FileHeader = instance.Header;

/// How one model reads and writes, in the flat shape the file states it.
pub const FileFlags = struct {
    supports_vision: bool = false,
    supports_tools: bool = true,
    reasoning_replay: request_ir.ReasoningReplay = .none,
    thinking_format: request_ir.ThinkingFormat = .none,
    anthropic_adaptive: bool = false,
    reasoning_budget_min: ?i64 = null,
    reasoning_budget_max: ?u64 = null,
    max_tokens_field: request_ir.MaxTokensField = .max_tokens,
};

/// One model `providers.json` defines. The library owns the effective shape, so this projects onto it.
pub const FileModel = struct {
    id: []const u8,
    upstream_id: []const u8,
    /// A limit the file omits stays unknown, and the run falls back to its own ceiling.
    limits: ai.model.Limits = .{},
    /// A price the file omits stays unknown. A local endpoint publishes none.
    cost: ai.model.Cost = .{},
    /// A null level means the model takes no effort at all.
    reasoning_levels: []const ?[]const u8 = &.{},
    flags: FileFlags = .{},
};

/// Project the file's models onto the library shape. The result borrows `arena`.
pub fn modelSpecs(arena: Allocator, models: []const FileModel) ![]const ai.model.ModelSpec {
    const out = try arena.alloc(ai.model.ModelSpec, models.len);
    for (models, 0..) |m, i| out[i] = .{
        .id = m.id,
        .upstream_id = m.upstream_id,
        // The file writes no display name, so the id names the model everywhere it is shown.
        .name = m.id,
        .limits = m.limits,
        .cost = m.cost,
        .caps = .{ .tools = m.flags.supports_tools, .vision = m.flags.supports_vision },
        .reasoning_levels = try levels(arena, m.reasoning_levels),
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

fn levels(arena: Allocator, patch: []const ?[]const u8) ![]const ai.model.ReasoningLevel {
    const out = try arena.alloc(ai.model.ReasoningLevel, patch.len);
    for (patch, 0..) |level, i| out[i] = .from(level);
    return out;
}

/// The file shape. Only `id` is required, and a catalog row can supply an absent routing field.
const FileProvider = struct {
    id: []const u8,
    base_url: ?[]const u8 = null,
    protocol: ?instance.Protocol = null,
    /// The long form names the header and the source.
    auth: ?FileAuth = null,
    /// The short form. It is a literal key, and the catalog names the header.
    api_key: ?[]const u8 = null,
    cache: ?instance.CachePolicy = null,
    /// A host that speaks the Codex flavor of the Responses API sets this.
    responses_dialect: ?instance.ResponsesDialect = null,
    headers: ?[]const FileHeader = null,
    models: []const FileModel = &.{},
};

const FileDoc = struct {
    version: u32,
    providers: []const FileProvider = &.{},
};

/// The writer omits an empty model list without broadening the strict input schema.
const WritableProvider = struct {
    id: []const u8,
    base_url: ?[]const u8 = null,
    protocol: ?instance.Protocol = null,
    auth: ?FileAuth = null,
    cache: ?instance.CachePolicy = null,
    responses_dialect: ?instance.ResponsesDialect = null,
    headers: ?[]const FileHeader = null,
    models: ?[]const FileModel = null,
};

const WritableDoc = struct {
    version: u32,
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

    if (doc.version != 1) return error.BadVersion;

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

    const doc: WritableDoc = .{ .version = 1, .providers = try fileProviders(arena.allocator(), providers) };
    var json: std.Io.Writer.Allocating = .init(arena.allocator());
    try std.json.Stringify.value(doc, .{ .emit_null_optional_fields = false, .whitespace = .indent_2 }, &json.writer);
    return gpa.dupe(u8, json.written());
}

/// Replace the absolute `path` with `bytes`. The caller renders and validates the document first.
/// The parent directory is created when it is absent, so a first write on a clean machine works.
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
        .protocol = p.protocol,
        .auth = p.auth,
        .cache = p.cache,
        .responses_dialect = p.responses_dialect,
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
    // Only an API-key route lets the file name the header. A grant always presents a bearer.
    const header: ?instance.ApiKeyHeader = if (auth) |a| switch (a) {
        .api_key => |key| key.header,
        .oauth => .authorization_bearer,
    } else null;

    if (fp.headers) |file_headers| for (file_headers, 0..) |fh, i| {
        if (!instance.validHeaderName(fh.name)) return error.BadHeaderName;
        if (!instance.validHeaderValue(fh.value)) return error.BadHeaderValue;
        for (file_headers[0..i]) |prev| {
            if (std.ascii.eqlIgnoreCase(prev.name, fh.name)) return error.HeaderConflict;
        }
        // A pinned header must not collide with the header the credential generates.
        if (header) |h| {
            const generated = (instance.AuthMechanism{ .api_key = h }).headerName().?;
            if (std.ascii.eqlIgnoreCase(fh.name, generated)) return error.HeaderConflict;
        }
    };

    for (fp.models, 0..) |fm, i| {
        if (fm.id.len == 0) return error.EmptyId;
        if (!proto.ids.isSelectorTail(fm.id)) return error.BadId;
        for (fp.models[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, fm.id)) return error.DuplicateModel;
        }
        if (fm.reasoning_levels.len > proto.meta.limits.max_reasoning_levels) return error.BadReasoningLevel;
        for (fm.reasoning_levels, 0..) |level, level_i| {
            if (level) |name| {
                if (std.meta.stringToEnum(request_ir.Effort, name) == null) return error.BadReasoningLevel;
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
        .protocol = fp.protocol,
        .auth = auth,
        .cache = fp.cache,
        .responses_dialect = fp.responses_dialect,
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

/// A local API-key credential uses a header, or the catalog names the missing header.
pub const LocalApiKey = struct {
    /// The catalog names the header when the file omits it.
    header: ?instance.ApiKeyHeader = null,
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
    protocol: ?instance.Protocol = null,
    /// Null means the route presents no credential at all.
    auth: ?LocalAuth = null,
    cache: ?instance.CachePolicy = null,
    responses_dialect: ?instance.ResponsesDialect = null,
    headers: ?[]const instance.Header = null,
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
    return "{\"version\":1,\"providers\":[" ++ provider_json ++ "]}";
}

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
        \\{"id":"minimax","base_url":"https://api.minimax.io/anthropic","protocol":"anthropic_messages",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"env":"MINIMAX_API_KEY"}}},
        \\ "headers":[{"name":"anthropic-version","value":"2023-06-01"}],
        \\ "models":[{"id":"local","upstream_id":"MiniMax-Text","limits":{"context_window":200000,"max_output_tokens":8192},
        \\ "reasoning_levels":[null,"high"]}]}
    );
    var loaded = try loadBytes(testing.allocator, json);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 1), loaded.providers.len);
    const p = loaded.providers[0];
    try testing.expectEqualStrings("minimax", p.id);
    try testing.expectEqual(instance.Protocol.anthropic_messages, p.protocol.?);
    try testing.expectEqualStrings("MINIMAX_API_KEY", p.auth.?.api_key.source.?.env);
    try testing.expectEqualStrings("anthropic-version", p.headers.?[0].name);
    try testing.expectEqualStrings("local", p.models[0].id);
    try testing.expectEqual(@as(u64, 8192), p.models[0].limits.max_output_tokens);
    try testing.expectEqual(@as(usize, 2), p.models[0].reasoning_levels.len);
    try testing.expect(p.models[0].reasoning_levels[0] == null);
    try testing.expectEqualStrings("high", p.models[0].reasoning_levels[1].?);
}

test "the strict schema rejects an unknown field" {
    try testing.expectError(error.UnknownField, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic_messages",
        \\ "surprise":true,
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}}}
    )));
}

test "the strict schema rejects a duplicate object key" {
    try testing.expectError(error.DuplicateField, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","id":"y","base_url":"https://x.example/v1","protocol":"anthropic_messages",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}}}
    )));
}

test "a bad document version is rejected" {
    try testing.expectError(error.BadVersion, loadBytes(testing.allocator,
        \\{"version":2,"providers":[]}
    ));
}

test "duplicate provider and model ids are rejected" {
    try testing.expectError(error.DuplicateProvider, loadBytes(testing.allocator,
        \\{"version":1,"providers":[
        \\ {"id":"dup","base_url":"https://a.example/v1","protocol":"anthropic_messages","auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}}},
        \\ {"id":"dup","base_url":"https://b.example/v1","protocol":"anthropic_messages","auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}}}]}
    ));
    try testing.expectError(error.DuplicateModel, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"p","base_url":"https://a.example/v1","protocol":"anthropic_messages","auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}},
        \\ "models":[{"id":"m","upstream_id":"a","limits":{"context_window":1,"max_output_tokens":1}},
        \\           {"id":"m","upstream_id":"b","limits":{"context_window":1,"max_output_tokens":1}}]}
    )));
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
        const json = try std.fmt.bufPrint(
            &buf,
            "{{\"version\":1,\"providers\":[{{\"id\":\"x\",\"base_url\":\"{s}\",\"protocol\":\"anthropic_messages\",\"auth\":{{\"api_key\":{{\"header\":\"x_api_key\",\"source\":{{\"env\":\"K\"}}}}}}}}]}}",
            .{url},
        );
        try testing.expectError(error.BadUrl, loadBytes(testing.allocator, json));
    }
}

test "a bad env name is rejected" {
    try testing.expectError(error.BadEnvName, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic_messages",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"env":"9BAD-NAME"}}}}
    )));
}

test "a literal with a control byte is rejected" {
    try testing.expectError(error.BadLiteral, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic_messages",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"literal":"line\none"}}}}
    )));
}

test "bad header names, values, and auth collisions are rejected" {
    try testing.expectError(error.BadHeaderName, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic_messages","auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}},
        \\ "headers":[{"name":"bad name","value":"v"}]}
    )));
    try testing.expectError(error.BadHeaderValue, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic_messages","auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}},
        \\ "headers":[{"name":"x-note","value":"a\r\nb"}]}
    )));
    try testing.expectError(error.HeaderConflict, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic_messages","auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}},
        \\ "headers":[{"name":"X-Api-Key","value":"injected"}]}
    )));
}

test "a keyless entry and an empty credential write back differently" {
    var loaded = try loadBytes(testing.allocator,
        \\{"version":1,"providers":[
        \\ {"id":"ollama","base_url":"http://127.0.0.1:11434/v1","protocol":"openai_chat"},
        \\ {"id":"anthropic","auth":{"api_key":{"header":"x_api_key"}}}]}
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
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}}}
    )));
}

test "a missing providers array yields an empty layer" {
    var loaded = try loadBytes(testing.allocator, "{\"version\":1}");
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
        \\{"version":1,"providers":[
        \\ {"id":"minimax","base_url":"https://api.minimax.io/anthropic","protocol":"anthropic_messages",
        \\  "auth":{"api_key":{"header":"x_api_key","source":{"env":"MINIMAX_API_KEY"}}},
        \\  "headers":[{"name":"anthropic-version","value":"2023-06-01"}],
        \\  "models":[{"id":"m","upstream_id":"MiniMax-Text","limits":{"context_window":200000,"max_output_tokens":8192}}]},
        \\ {"id":"ollama","base_url":"http://127.0.0.1:11434/v1","protocol":"openai_chat"},
        \\ {"id":"codex","base_url":"https://chatgpt.com/backend-api/codex","protocol":"openai_responses",
        \\  "responses_dialect":"codex","api_key":"sk-literal"}]}
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
    try testing.expectEqual(instance.ApiKeyHeader.x_api_key, again.providers[0].auth.?.api_key.header.?);
    try testing.expectEqualStrings("anthropic-version", again.providers[0].headers.?[0].name);
    try testing.expectEqualStrings("m", again.providers[0].models[0].id);
    // A keyless entry survives the round trip, so the writer never invents a credential.
    try testing.expect(again.providers[1].auth == null);
    // The short form is read once and written back in the long form.
    try testing.expectEqualStrings("sk-literal", again.providers[2].auth.?.api_key.source.?.literal);
    try testing.expectEqual(instance.ResponsesDialect.codex, again.providers[2].responses_dialect.?);
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
        \\{"id":"deepseek","base_url":"https://api.deepseek.com/v1","protocol":"openai_chat",
        \\ "models":[{"id":"r1","upstream_id":"deepseek-reasoner",
        \\ "limits":{"context_window":65536,"max_output_tokens":8192},
        \\ "reasoning_levels":[null,"high"],
        \\ "flags":{"reasoning_replay":"reasoning_content","thinking_format":"deepseek",
        \\ "max_tokens_field":"max_completion_tokens","supports_vision":true,"reasoning_budget_max":32000}}]}
    ));
    defer loaded.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spec = (try modelSpecs(arena.allocator(), loaded.providers[0].models))[0];

    try testing.expectEqualStrings("deepseek-reasoner", spec.upstream_id);
    try testing.expectEqualStrings("r1", spec.name); // The file writes no display name.
    try testing.expectEqual(@as(?u64, 65536), spec.limits.context_window);
    try testing.expectEqual(request_ir.ThinkingFormat.deepseek, spec.dialect.thinking_format);
    try testing.expectEqual(request_ir.ReasoningReplay.reasoning_content, spec.dialect.reasoning_replay);
    try testing.expectEqual(request_ir.MaxTokensField.max_completion_tokens, spec.dialect.max_tokens_field);
    try testing.expectEqual(@as(?u64, 32000), spec.dialect.reasoning_budget.range.max);
    try testing.expect(spec.caps.vision.? and spec.caps.tools.?); // `supports_tools` defaults true.
    try testing.expect(spec.reasoning_levels[0] == .none);
    try testing.expectEqualStrings("high", spec.reasoning_levels[1].named);

    // A price the file omits is unknown, not zero. A local endpoint publishes none.
    try testing.expect(spec.cost.input == null);
}

test "a file model may omit its limits entirely" {
    var loaded = try loadBytes(testing.allocator, wrapProvider(
        \\{"id":"ollama","base_url":"http://127.0.0.1:11434/v1","protocol":"openai_chat",
        \\ "models":[{"id":"qwen3","upstream_id":"qwen3:8b"}]}
    ));
    defer loaded.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spec = (try modelSpecs(arena.allocator(), loaded.providers[0].models))[0];
    // The run falls back to its own ceiling, so a local endpoint needs no invented number.
    try testing.expect(spec.limits.max_output_tokens == null);
}

test "the shipped sample document still loads" {
    // The sample is documentation, so a schema change must not leave it silently unparseable.
    var loaded = try loadBytes(testing.allocator, @embedFile("providers.sample.json"));
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.providers.len);
    try testing.expectEqualStrings("minimax", loaded.providers[0].id);
    try testing.expect(loaded.providers[0].models[0].flags.anthropic_adaptive);
    try testing.expect(loaded.providers[1].auth == null); // The local server needs no key.
}
