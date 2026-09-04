//! Turn one yuke catalog document into the Zig table that the AI module compiles in.
//! An unknown routing name fails the run; an unknown dialect name keeps the default and is reported.

const std = @import("std");
const vocab = @import("ai_vocab");

pub const Error = error{InvalidDocument};

/// The document version this generator accepts.
pub const version = 1;

/// What one run produced. The driver reports these numbers.
pub const Stats = struct {
    providers: usize = 0,
    models: usize = 0,
    /// Providers that name no environment variable. A preset cannot read a key without one.
    providers_without_env: usize = 0,
    /// Dialect names this generator does not know. Each one left a field at its default.
    unknown: []const []const u8 = &.{},
};

const preamble =
    \\//! The provider catalog, generated from the yuke control plane.
    \\//! Do not edit. Run `zig build cataloggen` to regenerate this file.
    \\
    \\const std = @import("std");
    \\const instance = @import("instance/instance.zig");
    \\const model = @import("model.zig");
    \\
    \\/// One provider this library can call, and the models it serves.
    \\pub const Provider = struct {
    \\    id: []const u8,
    \\    name: []const u8,
    \\    /// The environment variables that hold this provider's key by convention.
    \\    env: []const []const u8,
    \\    /// The credential scheme. This library runs no OAuth flow, so a grant arrives from the caller.
    \\    auth: model.AuthKind,
    \\    /// The one variable that holds the key, when the catalog can name it.
    \\    auth_env: ?[]const u8,
    \\    /// The route, less the identity headers that only a live grant carries.
    \\    route: instance.ProviderInstance,
    \\    models: []const model.ModelSpec,
    \\};
    \\
    \\/// Return the provider with this id, or null.
    \\pub fn find(id: []const u8) ?*const Provider {
    \\    for (&providers) |*row| if (std.mem.eql(u8, row.id, id)) return row;
    \\    return null;
    \\}
    \\
    \\/// Return the model that `provider_id` serves under `model_id`, or null.
    \\pub fn findModel(provider_id: []const u8, model_id: []const u8) ?*const model.ModelSpec {
    \\    const row = find(provider_id) orelse return null;
    \\    for (row.models) |*spec| if (std.mem.eql(u8, spec.id, model_id)) return spec;
    \\    return null;
    \\}
    \\
    \\
;

/// One run. It holds the report that `emitDialect` adds to.
const Run = struct {
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    stats: Stats = .{},
    unknown: std.ArrayList([]const u8) = .empty,

    /// Record a name this generator does not know. The field keeps its default.
    fn degrade(self: *Run, field: []const u8, name: []const u8) !void {
        const note = try std.fmt.allocPrint(self.arena, "{s}={s}", .{ field, name });
        for (self.unknown.items) |seen| if (std.mem.eql(u8, seen, note)) return;
        try self.unknown.append(self.arena, note);
    }
};

/// Write the canonically formatted table for one document, so `zig fmt` never makes it stale.
pub fn emit(arena: std.mem.Allocator, w: *std.Io.Writer, source: []const u8) !Stats {
    var raw: std.Io.Writer.Allocating = .init(arena);
    const stats = try build(arena, &raw.writer, source);

    const text_z = try arena.dupeZ(u8, raw.written());
    var tree = try std.zig.Ast.parse(arena, text_z, .zig);
    defer tree.deinit(arena);
    std.debug.assert(tree.errors.len == 0); // Every value is escaped, so the render input always parses.
    try tree.render(arena, w, .{});
    return stats;
}

fn build(arena: std.mem.Allocator, w: *std.Io.Writer, source: []const u8) !Stats {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{}) catch return Error.InvalidDocument;
    const root = try object(parsed);
    if (try number(try member(root, "version")) != version) return Error.InvalidDocument;

    var run: Run = .{ .arena = arena, .w = w };
    try w.writeAll(preamble);
    try w.print("/// The catalog revision these rows come from.\npub const revision = \"{f}\";\n\n", .{
        std.zig.fmtString(try string(root, "catalog_rev")),
    });

    try w.writeAll("pub const providers = [_]Provider{\n");
    for (try array(root, "providers")) |row| {
        try emitProvider(&run, try object(row));
        run.stats.providers += 1;
    }
    try w.writeAll("};\n");
    if (run.stats.providers == 0) return Error.InvalidDocument; // An empty table would compile and serve nothing.

    run.stats.unknown = run.unknown.items;
    return run.stats;
}

