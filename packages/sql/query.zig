//! Strict typed access to reusable SQLite prepared statements.

const std = @import("std");
const zqlite = @import("zqlite");
const c = zqlite.c;

pub const Connection = zqlite.Conn;

/// Report whether `conn` is inside an explicit transaction. A multi-statement store operation
/// asserts this so a partial failure cannot leave a half-applied commit.
pub fn inTransaction(conn: Connection) bool {
    return c.sqlite3_get_autocommit(conn.conn) == 0;
}

/// Marks bytes that SQLite must store as BLOB rather than TEXT.
pub const Blob = struct {
    bytes: []const u8,
};

pub fn blob(bytes: []const u8) Blob {
    return .{ .bytes = bytes };
}

/// Failures imposed by the typed layer rather than SQLite itself.
pub const Error = error{
    ParameterUnnamed,
    ParameterMissing,
    FieldMissing,
    ParameterDuplicate,
    RowColumnMissing,
    RowFieldMissing,
    RowColumnDuplicate,
    UnexpectedRow,
    NoRow,
    MultipleRows,
    StorageTypeMismatch,
    NullNotAllowed,
    ValueOutOfRange,
    EmptyStatement,
    MultipleStatements,
};

/// A scanned row owns every dynamic field in `allocator` and must not be copied.
pub fn Owned(comptime Row: type) type {
    comptime validateRecord(Row, .scan);
    return struct {
        value: Row,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *@This()) void {
            deinitRecord(Row, &self.value, self.allocator);
            self.* = undefined;
        }
    };
}

/// A reusable prepared statement specialized by its SQL text. It must not be copied.
pub fn Statement(comptime statement_sql: [:0]const u8) type {
    comptime if (statement_sql.len == 0) @compileError("sql.Statement needs non-empty SQL");
    return struct {
        const Self = @This();

        statement: zqlite.Stmt,
        active: bool = false,

        pub fn deinit(self: *Self) void {
            std.debug.assert(!self.active);
            self.statement.deinit();
            self.* = undefined;
        }

        /// Execute a statement with no result columns. Reset and clear the statement on every path.
        pub fn exec(self: *Self, params: anytype) !void {
            std.debug.assert(!self.active);
            if (c.sqlite3_column_count(self.statement.stmt) != 0) return error.UnexpectedRow;

            self.bind(params) catch |err| {
                try self.resetAndClear();
                return err;
            };

            const has_row = self.statement.step() catch |err| {
                try self.resetAndClear();
                return err;
            };
            try self.resetAndClear();
            if (has_row) return error.UnexpectedRow;
        }

        /// Read exactly one row. The returned row owns all text and dynamic blob fields.
        pub fn one(
            self: *Self,
            allocator: std.mem.Allocator,
            comptime Row: type,
            params: anytype,
        ) !Owned(Row) {
            return (try self.read(allocator, Row, params)) orelse error.NoRow;
        }

        /// Read zero or one row. More than one is rejected.
        pub fn maybeOne(
            self: *Self,
            allocator: std.mem.Allocator,
            comptime Row: type,
            params: anytype,
        ) !?Owned(Row) {
            return self.read(allocator, Row, params);
        }

        /// Bind once and stream owned rows until exhaustion or `deinit`. Do not copy the iterator.
        pub fn rows(self: *Self, comptime Row: type, params: anytype) !Rows(Row) {
            comptime validateRecord(Row, .scan);
            std.debug.assert(!self.active);

            var result: Rows(Row) = .{
                .owner = self,
                .column_indices = undefined,
                .finished = false,
            };
            try resolveColumns(Row, self.statement, &result.column_indices);
            self.bind(params) catch |err| {
                try self.resetAndClear();
                return err;
            };
            self.active = true;
            return result;
        }

        pub fn Rows(comptime Row: type) type {
            comptime validateRecord(Row, .scan);
            const row_fields = @typeInfo(Row).@"struct".fields;

            return struct {
                const Iterator = @This();

                owner: *Self,
                column_indices: [row_fields.len]usize,
                finished: bool,

                pub fn next(self: *Iterator, allocator: std.mem.Allocator) !?Owned(Row) {
                    if (self.finished) return null;
                    std.debug.assert(self.owner.active);

                    const has_row = self.owner.statement.step() catch |err| {
                        try self.finish();
                        return err;
                    };
                    if (!has_row) {
                        try self.finish();
                        return null;
                    }

                    const value = scanRecord(
                        Row,
                        self.owner.statement,
                        &self.column_indices,
                        allocator,
                    ) catch |err| {
                        try self.finish();
                        return err;
                    };
                    return .{ .value = value, .allocator = allocator };
                }

                pub fn deinit(self: *Iterator) void {
                    if (!self.finished) {
                        std.debug.assert(self.owner.active);
                        self.finished = true;
                        self.owner.active = false;
                        self.owner.resetAndClear() catch {};
                    }
                    self.* = undefined;
                }

                fn finish(self: *Iterator) !void {
                    std.debug.assert(!self.finished);
                    std.debug.assert(self.owner.active);
                    self.finished = true;
                    self.owner.active = false;
                    try self.owner.resetAndClear();
                }
            };
        }

        fn read(
            self: *Self,
            allocator: std.mem.Allocator,
            comptime Row: type,
            params: anytype,
        ) !?Owned(Row) {
            comptime validateRecord(Row, .scan);
            std.debug.assert(!self.active);

            const row_fields = @typeInfo(Row).@"struct".fields;
            var column_indices: [row_fields.len]usize = undefined;
            try resolveColumns(Row, self.statement, &column_indices);
            self.bind(params) catch |err| {
                try self.resetAndClear();
                return err;
            };

            const has_first = self.statement.step() catch |err| {
                try self.resetAndClear();
                return err;
            };
            if (!has_first) {
                try self.resetAndClear();
                return null;
            }

            var value = scanRecord(Row, self.statement, &column_indices, allocator) catch |err| {
                try self.resetAndClear();
                return err;
            };
            errdefer deinitRecord(Row, &value, allocator);

            const has_second = self.statement.step() catch |err| {
                try self.resetAndClear();
                return err;
            };
            try self.resetAndClear();
            if (has_second) return error.MultipleRows;

            return .{ .value = value, .allocator = allocator };
        }

        fn bind(self: *Self, params: anytype) !void {
            const Params = @TypeOf(params);
            comptime validateRecord(Params, .bind);
            const param_fields = @typeInfo(Params).@"struct".fields;
            var param_indices: [param_fields.len]usize = undefined;
            try resolveParams(Params, self.statement, &param_indices);
            inline for (param_fields, 0..) |field, i| {
                try bindValue(field.type, self.statement, param_indices[i], @field(params, field.name));
            }
        }

        fn resetAndClear(self: *Self) !void {
            const reset_result = self.statement.reset();
            const clear_result = self.statement.clearBindings();
            try reset_result;
            try clear_result;
        }
    };
}

