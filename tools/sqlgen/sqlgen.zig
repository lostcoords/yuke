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
};

pub const Resolved = struct {
    definition: Definition,
    params: []const Field,
    row: []const Field,
};

pub const Error = error{
    InvalidSource,
    DuplicateField,
    ParameterUnnamed,
    ParameterMissingType,
    ParameterDuplicate,
    ColumnInvalidName,
    ColumnDuplicate,
    ColumnMissingType,
    AnnotationUnused,
    CardinalityMismatch,
    InvalidIdentifier,
    NameCollision,
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
        while (i < lines.items.len) : (i += 1) {
            const trimmed = std.mem.trim(u8, lines.items[i], " \t");
            if (!std.mem.startsWith(u8, trimmed, "--")) break;
            if (parseHeader(lines.items[i]) != null) break;
            const field = parseField(trimmed) orelse continue;
            for (fields.items) |existing| {
                if (std.mem.eql(u8, existing.name, field.name)) return error.DuplicateField;
            }
            try fields.append(a, field);
        }

        const sql_start = i;
        while (i < lines.items.len and parseHeader(lines.items[i]) == null) : (i += 1) {}
        const sql = try joinLines(a, lines.items[sql_start..i]);
        if (sql.len == 0) return error.InvalidSource;

        for (definitions.items) |definition| {
            if (std.mem.eql(u8, definition.name, header.name)) return error.InvalidSource;
        }

        try definitions.append(a, .{
            .name = try a.dupe(u8, header.name),
            .cardinality = header.cardinality,
            .sql = sql,
            .fields = try fields.toOwnedSlice(a),
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
    var end = lines.len;
    while (end > first and std.mem.trim(u8, lines[end - 1], " \t").len == 0) : (end -= 1) {}
    if (first == end) return a.dupe(u8, "");

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    for (lines[first..end], 0..) |line, line_i| {
        if (line_i > 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(line);
    }
    return out.toOwnedSlice();
}

pub fn resolve(a: std.mem.Allocator, conn: zqlite.Conn, definition: Definition) !Resolved {
    var statement = try prepareStatement(conn, definition.sql);
    defer statement.deinit();

    const column_count: usize = @intCast(c.sqlite3_column_count(statement.stmt));
    if ((definition.cardinality == .exec) != (column_count == 0)) return error.CardinalityMismatch;

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
        for (params.items) |existing| {
            if (std.mem.eql(u8, existing.name, definition.fields[annotation_i].name)) {
                return error.ParameterDuplicate;
            }
        }
        used[annotation_i] = true;
        try params.append(a, definition.fields[annotation_i]);
    }

    for (0..column_count) |column_i| {
        const raw_name = c.sqlite3_column_name(statement.stmt, @intCast(column_i));
        if (raw_name == null) return error.NoMem;
        const name = std.mem.span(raw_name);
        if (!isIdentifier(name)) return error.ColumnInvalidName;
        for (row.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) return error.ColumnDuplicate;
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
    defer {
        for (names) |name| {
            a.free(name.type_name);
            a.free(name.field_name);
        }
        a.free(names);
    }

    try w.writeAll(
        \\// Generated by tools/sqlgen. DO NOT EDIT.
        \\const sql = @import("sql");
        \\const wire = @import("wire");
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
        try writeStruct(w, query.params, 1);
        if (query.definition.cardinality != .exec) {
            try w.writeAll(",\n");
            try writeStruct(w, query.row, 1);
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
    var initialized: usize = 0;
    errdefer {
        for (names[0..initialized]) |name| {
            a.free(name.type_name);
            a.free(name.field_name);
        }
        a.free(names);
    }

    for (queries, 0..) |query, i| {
        const type_name = try transformName(a, query.definition.name, .title);
        errdefer a.free(type_name);
        const field_name = try transformName(a, query.definition.name, .snake);
        errdefer a.free(field_name);
        if (!isZigIdentifier(type_name) or !isZigIdentifier(field_name)) return error.InvalidIdentifier;
        if (std.mem.eql(u8, type_name, "Queries") or std.mem.eql(u8, field_name, "deinit")) {
            return error.NameCollision;
        }
        for (query.params) |field| if (!isZigIdentifier(field.name)) return error.InvalidIdentifier;
        for (query.row) |field| if (!isZigIdentifier(field.name)) return error.InvalidIdentifier;

        for (names[0..initialized]) |existing| {
            if (std.mem.eql(u8, type_name, existing.type_name) or
                std.mem.eql(u8, field_name, existing.field_name)) return error.NameCollision;
        }
        names[i] = .{ .type_name = type_name, .field_name = field_name };
        initialized += 1;
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

fn writeStruct(w: *std.Io.Writer, fields: []const Field, indent: usize) !void {
    if (fields.len == 0) return w.writeAll("    struct {}");
    try w.writeAll("    struct {\n");
    for (fields) |field| {
        try w.splatByteAll(' ', (indent + 1) * 4);
        try w.writeAll(field.name);
        try w.writeAll(": ");
        if (!field.required) try w.writeByte('?');
        try w.writeAll(field.zig_type);
        try w.writeAll(",\n");
    }
    try w.splatByteAll(' ', indent * 4);
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

test "parse explicit cardinality and typed annotations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
}

test "resolve uses SQLite names and requires ambiguous types to be annotated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex);
    defer conn.tryClose() catch unreachable;
    try conn.execNoArgs("CREATE TABLE widget (id INTEGER NOT NULL, name TEXT)");

    const definitions = try parse(arena.allocator(),
        \\-- name: ReadWidget :optional
        \\-- id: i64!
        \\SELECT id, name FROM widget WHERE id = :id;
        \\
    );
    const query = try resolve(arena.allocator(), conn, definitions[0]);
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
    try std.testing.expectError(error.InvalidSource, resolve(arena.allocator(), conn, definitions[0]));
}