fn emitProvider(run: *Run, provider: std.json.ObjectMap) !void {
    const w = run.w;
    // An executable provider states every routing field. A null here is a document this tool cannot use.
    const protocol = try routingName(vocab.types.Protocol, try string(provider, "protocol"));
    const auth = try object(try member(provider, "auth"));
    const kind = try string(auth, "kind");

    try w.print("    .{{\n        .id = \"{f}\",\n        .name = \"{f}\",\n", .{
        std.zig.fmtString(try string(provider, "id")),
        std.zig.fmtString(try string(provider, "name")),
    });

    try w.writeAll("        .env = &.{");
    const env = optionalArray(provider, "env");
    if (env.len == 0) run.stats.providers_without_env += 1;
    for (env, 0..) |name, i| {
        try w.print("{s} \"{f}\"", .{ if (i == 0) "" else ",", std.zig.fmtString(try text(name)) });
    }
    try w.writeAll(if (env.len == 0) "}," else " },");

    try w.print("\n        .auth = .{s},\n", .{try routingName(vocab.model.AuthKind, kind)});
    if (auth.get("env")) |value| {
        try w.print("        .auth_env = \"{f}\",\n", .{std.zig.fmtString(try text(value))});
    } else try w.writeAll("        .auth_env = null,\n");
    try w.writeAll("        .route = .{\n");
    try w.print("            .base_url = \"{f}\",\n", .{std.zig.fmtString(try string(provider, "base_url"))});
    try w.print("            .protocol = .{s},\n", .{protocol});
    // Every grant presents a bearer, so an OAuth flow selects only the response dialect.
    try w.print("            .auth = .{{ .api_key = .{s} }},\n", .{
        if (std.mem.eql(u8, kind, "oauth")) "authorization_bearer" else try routingName(vocab.instance.ApiKeyHeader, try string(auth, "header")),
    });
    try w.print("            .cache = .{s},\n", .{try routingName(vocab.instance.CachePolicy, try string(provider, "cache"))});
    try w.print("            .responses_dialect = .{s},\n", .{
        try routingName(vocab.ir.ResponsesDialect, try string(provider, "responses_dialect")),
    });

    try w.writeAll("            .headers = &.{");
    const headers = try array(provider, "headers");
    for (headers, 0..) |item, i| {
        const header = try object(item);
        try w.print("{s} .{{ .name = \"{f}\", .value = \"{f}\" }}", .{
            if (i == 0) "" else ",",
            std.zig.fmtString(try string(header, "name")),
            std.zig.fmtString(try string(header, "value")),
        });
    }
    try w.writeAll(if (headers.len == 0) "},\n" else " },\n");
    try w.writeAll("        },\n        .models = &.{\n");

    for (try array(provider, "models")) |item| {
        try emitModel(run, try object(item), protocol);
        run.stats.models += 1;
    }
    try w.writeAll("        },\n    },\n");
}

