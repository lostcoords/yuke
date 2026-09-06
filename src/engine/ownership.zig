//! A root tree has one engine owner until the root is removed or the engine closes.

const std = @import("std");
const zqlite = @import("zqlite");
const Database = @import("../store/store.zig").Database;

pub const Guard = struct {
    file: ?std.Io.File,
    db: *Database,
    root: [16]u8,
    repaired: bool = false,
    admitting: bool = false,

    pub fn release(self: Guard, io: std.Io) void {
        if (self.file) |file| {
            file.close(io);
        } else {
            std.debug.assert(self.db.private_owners.remove(self.root));
            if (self.db.private_owners.count() == 0) {
                self.db.private_owners.deinit(std.heap.page_allocator);
                self.db.private_owners = .empty;
            }
        }
    }
};

/// A permanent sibling lock file keeps one identity across owner exits and database writes.
pub fn acquire(gpa: std.mem.Allocator, io: std.Io, db: *Database, root: [16]u8) !Guard {
    const filename = zqlite.c.sqlite3_db_filename(db.conn.conn, "main");
    const path = if (filename != null) std.mem.span(filename) else "";
    if (path.len == 0) {
        const entry = try db.private_owners.getOrPut(std.heap.page_allocator, root);
        if (entry.found_existing) return error.SessionOwned;
        return .{ .file = null, .db = db, .root = root };
    }
    const canonical = try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, gpa);
    defer gpa.free(canonical);
    const directory = try std.mem.concat(gpa, u8, &.{ canonical, ".owners" });
    defer gpa.free(directory);
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const lock_path = try std.fmt.allocPrint(gpa, "{s}/{s}.lock", .{ directory, std.fmt.bytesToHex(root, .lower) });
    defer gpa.free(lock_path);
    const file = try std.Io.Dir.createFileAbsolute(io, lock_path, .{
        .truncate = false,
        .permissions = .fromMode(0o600),
    });
    errdefer file.close(io);
    if (!try file.tryLock(io, .exclusive)) return error.SessionOwned;
    return .{ .file = file, .db = db, .root = root };
}

test "private roots exclude a second owner and can be claimed again" {
    var db = try Database.openTest();
    defer db.deinit();
    const first = try acquire(std.testing.allocator, std.testing.io, &db, [_]u8{1} ** 16);
    try std.testing.expectError(error.SessionOwned, acquire(std.testing.allocator, std.testing.io, &db, [_]u8{1} ** 16));
    const other = try acquire(std.testing.allocator, std.testing.io, &db, [_]u8{2} ** 16);
    other.release(std.testing.io);
    first.release(std.testing.io);
    const again = try acquire(std.testing.allocator, std.testing.io, &db, [_]u8{1} ** 16);
    again.release(std.testing.io);
}