/// Prepare one reusable statement. SQLite remains authoritative for SQL validity.
pub fn prepare(conn: zqlite.Conn, comptime statement_sql: [:0]const u8) !Statement(statement_sql) {
    return .{ .statement = try prepareStatement(conn, statement_sql) };
}

/// Validate that `Actual` has exactly the fields in `Expected`. Report a mismatch as a compile error.
fn validateParamShape(comptime Expected: type, comptime Actual: type) void {
    const actual = switch (@typeInfo(Actual)) {
        .@"struct" => |info| info,
        else => @compileError("SQL parameters must be a struct, got " ++ @typeName(Actual)),
    };
    if (actual.is_tuple and actual.fields.len != 0) @compileError("SQL parameters must be a named struct");
    const expected = @typeInfo(Expected).@"struct".fields;
    if (actual.fields.len != expected.len) @compileError("wrong SQL parameter count for " ++ @typeName(Expected));
    // Equal counts plus every expected field present proves the two field sets match.
    inline for (expected) |field| {
        if (!@hasField(Actual, field.name)) @compileError("missing SQL parameter field: " ++ field.name);
    }
}

/// Copy `params` into the declared parameter type. The caller must pass exactly its fields.
/// Each assignment checks the field type.
fn coerceParams(comptime Expected: type, params: anytype) Expected {
    comptime validateParamShape(Expected, @TypeOf(params));
    var result: Expected = undefined;
    inline for (@typeInfo(Expected).@"struct".fields) |field| {
        @field(result, field.name) = @field(params, field.name);
    }
    return result;
}

pub fn ExecQuery(comptime statement_sql: [:0]const u8, comptime ParamsType: type) type {
    comptime validateRecord(ParamsType, .bind);
    return struct {
        const Self = @This();

        pub const Params = ParamsType;
        pub const sql = statement_sql;

        statement: Statement(statement_sql),

        pub fn prepare(conn: zqlite.Conn) !Self {
            return .{ .statement = try queryPrepare(conn, statement_sql) };
        }

        pub fn deinit(self: *Self) void {
            self.statement.deinit();
            self.* = undefined;
        }

        pub fn exec(self: *Self, params: anytype) !void {
            return self.statement.exec(coerceParams(Params, params));
        }
    };
}

/// A generated statement that must return exactly one row.
pub fn OneQuery(
    comptime statement_sql: [:0]const u8,
    comptime ParamsType: type,
    comptime RowType: type,
) type {
    return RowQuery(.one, statement_sql, ParamsType, RowType);
}

/// A generated statement that may return one row.
pub fn OptionalQuery(
    comptime statement_sql: [:0]const u8,
    comptime ParamsType: type,
    comptime RowType: type,
) type {
    return RowQuery(.optional, statement_sql, ParamsType, RowType);
}

/// A generated statement that streams rows.
pub fn ManyQuery(
    comptime statement_sql: [:0]const u8,
    comptime ParamsType: type,
    comptime RowType: type,
) type {
    return RowQuery(.many, statement_sql, ParamsType, RowType);
}

const QueryCardinality = enum { one, optional, many };

