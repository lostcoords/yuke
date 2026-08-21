//! Strict typed SQLite queries over zqlite.

const query = @import("query.zig");

pub const Blob = query.Blob;
pub const Connection = query.Connection;
pub const Error = query.Error;
pub const ExecQuery = query.ExecQuery;
pub const ManyQuery = query.ManyQuery;
pub const OneQuery = query.OneQuery;
pub const Owned = query.Owned;
pub const OptionalQuery = query.OptionalQuery;
pub const Statement = query.Statement;
pub const blob = query.blob;
pub const deinitAll = query.deinitAll;
pub const prepare = query.prepare;
pub const prepareAll = query.prepareAll;

test {
    @import("std").testing.refAllDecls(@This());
}
