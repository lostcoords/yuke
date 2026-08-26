//! Extract wire documentation comments without resolving any Zig types.

const std = @import("std");

const DocMap = std.StringHashMap([]const u8);

fn docComment(a: std.mem.Allocator, tree: std.zig.Ast, first_token: std.zig.Ast.TokenIndex) !?[]const u8 {
    if (first_token == 0 or tree.tokenTag(first_token - 1) != .doc_comment) return null;

    var first = first_token - 1;
    while (first > 0 and tree.tokenTag(first - 1) == .doc_comment) first -= 1;

    var text: std.Io.Writer.Allocating = .init(a);
    var token = first;
    var first_line = true;
    while (tree.tokenTag(token) == .doc_comment) : (token += 1) {
        if (!first_line) try text.writer.writeByte(' ');
        first_line = false;
        const raw = tree.tokenSlice(token);
        const line = if (raw.len >= 3) raw[3..] else "";
        try text.writer.writeAll(std.mem.trim(u8, line, " \t\r\n"));
    }

    const result = std.mem.trim(u8, text.written(), " \t\r\n");
    if (result.len == 0) return null;
    return result;
}

fn identifierName(a: std.mem.Allocator, tree: std.zig.Ast, token: std.zig.Ast.TokenIndex) ![]const u8 {
    const raw = tree.tokenSlice(token);
    if (raw.len >= 3 and raw[0] == '@' and raw[1] == '"' and raw[raw.len - 1] == '"') {
        return a.dupe(u8, raw[2 .. raw.len - 1]);
    }
    return raw;
}

fn putFieldDoc(
    a: std.mem.Allocator,
    docs: *DocMap,
    tree: std.zig.Ast,
    type_name: []const u8,
    field: std.zig.Ast.full.ContainerField,
) !void {
    const name = try identifierName(a, tree, field.ast.main_token);
    const key = try std.fmt.allocPrint(a, "{s}.{s}", .{ type_name, name });
    if (try docComment(a, tree, field.firstToken())) |doc| try docs.put(key, doc);
}

fn extractSource(a: std.mem.Allocator, docs: *DocMap, source: []const u8) !void {
    const source_z = try a.dupeZ(u8, source);
    var tree = try std.zig.Ast.parse(a, source_z, .zig);
    defer tree.deinit(a);

    var container_buffer: [2]std.zig.Ast.Node.Index = undefined;
    for (tree.rootDecls()) |node| {
        const var_decl = tree.fullVarDecl(node) orelse continue;
        if (var_decl.visib_token == null or tree.tokenTag(var_decl.visib_token.?) != .keyword_pub or
            tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) continue;

        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        const container = tree.fullContainerDecl(&container_buffer, init_node) orelse continue;
        const type_name = tree.tokenSlice(var_decl.ast.mut_token + 1);
        if (try docComment(a, tree, tree.firstToken(node))) |doc| try docs.put(type_name, doc);

        for (container.ast.members) |member| {
            const field = tree.fullContainerField(member) orelse continue;
            try putFieldDoc(a, docs, tree, type_name, field);
        }
    }
}

pub fn load(a: std.mem.Allocator, io: std.Io) !DocMap {
    var docs = DocMap.init(a);
    errdefer docs.deinit();

    var dir = try std.Io.Dir.cwd().openDir(io, "lib/wire", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const source = try dir.readFileAlloc(io, entry.name, a, .unlimited);
        try extractSource(a, &docs, source);
    }

    return docs;
}
