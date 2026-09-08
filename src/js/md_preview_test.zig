//! Test the bounded Markdown row path against the complete renderer.

const std = @import("std");
const Host = @import("host.zig").Host;

fn expectJs(host: *Host, want: []const u8) !void {
    const value = try host.ctx.eval("globalThis.result", "md-preview-result.js", .{});
    defer host.ctx.freeValue(value);
    const text = try host.ctx.toCStringLen(value);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings(want, text);
}

test "yuke:md bounded rows preserve prefixes, spans, and full output" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { Document } from "yuke:md";
        \\const fail = [];
        \\const check = (name, value) => { if (!value) fail.push(name); };
        \\const rowText = (row) => (row.segments || []).map((segment) => segment.text).join("");
        \\const encoded = (rows) => JSON.stringify(rows);
        \\const sourceSpansMatch = (source, rows) => rows.every((row) => (row.segments || []).every((segment) =>
        \\  segment.src == null || (segment.src >= 0 && segment.srcEnd >= segment.src && segment.srcEnd <= source.length &&
        \\    (segment.mark || source.slice(segment.src, segment.srcEnd) === segment.text))));
        \\const cases = [
        \\  ["heading", "# a heading with enough words to wrap"],
        \\  ["paragraph", "first paragraph has many words and **strong text**\ncontinued here"],
        \\  ["quote", "> a quoted paragraph with enough words to wrap\n> and a second line"],
        \\  ["code", "```zig\nconst first = 1;\nconst second = 2;\n```"],
        \\  ["list", "- first item with many words\n- second item with many words"],
        \\  ["table", "| first column | second column |\n|---|---|\n| a long value | another long value |\n| tail | remains |"],
        \\  ["rule", "---"],
        \\];
        \\for (const [name, text] of cases) {
        \\  for (const width of [8, 20, 80]) {
        \\    const warm = new Document();
        \\    warm.setText(text);
        \\    const full = warm.rows(width);
        \\    check(name + "-full-nonempty-" + width, full.length > 0);
        \\    for (const limit of [0, 1, 2, 3, 7]) {
        \\      const prefix = warm.rows(width, limit);
        \\      check(name + "-warm-prefix-" + width + "-" + limit, encoded(prefix) === encoded(full.slice(0, limit)));
        \\      check(name + "-warm-full-" + width + "-" + limit, encoded(warm.rows(width)) === encoded(full));
        \\      const cold = new Document();
        \\      cold.setText(text);
        \\      check(name + "-cold-prefix-" + width + "-" + limit, encoded(cold.rows(width, limit)) === encoded(full.slice(0, limit)));
        \\      check(name + "-cold-full-" + width + "-" + limit, encoded(cold.rows(width)) === encoded(full));
        \\    }
        \\  }
        \\}
        \\const code = "```zig\nconst first = 1;\nconst second = 2;\nconst third = 3;\n```";
        \\const codeDoc = new Document();
        \\codeDoc.setText(code);
        \\const codeFull = codeDoc.rows(20);
        \\const codePrefix = codeDoc.rows(20, 2);
        \\check("code-prefix-spans", sourceSpansMatch(code, codePrefix));
        \\check("code-prefix-content", rowText(codePrefix[0]).includes("const first") && rowText(codePrefix[1]).includes("const second"));
        \\check("code-later-full", encoded(codeDoc.rows(20)) === encoded(codeFull) && rowText(codeDoc.rows(20)[codeFull.length - 1]).includes("const third"));
        \\const table = "| first column | second column |\n|---|---|\n| a long value | another long value |\n| tail | remains |";
        \\const tableDoc = new Document();
        \\tableDoc.setText(table);
        \\const tableFull = tableDoc.rows(16);
        \\const tablePrefix = tableDoc.rows(16, 3);
        \\check("table-prefix-spans", sourceSpansMatch(table, tablePrefix));
        \\check("table-prefix-content", tablePrefix.length === 3 && tablePrefix.some((row) => rowText(row).includes("first")));
        \\check("table-later-full", encoded(tableDoc.rows(16)) === encoded(tableFull) && rowText(tableDoc.rows(16)[tableFull.length - 1]).includes("remains"));
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "md-preview.js");
    try expectJs(host, "ok");
}

test "yuke:md an append preserves closed caches and a replacement releases them" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { Document } from "yuke:md";
        \\const fail = [];
        \\const check = (name, value) => { if (!value) fail.push(name); };
        \\const doc = new Document();
        \\let source = "# Prefix\n\nstable 世界 é 👩‍💻\n\n```txt\nbody\n```\n\nTail";
        \\doc.setText(source);
        \\doc.rows(24);
        \\const prefix = doc._cache.get(0);
        \\const codeAt = source.indexOf("```txt");
        \\const code = doc._cache.get(codeAt);
        \\check("closed-caches-exist", !!prefix && !!code);
        \\for (const delta of [" extended", "\r", "\n\r\nNext", "\n===", "\n\n| a | b |\n|---|---|\n| 1 | 2 |", "\n\nEnd"]) {
        \\  source += delta;
        \\  doc.setText(source);
        \\  const fresh = new Document();
        \\  fresh.setText(source);
        \\  check("append-rows", JSON.stringify(doc.rows(24)) === JSON.stringify(fresh.rows(24)));
        \\  check("append-blocks", JSON.stringify(doc.blocks()) === JSON.stringify(fresh.blocks()));
        \\  check("prefix-cache", doc._cache.get(0) === prefix);
        \\  check("closed-tail-cache", doc._cache.get(codeAt) === code);
        \\  const closed = new Set(doc._blocks.filter(block => !block.open).map(block => block.at));
        \\  check("no-orphan-cache", [...doc._cache.keys()].every(at => closed.has(at)));
        \\}
        \\const fresh = new Document();
        \\fresh.setText(source);
        \\check("resize", JSON.stringify(doc.rows(9)) === JSON.stringify(fresh.rows(9)));
        \\check("replacement-changed", doc.setText("replacement\r\ntext"));
        \\check("replacement-releases-cache", doc._cache.size === 0);
        \\check("replacement-normalized", doc.sourceText() === "replacement\ntext");
        \\check("unchanged", !doc.setText("replacement\r\ntext"));
        \\check("empty", doc.setText("") && doc.rows(24).length === 0 && doc._cache.size === 0);
        \\const short = new Document();
        \\short.setText("```txt\nlarge closed block\n```\n\nTail");
        \\short.rows(24);
        \\const shortCode = short._cache.get(0);
        \\short.setText(short.sourceText() + " extended");
        \\short.rows(24);
        \\check("two-block-cache", !!shortCode && short._cache.get(0) === shortCode);
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "md-cache-tail.js");
    try expectJs(host, "ok");
}