fn emitModel(run: *Run, spec: std.json.ObjectMap, protocol: []const u8) !void {
    const w = run.w;
    const flags = try object(try member(spec, "flags"));
    const limits = try object(try member(spec, "limits"));
    const cost = try object(try member(spec, "cost"));

    try w.print("            .{{\n                .id = \"{f}\",\n                .upstream_id = \"{f}\",\n                .name = \"{f}\",\n", .{
        std.zig.fmtString(try string(spec, "id")),
        std.zig.fmtString(try string(spec, "upstream_id")),
        std.zig.fmtString(try string(spec, "name")),
    });

    try w.writeAll("                .limits = .{");
    try emitOptionalInt(w, limits, "context_window");
    try emitOptionalInt(w, limits, "max_output_tokens");
    try w.writeAll(" },\n                .cost = .{");
    for ([_][]const u8{ "input", "output", "cache_read", "cache_write" }) |name| {
        try emitOptionalFloat(w, cost, name);
    }
    try w.print(" }},\n                .caps = .{{ .tools = {}, .vision = {}", .{
        try boolean(flags, "supports_tools"),
        try boolean(flags, "supports_vision"),
    });
    // An absent capability stays unknown, so a caller may still try it.
    try emitOptionalBool(w, flags, "supports_structured_output", "structured_output");
    try emitOptionalBool(w, flags, "can_disable_reasoning", "disable_reasoning");
    try w.writeAll(" },\n");
    try emitModalities(run, try object(try member(spec, "modalities")));
    if (try member(spec, "status") != .null) {
        try w.print("                .status = \"{f}\",\n", .{std.zig.fmtString(try string(spec, "status"))});
    }

    // The level set is open, so any name reaches the table as it stands.
    try w.writeAll("                .reasoning_levels = &.{");
    for (try array(spec, "reasoning_levels"), 0..) |item, i| {
        const separator = if (i == 0) "" else ",";
        // A null level means the model takes no effort at all.
        if (item == .null) {
            try w.print("{s} .none", .{separator});
        } else {
            try w.print("{s} .{{ .named = \"{f}\" }}", .{ separator, std.zig.fmtString(try text(item)) });
        }
    }
    try w.writeAll("},\n                .dialect = .{");
    try emitDialect(run, flags, protocol);
    try w.writeAll(" },\n            },\n");
}

/// Write the dialect members this model states. An unknown name is reported and left out.
fn emitDialect(run: *Run, flags: std.json.ObjectMap, protocol: []const u8) !void {
    const w = run.w;
    // Only an OpenAI-chat host reads a thinking format, so another protocol would reject it.
    if (flags.get("thinking_format")) |value| {
        const name = try text(value);
        // Only an OpenAI-chat host reads a thinking format, so another protocol would reject it.
        if (!std.mem.eql(u8, protocol, "openai_chat")) {
            try run.degrade("thinking_format outside openai_chat", name);
        } else try emitDialectMember(run, vocab.ir.ThinkingFormat, "thinking_format", name);
    }
    if (flags.get("reasoning_replay")) |value| {
        try emitDialectMember(run, vocab.ir.ReasoningReplay, "reasoning_replay", try text(value));
    }
    if (flags.get("max_tokens_field")) |value| {
        try emitDialectMember(run, vocab.ir.MaxTokensField, "max_tokens_field", try text(value));
    }
    if (flags.get("anthropic_adaptive")) |value| {
        if (value != .bool) return Error.InvalidDocument;
        try w.print(" .anthropic_adaptive = {},", .{value.bool});
    }

    const min = flags.get("reasoning_budget_min");
    const max = flags.get("reasoning_budget_max");
    if (min == null and max == null) return;
    try w.writeAll(" .reasoning_budget = .{ .range = .{");
    if (min) |value| try w.print(" .min = {d},", .{try number(value)});
    if (max) |value| try w.print(" .max = {d},", .{try number(value)});
    try w.writeAll(" } },");
}

/// Write one dialect member, or report a name this build does not know and keep the field default.
fn emitDialectMember(run: *Run, comptime Vocabulary: type, member_name: []const u8, name: []const u8) !void {
    const tag = std.meta.stringToEnum(Vocabulary, name) orelse return run.degrade(member_name, name);
    try run.w.print(" .{s} = .{s},", .{ member_name, @tagName(tag) });
}

fn emitOptionalBool(w: *std.Io.Writer, map: std.json.ObjectMap, key: []const u8, member_name: []const u8) !void {
    const value = map.get(key) orelse return;
    if (value != .bool) return Error.InvalidDocument;
    try w.print(", .{s} = {}", .{ member_name, value.bool });
}

/// Write the kinds this model reads and writes, and report a kind this build does not know.
fn emitModalities(run: *Run, modalities: std.json.ObjectMap) !void {
    const w = run.w;
    try w.writeAll("                .modalities = .{");
    for ([_][]const u8{ "input", "output" }) |side| {
        const items = try array(modalities, side);
        if (items.len == 0) continue;
        try w.print(" .{s} = &.{{", .{side});
        var written: usize = 0;
        for (items) |item| {
            const name = try text(item);
            const tag = std.meta.stringToEnum(vocab.model.Modality, name) orelse {
                try run.degrade("modality", name);
                continue;
            };
            try w.print("{s} .{s}", .{ if (written == 0) "" else ",", @tagName(tag) });
            written += 1;
        }
        try w.writeAll(if (written == 0) "}," else " },");
    }
    try w.writeAll(" },\n");
}

