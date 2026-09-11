//! Blobs: engine-stored media bytes that a content part names by hash.

const std = @import("std");

/// These are the parameters for `blob.put`. The engine reads the file, so no bytes cross the wire.
pub const BlobPutParams = struct {
    /// An absolute path to an image file on the engine host.
    path: []const u8,
};

const testing = std.testing;

test "blob put parameters need a string path" {
    const a = testing.allocator;
    const parsed = try std.json.parseFromSlice(BlobPutParams, a, "{\"path\":\"/tmp/shot.png\"}", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/tmp/shot.png", parsed.value.path);
    try testing.expectError(error.MissingField, std.json.parseFromSlice(BlobPutParams, a, "{}", .{}));
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(BlobPutParams, a, "{\"path\":7}", .{}));
}
