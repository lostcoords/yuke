import { Transcript, registerRender } from "yuke:internal/transcript";
import { defaultRender } from "yuke:internal/transcript-view";
import { term } from "yuke:internal/native/term";
import { client } from "yuke:internal/client";
import { route } from "yuke:internal/core";
import { rowText, segmentsOf } from "yuke:internal/pager";

/** @import { MessagePart, SessionOutline } from "yuke:internal/native/engine" */
/** @import { TranscriptRow } from "../app/types/pager.js" */
/** @import { MessageDescriptor, TranscriptOptions } from "../app/types/transcript.js" */
// The bench renders with the default look, as a chat pane does.
registerRender(defaultRender);

/** @typedef {{ type: MessageDescriptor["type"], text?: string, parts?: Wire.AssistantPart[] }} FixtureMessage */
/** @type {FixtureMessage[]} */
const sample = [
  { type: "user", text: "Hello 世界 e\u0301 👩‍💻" },
  { type: "assistant", parts: [
    { type: "text", id: 1, text: "# Answer\n\nA **bold** word and `code`.\n\n" + "One two three 世界.\n\n".repeat(24) },
    { type: "reasoning", id: 2, text: "Reason\n\n".repeat(12), signature: "", title: "" },
    { type: "text", id: 3, text: "```zig\nconst answer = 42;\n```" },
  ] },
];

/** @type {MessageDescriptor[]} */
let outline;
/** @type {Map<number, Wire.AssistantPart[]>} */
let parts;
/** @type {Extract<Wire.AssistantPart, { type: "text" }>[]} */
let live;
/** @type {Transcript} */
let transcript;
let phase = "", width = 0, height = 0, iteration = 0;
let streamSuffixOffset = 0;
let nativeTextUnits = 0;
let nativeInitialText = "";
let nextPart = 1;
/** @type {MessagePart | null} */
let projected = null;
/** @type {(() => void) | null} */
let routeOff = null;
const activeId = 0;

const PREVIEW_REPORT_ID = 1;
const PREVIEW_ASSISTANT_ID = 2;
const PREVIEW_REASONING_ID = 9;
const NATIVE_STREAM_MESSAGE_ID = 2;
const NATIVE_STREAM_PART_ID = 0;
const TOOL_STREAM_PART_ID = 1;

// The native stream phases read their draft from the engine: message 2, or the draft after the seeded exchanges.
function nativeStream() {
  return phase === "stream_native" || phase === "stream_tool" || phase === "stream_part";
}

function draftId() {
  return phase === "stream_part" ? globalThis.PROJECTION_DRAFT : NATIVE_STREAM_MESSAGE_ID;
}
const streamPrefix = "Stable paragraph.\n\n".repeat(16) + "Tail";
const streamSuffix = Array.from({ length: 256 }, (_, i) => "stable-suffix-" + i + " 世界 e\u0301 👩‍💻").join("\n");
const nativeDeltas = [" word", " 世界", " e\u0301", " 👩‍💻", "\n\n"];

const previewReport = Array.from({ length: 256 }, (_, i) => "report-line-" + i + " with stable context").join("\n");
const previewReasoning = [
  "reason-first",
  ...Array.from({ length: 254 }, (_, i) => "reason-middle-" + i),
  "reason-last",
].join("\n");

/** @returns {Wire.AssistantPart[]} */
function previewParts() {
  /** @type {Wire.AssistantPart[]} */
  const parts = [];
  for (let i = 0; i < 8; i++) {
    const structured = i === 1;
    parts.push({
      type: "tool",
      id: i + 1,
      call_id: "call_" + (i + 1),
      name: structured ? "view" : "plain-" + i,
      arguments: JSON.stringify({ path: structured ? "view.md" : "plain-" + i + ".txt" }),
      state: {
        type: "completed",
        duration_ms: i + 1,
        output: structured ? "" : Array.from({ length: 128 }, (_, line) => "plain-" + i + "-line-" + line).join("\n"),
        ...(structured ? { view: [
          { type: "markdown", text: "view-first\n\nview-second" },
          { type: "text", text: "view-tail" },
        ] } : {}),
      },
    });
  }
  parts.push({ type: "reasoning", id: PREVIEW_REASONING_ID, text: previewReasoning, signature: "", title: "" });
  return parts;
}