fn RowQuery(
    comptime cardinality: QueryCardinality,
    comptime statement_sql: [:0]const u8,
    comptime ParamsType: type,
    comptime RowType: type,
) type {
    comptime {
        validateRecord(ParamsType, .bind);
        validateRecord(RowType, .scan);
    }
    return struct {
        const Self = @This();

        pub const Params = ParamsType;
        pub const Row = RowType;
        pub const sql = statement_sql;

        statement: Statement(statement_sql),

        pub fn prepare(conn: zqlite.Conn) !Self {
            return .{ .statement = try queryPrepare(conn, statement_sql) };
        }

        pub fn deinit(self: *Self) void {
            self.statement.deinit();
            self.* = undefined;
        }

        pub fn one(self: *Self, allocator: std.mem.Allocator, params: anytype) !Owned(Row) {
            if (cardinality != .one) @compileError("one requires sql.OneQuery");
            return self.statement.one(allocator, Row, coerceParams(Params, params));
        }

        pub fn maybeOne(self: *Self, allocator: std.mem.Allocator, params: anytype) !?Owned(Row) {
            if (cardinality != .optional) @compileError("maybeOne requires sql.OptionalQuery");
            return self.statement.maybeOne(allocator, Row, coerceParams(Params, params));
        }

        pub fn rows(self: *Self, params: anytype) !Statement(statement_sql).Rows(Row) {
            if (cardinality != .many) @compileError("rows requires sql.ManyQuery");
            return self.statement.rows(Row, coerceParams(Params, params));
        }
    };
}

fn queryPrepare(conn: zqlite.Conn, comptime statement_sql: [:0]const u8) !Statement(statement_sql) {
    return prepare(conn, statement_sql);
}

/// Prepare every generated query field, unwinding completed fields on failure.
pub fn prepareAll(comptime Queries: type, conn: zqlite.Conn) !Queries {
    @setEvalBranchQuota(10_000); // the two inline loops unroll over every generated query.
    const fields = comptime queryFields(Queries);
    var queries: Queries = undefined;
    var initialized: usize = 0;
    errdefer inline for (0..fields.len) |offset| {
        const i = fields.len - 1 - offset;
        if (i < initialized) @field(queries, fields[i].name).deinit();
    };

    inline for (fields) |field| {
        @field(queries, field.name) = try field.type.prepare(conn);
        initialized += 1;
    }
    std.debug.assert(initialized == fields.len);
    return queries;
}

/// Finalize every query field in reverse preparation order.
pub fn deinitAll(queries: anytype) void {
    const QueriesPointer = @TypeOf(queries);
    const pointer = switch (@typeInfo(QueriesPointer)) {
        .pointer => |pointer| pointer,
        else => @compileError("sql.deinitAll needs a pointer to a query struct"),
    };
    if (pointer.size != .one or pointer.is_const) {
        @compileError("sql.deinitAll needs a mutable single-item pointer");
    }

    const fields = comptime queryFields(pointer.child);
    inline for (0..fields.len) |offset| {
        const field = fields[fields.len - 1 - offset];
        @field(queries.*, field.name).deinit();
    }
    queries.* = undefined;
}

fn queryFields(comptime Queries: type) []const std.builtin.Type.StructField {
    const info = switch (@typeInfo(Queries)) {
        .@"struct" => |info| info,
        else => @compileError("generated queries must be a struct, got " ++ @typeName(Queries)),
    };
    if (info.is_tuple) @compileError("generated queries must be a named struct");
    for (info.fields) |field| {
        if (!@hasDecl(field.type, "prepare")) {
            @compileError("query field has no prepare declaration: " ++ field.name);
        }
        if (!@hasDecl(field.type, "deinit")) {
            @compileError("query field has no deinit declaration: " ++ field.name);
        }
    }
    return info.fields;
}

const Direction = enum { bind, scan };

fn validateRecord(comptime T: type, comptime direction: Direction) void {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => @compileError("sql query shapes must be structs, got " ++ @typeName(T)),
    };
    if (info.is_tuple and info.fields.len != 0) {
        @compileError("sql query shapes must be named structs, got " ++ @typeName(T));
    }
    for (info.fields) |field| {
        if (field.is_comptime and direction == .scan) {
            @compileError("sql row fields cannot be comptime: " ++ field.name);
        }
        validateValue(field.type, direction);
    }
}

fn validateValue(comptime T: type, comptime direction: Direction) void {
    if (T == Blob) return;
    switch (@typeInfo(T)) {
        .bool => {},
        .comptime_int => if (direction == .scan) unsupported(T, direction),
        .int => |info| if (info.bits > 64) unsupported(T, direction),
        .comptime_float => if (direction == .scan) unsupported(T, direction),
        .float => |info| if (info.bits != 16 and info.bits != 32 and info.bits != 64) unsupported(T, direction),
        .null => if (direction == .scan) unsupported(T, direction),
        .@"enum" => |info| {
            if (!info.is_exhaustive or @typeInfo(info.tag_type).int.bits > 64) unsupported(T, direction);
        },
        .optional => |info| validateValue(info.child, direction),
        .array => |info| {
            if (info.child != u8) unsupported(T, direction);
        },
        .pointer => |info| {
            if (direction == .scan and (T == []const u8 or T == []u8)) return;
            if (direction == .bind and info.size == .slice and info.child == u8 and !info.is_volatile) return;
            if (direction == .bind and info.size == .one) {
                switch (@typeInfo(info.child)) {
                    .array => |array| if (array.child == u8 and !info.is_volatile) return,
                    else => {},
                }
            }
            unsupported(T, direction);
        },
        else => unsupported(T, direction),
    }
}

