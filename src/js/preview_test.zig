//! The preview workload pins visible content and source spans before a renderer change.

const std = @import("std");
const Host = @import("host.zig").Host;
const Paint = @import("test_paint.zig").Paint;

fn expectJs(host: *Host, want: []const u8) !void {
    const value = try host.ctx.eval("globalThis.result", "preview-result.js", .{});
    defer host.ctx.freeValue(value);
    const text = try host.ctx.toCStringLen(value);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings(want, text);
}

test "preview workload keeps bounded rows, full details, and source spans" {
    var paint: Paint = undefined;
    try paint.setup(std.testing.allocator, 40, 100);
    defer paint.deinit();
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    paint.bind(host);
    try host.evalModule(
        \\import { root } from "yuke:core";
        \\import { Transcript } from "yuke:transcript";
        \\const fail = [];
        \\const check = (name, value) => { if (!value) fail.push(name); };
        \\const rowText = (row) => row.text || (row.segments || []).map((segment) => segment.text).join("");
        \\const sourceSpan = (source, rows, needle) => {
        \\  const segment = rows.flatMap((row) => row.segments || []).find((entry) => entry.text.indexOf(needle) >= 0);
        \\  return !!segment && segment.src >= 0 && segment.srcEnd > segment.src && source.slice(segment.src, segment.srcEnd) === segment.text;
        \\};
        \\const report = Array.from({ length: 256 }, (_, i) => "report-line-" + i + " with stable context").join("\n");
        \\const reasoning = ["reason-first", ...Array.from({ length: 254 }, (_, i) => "reason-middle-" + i), "reason-last"].join("\n");
        \\const plainOutput = Array.from({ length: 128 }, (_, i) => "plain-line-" + i).join("\n");
        \\const plain = { type: "tool", id: 1, name: "plain", arguments: '{"path":"plain.txt"}', state: { type: "completed", output: plainOutput, duration_ms: 1 } };
        \\const viewed = { type: "tool", id: 2, name: "view", arguments: '{"path":"view.md"}', state: { type: "completed", output: "", duration_ms: 2, view: [
        \\  { type: "markdown", text: "view-first\n\nview-second" }, { type: "text", text: "view-tail" },
        \\] } };
        \\const tools = [plain, viewed];
        \\for (let i = 2; i < 8; i++) tools.push({ ...plain, id: i + 1, name: "plain-" + i, arguments: '{"path":"plain-' + i + '.txt"}' });
        \\const parts = tools.concat([{ type: "reasoning", id: 9, text: reasoning, signature: "" }]);
        \\const t = new Transcript({
        \\  textOf: (id) => id === "report" ? report : "",
        \\  partsOf: (id) => id === "answer" ? parts : [],
        \\});
        \\t.setOutline([
        \\  { id: "report", type: "user", source: { type: "child_report", session_id: "s", run_id: 1, name: "agent", outcome: { type: "turn", finish: "stop", rounds: 1 }, partial: false, truncated: false } },
        \\  { id: "answer", type: "assistant" },
        \\], null);
        \\const width = 100;
        \\t.rowCount(width);
        \\const publicRows = (id) => t.rows(width, 0, t.rowCount(width)).filter((row) => String(row.key) === String(id));
        \\const reportRows = publicRows("report");
        \\check("report-row-cap", reportRows.length === 11);
        \\check("report-first-eight", reportRows.slice(1, 9).every((row, i) => rowText(row) === "report-line-" + i + " with stable context"));
        \\check("report-footer", rowText(reportRows[9]).indexOf("click the header") >= 0);
        \\check("report-source", sourceSpan(t._sourceOf("report"), reportRows, "report-line-0"));
        \\for (const part of parts) t.togglePart("answer", part.id);
        \\const rows = t.rows(width, 0, t.rowCount(width));
        \\const toolRows = publicRows("answer");
        \\check("eight-tools", toolRows.filter((row) => row.kind === "tool-header").length === 8);
        \\for (const part of tools) {
        \\  const bodyRows = toolRows.filter((row) => row.kind === "tool-body" && row.partId === part.id);
        \\  check("tool-preview-cap-" + part.id, bodyRows.length === 3);
        \\}
        \\const plainRows = toolRows.filter((row) => row.kind === "tool-body" && row.partId === 1);
        \\check("plain-first-three", plainRows.length === 3 && plainRows.every((row, i) => row.segments?.some((segment) => segment.text === "plain-line-" + i)));
        \\const viewRows = toolRows.filter((row) => row.kind === "tool-body" && row.partId === 2);
        \\check("view-first-three", viewRows.length === 3 && viewRows.some((row) => row.segments?.some((segment) => segment.text === "view-first")));
        \\check("plain-source", sourceSpan(t._sourceOf("answer"), toolRows, "plain-line-0"));
        \\const reasoningRows = toolRows.filter((row) => row.kind === "reasoning-body");
        \\check("reasoning-first-ellipsis-last", reasoningRows.length === 3 && rowText(reasoningRows[0]).indexOf("reason-first") >= 0 && rowText(reasoningRows[1]) === "…" && rowText(reasoningRows[2]).indexOf("reason-last") >= 0);
        \\check("reasoning-source", sourceSpan(t._sourceOf("answer"), reasoningRows, "reason-first") && sourceSpan(t._sourceOf("answer"), reasoningRows, "reason-last"));
        \\check("rows-visible", rows.some((row) => rowText(row).indexOf("plain-line-0") >= 0));
        \\check("plain-details", t.openTool("answer", 1) && root.overlays[0].content.sections[0].text === '{"path":"plain.txt"}' && root.overlays[0].content.sections[1].text === plainOutput);
        \\root.popOverlay(root.overlays[0]);
        \\check("view-details", t.openTool("answer", 2) && root.overlays[0].content.sections[2].text.indexOf("view-first") >= 0 && root.overlays[0].content.sections[2].text.indexOf("view-tail") >= 0);
        \\root.popOverlay(root.overlays[0]);
        \\check("reasoning-details", t.openReasoning("answer", 9) && root.overlays[0].content.sections[0].text === reasoning);
        \\root.popOverlay(root.overlays[0]);
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "preview.js");
    try expectJs(host, "ok");

    host.paint.counters = .{};
    try host.evalModule(
        \\import { Transcript } from "yuke:transcript";
        \\const line = (prefix, i) => prefix + "-" + i + " with enough context to wrap";
        \\const large = Array.from({ length: 4096 }, (_, i) => line("preview-budget", i)).join("\\n");
        \\const tools = [
        \\  { type: "tool", id: 1, name: "large", arguments: "{}", state: { type: "completed", output: large } },
        \\  { type: "reasoning", id: 2, text: large, signature: "" },
        \\];
        \\const t = new Transcript({
        \\  textOf: (id) => id === "report" ? large : "",
        \\  partsOf: (id) => id === "answer" ? tools : [],
        \\});
        \\t.setOutline([
        \\  { id: "report", type: "user", source: { type: "child_report", session_id: "s", run_id: 1, name: "agent", outcome: { type: "turn", finish: "stop", rounds: 1 }, partial: false, truncated: false } },
        \\  { id: "answer", type: "assistant" },
        \\], null);
        \\for (const part of tools) t.togglePart("answer", part.id);
        \\const rows = t.rows(100, 0, t.rowCount(100));
        \\const body = (kind, partId) => rows.filter((row) => row.kind === kind && row.partId === partId);
        \\globalThis.result = body("report-body", -1).length === 8
        \\  && body("tool-body", 1).length === 3
        \\  && body("reasoning-body", 2).length === 3 ? "ok" : "bad";
    , "preview-budget.js");
    try expectJs(host, "ok");
    try std.testing.expect(host.paint.counters.wrap_rows <= 32);
    try std.testing.expect(host.paint.counters.wrap_bytes >= 200_000);
}