/** @param {number} scale */
function configurePreview(scale) {
  outline = [];
  parts = new Map();
  for (let copy = 0; copy < scale; copy++) {
    const reportId = outline.length + 1;
    outline.push({ id: reportId, type: "user", source: {
      type: "child_report",
      session_id: "preview-session",
      run_id: 1,
      name: "preview-agent",
      outcome: { type: "turn", finish: "stop", rounds: 1 },
      partial: false,
      truncated: false,
      usage: { rounds: 1, tool_calls: 0, tokens: { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 }, duration_ms: 1500 },
    } });
    parts.set(reportId, [{ type: "text", id: 0, text: previewReport }]);
    const assistantId = outline.length + 1;
    outline.push({ id: assistantId, type: "assistant" });
    parts.set(assistantId, previewParts());
  }
}

/** @returns {TranscriptOptions} */
function options() {
  const session = globalThis.PROJECTION_SESSION;
  // The part stream reads every message through the native client, the same as a chat pane.
  if (phase === "stream_part") {
    return {
      partsOf: id => client.sessionParts(session, id),
      partOf: (id, partId, cursor) => client.sessionPart(session, id, partId, cursor),
      partTextPage: (id, partId, field, offset, limit) => client.partTextPage(session, id, partId, field, offset, limit),
    };
  }
  // The other native streams read only their draft through the client.
  return {
    partsOf: id => id === activeId ? live : nativeStream() && id === NATIVE_STREAM_MESSAGE_ID ? client.sessionParts(session, id) : parts.get(id) || [],
    partOf: (id, pid, cursor) => {
      if (nativeStream() && id === NATIVE_STREAM_MESSAGE_ID) return client.sessionPart(session, id, pid, cursor);
      const part = (id === activeId ? live : parts.get(id) || []).find(p => p.id === pid);
      return part ? { part } : null;
    },
  };
}

function fresh() {
  const t = new Transcript(options());
  /** @type {MessageDescriptor | null} */
  const active = phase === "stream" ? { id: activeId, type: "assistant" }
    : nativeStream() ? { id: draftId(), type: "assistant" } : null;
  t.setOutline(outline, active);
  return t;
}

/** @param {string} name @param {number} scale @param {number} w @param {number} h */
function start(name, scale, w, h) {
  phase = name;
  width = w;
  height = h;
  iteration = 0;
  streamSuffixOffset = 0;
  projected = null;
  if (routeOff) routeOff();
  routeOff = null;
  outline = [];
  parts = new Map();
  const fixture = /** @type {FixtureMessage[]} */ (globalThis.FIXTURE ? JSON.parse(globalThis.FIXTURE) : sample);
  for (let copy = 0; copy < scale; copy++) {
    for (const message of fixture) {
      const id = outline.length + 1;
      outline.push({ id, type: message.type });
      if (message.type === "assistant") parts.set(id, JSON.parse(JSON.stringify(message.parts || [])));
      else parts.set(id, [{ type: "text", id: 0, text: message.text || "" }]);
    }
  }
  if (phase === "preview") configurePreview(scale);
  if (nativeStream()) {
    const snapshot = /** @type {SessionOutline} */ (client.sessionOutline(globalThis.PROJECTION_SESSION));
    if (!snapshot) throw new Error(phase + " session missing");
    outline = snapshot.messages;
    nextPart = 1;
  }
  if (phase === "stream_native") {
    const part = client.sessionPart(globalThis.PROJECTION_SESSION, NATIVE_STREAM_MESSAGE_ID, NATIVE_STREAM_PART_ID)?.part;
    if (!part || part.type !== "text") throw new Error("native stream part missing");
    nativeTextUnits = part.text.length;
    nativeInitialText = part.text;
  }
  if (phase === "stream_tool") {
    const text = client.sessionPart(globalThis.PROJECTION_SESSION, NATIVE_STREAM_MESSAGE_ID, NATIVE_STREAM_PART_ID)?.part;
    const tool = client.sessionPart(globalThis.PROJECTION_SESSION, NATIVE_STREAM_MESSAGE_ID, TOOL_STREAM_PART_ID)?.part;
    if (!text || text.type !== "text" || !tool || tool.type !== "tool" || tool.state.type !== "running") throw new Error("tool stream part missing");
  }
  live = [
    { type: "text", id: 1, text: streamPrefix },
    { type: "text", id: 2, text: streamSuffix },
  ];
  transcript = fresh();
  transcript.rowCount(width);
  if (phase === "key_routing") routeOff = route.add("keymap");
  return outline.length;
}