fn unsupported(comptime T: type, comptime direction: Direction) noreturn {
    @compileError("cannot " ++ @tagName(direction) ++ " SQL value of type " ++ @typeName(T));
}

fn prepareStatement(conn: zqlite.Conn, sql: [:0]const u8) !zqlite.Stmt {
    var raw_statement: ?*c.sqlite3_stmt = null;
    var tail: [*c]const u8 = undefined;
    const rc = c.sqlite3_prepare_v2(
        conn.conn,
        sql.ptr,
        @intCast(sql.len),
        &raw_statement,
        @ptrCast(&tail),
    );
    if (rc != c.SQLITE_OK) return sqliteErrorFromCode(rc);

    const statement = raw_statement orelse return error.EmptyStatement;
    errdefer _ = c.sqlite3_finalize(statement);

    const consumed = @intFromPtr(tail) - @intFromPtr(sql.ptr);
    std.debug.assert(consumed <= sql.len);
    const remaining = sql.len - consumed;
    if (remaining > 0) {
        var extra: ?*c.sqlite3_stmt = null;
        const tail_rc = c.sqlite3_prepare_v2(
            conn.conn,
            tail,
            @intCast(remaining),
            &extra,
            null,
        );
        if (tail_rc != c.SQLITE_OK) return sqliteErrorFromCode(tail_rc);
        if (extra) |second| {
            _ = c.sqlite3_finalize(second);
            return error.MultipleStatements;
        }
    }

    return .{ .conn = conn.conn, .stmt = statement };
}

fn sqliteErrorFromCode(result: c_int) zqlite.Error {
    return switch (result & 0xff) {
        c.SQLITE_ABORT => error.Abort,
        c.SQLITE_AUTH => error.Auth,
        c.SQLITE_BUSY => error.Busy,
        c.SQLITE_CANTOPEN => error.CantOpen,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CORRUPT => error.Corrupt,
        c.SQLITE_EMPTY => error.Empty,
        c.SQLITE_ERROR => error.Error,
        c.SQLITE_FORMAT => error.Format,
        c.SQLITE_FULL => error.Full,
        c.SQLITE_INTERNAL => error.Internal,
        c.SQLITE_INTERRUPT => error.Interrupt,
        c.SQLITE_IOERR => error.IoErr,
        c.SQLITE_LOCKED => error.Locked,
        c.SQLITE_MISMATCH => error.Mismatch,
        c.SQLITE_MISUSE => error.Misuse,
        c.SQLITE_NOLFS => error.NoLFS,
        c.SQLITE_NOMEM => error.NoMem,
        c.SQLITE_NOTADB => error.NotADB,
        c.SQLITE_NOTFOUND => error.Notfound,
        c.SQLITE_NOTICE => error.Notice,
        c.SQLITE_PERM => error.Perm,
        c.SQLITE_PROTOCOL => error.Protocol,
        c.SQLITE_RANGE => error.Range,
        c.SQLITE_READONLY => error.ReadOnly,
        c.SQLITE_SCHEMA => error.Schema,
        c.SQLITE_TOOBIG => error.TooBig,
        c.SQLITE_WARNING => error.Warning,
        else => error.Error,
    };
}

fn resolveParams(
    comptime Params: type,
    statement: zqlite.Stmt,
    indices: *[@typeInfo(Params).@"struct".fields.len]usize,
) Error!void {
    const fields = @typeInfo(Params).@"struct".fields;
    const count: usize = @intCast(c.sqlite3_bind_parameter_count(statement.stmt));

    var seen = [_]bool{false} ** fields.len;
    for (0..count) |param_i| {
        const raw = c.sqlite3_bind_parameter_name(statement.stmt, @intCast(param_i + 1)) orelse
            return error.ParameterUnnamed;
        const full = std.mem.span(raw);
        if (full.len < 2 or (full[0] != ':' and full[0] != '@' and full[0] != '$')) {
            return error.ParameterUnnamed;
        }

        var matched = false;
        inline for (fields, 0..) |field, field_i| {
            if (std.mem.eql(u8, full[1..], field.name)) {
                if (seen[field_i]) return error.ParameterDuplicate;
                seen[field_i] = true;
                indices[field_i] = param_i;
                matched = true;
            }
        }
        if (!matched) return error.FieldMissing;
    }

    for (seen) |field_seen| if (!field_seen) return error.ParameterMissing;
}

