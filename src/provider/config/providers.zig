//! Load the strict `providers.json` user file into resolved provider instances.
//! The file layer stays separate from the internal `ProviderInstance`. The owner zeroes each literal key.

const std = @import("std");
const instance = @import("../instance/instance.zig");
const resolve = @import("../instance/resolve.zig");

const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;

/// Bound the whole file so one document cannot exhaust memory.
const max_file_bytes = 1 << 20;
/// Limit one literal key. A valid literal key is much shorter.
const max_literal_bytes = 8 << 10;

pub const Error = error{
    BadVersion,
    DuplicateProvider,
    DuplicateModel,
    EmptyId,
    BadUrl,
    BadEnvName,
    BadLiteral,
    BadHeaderName,
    BadHeaderValue,
    HeaderConflict,
    FileTooLarge,
    NotRegularFile,
    InsecurePermissions,
} || Allocator.Error || std.Uri.ParseError;

// The file schema is strict. std.json rejects unknown fields, duplicate keys, and invalid union shapes.

const FileSource = union(enum) {
    env: []const u8,
    literal: []const u8,
};

const FileApiKey = struct {
    header: instance.ApiKeyHeader,
    source: FileSource,
};

const FileAuth = struct {
    api_key: FileApiKey,
};

const FileHeader = struct {
    name: []const u8,
    value: []const u8,
};

const FileModel = struct {
    id: []const u8,
    upstream_id: []const u8,
    limits: instance.Limits,
    cost: instance.Cost = .{},
    flags: instance.ModelFlags = .{},
};

const FileProvider = struct {
    id: []const u8,
    base_url: []const u8,
    protocol: instance.Protocol,
    auth: FileAuth,
    cache: instance.CachePolicy = .unsupported,
    headers: []const FileHeader = &.{},
    models: []const FileModel = &.{},
};

const FileDoc = struct {
    version: u32,
    providers: []const FileProvider = &.{},
};

/// The arena owns every non-secret string. The owner stores and zeroes each literal key separately.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    gpa: Allocator,
    providers: []instance.ProviderInstance = &.{},
    literals: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Loaded) void {
        for (self.literals.items) |lit| {
            std.crypto.secureZero(u8, lit);
            self.gpa.free(lit);
        }
        self.literals.deinit(self.gpa);
        self.arena.deinit();
    }
};

/// Read `path` and resolve it. A missing file returns an empty layer. An invalid file returns an error.
/// `path` must be absolute. The daemon builds it from the config directory.
pub fn load(gpa: Allocator, io: std.Io, path: []const u8) !Loaded {
    const raw = readSecureFile(gpa, io, path) catch |err| switch (err) {
        error.FileNotFound => return empty(gpa),
        else => |e| return e,
    };
    // The raw bytes may hold a literal key. Zero and free the raw bytes after the parse copies every value.
    defer {
        std.crypto.secureZero(u8, raw);
        gpa.free(raw);
    }
    return loadBytes(gpa, raw);
}

/// Parse and resolve one document. The caller owns and zeroes `bytes`. `alloc_always` copies each value.
pub fn loadBytes(gpa: Allocator, bytes: []const u8) !Loaded {
    if (bytes.len > max_file_bytes) return error.FileTooLarge;
    // Parse into a private scratch buffer, so we can zero every parsed copy even after a parse error.
    const scratch = try gpa.alloc(u8, bytes.len * 8 + 4096);
    defer {
        std.crypto.secureZero(u8, scratch);
        gpa.free(scratch);
    }
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const doc = std.json.parseFromSliceLeaky(FileDoc, fba.allocator(), bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.FileTooLarge, // the scratch is 8x the input; a denser doc is hostile
        else => |e| return e,
    };

    if (doc.version != 1) return error.BadVersion;
    return resolveDoc(gpa, doc, bytes);
}

fn empty(gpa: Allocator) Loaded {
    return .{ .arena = std.heap.ArenaAllocator.init(gpa), .gpa = gpa };
}

