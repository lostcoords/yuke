const support = @import("test_support.zig");

test "layout column fits fixed content and gives the remainder to grow" {
    try support.run("tests/layout/layout-column.test.js");
}

test "layout row splits an odd remainder in source order" {
    try support.run("tests/layout/layout-row.test.js");
}

test "layout honors min and max and centers a non-stretch child" {
    try support.run("tests/layout/layout-limits.test.js");
}

test "layout clips an over-constrained child to the available bounds" {
    try support.run("tests/layout/layout-clip.test.js");
}

test "layout keeps empty padding and large grow weights bounded" {
    try support.run("tests/layout/layout-bounds.test.js");
}

test "mounted views have one owner and same-owner claims are idempotent" {
    try support.run("tests/layout/view-ownership.test.js");
}
