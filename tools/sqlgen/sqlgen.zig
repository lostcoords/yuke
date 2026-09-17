//! Validate named SQLite queries against a real schema and emit typed Zig declarations.

const std = @import("std");
const zqlite = @import("zqlite");
const c = zqlite.c;

pub const Cardinality = enum { exec, one, optional, many };

pub const Field = struct {
    name: []const u8,
    zig_type: []const u8,
    required: bool,
};

pub const Definition = struct {
    name: []const u8,
    cardinality: Cardinality,
    sql: []const u8,
    fields: []const Field,
    row_from: ?[]const u8 = null,
};

pub const Resolved = struct {
    definition: Definition,
    params: []const Field,
    row: []const Field,
};

pub fn parse(a: std.mem.Allocator, source: []const u8) ![]const Definition {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    var line_it = std.mem.splitScalar(u8, source, '\n');
    while (line_it.next()) |line| try lines.append(a, std.mem.trimEnd(u8, line, "\r"));

    var definitions: std.ArrayList(Definition) = .empty;
    errdefer definitions.deinit(a);
    var i: usize = 0;
    while (i < lines.items.len) {
        const header = parseHeader(lines.items[i]) orelse {
            if (std.mem.startsWith(u8, std.mem.trim(u8, lines.items[i], " \t"), "-- name:")) {
                return error.InvalidSource;
            }
            i += 1;
            continue;
        };
        i += 1;

        var fields: std.ArrayList(Field) = .empty;
        var row_from: ?[]const u8 = null;
        while (i < lines.items.len) : (i += 1) {
            const trimmed = std.mem.trim(u8, lines.items[i], " \t");
            if (!std.mem.startsWith(u8, trimmed, "--")) break;
            if (parseHeader(lines.items[i]) != null) break;
            const row_prefix = "-- row-from:";
            if (std.mem.startsWith(u8, trimmed, row_prefix)) {
                const name = std.mem.trim(u8, trimmed[row_prefix.len..], " \t");
                if (row_from != null or !isIdentifier(name) or header.cardinality == .exec) return error.InvalidSource;
                row_from = name;
                continue;
            }
            const field = parseField(trimmed) orelse continue;
            if (fieldIndex(fields.items, field.name) != null) return error.DuplicateField;
            try fields.append(a, field);
        }

        const sql_start = i;
        while (i < lines.items.len and parseHeader(lines.items[i]) == null) : (i += 1) {}
        const sql = try joinLines(a, lines.items[sql_start..i]);
        if (sql.len == 0) return error.InvalidSource;

        try definitions.append(a, .{
            .name = try a.dupe(u8, header.name),
            .cardinality = header.cardinality,
            .sql = sql,
            .fields = try fields.toOwnedSlice(a),
            .row_from = row_from,
        });
    }
    if (definitions.items.len == 0) return error.InvalidSource;
    return definitions.toOwnedSlice(a);
}

const Header = struct { name: []const u8, cardinality: Cardinality };

fn parseHeader(line: []const u8) ?Header {
    const trimmed = std.mem.trim(u8, line, " \t");
    const prefix = "-- name:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const rest = std.mem.trim(u8, trimmed[prefix.len..], " \t");
    const space = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse return null;
    const name = std.mem.trim(u8, rest[0..space], " \t");
    const marker = std.mem.trim(u8, rest[space + 1 ..], " \t");
    if (!isIdentifier(name)) return null;
    const cardinality: Cardinality = if (std.mem.eql(u8, marker, ":exec"))
        .exec
    else if (std.mem.eql(u8, marker, ":one"))
        .one
    else if (std.mem.eql(u8, marker, ":optional"))
        .optional
    else if (std.mem.eql(u8, marker, ":many"))
        .many
    else
        return null;
    return .{ .name = name, .cardinality = cardinality };
}