fn resolveColumns(
    comptime Row: type,
    statement: zqlite.Stmt,
    indices: *[@typeInfo(Row).@"struct".fields.len]usize,
) !void {
    const fields = @typeInfo(Row).@"struct".fields;
    const count: usize = @intCast(c.sqlite3_column_count(statement.stmt));

    var seen = [_]bool{false} ** fields.len;
    for (0..count) |column_i| {
        const raw_name = c.sqlite3_column_name(statement.stmt, @intCast(column_i));
        if (raw_name == null) return error.NoMem;
        const name = std.mem.span(raw_name);
        var matched = false;
        inline for (fields, 0..) |field, field_i| {
            if (std.mem.eql(u8, name, field.name)) {
                if (seen[field_i]) return error.RowColumnDuplicate;
                seen[field_i] = true;
                indices[field_i] = column_i;
                matched = true;
            }
        }
        if (!matched) return error.RowFieldMissing;
    }

    for (seen) |field_seen| if (!field_seen) return error.RowColumnMissing;
}

fn bindValue(comptime T: type, statement: zqlite.Stmt, index: usize, value: T) !void {
    if (T == Blob) return bindBytes(statement, index, value.bytes, .blob);
    switch (@typeInfo(T)) {
        .bool => try statement.bindValue(value, index),
        .comptime_int => {
            const narrowed = std.math.cast(i64, value) orelse return error.ValueOutOfRange;
            try statement.bindValue(narrowed, index);
        },
        .int => {
            const narrowed = std.math.cast(i64, value) orelse return error.ValueOutOfRange;
            try statement.bindValue(narrowed, index);
        },
        .comptime_float => try statement.bindValue(@as(f64, value), index),
        .float => try statement.bindValue(@as(f64, @floatCast(value)), index),
        .null => try statement.bindValue(null, index),
        .@"enum" => try bindValue(@TypeOf(@intFromEnum(value)), statement, index, @intFromEnum(value)),
        .optional => |info| {
            if (value) |payload| {
                try bindValue(info.child, statement, index, payload);
            } else {
                try statement.bindValue(null, index);
            }
        },
        .array => try bindBytes(statement, index, value[0..], .blob),
        .pointer => |info| switch (info.size) {
            .slice => try bindBytes(statement, index, value, .text),
            .one => try bindBytes(statement, index, value[0..@typeInfo(info.child).array.len], .text),
            else => unreachable,
        },
        else => unreachable,
    }
}

const ByteStorage = enum { text, blob };

// SQLITE_TRANSIENT (-1 as a fn pointer) trips Zig's arm64 alignment check; a data pointer is
// ABI-identical and SQLite only compares the sentinel, never calls it.
const sqlite_transient: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
extern fn sqlite3_bind_text(?*c.sqlite3_stmt, c_int, [*c]const u8, c_int, ?*const anyopaque) c_int;
extern fn sqlite3_bind_blob(?*c.sqlite3_stmt, c_int, ?*const anyopaque, c_int, ?*const anyopaque) c_int;

fn bindBytes(statement: zqlite.Stmt, index: usize, bytes: []const u8, storage: ByteStorage) !void {
    const len = std.math.cast(c_int, bytes.len) orelse return error.TooBig;
    const sqlite_index: c_int = @intCast(index + 1);
    const rc = switch (storage) {
        .text => sqlite3_bind_text(statement.stmt, sqlite_index, bytes.ptr, len, sqlite_transient),
        .blob => sqlite3_bind_blob(statement.stmt, sqlite_index, bytes.ptr, len, sqlite_transient),
    };
    if (rc != c.SQLITE_OK) return sqliteErrorFromCode(rc);
}

fn scanRecord(
    comptime Row: type,
    statement: zqlite.Stmt,
    indices: *const [@typeInfo(Row).@"struct".fields.len]usize,
    allocator: std.mem.Allocator,
) !Row {
    const fields = @typeInfo(Row).@"struct".fields;
    var value: Row = undefined;
    var initialized: usize = 0;
    errdefer inline for (fields, 0..) |field, i| {
        if (i < initialized) deinitValue(field.type, &@field(value, field.name), allocator);
    };

    inline for (fields, 0..) |field, i| {
        @field(value, field.name) = try scanValue(field.type, statement, indices[i], allocator);
        initialized += 1;
    }
    return value;
}

fn scanValue(comptime T: type, statement: zqlite.Stmt, index: usize, allocator: std.mem.Allocator) !T {
    const storage = statement.columnType(index);
    if (T == Blob) {
        if (storage == .null) return error.NullNotAllowed;
        if (storage != .blob) return error.StorageTypeMismatch;
        return .{ .bytes = try allocator.dupe(u8, try columnBlob(statement, index)) };
    }

    switch (@typeInfo(T)) {
        .optional => |info| {
            if (storage == .null) return null;
            return try scanValue(info.child, statement, index, allocator);
        },
        else => if (storage == .null) return error.NullNotAllowed,
    }

    return switch (@typeInfo(T)) {
        .bool => blk: {
            if (storage != .int) return error.StorageTypeMismatch;
            const value = statement.int(index);
            if (value != 0 and value != 1) return error.ValueOutOfRange;
            break :blk value == 1;
        },
        .int => blk: {
            if (storage != .int) return error.StorageTypeMismatch;
            break :blk std.math.cast(T, statement.int(index)) orelse return error.ValueOutOfRange;
        },
        .float => blk: {
            if (storage != .float) return error.StorageTypeMismatch;
            const source = statement.float(index);
            const value: T = @floatCast(source);
            if (std.math.isInf(value) and !std.math.isInf(source)) return error.ValueOutOfRange;
            break :blk value;
        },
        .@"enum" => |info| blk: {
            if (storage != .int) return error.StorageTypeMismatch;
            const source = statement.int(index);
            const tag = std.math.cast(info.tag_type, source) orelse return error.ValueOutOfRange;
            inline for (info.fields) |field| {
                if (source == field.value) break :blk @enumFromInt(tag);
            }
            return error.ValueOutOfRange;
        },
        .array => |info| blk: {
            if (storage != .blob) return error.StorageTypeMismatch;
            const source = try columnBlob(statement, index);
            if (source.len != info.len) return error.ValueOutOfRange;
            var value: T = undefined;
            @memcpy(value[0..], source);
            break :blk value;
        },
        .pointer => blk: {
            if (storage != .text) return error.StorageTypeMismatch;
            break :blk try allocator.dupe(u8, try columnText(statement, index));
        },
        else => unreachable,
    };
}