/// Open the file with no symlink traversal. Reject a non-regular file or a group- or other-readable file.
/// Read the file into a size-limited buffer.
fn readSecureFile(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .follow_symlinks = false });
    defer file.close(io);

    const st = try file.stat(io);
    if (st.kind != .file) return error.NotRegularFile;
    const mode: u64 = @intCast(st.permissions.toMode());
    if ((mode & 0o077) != 0) return error.InsecurePermissions; // a file that can hold a literal key stays private
    if (st.size > max_file_bytes) return error.FileTooLarge;

    var buf: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf); // the reader buffer may hold key bytes
    var reader = file.reader(io, &buf);
    const raw = try gpa.alloc(u8, @intCast(st.size));
    errdefer {
        std.crypto.secureZero(u8, raw);
        gpa.free(raw);
    }
    try reader.interface.readSliceAll(raw);
    return raw;
}

/// Validate the document and copy it into resolved `ProviderInstance` values. `source_json` is the raw file.
fn resolveDoc(gpa: Allocator, doc: FileDoc, source_json: []const u8) !Loaded {
    var out: Loaded = empty(gpa);
    errdefer out.deinit();
    const arena = out.arena.allocator();

    var providers = try arena.alloc(instance.ProviderInstance, doc.providers.len);
    for (doc.providers, 0..) |fp, i| {
        for (doc.providers[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, fp.id)) return error.DuplicateProvider;
        }
        providers[i] = try resolveProvider(&out, arena, fp, source_json);
    }
    out.providers = providers;
    return out;
}

fn resolveProvider(out: *Loaded, arena: Allocator, fp: FileProvider, source_json: []const u8) !instance.ProviderInstance {
    if (fp.id.len == 0) return error.EmptyId;
    try checkUrl(fp.base_url);

    const source: instance.CredentialSource = switch (fp.auth.api_key.source) {
        .env => |name| blk: {
            if (!validEnvName(name)) return error.BadEnvName;
            break :blk .{ .env = try arena.dupe(u8, name) };
        },
        .literal => |value| blk: {
            if (value.len == 0 or value.len > max_literal_bytes or !cleanLiteral(value)) return error.BadLiteral;
            // The literal must appear plainly in the source. A JSON escape would leave key bytes in the
            // scanner stack that we cannot zero. A plain literal never reaches that decode path.
            if (std.mem.indexOf(u8, source_json, value) == null) return error.BadLiteral;
            const owned = try out.gpa.dupe(u8, value);
            // Give `owned` to `literals` at once. `out.deinit` frees `owned` after a later error.
            out.literals.append(out.gpa, owned) catch |err| {
                std.crypto.secureZero(u8, owned);
                out.gpa.free(owned);
                return err;
            };
            break :blk .{ .literal = owned };
        },
    };

    const generated = generatedHeaderName(fp.auth.api_key.header);
    const headers = try arena.alloc(instance.Header, fp.headers.len);
    for (fp.headers, 0..) |fh, i| {
        if (!validHeaderName(fh.name)) return error.BadHeaderName;
        if (!cleanHeaderValue(fh.value)) return error.BadHeaderValue;
        if (std.ascii.eqlIgnoreCase(fh.name, generated)) return error.HeaderConflict;
        headers[i] = .{ .name = try arena.dupe(u8, fh.name), .value = try arena.dupe(u8, fh.value) };
    }

    const models = try arena.alloc(instance.ModelBinding, fp.models.len);
    for (fp.models, 0..) |fm, i| {
        if (fm.id.len == 0) return error.EmptyId;
        for (fp.models[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, fm.id)) return error.DuplicateModel;
        }
        models[i] = .{
            .id = try arena.dupe(u8, fm.id),
            .upstream_id = try arena.dupe(u8, fm.upstream_id),
            .limits = fm.limits,
            .cost = fm.cost,
            .flags = fm.flags,
        };
    }

    return .{
        .id = try arena.dupe(u8, fp.id),
        .base_url = try arena.dupe(u8, fp.base_url),
        .protocol = fp.protocol,
        .auth = .{ .api_key = .{ .header = fp.auth.api_key.header, .source = source } },
        .cache = fp.cache,
        .headers = headers,
        .models = models,
    };
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

/// A literal key holds no control byte. A control byte breaks a header line or a log.
fn cleanLiteral(value: []const u8) bool {
    for (value) |c| if (std.ascii.isControl(c)) return false;
    return true;
}

