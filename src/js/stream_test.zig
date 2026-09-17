//! Test source bases and selection anchors across a streamed part update.

const support = @import("test_support.zig");

test "yuke:transcript keeps suffix rows local across an earlier part update" {
    try support.run("tests/stream/stream.test.js");
}