fn columnText(statement: zqlite.Stmt, index: usize) ![]const u8 {
    const data = c.sqlite3_column_text(statement.stmt, @intCast(index));
    const len: usize = @intCast(c.sqlite3_column_bytes(statement.stmt, @intCast(index)));
    if (data == null) return error.NoMem;
    if (len == 0) return "";
    return @as([*c]const u8, @ptrCast(data))[0..len];
}

fn columnBlob(statement: zqlite.Stmt, index: usize) ![]const u8 {
    const data = c.sqlite3_column_blob(statement.stmt, @intCast(index));
    const len: usize = @intCast(c.sqlite3_column_bytes(statement.stmt, @intCast(index)));
    if (data == null) {
        if (len == 0) return "";
        return error.NoMem;
    }
    return @as([*c]const u8, @ptrCast(data))[0..len];
}

fn deinitRecord(comptime T: type, value: *T, allocator: std.mem.Allocator) void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        deinitValue(field.type, &@field(value.*, field.name), allocator);
    }
}

fn deinitValue(comptime T: type, value: *T, allocator: std.mem.Allocator) void {
    if (T == Blob) {
        allocator.free(value.bytes);
        return;
    }
    switch (@typeInfo(T)) {
        .optional => |info| if (value.*) |*payload| deinitValue(info.child, payload, allocator),
        .pointer => allocator.free(value.*),
        else => {},
    }
}

const testing = std.testing;

fn testConnection() !zqlite.Conn {
    return zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
}

test "typed query binds by name and owns a strict row" {
    const conn = try testConnection();
    defer conn.tryClose() catch unreachable;
    try conn.execNoArgs("CREATE TABLE item (id BLOB NOT NULL, name TEXT NOT NULL, score REAL, active INTEGER NOT NULL)");

    const Id = [4]u8;
    var insert = try prepare(
        conn,
        "INSERT INTO item (id, name, score, active) VALUES (:id, :name, :score, :active)",
    );
    defer insert.deinit();

    const id: Id = .{ 1, 2, 3, 4 };
    try insert.exec(.{ .id = id, .name = "alpha", .score = 1.5, .active = true });
    try insert.exec(.{
        .id = @as(Id, .{ 5, 6, 7, 8 }),
        .name = "beta",
        .score = null,
        .active = false,
    });

    var select = try prepare(
        conn,
        "SELECT active, score, name, id FROM item WHERE name = :name",
    );
    defer select.deinit();

    const Row = struct { id: Id, name: []const u8, score: ?f64, active: bool };
    var row = try select.one(testing.allocator, Row, .{ .name = "alpha" });
    defer row.deinit();
    try testing.expectEqual(id, row.value.id);
    try testing.expectEqualStrings("alpha", row.value.name);
    try testing.expectEqual(@as(?f64, 1.5), row.value.score);
    try testing.expect(row.value.active);

    const missing = try select.maybeOne(testing.allocator, Row, .{ .name = "missing" });
    try testing.expect(missing == null);
}

test "generated-query wrappers accept a matching named struct" {
    const conn = try testConnection();
    defer conn.tryClose() catch unreachable;
    try conn.execNoArgs("CREATE TABLE item (id INTEGER NOT NULL, name TEXT NOT NULL)");

    const Insert = ExecQuery("INSERT INTO item (id, name) VALUES (:id, :name)", struct { id: i64, name: []const u8 });
    const Get = OneQuery("SELECT name FROM item WHERE id = :id", struct { id: i64 }, struct { name: []const u8 });

    var insert = try Insert.prepare(conn);
    defer insert.deinit();
    var get = try Get.prepare(conn);
    defer get.deinit();

    // A domain struct distinct from the generated Params type binds by field name.
    const Domain = struct { id: i64, name: []const u8 };
    try insert.exec(Domain{ .id = 1, .name = "alpha" });

    var row = try get.one(testing.allocator, .{ .id = 1 });
    defer row.deinit();
    try testing.expectEqualStrings("alpha", row.value.name);
}