fn parseField(line: []const u8) ?Field {
    const body = std.mem.trim(u8, line[2..], " \t");
    const colon = std.mem.indexOfScalar(u8, body, ':') orelse return null;
    const name = std.mem.trim(u8, body[0..colon], " \t");
    if (!isIdentifier(name)) return null;
    const raw_type = std.mem.trim(u8, body[colon + 1 ..], " \t");
    if (raw_type.len == 0) return null;
    const required = raw_type[raw_type.len - 1] == '!';
    const zig_type = std.mem.trimEnd(u8, raw_type[0 .. raw_type.len - @intFromBool(required)], " \t");
    if (zig_type.len == 0) return null;
    return .{ .name = name, .zig_type = zig_type, .required = required };
}

fn joinLines(a: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    var first: usize = 0;
    while (first < lines.len and std.mem.trim(u8, lines[first], " \t").len == 0) : (first += 1) {}
    // Drop blank or comment-only lines at the end. A loose comment before the next query is not part of the current SQL.
    var end = lines.len;
    while (end > first and isBlankOrComment(lines[end - 1])) : (end -= 1) {}
    if (first == end) return a.dupe(u8, "");

    return std.mem.join(a, "\n", lines[first..end]);
}

/// Resolve source rows first, then validate each reference against its source.
pub fn resolveAll(a: std.mem.Allocator, conn: zqlite.Conn, definitions: []const Definition, diagnostic: ?*?[]const u8) ![]const Resolved {
    const queries = try a.alloc(Resolved, definitions.len);
    for (definitions, 0..) |definition, i| {
        if (definition.row_from != null) continue;
        if (diagnostic) |out| out.* = definition.name;
        queries[i] = try resolve(a, conn, definition, null);
    }
    for (definitions, 0..) |definition, i| {
        if (definition.row_from == null) continue;
        if (diagnostic) |out| out.* = definition.name;
        var source = i;
        // A chain longer than the query set must contain a cycle.
        for (0..definitions.len) |_| {
            const name = definitions[source].row_from orelse break;
            source = for (definitions, 0..) |candidate, index| {
                if (std.mem.eql(u8, candidate.name, name)) break index;
            } else return error.UnknownRowSource;
        } else return error.RowSourceCycle;
        const row = queries[source].row;
        if (row.len == 0) return error.RowShapeMismatch;
        queries[i] = try resolve(a, conn, definition, row);
    }
    if (diagnostic) |out| out.* = null;
    return queries;
}

fn resolve(a: std.mem.Allocator, conn: zqlite.Conn, definition: Definition, shared_row: ?[]const Field) !Resolved {
    std.debug.assert((definition.row_from != null) == (shared_row != null));
    var statement = try prepareStatement(conn, definition.sql);
    defer statement.deinit();

    const column_count: usize = @intCast(c.sqlite3_column_count(statement.stmt));
    if ((definition.cardinality == .exec) != (column_count == 0)) return error.CardinalityMismatch;

    if (shared_row) |fields| if (fields.len != column_count) return error.RowShapeMismatch;

    const used = try a.alloc(bool, definition.fields.len);
    defer a.free(used);
    @memset(used, false);
    var params: std.ArrayList(Field) = .empty;
    errdefer params.deinit(a);
    var row: std.ArrayList(Field) = .empty;
    errdefer row.deinit(a);

    const parameter_count: usize = @intCast(c.sqlite3_bind_parameter_count(statement.stmt));
    for (0..parameter_count) |parameter_i| {
        const raw_name = c.sqlite3_bind_parameter_name(statement.stmt, @intCast(parameter_i + 1));
        if (raw_name == null) return error.ParameterUnnamed;
        const full_name = std.mem.span(raw_name);
        if (full_name.len < 2 or (full_name[0] != ':' and full_name[0] != '@' and full_name[0] != '$')) {
            return error.ParameterUnnamed;
        }
        const annotation_i = fieldIndex(definition.fields, full_name[1..]) orelse
            return error.ParameterMissingType;
        if (fieldIndex(params.items, definition.fields[annotation_i].name) != null) return error.ParameterDuplicate;
        used[annotation_i] = true;
        try params.append(a, definition.fields[annotation_i]);
    }

    for (0..column_count) |column_i| {
        const raw_name = c.sqlite3_column_name(statement.stmt, @intCast(column_i));
        if (raw_name == null) return error.NoMem;
        const name = std.mem.span(raw_name);
        if (!isIdentifier(name)) return error.ColumnInvalidName;
        if (fieldIndex(row.items, name) != null) return error.ColumnDuplicate;

        if (shared_row) |fields| {
            const field = fields[column_i];
            if (!std.mem.eql(u8, field.name, name)) return error.RowShapeMismatch;
            if (fieldIndex(definition.fields, name)) |annotation_i| {
                const annotation = definition.fields[annotation_i];
                if (!std.mem.eql(u8, annotation.zig_type, field.zig_type) or annotation.required != field.required) return error.RowShapeMismatch;
                used[annotation_i] = true;
            }
            try row.append(a, field);
            continue;
        }

        if (fieldIndex(definition.fields, name)) |annotation_i| {
            used[annotation_i] = true;
            try row.append(a, definition.fields[annotation_i]);
            continue;
        }

        const raw_decltype = c.sqlite3_column_decltype(statement.stmt, @intCast(column_i));
        if (raw_decltype == null) return error.ColumnMissingType;
        const zig_type = scalarType(std.mem.span(raw_decltype)) orelse return error.ColumnMissingType;
        try row.append(a, .{ .name = try a.dupe(u8, name), .zig_type = zig_type, .required = false });
    }

    for (used) |field_used| if (!field_used) return error.AnnotationUnused;
    return .{
        .definition = definition,
        .params = try params.toOwnedSlice(a),
        .row = try row.toOwnedSlice(a),
    };
}