fn emitOptionalInt(w: *std.Io.Writer, map: std.json.ObjectMap, key: []const u8) !void {
    const value = map.get(key) orelse return Error.InvalidDocument;
    if (value == .null) return; // A limit the source does not publish stays null.
    const count = try number(value);
    if (count < 0) return Error.InvalidDocument; // The field is unsigned, so a negative never compiles.
    try w.print(" .{s} = {d},", .{ key, count });
}

fn emitOptionalFloat(w: *std.Io.Writer, map: std.json.ObjectMap, key: []const u8) !void {
    const value = map.get(key) orelse return Error.InvalidDocument;
    if (value == .null) return; // A null price is not a zero price.
    try w.print(" .{s} = {d},", .{ key, switch (value) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return Error.InvalidDocument,
    } });
}

// ── The routing sets. An unknown name fails the run, because no request can be built without it. ──

/// Name the tag `name` selects, or fail: these decide the route, so they have no working default.
fn routingName(comptime Vocabulary: type, name: []const u8) ![]const u8 {
    const tag = std.meta.stringToEnum(Vocabulary, name) orelse return Error.InvalidDocument;
    return @tagName(tag);
}

// ── Strict readers. Every one fails on a shape the document does not state. ──

fn object(value: std.json.Value) !std.json.ObjectMap {
    return if (value == .object) value.object else Error.InvalidDocument;
}

fn member(map: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return map.get(key) orelse Error.InvalidDocument;
}

fn text(value: std.json.Value) ![]const u8 {
    return if (value == .string) value.string else Error.InvalidDocument;
}

fn string(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return text(try member(map, key));
}

fn boolean(map: std.json.ObjectMap, key: []const u8) !bool {
    const value = try member(map, key);
    return if (value == .bool) value.bool else Error.InvalidDocument;
}

fn number(value: std.json.Value) !i64 {
    return if (value == .integer) value.integer else Error.InvalidDocument;
}

fn array(map: std.json.ObjectMap, key: []const u8) ![]const std.json.Value {
    const value = try member(map, key);
    return if (value == .array) value.array.items else Error.InvalidDocument;
}

/// Read an array the document may not carry yet. A missing key gives an empty list.
fn optionalArray(map: std.json.ObjectMap, key: []const u8) []const std.json.Value {
    const value = map.get(key) orelse return &.{};
    return if (value == .array) value.array.items else &.{};
}

const testing = std.testing;

const one_provider =
    \\{"version":1,"catalog_rev":"abc","providers":[
    \\ {"id":"anthropic","name":"Anthropic","env":["ANTHROPIC_API_KEY"],
    \\  "base_url":"https://api.anthropic.com/v1","protocol":"anthropic_messages",
    \\  "auth":{"kind":"api_key","header":"x_api_key","env":"ANTHROPIC_API_KEY"},
    \\  "cache":"ephemeral","responses_dialect":"standard",
    \\  "headers":[{"name":"anthropic-version","value":"2023-06-01"}],
    \\  "models":[{"id":"claude","upstream_id":"claude","name":"Claude",
    \\   "limits":{"context_window":200000,"max_output_tokens":64000},
    \\   "cost":{"input":3,"output":15,"cache_read":0.3,"cache_write":null},
    \\   "flags":{"supports_tools":true,"supports_vision":true,"reasoning_budget_min":1024},
    \\   "modalities":{"input":["text","image"],"output":["text"]},
    \\   "reasoning":true,"reasoning_levels":["low","high"],"status":"beta"}]}]}
;

fn generate(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    _ = try emit(a, &out.writer, source);
    return out.written();
}

test "a provider and its model reach the generated table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try generate(arena.allocator(), one_provider);

    try testing.expect(std.mem.indexOf(u8, out, "pub const revision = \"abc\";") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".env = &.{\"ANTHROPIC_API_KEY\"}") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".protocol = .anthropic_messages") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".auth = .{ .api_key = .x_api_key }") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".cache = .ephemeral") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".{ .name = \"anthropic-version\", .value = \"2023-06-01\" }") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".reasoning_levels = &.{ .{ .named = \"low\" }, .{ .named = \"high\" } }") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".min = 1024,") != null);

    // A null price is not a zero price, so the member stays absent and the field default holds.
    try testing.expect(std.mem.indexOf(u8, out, ".cache_write") == null);
    try testing.expect(std.mem.indexOf(u8, out, ".cache_read = 0.3,") != null);
}

