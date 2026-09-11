//! Test source bases and selection anchors across a streamed part update.

const support = @import("test_support.zig");
const std = @import("std");
const Host = @import("host.zig").Host;

test "yuke:transcript keeps suffix rows local across an earlier part update" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/stream/stream.test.js");
}
