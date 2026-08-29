//! Keep the local catalog snapshot current. The daemon holds no cloud credential for this document,
//! so any yuke user gets the model list, signed in or not.

const std = @import("std");
const catalog = @import("catalog.zig");
const http = @import("http.zig");
const catalog_store = @import("../database/catalog.zig");
const Database = @import("../database/database.zig").Database;

/// The executable variant carries only the providers that yuke can call. It decompresses to about
/// 185 KB, so this bound leaves generous room for growth.
const max_catalog_bytes = 1024 * 1024;

/// Bound the ETag that the cloud returns. A weak validator adds a `W/` prefix.
const max_etag_bytes = 256;

/// The executable catalog omits every provider that yuke cannot call.
pub const catalog_path = "/api/v1/catalog?executable=true";

/// The status that the control plane sends before its first catalog sync.
const status_unavailable = 503;

pub const Outcome = enum {
    /// The stored snapshot already matches the cloud.
    unchanged,
    /// The snapshot was replaced.
    updated,
    /// The cloud has not synced its catalog yet. Ask again later.
    unavailable,
};

/// Fetch the catalog and replace the snapshot when it changed.
/// A conditional request makes an unchanged catalog cost one small response.
pub fn refreshCatalog(
    gpa: std.mem.Allocator,
    client: *http.Client,
    db: *Database,
    base_url: []const u8,
) !Outcome {
    std.debug.assert(base_url.len != 0); // The caller resolves the control-plane URL.

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    const url = try std.mem.concat(scratch, u8, &.{ std.mem.trimEnd(u8, base_url, "/"), catalog_path });
    const stored_etag = (try catalog_store.etag(db, scratch)) orelse "";

    const body = try gpa.alloc(u8, max_catalog_bytes);
    defer gpa.free(body);
    var etag_buf: [max_etag_bytes]u8 = undefined;

    const response = try client.get(.{
        .url = url,
        .if_none_match = stored_etag,
        .body_out = body,
        .etag_out = &etag_buf,
    });

    if (response.status == http.status_not_modified) return .unchanged;
    if (response.status == status_unavailable) return .unavailable;
    if (response.status < 200 or response.status >= 300) return error.CatalogRejected;

    const doc = try catalog.decode(scratch, response.body);
    try catalog_store.replace(db, scratch, doc.providers, doc.catalog_rev, response.etag);
    return .updated;
}
