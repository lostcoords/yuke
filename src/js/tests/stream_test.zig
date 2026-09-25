//! Test source bases and selection anchors across a streamed part update.

const support = @import("support.zig");

test "yuke:internal/transcript keeps suffix rows local across an earlier part update" {
    try support.run("stream/stream.test.js");
}
