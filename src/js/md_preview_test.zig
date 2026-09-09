//! Test the bounded Markdown row path against the complete renderer.

const support = @import("test_support.zig");
const std = @import("std");
const Host = @import("host.zig").Host;

test "yuke:md bounded rows preserve prefixes, spans, and full output" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/md_preview/md-preview.test.js");
}

test "yuke:md an append preserves closed caches and a replacement releases them" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/md_preview/md-cache-tail.test.js");
}