fn prepareStatement(conn: zqlite.Conn, source: []const u8) !zqlite.Stmt {
    if (source.len == 0) return error.InvalidSource;

    var raw_statement: ?*c.sqlite3_stmt = null;
    var tail: [*c]const u8 = undefined;
    const result = c.sqlite3_prepare_v2(
        conn.conn,
        source.ptr,
        @intCast(source.len),
        &raw_statement,
        &tail,
    );
    if (result != c.SQLITE_OK) return error.InvalidSource;
    errdefer _ = c.sqlite3_finalize(raw_statement);
    if (raw_statement == null) return error.InvalidSource;

    const consumed: usize = @intCast(@intFromPtr(tail) - @intFromPtr(source.ptr));
    std.debug.assert(consumed <= source.len);
    if (consumed < source.len) {
        var extra: ?*c.sqlite3_stmt = null;
        const tail_result = c.sqlite3_prepare_v2(
            conn.conn,
            tail,
            @intCast(source.len - consumed),
            &extra,
            null,
        );
        if (tail_result != c.SQLITE_OK) return error.InvalidSource;
        if (extra) |extra_statement| {
            _ = c.sqlite3_finalize(extra_statement);
            return error.InvalidSource;
        }
    }
    return .{ .stmt = raw_statement.?, .conn = conn.conn };
}

fn isBlankOrComment(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "--");
}

fn fieldIndex(fields: []const Field, name: []const u8) ?usize {
    for (fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name, name)) return i;
    }
    return null;
}

fn scalarType(declaration: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(declaration, "TEXT")) return "[]const u8";
    if (std.ascii.eqlIgnoreCase(declaration, "BLOB")) return "sql.Blob";
    if (std.ascii.eqlIgnoreCase(declaration, "REAL")) return "f64";
    return null;
}

