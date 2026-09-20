const support = @import("support.zig");

test "the layout solver places fixed, fit and grow, honors limits, clips, and stays bounded" {
    try support.run("layout/layout-solver.test.js");
}

test "mounted views have one owner and same-owner claims are idempotent" {
    try support.run("layout/view-ownership.test.js");
}