function step() {
  const i = iteration++;
  if (phase === "key_routing") return route.reader() === "keymap" ? 1 : 0;
  if (phase === "projection") {
    projected = client.sessionPart(globalThis.PROJECTION_SESSION, 1, 0)?.part || null;
    return projected?.type === "text" ? projected.text.length : 0;
  }
  if (phase === "build") transcript = fresh();
  if (phase === "reflow") width = term.width - ((i + 1) & 1);
  if (phase === "preview") width = term.width - ((i + 1) & 1);
  if (phase === "stream") {
    const part = /** @type {Extract<Wire.AssistantPart, { type: "text" }>} */ (live[0]);
    const delta = [" word", " 世界", " e\u0301", " 👩‍💻", "\n\n"][i % 5] || "";
    live[0] = { ...part, text: part.text + delta };
    streamSuffixOffset += delta.length;
    transcript.setActive(activeId, 1);
  }
  // The engine grew the draft before this step, so the transcript reads the part again, as it does for a delta digest.
  if (nativeStream()) {
    if (phase === "stream_tool") transcript.setActive(NATIVE_STREAM_MESSAGE_ID, TOOL_STREAM_PART_ID);
    else if (phase === "stream_part") transcript.setActive(draftId(), nextPart++);
    else {
      nativeTextUnits += (nativeDeltas[i % nativeDeltas.length] || "").length;
      transcript.setActive(NATIVE_STREAM_MESSAGE_ID, NATIVE_STREAM_PART_ID);
    }
    const total = transcript.rowCount(width);
    transcript.pager.toBottom();
    paint(transcript, true);
    return Math.min(height, total);
  }
  const total = transcript.rowCount(width);
  const top = phase === "scroll" ? (i * 7) % Math.max(1, total - height + 1)
    : phase === "stream" ? Math.max(0, total - height) : 0;
  if (phase === "paint" || phase === "selection") {
    const first = /** @type {MessageDescriptor} */ (outline[0]);
    transcript.selection = phase === "selection" ? {
      anchor: { id: first.id, row: 0, col: 0 },
      cursor: { id: first.id, row: 0, col: i % 6 + 1 },
    } : null;
    paint(transcript);
  }
  return transcript.rows(width, top, phase === "build" ? total : height).length;
}

/** @param {Transcript} view @param {boolean} [followTail] */
function paint(view, followTail = false) {
  term.beginFrame();
  if (followTail) view.pager.toBottom();
  else {
    view.pager.stuck = false;
    view.pager.scroll = 0;
  }
  view.draw({ x: 0, y: 0, w: width, h: height });
  term.endFrame();
}

/** @param {boolean} [withChecksum] */
function verify(withChecksum = true) {
  // The boot phase drives no transcript, so it compares nothing.
  if (phase === "boot") return 0;
  if (phase === "key_routing") {
    if (route.reader() !== "keymap") throw new Error("key route changed");
    return iteration;
  }
  if (phase === "projection") {
    if (projected?.type !== "text" || projected.text !== globalThis.PROJECTION_TEXT)
      throw new Error("native projection lost text across a page boundary");
    return withChecksum ? checksum(projected.text) : 0;
  }
  if (phase === "stream") verifyStreamSuffix();
  if (phase === "stream_native") verifyNativeStream();
  if (phase === "preview") verifyPreview();
  const reference = fresh();
  const total = reference.rowCount(width);
  reference.selection = transcript.selection;
  const expected = reference.rows(width, 0, total);
  const actual = transcript.rows(width, 0, transcript.rowCount(width));
  if (actual.length !== expected.length)
    throw new Error(phase + " has " + actual.length + " rows; expected " + expected.length);
  const encoded = JSON.stringify(actual);
  if (encoded !== JSON.stringify(expected)) {
    const row = actual.findIndex((r, i) => JSON.stringify(r) !== JSON.stringify(expected[i]));
    throw new Error(phase + " differs at row " + row + ": " + JSON.stringify(actual[row]) + " expected " + JSON.stringify(expected[row]));
  }
  if (actual.length === 0 || !actual.some(r => r.segments?.some(s => s.text.length > 0))) throw new Error("empty benchmark output");
  if (phase === "paint" || phase === "selection") paint(reference);
  if (nativeStream()) paint(reference, true);
  return withChecksum ? checksum(encoded) : 0;
}