pub fn emit(a: std.mem.Allocator, w: *std.Io.Writer, queries: []const Resolved) !void {
    const names = try generatedNames(a, queries);

    try w.writeAll(
        \\// Generated by tools/sqlgen. DO NOT EDIT.
        \\const sql = @import("sql");
        \\
        \\
    );

    for (queries, names, 0..) |query, name, query_i| {
        if (query_i > 0) try w.writeByte('\n');
        try w.writeAll("pub const ");
        try w.writeAll(name.type_name);
        try w.writeAll(" = sql.");
        try w.writeAll(switch (query.definition.cardinality) {
            .exec => "ExecQuery(\n",
            .one => "OneQuery(\n",
            .optional => "OptionalQuery(\n",
            .many => "ManyQuery(\n",
        });
        try writeSql(w, query.definition.sql);
        try w.writeAll(",\n");
        try writeStruct(w, query.params);
        if (query.definition.cardinality != .exec) {
            try w.writeAll(",\n");
            if (query.definition.row_from) |source| {
                try w.writeAll("    ");
                try writeTitleName(w, source);
                try w.writeAll(".Row");
            } else try writeStruct(w, query.row);
        }
        try w.writeAll(",\n);\n");
    }

    try w.writeAll("\npub const Queries = struct {\n");
    for (names) |name| {
        try w.writeAll("    ");
        try w.writeAll(name.field_name);
        try w.writeAll(": ");
        try w.writeAll(name.type_name);
        try w.writeAll(",\n");
    }
    try w.writeAll(
        \\
        \\    pub fn prepareAll(conn: sql.Connection) !@This() {
        \\        return sql.prepareAll(@This(), conn);
        \\    }
        \\
        \\    pub fn deinit(self: *@This()) void {
        \\        sql.deinitAll(self);
        \\    }
        \\};
        \\
    );
}

const GeneratedName = struct {
    type_name: []u8,
    field_name: []u8,
};

fn generatedNames(a: std.mem.Allocator, queries: []const Resolved) ![]GeneratedName {
    const names = try a.alloc(GeneratedName, queries.len);

    for (queries, 0..) |query, i| {
        const type_name = try transformName(a, query.definition.name, .title);
        const field_name = try transformName(a, query.definition.name, .snake);
        if (!isZigIdentifier(type_name) or !isZigIdentifier(field_name)) return error.InvalidIdentifier;
        if (std.mem.eql(u8, type_name, "Queries") or std.mem.eql(u8, field_name, "deinit")) {
            return error.NameCollision;
        }
        for (query.params) |field| if (!isZigIdentifier(field.name)) return error.InvalidIdentifier;
        for (query.row) |field| if (!isZigIdentifier(field.name)) return error.InvalidIdentifier;

        for (names[0..i]) |existing| {
            if (std.mem.eql(u8, type_name, existing.type_name) or
                std.mem.eql(u8, field_name, existing.field_name)) return error.NameCollision;
        }
        names[i] = .{ .type_name = type_name, .field_name = field_name };
    }
    return names;
}

const NameCase = enum { title, snake };

fn transformName(a: std.mem.Allocator, source: []const u8, name_case: NameCase) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    switch (name_case) {
        .title => try writeTitleName(&output.writer, source),
        .snake => try writeSnakeName(&output.writer, source),
    }
    return output.toOwnedSlice();
}

fn writeSql(w: *std.Io.Writer, source: []const u8) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| try w.print("    \\\\{s}\n", .{line});
}

fn writeStruct(w: *std.Io.Writer, fields: []const Field) !void {
    if (fields.len == 0) return w.writeAll("    struct {}");
    try w.writeAll("    struct {\n");
    for (fields) |field| {
        try w.writeAll("        ");
        try w.writeAll(field.name);
        try w.writeAll(": ");
        if (!field.required) try w.writeByte('?');
        try w.writeAll(field.zig_type);
        try w.writeAll(",\n");
    }
    try w.writeAll("    ");
    try w.writeByte('}');
}

fn writeTitleName(w: *std.Io.Writer, name: []const u8) !void {
    var uppercase_next = true;
    for (name) |byte| {
        if (byte == '_') {
            uppercase_next = true;
            continue;
        }
        try w.writeByte(if (uppercase_next) std.ascii.toUpper(byte) else byte);
        uppercase_next = false;
    }
}

fn writeSnakeName(w: *std.Io.Writer, name: []const u8) !void {
    var previous_was_lower = false;
    for (name, 0..) |byte, i| {
        if (byte == '_') {
            if (i > 0) try w.writeByte('_');
            previous_was_lower = false;
            continue;
        }
        const uppercase = std.ascii.isUpper(byte);
        if (uppercase and previous_was_lower) try w.writeByte('_');
        try w.writeByte(std.ascii.toLower(byte));
        previous_was_lower = std.ascii.isLower(byte) or std.ascii.isDigit(byte);
    }
}