fn generatedHeaderName(header: instance.ApiKeyHeader) []const u8 {
    return switch (header) {
        .x_api_key => "x-api-key",
        .authorization_bearer => "Authorization",
    };
}

/// RFC 9110 defines the field-name token characters.
fn isTchar(c: u8) bool {
    return switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!isTchar(c)) return false;
    return true;
}

/// A header value holds no control byte except a tab. This rejects CR, LF, NUL, and DEL.
fn cleanHeaderValue(value: []const u8) bool {
    for (value) |c| if (c != '\t' and std.ascii.isControl(c)) return false;
    return true;
}

/// A resolved value holds a provider and a model binding. Both values borrow the `Loaded` arena.
pub const Resolved = struct {
    provider: instance.ProviderInstance,
    binding: instance.ModelBinding,
};

/// Resolve a provider-qualified "providerId/modelId" key against the loaded providers.
/// Return null when the key names no provider or model.
pub fn resolveModel(loaded: Loaded, qualified: []const u8) ?Resolved {
    const slash = std.mem.indexOfScalar(u8, qualified, '/') orelse return null;
    const provider_id = qualified[0..slash];
    const model_id = qualified[slash + 1 ..];
    for (loaded.providers) |p| {
        if (!std.mem.eql(u8, p.id, provider_id)) continue;
        for (p.models) |m| if (std.mem.eql(u8, m.id, model_id)) return .{ .provider = p, .binding = m };
        return null; // the provider has no binding for the model
    }
    return null;
}

pub const ResolveError = error{ AuthMismatch, MissingCredential, CredentialUnsupported };

/// Resolve one provider's API key from the process environment or a literal key.
/// The result borrows the key. Never log the key.
pub fn resolveApiKey(p: instance.ProviderInstance, env: ?*const EnvMap) ResolveError!resolve.Secret {
    const src = switch (p.auth) {
        .api_key => |a| a.source,
        else => return error.AuthMismatch,
    };
    const key = switch (src) {
        .env => |name| (if (env) |e| e.get(name) else null) orelse return error.MissingCredential,
        .literal => |bytes| bytes,
        .store => return error.CredentialUnsupported,
    };
    return .{ .api_key = key };
}

const testing = std.testing;

fn wrapProvider(comptime provider_json: []const u8) []const u8 {
    return "{\"version\":1,\"providers\":[" ++ provider_json ++ "]}";
}

test "load a provider with an env api key and one model" {
    const json = wrapProvider(
        \\{"id":"minimax","base_url":"https://api.minimax.io/anthropic","protocol":"anthropic-messages",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"env":"MINIMAX_API_KEY"}}},
        \\ "headers":[{"name":"anthropic-version","value":"2023-06-01"}],
        \\ "models":[{"id":"local","upstream_id":"MiniMax-Text","limits":{"context_window":200000,"max_output_tokens":8192}}]}
    );
    var loaded = try loadBytes(testing.allocator, json);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 1), loaded.providers.len);
    const p = loaded.providers[0];
    try testing.expectEqualStrings("minimax", p.id);
    try testing.expectEqual(instance.Protocol.@"anthropic-messages", p.protocol);
    try testing.expectEqualStrings("MINIMAX_API_KEY", p.auth.api_key.source.env);
    try testing.expectEqualStrings("anthropic-version", p.headers[0].name);
    try testing.expectEqualStrings("local", p.models[0].id);
    try testing.expectEqual(@as(u64, 8192), p.models[0].limits.max_output_tokens);
}

test "a literal api key resolves without touching the environment" {
    const json = wrapProvider(
        \\{"id":"local","base_url":"http://127.0.0.1:8080/v1","protocol":"openai-completions",
        \\ "auth":{"api_key":{"header":"authorization_bearer","source":{"literal":"sk-secret-value"}}}}
    );
    var loaded = try loadBytes(testing.allocator, json);
    defer loaded.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    const secret = try resolveApiKey(loaded.providers[0], &env);
    try testing.expectEqualStrings("sk-secret-value", secret.api_key);
}

