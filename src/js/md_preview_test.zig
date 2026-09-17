//! Test the bounded Markdown row path against the complete renderer.

const support = @import("test_support.zig");

test "yuke:md bounded rows preserve prefixes, spans, and full output" {
    try support.run("tests/md_preview/md-preview.test.js");
}

test "yuke:md an append preserves closed caches and a replacement releases them" {
    try support.run("tests/md_preview/md-cache-tail.test.js");
}