fn isIdentifier(name: []const u8) bool {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

fn isZigIdentifier(name: []const u8) bool {
    return isIdentifier(name) and
        !std.mem.eql(u8, name, "_") and
        std.zig.Token.getKeyword(name) == null and
        !std.zig.primitives.isPrimitive(name);
}

test "parse drops a trailing comment that belongs to the next query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const definitions = try parse(arena.allocator(),
        \\-- name: ReadWidget :optional
        \\-- id: i64!
        \\SELECT id FROM widget WHERE id = :id;
        \\
        \\-- A loose comment that documents the next query.
        \\-- name: ReadOther :one
        \\SELECT 1 AS value;
        \\
    );
    try std.testing.expectEqual(@as(usize, 2), definitions.len);
    try std.testing.expectEqualStrings("SELECT id FROM widget WHERE id = :id;", definitions[0].sql);
}

test "resolve uses SQLite names and requires ambiguous types to be annotated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex);
    defer conn.tryClose() catch unreachable;
    try conn.execNoArgs("CREATE TABLE widget (id INTEGER NOT NULL, name TEXT)");

    const definitions = try parse(arena.allocator(),
        \\-- name: ReadWidget :optional
        \\-- Documentation is ignored by the fixed annotation grammar.
        \\-- id: i64!
        \\-- name: []const u8
        \\SELECT id, name FROM widget WHERE id = :id;
        \\
    );
    try std.testing.expectEqual(@as(usize, 1), definitions.len);
    try std.testing.expectEqual(Cardinality.optional, definitions[0].cardinality);
    try std.testing.expectEqualStrings("ReadWidget", definitions[0].name);
    try std.testing.expectEqual(@as(usize, 2), definitions[0].fields.len);
    try std.testing.expect(definitions[0].fields[0].required);
    try std.testing.expect(!definitions[0].fields[1].required);
    const query = try resolve(arena.allocator(), conn, definitions[0], null);
    try std.testing.expectEqualStrings("id", query.params[0].name);
    try std.testing.expectEqualStrings("i64", query.row[0].zig_type);
    try std.testing.expectEqualStrings("[]const u8", query.row[1].zig_type);
    try std.testing.expect(!query.row[1].required);

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    try emit(arena.allocator(), &output.writer, &.{query});
    const source_z = try arena.allocator().dupeZ(u8, output.written());
    var tree = try std.zig.Ast.parse(arena.allocator(), source_z, .zig);
    defer tree.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "emit rejects normalized collisions and Zig keywords" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output: std.Io.Writer.Discarding = .init(&.{});

    const collision = [_]Resolved{
        .{ .definition = .{ .name = "foo_bar", .cardinality = .exec, .sql = "SELECT 1", .fields = &.{} }, .params = &.{}, .row = &.{} },
        .{ .definition = .{ .name = "FooBar", .cardinality = .exec, .sql = "SELECT 1", .fields = &.{} }, .params = &.{}, .row = &.{} },
    };
    try std.testing.expectError(error.NameCollision, emit(arena.allocator(), &output.writer, &collision));

    const keyword = [_]Resolved{
        .{
            .definition = .{ .name = "Read", .cardinality = .one, .sql = "SELECT 1", .fields = &.{} },
            .params = &.{},
            .row = &.{.{ .name = "type", .zig_type = "i64", .required = true }},
        },
    };
    try std.testing.expectError(error.InvalidIdentifier, emit(arena.allocator(), &output.writer, &keyword));
}

test "resolve rejects a second SQL statement in every build mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex);
    defer conn.tryClose() catch unreachable;

    const definitions = try parse(arena.allocator(),
        \\-- name: Invalid :exec
        \\DELETE FROM sqlite_schema; SELECT 1;
        \\
    );
    try std.testing.expectError(error.InvalidSource, resolve(arena.allocator(), conn, definitions[0], null));
}