function verifyNativeStream() {
  const source = transcript._sourceOf(NATIVE_STREAM_MESSAGE_ID);
  let appended = "";
  for (let i = 0; i < iteration; i++) appended += nativeDeltas[i % nativeDeltas.length] || "";
  if (source !== nativeInitialText + appended) throw new Error("native stream source changed");
  if (source.length !== nativeTextUnits)
    throw new Error("native stream source length changed");
  const rows = publicRowsFor(NATIVE_STREAM_MESSAGE_ID);
  const unicode = rows.flatMap((row) => row.segments || []).find((entry) => entry.text.indexOf("👩‍💻") >= 0);
  if (!unicode || source.slice(unicode.src, unicode.srcEnd) !== unicode.text)
    throw new Error("native stream Unicode span changed");
}

function verifyStreamSuffix() {
  const source = transcript._sourceOf(activeId);
  const active = /** @type {Extract<Wire.AssistantPart, { type: "text" }>} */ (live[0]);
  const expectedOffset = active.text.length + 1;
  if (expectedOffset !== streamSuffixOffset + streamPrefix.length + 1)
    throw new Error("stream suffix offset accounting changed");
  if (source.slice(expectedOffset) !== streamSuffix) throw new Error("stream suffix source changed");
  const rows = publicRowsFor(activeId);
  const segment = rows.flatMap((row) => row.segments || []).find((entry) => entry.text.indexOf("stable-suffix-0") >= 0);
  if (!segment || segment.src !== expectedOffset || source.slice(segment.src, segment.srcEnd) !== segment.text)
    throw new Error("stream suffix span changed");
}

// The folded look is the preview: a report shows ten lines, a tool its first ten output rows, and a thought its header alone.
function verifyPreview() {
  const reportRows = publicRowsFor(PREVIEW_REPORT_ID);
  if (reportRows.length !== 13) throw new Error("preview report row cap changed");
  if (!reportRows.slice(1, 11).every((row, i) => rowText(row) === "report-line-" + i + " with stable context"))
    throw new Error("preview report content changed");
  if (rowText(/** @type {TranscriptRow} */ (reportRows[11])).indexOf("expands") < 0) throw new Error("preview report hint missing");
  if (!spanMatches(transcript._sourceOf(PREVIEW_REPORT_ID), reportRows, "report-line-0")) throw new Error("preview report source span changed");

  const toolRows = publicRowsFor(PREVIEW_ASSISTANT_ID);
  for (const part of parts.get(PREVIEW_ASSISTANT_ID) || []) {
    const rows = toolRows.filter((row) => row.partId === part.id);
    if (part.type === "reasoning" && rows.length !== 1) throw new Error("preview thought fold changed");
    if (part.type === "tool" && rows.filter((row) => row.header).length !== 1) throw new Error("preview tool count changed");
    if (part.type === "tool" && part.name !== "view" && rows.filter((row) => !row.header && row.src != null).length !== 10) throw new Error("preview tool body cap changed");
  }
  const source = transcript._sourceOf(PREVIEW_ASSISTANT_ID);
  // A folded thought still holds its whole text in the source.
  if (!source.includes("reason-first") || !source.includes("reason-last")) throw new Error("preview thought source changed");
  for (const needle of ["plain-0-line-0", "view-first"])
    if (!spanMatches(source, toolRows, needle)) throw new Error("preview source span changed: " + needle);
}

// A segment or a wrapped text row that shows `needle` maps back to the same source text.
/** @param {string} source @param {TranscriptRow[]} rows @param {string} needle @returns {boolean} */
function spanMatches(source, rows, needle) {
  for (const row of rows) {
    const segment = segmentsOf(row)?.find((entry) => entry.src != null && entry.text.indexOf(needle) >= 0);
    if (segment) return source.slice(segment.src, segment.srcEnd) === segment.text;
  }
  return false;
}

/** @param {number} id @returns {TranscriptRow[]} */
function publicRowsFor(id) {
  const rows = transcript.rows(width, 0, transcript.rowCount(width));
  return rows.filter((row) => String(row.key) === String(id));
}

/** @param {string} encoded */
function checksum(encoded) {
  let hash = 2166136261;
  for (let i = 0; i < encoded.length; i++) hash = Math.imul(hash ^ encoded.charCodeAt(i), 16777619);
  return hash | 0;
}

globalThis.bench = { start, step, verify };
