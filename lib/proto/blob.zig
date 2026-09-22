//! Blobs: engine-stored media bytes that a content part names by hash.

const std = @import("std");

/// A caller names one source for `blob.put`: an absolute path or base64 image bytes.
pub const BlobPutParams = struct {
    /// An absolute path to an image file on the engine host.
    path: ?[]const u8 = null,
    /// The image bytes in standard base64 when no file holds them.
    data: ?[]const u8 = null,
};

const testing = std.testing;

test "blob put parameters name a string path or string data" {
    const a = testing.allocator;
    const parsed = try std.json.parseFromSlice(BlobPutParams, a, "{\"path\":\"/tmp/shot.png\"}", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/tmp/shot.png", parsed.value.path.?);
    const bytes = try std.json.parseFromSlice(BlobPutParams, a, "{\"data\":\"iVBORw0KGgo=\"}", .{});
    defer bytes.deinit();
    try testing.expectEqualStrings("iVBORw0KGgo=", bytes.value.data.?);
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(BlobPutParams, a, "{\"path\":7}", .{}));
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(BlobPutParams, a, "{\"data\":7}", .{}));
}