test "shared rows resolve forward references and preserve result annotations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex);
    defer conn.tryClose() catch unreachable;
    const definitions = try parse(a,
        \\-- name: Page :many
        \\-- row-from: Lookup
        \\-- after: u64!
        \\SELECT :after AS id, NULL AS label;
        \\-- name: Lookup :optional
        \\-- row-from: Record
        \\SELECT 2 AS id, NULL AS label;
        \\-- name: Record :one
        \\-- id: u64!
        \\-- label: []const u8
        \\SELECT 1 AS id, 'label' AS label;
    );
    const queries = try resolveAll(a, conn, definitions, null);
    try std.testing.expectEqualStrings("after", queries[0].params[0].name);
    try std.testing.expectEqualDeep(queries[2].row, queries[0].row);
    try std.testing.expectEqualDeep(queries[2].row, queries[1].row);
    var output: std.Io.Writer.Allocating = .init(a);
    try emit(a, &output.writer, queries);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "    Lookup.Row,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "    Record.Row,\n") != null);
}

test "shared rows reject shape drift and keep parameter checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex);
    defer conn.tryClose() catch unreachable;
    const base =
        \\-- name: Record :one
        \\-- id: u64!
        \\-- label: []const u8
        \\SELECT 1 AS id, 'label' AS label;
        \\
        \\-- name: Page :many
        \\-- row-from: Record
        \\
    ;
    const cases = [_]struct { source: []const u8, err: anyerror }{
        .{ .source = "SELECT 1 AS id;", .err = error.RowShapeMismatch },
        .{ .source = "SELECT 1 AS id, 'x' AS label, 2 AS extra;", .err = error.RowShapeMismatch },
        .{ .source = "SELECT 'x' AS label, 1 AS id;", .err = error.RowShapeMismatch },
        .{ .source = "SELECT 1 AS other, 'x' AS label;", .err = error.RowShapeMismatch },
        .{ .source = "-- id: i64!\nSELECT 1 AS id, 'x' AS label;", .err = error.RowShapeMismatch },
        .{ .source = "-- label: []const u8!\nSELECT 1 AS id, 'x' AS label;", .err = error.RowShapeMismatch },
        .{ .source = "SELECT :id AS id, 'x' AS label;", .err = error.ParameterMissingType },
        .{ .source = "-- unused: u64!\nSELECT 1 AS id, 'x' AS label;", .err = error.AnnotationUnused },
    };
    for (cases) |case| {
        const definitions = try parse(a, try std.mem.concat(a, u8, &.{ base, case.source }));
        try std.testing.expectError(case.err, resolveAll(a, conn, definitions, null));
    }
}

test "shared rows reject invalid references and declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex);
    defer conn.tryClose() catch unreachable;
    const cases = [_]struct { source: []const u8, err: anyerror }{
        .{ .source = "-- name: Page :many\n-- row-from: Missing\nSELECT 1 AS id;", .err = error.UnknownRowSource },
        .{ .source = "-- name: Page :many\n-- row-from: Page\nSELECT 1 AS id;", .err = error.RowSourceCycle },
        .{ .source = "-- name: A :one\n-- row-from: B\nSELECT 1 AS id;\n-- name: B :one\n-- row-from: A\nSELECT 1 AS id;", .err = error.RowSourceCycle },
        .{ .source = "-- name: Empty :exec\nCREATE TABLE widget (id INTEGER);\n-- name: Page :many\n-- row-from: Empty\nSELECT 1 AS id;", .err = error.RowShapeMismatch },
    };
    for (cases) |case| {
        const definitions = try parse(a, case.source);
        try std.testing.expectError(case.err, resolveAll(a, conn, definitions, null));
    }
    const invalid = [_][]const u8{
        "-- name: Page :many\n-- row-from:\nSELECT 1;",
        "-- name: Page :many\n-- row-from: bad name\nSELECT 1;",
        "-- name: Page :many\n-- row-from: A\n-- row-from: B\nSELECT 1;",
        "-- name: Page :exec\n-- row-from: A\nDELETE FROM widget;",
    };
    for (invalid) |source| try std.testing.expectError(error.InvalidSource, parse(a, source));
}