test "an oauth provider routes as a bearer and keeps its dialect" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source =
        \\{"version":1,"catalog_rev":"r","providers":[
        \\ {"id":"openai-codex","name":"Codex","env":[],
        \\  "base_url":"https://chatgpt.com/backend-api/codex","protocol":"openai_responses",
        \\  "auth":{"kind":"oauth","flow":"codex"},"cache":"unsupported",
        \\  "responses_dialect":"codex","headers":[],"models":[]}]}
    ;
    const out = try generate(arena.allocator(), source);
    try testing.expect(std.mem.indexOf(u8, out, ".auth = .oauth") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".auth = .{ .api_key = .authorization_bearer }") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".responses_dialect = .codex") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".env = &.{}") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".headers = &.{}") != null);
}

test "an unknown routing name fails the run" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A request cannot be built without these, so a wrong name must never reach the table.
    inline for (.{
        .{ "\"protocol\":\"anthropic_messages\"", "\"protocol\":\"gemini\"" },
        .{ "\"kind\":\"api_key\",\"header\":\"x_api_key\"", "\"kind\":\"api_key\",\"header\":\"x-api-key\"" },
        .{ "\"cache\":\"ephemeral\"", "\"cache\":\"eternal\"" },
        .{ "\"version\":1", "\"version\":2" },
    }) |case| {
        const broken = try std.mem.replaceOwned(u8, a, one_provider, case[0], case[1]);
        try testing.expectError(Error.InvalidDocument, generate(a, broken));
    }
}

const Run_ = struct { stats: Stats, text: []const u8 };

/// Generate from a document whose model carries `extra` flags.
fn withFlags(a: std.mem.Allocator, extra: []const u8) !Run_ {
    const source = try std.mem.replaceOwned(u8, a, one_provider, "\"supports_vision\":true", extra);
    var out: std.Io.Writer.Allocating = .init(a);
    return .{ .stats = try emit(a, &out.writer, source), .text = out.written() };
}

test "an unknown dialect name keeps the default and is reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A new upstream name must never break the build, because the field has a working default.
    const unknown = try withFlags(a, "\"supports_vision\":true,\"reasoning_replay\":\"reasoning_blocks\"");
    try testing.expectEqual(@as(usize, 1), unknown.stats.unknown.len);
    try testing.expectEqualStrings("reasoning_replay=reasoning_blocks", unknown.stats.unknown[0]);
    // The name must stay out of the table, or the generated file names an enum tag that does not exist.
    try testing.expect(std.mem.indexOf(u8, unknown.text, "reasoning_blocks") == null);

    // A thinking format belongs to OpenAI-chat alone, so another protocol reports it and drops it.
    const wrong = try withFlags(a, "\"supports_vision\":true,\"thinking_format\":\"deepseek\"");
    try testing.expectEqual(@as(usize, 1), wrong.stats.unknown.len);
    try testing.expectEqualStrings("thinking_format outside openai_chat=deepseek", wrong.stats.unknown[0]);
    try testing.expect(std.mem.indexOf(u8, wrong.text, "thinking_format") == null);

    const clean = try withFlags(a, "\"supports_vision\":true,\"reasoning_replay\":\"reasoning_content\"");
    try testing.expectEqual(@as(usize, 0), clean.stats.unknown.len);
    try testing.expect(std.mem.indexOf(u8, clean.text, ".reasoning_replay = .reasoning_content,") != null);
}

test "a negative limit is rejected before it reaches an unsigned field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const broken = try std.mem.replaceOwned(u8, a, one_provider, "\"context_window\":200000", "\"context_window\":-1");
    try testing.expectError(Error.InvalidDocument, generate(a, broken));
}

test "a document with no provider is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        Error.InvalidDocument,
        generate(arena.allocator(), "{\"version\":1,\"catalog_rev\":\"r\",\"providers\":[]}"),
    );
}