test "operations reject open parameter and row shapes" {
    const conn = try testConnection();
    defer conn.tryClose() catch unreachable;

    var missing_param = try prepare(conn, "SELECT :a AS a");
    defer missing_param.deinit();
    try testing.expectError(
        error.FieldMissing,
        missing_param.one(testing.allocator, struct { a: i64 }, .{ .b = 1 }),
    );

    var unnamed = try prepare(conn, "SELECT ? AS value");
    defer unnamed.deinit();
    try testing.expectError(
        error.ParameterUnnamed,
        unnamed.one(testing.allocator, struct { value: i64 }, .{ .a = 1 }),
    );

    var unknown_column = try prepare(conn, "SELECT 1 AS a, 2 AS b");
    defer unknown_column.deinit();
    try testing.expectError(
        error.RowFieldMissing,
        unknown_column.one(testing.allocator, struct { a: i64, c: i64 }, .{}),
    );

    var extra_param = try prepare(conn, "SELECT :a AS a");
    defer extra_param.deinit();
    try testing.expectError(
        error.ParameterMissing,
        extra_param.one(testing.allocator, struct { a: i64 }, .{ .a = 1, .b = 2 }),
    );

    var duplicate_param = try prepare(conn, "SELECT :a + @a AS value");
    defer duplicate_param.deinit();
    try testing.expectError(
        error.ParameterDuplicate,
        duplicate_param.one(testing.allocator, struct { value: i64 }, .{ .a = 1 }),
    );

    var missing_column = try prepare(conn, "SELECT 1 AS a");
    defer missing_column.deinit();
    try testing.expectError(
        error.RowColumnMissing,
        missing_column.one(testing.allocator, struct { a: i64, b: i64 }, .{}),
    );

    var duplicate_column = try prepare(conn, "SELECT 1 AS a, 2 AS a");
    defer duplicate_column.deinit();
    try testing.expectError(
        error.RowColumnDuplicate,
        duplicate_column.one(testing.allocator, struct { a: i64 }, .{}),
    );
}

test "prepare admits one statement and repeated named markers" {
    const conn = try testConnection();
    defer conn.tryClose() catch unreachable;

    try testing.expectError(error.EmptyStatement, prepare(conn, " -- only a comment\n"));

    try testing.expectError(
        error.MultipleStatements,
        prepare(conn, "SELECT 1 AS value; SELECT 2 AS value"),
    );

    var repeated = try prepare(
        conn,
        "SELECT :value + :value AS doubled",
    );
    defer repeated.deinit();
    var row = try repeated.one(testing.allocator, struct { doubled: i64 }, .{ .value = 4 });
    defer row.deinit();
    try testing.expectEqual(@as(i64, 8), row.value.doubled);
}

test "scan rejects null, storage coercion, narrowing, and unknown enums" {
    const conn = try testConnection();
    defer conn.tryClose() catch unreachable;

    var null_query = try prepare(conn, "SELECT NULL AS value");
    defer null_query.deinit();
    try testing.expectError(
        error.NullNotAllowed,
        null_query.one(testing.allocator, struct { value: i64 }, .{}),
    );

    var coercion = try prepare(conn, "SELECT '7' AS value");
    defer coercion.deinit();
    try testing.expectError(
        error.StorageTypeMismatch,
        coercion.one(testing.allocator, struct { value: i64 }, .{}),
    );

    var narrow = try prepare(conn, "SELECT 256 AS value");
    defer narrow.deinit();
    try testing.expectError(
        error.ValueOutOfRange,
        narrow.one(testing.allocator, struct { value: u8 }, .{}),
    );

    const State = enum(u8) { pending = 0, done = 1 };
    var unknown = try prepare(conn, "SELECT 2 AS state");
    defer unknown.deinit();
    try testing.expectError(
        error.ValueOutOfRange,
        unknown.one(testing.allocator, struct { state: State }, .{}),
    );
}

test "one rejects zero and multiple rows without leaking owned fields" {
    const conn = try testConnection();
    defer conn.tryClose() catch unreachable;

    var read = try prepare(
        conn,
        "SELECT value FROM (SELECT 'a' AS value UNION ALL SELECT 'b') WHERE value >= :min",
    );
    defer read.deinit();

    const Row = struct { value: []const u8 };
    try testing.expectError(error.NoRow, read.one(testing.allocator, Row, .{ .min = "z" }));
    try testing.expectError(error.MultipleRows, read.one(testing.allocator, Row, .{ .min = "a" }));
}

test "dynamic and empty blobs remain owned blobs" {
    const conn = try testConnection();
    defer conn.tryClose() catch unreachable;
    try conn.execNoArgs("CREATE TABLE binary (id INTEGER PRIMARY KEY, payload BLOB)");

    var insert = try prepare(conn, "INSERT INTO binary (id, payload) VALUES (:id, :payload)");
    defer insert.deinit();
    try insert.exec(.{ .id = 1, .payload = blob("") });
    try insert.exec(.{ .id = 2, .payload = blob(&.{ 0, 1, 2 }) });
    try insert.exec(.{ .id = 3, .payload = null });

    var select = try prepare(conn, "SELECT payload FROM binary WHERE id = :id");
    defer select.deinit();

    const Row = struct { payload: ?Blob };
    var empty = try select.one(testing.allocator, Row, .{ .id = 1 });
    defer empty.deinit();
    try testing.expect(empty.value.payload != null);
    try testing.expectEqual(@as(usize, 0), empty.value.payload.?.bytes.len);

    var bytes = try select.one(testing.allocator, Row, .{ .id = 2 });
    defer bytes.deinit();
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2 }, bytes.value.payload.?.bytes);

    var null_row = try select.one(testing.allocator, Row, .{ .id = 3 });
    defer null_row.deinit();
    try testing.expect(null_row.value.payload == null);
}