test "an env api key resolves from the process environment" {
    const json = wrapProvider(
        \\{"id":"minimax","base_url":"https://api.minimax.io/anthropic","protocol":"anthropic-messages",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"env":"MINIMAX_API_KEY"}}}}
    );
    var loaded = try loadBytes(testing.allocator, json);
    defer loaded.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("MINIMAX_API_KEY", "sk-from-env");
    const secret = try resolveApiKey(loaded.providers[0], &env);
    try testing.expectEqualStrings("sk-from-env", secret.api_key);

    var absent = try loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic-messages",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"env":"ABSENT_KEY_NAME"}}}}
    ));
    defer absent.deinit();
    try testing.expectError(error.MissingCredential, resolveApiKey(absent.providers[0], &env));
}

test "the strict schema rejects an unknown field" {
    try testing.expectError(error.UnknownField, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic-messages",
        \\ "surprise":true,
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}}}
    )));
}

test "the strict schema rejects a duplicate object key" {
    try testing.expectError(error.DuplicateField, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","id":"y","base_url":"https://x.example/v1","protocol":"anthropic-messages",
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
        \\ {"id":"dup","base_url":"https://a.example/v1","protocol":"anthropic-messages","auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}}},
        \\ {"id":"dup","base_url":"https://b.example/v1","protocol":"anthropic-messages","auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}}}]}
    ));
    try testing.expectError(error.DuplicateModel, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"p","base_url":"https://a.example/v1","protocol":"anthropic-messages","auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}},
        \\ "models":[{"id":"m","upstream_id":"a","limits":{"context_window":1,"max_output_tokens":1}},
        \\           {"id":"m","upstream_id":"b","limits":{"context_window":1,"max_output_tokens":1}}]}
    )));
}

test "url validation rejects scheme, host, userinfo, query, and fragment" {
    const cases = [_][]const u8{
        "ftp://a.example/v1", // the URL uses the wrong scheme
        "https:///v1", // the URL has no host
        "https://user:pw@a.example/v1", // the URL includes userinfo
        "https://a.example/v1?k=v", // the URL includes a query
        "https://a.example/v1#frag", // the URL includes a fragment
    };
    for (cases) |url| {
        var buf: [256]u8 = undefined;
        const json = try std.fmt.bufPrint(
            &buf,
            "{{\"version\":1,\"providers\":[{{\"id\":\"x\",\"base_url\":\"{s}\",\"protocol\":\"anthropic-messages\",\"auth\":{{\"api_key\":{{\"header\":\"x_api_key\",\"source\":{{\"env\":\"K\"}}}}}}}}]}}",
            .{url},
        );
        try testing.expectError(error.BadUrl, loadBytes(testing.allocator, json));
    }
}

test "a bad env name is rejected" {
    try testing.expectError(error.BadEnvName, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic-messages",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"env":"9BAD-NAME"}}}}
    )));
}

test "a literal with a control byte is rejected" {
    try testing.expectError(error.BadLiteral, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic-messages",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"literal":"line\none"}}}}
    )));
}

test "bad header names, values, and auth collisions are rejected" {
    try testing.expectError(error.BadHeaderName, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic-messages","auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}},
        \\ "headers":[{"name":"bad name","value":"v"}]}
    )));
    try testing.expectError(error.BadHeaderValue, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic-messages","auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}},
        \\ "headers":[{"name":"x-note","value":"a\r\nb"}]}
    )));
    try testing.expectError(error.HeaderConflict, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic-messages","auth":{"api_key":{"header":"x_api_key","source":{"env":"K"}}},
        \\ "headers":[{"name":"X-Api-Key","value":"injected"}]}
    )));
}

test "a literal written with a json escape is rejected" {
    // The decoded value is "sk-Abc" but the source escapes it, so it never appears plainly.
    try testing.expectError(error.BadLiteral, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic-messages",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"literal":"sk-\u0041bc"}}}}
    )));
}

test "a literal key is freed once when a later check fails" {
    // The code appends the literal key before the header check fails. out.deinit frees the literal key once.
    try testing.expectError(error.HeaderConflict, loadBytes(testing.allocator, wrapProvider(
        \\{"id":"x","base_url":"https://x.example/v1","protocol":"anthropic-messages",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"literal":"sk-secret"}}},
        \\ "headers":[{"name":"X-Api-Key","value":"injected"}]}
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
