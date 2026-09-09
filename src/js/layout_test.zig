const support = @import("test_support.zig");
const std = @import("std");
const Host = @import("host.zig").Host;

test "layout column fits fixed content and gives the remainder to grow" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/layout/layout-column.test.js");
}

test "layout row splits an odd remainder in source order" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/layout/layout-row.test.js");
}

test "layout honors min and max and centers a non-stretch child" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/layout/layout-limits.test.js");
}

test "layout clips an over-constrained child to the available bounds" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/layout/layout-clip.test.js");
}

test "layout keeps empty padding and large grow weights bounded" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/layout/layout-bounds.test.js");
}

test "mounted views have one owner and same-owner claims are idempotent" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/layout/view-ownership.test.js");
}