test "failed bind leaves a prepared statement reusable" {
    const conn = try testConnection();
    defer conn.tryClose() catch unreachable;
    try conn.execNoArgs("CREATE TABLE number (value INTEGER NOT NULL)");

    var insert = try prepare(conn, "INSERT INTO number VALUES (:value)");
    defer insert.deinit();

    try testing.expectError(error.ValueOutOfRange, insert.exec(.{ .value = std.math.maxInt(u64) }));
    try insert.exec(.{ .value = 7 });

    const row = (try conn.row("SELECT value FROM number", .{})).?;
    defer row.deinit();
    try testing.expectEqual(@as(i64, 7), row.int(0));
}

test "failed step leaves a prepared statement reusable" {
    const conn = try testConnection();
    defer conn.tryClose() catch unreachable;
    try conn.execNoArgs("CREATE TABLE unique_number (value INTEGER NOT NULL UNIQUE)");

    var insert = try prepare(conn, "INSERT INTO unique_number VALUES (:value)");
    defer insert.deinit();

    try insert.exec(.{ .value = 1 });
    try testing.expectError(error.ConstraintUnique, insert.exec(.{ .value = 1 }));
    try insert.exec(.{ .value = 2 });

    const row = (try conn.row("SELECT count(*) FROM unique_number", .{})).?;
    defer row.deinit();
    try testing.expectEqual(@as(i64, 2), row.int(0));
}

test "partial row allocation failure frees clones and leaves the query reusable" {
    const conn = try testConnection();
    defer conn.tryClose() catch unreachable;

    var read = try prepare(conn, "SELECT 'first' AS first, 'second' AS second");
    defer read.deinit();

    const Row = struct { first: []const u8, second: []const u8 };
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, read.one(failing.allocator(), Row, .{}));

    var row = try read.one(testing.allocator, Row, .{});
    defer row.deinit();
    try testing.expectEqualStrings("first", row.value.first);
    try testing.expectEqualStrings("second", row.value.second);
}

test "rows streams owned values and early deinit leaves the statement reusable" {
    const conn = try testConnection();
    defer conn.tryClose() catch unreachable;

    var read = try prepare(
        conn,
        "SELECT value FROM (SELECT 'a' AS value UNION ALL SELECT 'b') ORDER BY value",
    );
    defer read.deinit();

    const Row = struct { value: []const u8 };
    var iterator = try read.rows(Row, .{});
    var first = (try iterator.next(testing.allocator)).?;
    try testing.expectEqualStrings("a", first.value.value);
    first.deinit();
    iterator.deinit();

    var iterator_again = try read.rows(Row, .{});
    defer iterator_again.deinit();
    var expected: usize = 0;
    const values = [_][]const u8{ "a", "b" };
    while (try iterator_again.next(testing.allocator)) |owned_value| {
        var row = owned_value;
        defer row.deinit();
        try testing.expectEqualStrings(values[expected], row.value.value);
        expected += 1;
    }
    try testing.expectEqual(values.len, expected);
    try testing.expect((try iterator_again.next(testing.allocator)) == null);
}

test "rows binds transient text and scan failure leaves the statement reusable" {
    const conn = try testConnection();
    defer conn.tryClose() catch unreachable;

    var read = try prepare(conn, "SELECT :value AS value");
    defer read.deinit();

    const TextRow = struct { value: []const u8 };
    var source = [_]u8{ 'a', 'b', 'c' };
    var iterator = try read.rows(TextRow, .{ .value = source[0..] });
    source = .{ 'x', 'y', 'z' };
    var owned = (try iterator.next(testing.allocator)).?;
    defer owned.deinit();
    try testing.expectEqualStrings("abc", owned.value.value);
    try testing.expect((try iterator.next(testing.allocator)) == null);
    iterator.deinit();

    var wrong_type = try read.rows(struct { value: i64 }, .{ .value = "text" });
    try testing.expectError(error.StorageTypeMismatch, wrong_type.next(testing.allocator));
    wrong_type.deinit();

    var reused = try read.one(testing.allocator, TextRow, .{ .value = "reused" });
    defer reused.deinit();
    try testing.expectEqualStrings("reused", reused.value.value);
}

test "prepareAll unwinds earlier statements when a later prepare fails" {
    const conn = try testConnection();
    try conn.execNoArgs("CREATE TABLE item (id INTEGER)");

    const Delete = ExecQuery("DELETE FROM item", struct {});
    const Invalid = ExecQuery("NOT VALID SQL", struct {});
    const Queries = struct {
        delete: Delete,
        invalid: Invalid,
    };

    try testing.expectError(error.Error, prepareAll(Queries, conn));
    try conn.tryClose();
}
