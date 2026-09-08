import { Transcript } from "yuke:transcript";
import { term } from "yuke:term";
import { client } from "yuke:client";

/** @typedef {import("yuke:transcript").MessageDescriptor} MessageDescriptor */
/** @typedef {{ type: MessageDescriptor["type"], text?: string, parts?: Wire.AssistantPart[] }} FixtureMessage */
/** @type {FixtureMessage[]} */
const sample = [
  { type: "user", text: "Hello 世界 e\u0301 👩‍💻" },
  { type: "assistant", parts: [
    { type: "text", id: 1, text: "# Answer\n\nA **bold** word and `code`.\n\n" + "One two three 世界.\n\n".repeat(24) },
    { type: "reasoning", id: 2, text: "Reason\n\n".repeat(12), signature: "" },
    { type: "text", id: 3, text: "```zig\nconst answer = 42;\n```" },
  ] },
];

/** @type {MessageDescriptor[]} */
let outline;
/** @type {Map<number, Wire.AssistantPart[]>} */
let parts;
/** @type {Map<number, string>} */
let texts;
/** @type {Extract<Wire.AssistantPart, { type: "text" }>[]} */
let live;
/** @type {Wire.AssistantPart[]} */
let nativeLive;
/** @type {Transcript} */
let transcript;
let phase = "", width = 0, height = 0, iteration = 0;
let streamSuffixOffset = 0;
let nativeTextUnits = 0;
let nativeInitialText = "";
/** @type {Wire.AssistantPart | null} */
let projected = null;
const activeId = 0;

const PREVIEW_REPORT_ID = 1;
const PREVIEW_ASSISTANT_ID = 2;
const PREVIEW_REASONING_ID = 9;
const NATIVE_STREAM_MESSAGE_ID = 2;
const NATIVE_STREAM_PART_ID = 0;
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
  parts.push({ type: "reasoning", id: PREVIEW_REASONING_ID, text: previewReasoning, signature: "" });
  return parts;
}

/** @param {number} scale */
function configurePreview(scale) {
  outline = [];
  parts = new Map();
  texts = new Map();
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
    } });
    texts.set(reportId, previewReport);
    const assistantId = outline.length + 1;
    outline.push({ id: assistantId, type: "assistant" });
    parts.set(assistantId, previewParts());
  }
}

/** @returns {import("yuke:transcript").TranscriptOptions} */
function options() {
  return {
    textOf: id => texts.get(id) || "",
    partsOf: id => id === activeId ? live : phase === "stream_native" && id === NATIVE_STREAM_MESSAGE_ID ? nativeLive : parts.get(id) || [],
    partOf: (id, pid) => (id === activeId ? live : phase === "stream_native" && id === NATIVE_STREAM_MESSAGE_ID ? nativeLive : parts.get(id) || []).find(p => p.id === pid) || null,
  };
}

function fresh() {
  const t = new Transcript(options());
  /** @type {MessageDescriptor | null} */
  const active = phase === "stream" ? { id: activeId, type: "assistant" }
    : phase === "stream_native" ? { id: NATIVE_STREAM_MESSAGE_ID, type: "assistant" } : null;
  t.setOutline(outline, active);
  if (phase === "preview") {
    for (const message of outline) if (message.type === "assistant") {
      for (const part of parts.get(message.id) || []) t.togglePart(message.id, part.id);
    }
  }
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
  outline = [];
  parts = new Map();
  texts = new Map();
  const fixture = /** @type {FixtureMessage[]} */ (globalThis.FIXTURE ? JSON.parse(globalThis.FIXTURE) : sample);
  for (let copy = 0; copy < scale; copy++) {
    for (const message of fixture) {
      const id = outline.length + 1;
      outline.push({ id, type: message.type });
      if (message.type === "assistant") parts.set(id, JSON.parse(JSON.stringify(message.parts || [])));
      else texts.set(id, message.text || "");
    }
  }
  if (phase === "preview") configurePreview(scale);
  if (phase === "stream_native") {
    const snapshot = /** @type {import("yuke:engine-native").SessionOutline} */ (client.sessionOutline(globalThis.PROJECTION_SESSION));
    if (!snapshot) throw new Error("native stream session missing");
    outline = snapshot.messages;
    const part = client.sessionPart(globalThis.PROJECTION_SESSION, NATIVE_STREAM_MESSAGE_ID, NATIVE_STREAM_PART_ID);
    if (!part || part.type !== "text") throw new Error("native stream part missing");
    nativeLive = [part];
    nativeTextUnits = part.text.length;
    nativeInitialText = part.text;
  }
  live = [
    { type: "text", id: 1, text: streamPrefix },
    { type: "text", id: 2, text: streamSuffix },
  ];
  transcript = fresh();
  transcript.rowCount(width);
  return outline.length;
}

function step() {
  const i = iteration++;
  if (phase === "projection") {
    projected = client.sessionPart(globalThis.PROJECTION_SESSION, 1, 0);
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
  if (phase === "stream_native") {
    const delta = nativeDeltas[i % nativeDeltas.length] || "";
    const part = client.sessionPart(globalThis.PROJECTION_SESSION, NATIVE_STREAM_MESSAGE_ID, NATIVE_STREAM_PART_ID);
    if (!part || part.type !== "text") throw new Error("native stream part missing");
    nativeTextUnits += delta.length;
    nativeLive = [part];
    transcript.setActive(NATIVE_STREAM_MESSAGE_ID, NATIVE_STREAM_PART_ID);
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

function verify() {
  if (phase === "projection") {
    if (projected?.type !== "text" || projected.text !== globalThis.PROJECTION_TEXT)
      throw new Error("native projection lost text across a page boundary");
    return checksum(projected.text);
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
  if (phase === "stream_native") paint(reference, true);
  return checksum(encoded);
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

function verifyPreview() {
  const reportRows = publicRowsFor(PREVIEW_REPORT_ID);
  if (reportRows.length !== 11) throw new Error("preview report row cap changed");
  if (!reportRows.slice(1, 9).every((row, i) => rowText(row) === "report-line-" + i + " with stable context"))
    throw new Error("preview report content changed");
  const reportFooter = reportRows[9];
  if (!reportFooter || rowText(reportFooter).indexOf("click the header") < 0) throw new Error("preview report footer missing");
  const reportSource = transcript._sourceOf(PREVIEW_REPORT_ID);
  const reportBodyRow = reportRows[1];
  const reportBody = reportBodyRow?.segments?.find((segment) => segment.src != null);
  if (!reportBody || reportSource.slice(reportBody.src, reportBody.srcEnd) !== reportBody.text)
    throw new Error("preview report source span changed");

  const toolRows = publicRowsFor(PREVIEW_ASSISTANT_ID);
  if (toolRows.filter((row) => row.kind === "tool-header").length !== 8)
    throw new Error("preview tool count changed");
  for (const part of parts.get(PREVIEW_ASSISTANT_ID) || []) if (part.type === "tool") {
    const bodyRows = toolRows.filter((row) => row.kind === "tool-body" && row.partId === part.id);
    if (bodyRows.length !== 3) throw new Error("preview tool body cap changed");
  }
  const plain = toolRows.find((row) => row.kind === "tool-body" && row.segments?.some((segment) => segment.text.indexOf("plain-0-line-0") >= 0));
  if (!plain) throw new Error("preview plain tool content changed");
  const viewed = toolRows.find((row) => row.kind === "tool-body" && row.segments?.some((segment) => segment.text.indexOf("view-first") >= 0));
  if (!viewed) throw new Error("preview structured view content changed");
  const toolSource = transcript._sourceOf(PREVIEW_ASSISTANT_ID);
  const toolBody = plain?.segments?.find((segment) => segment.text.indexOf("plain-0-line-0") >= 0);
  if (!toolBody || toolSource.slice(toolBody.src, toolBody.srcEnd) !== toolBody.text)
    throw new Error("preview tool source span changed");
  const viewBody = viewed?.segments?.find((segment) => segment.text === "view-first");
  if (!viewBody || toolSource.slice(viewBody.src, viewBody.srcEnd) !== viewBody.text)
    throw new Error("preview view source span changed");

  const reasoningRows = toolRows.filter((row) => row.kind === "reasoning-body");
  if (reasoningRows.length !== 3) throw new Error("preview reasoning cap changed");
  const firstReasoning = reasoningRows[0];
  const ellipsisReasoning = reasoningRows[1];
  const lastReasoning = reasoningRows[2];
  if (!firstReasoning || !ellipsisReasoning || !lastReasoning
    || rowText(firstReasoning).indexOf("reason-first") < 0 || rowText(ellipsisReasoning) !== "…" || rowText(lastReasoning).indexOf("reason-last") < 0)
    throw new Error("preview reasoning content changed");
  const reasoningSource = transcript._sourceOf(PREVIEW_ASSISTANT_ID);
  const first = firstReasoning?.segments?.find((segment) => segment.src != null);
  const last = lastReasoning?.segments?.find((segment) => segment.src != null);
  if (!first || !last || reasoningSource.slice(first.src, first.srcEnd) !== first.text || reasoningSource.slice(last.src, last.srcEnd) !== last.text)
    throw new Error("preview reasoning source spans changed");
}

/** @param {number} id @returns {import("yuke:transcript").TranscriptRow[]} */
function publicRowsFor(id) {
  const rows = transcript.rows(width, 0, transcript.rowCount(width));
  return rows.filter((row) => String(row.key) === String(id));
}

/** @param {import("yuke:transcript").TranscriptRow} row */
function rowText(row) {
  return row.text || (row.segments || []).map((segment) => segment.text).join("");
}

/** @param {string} encoded */
function checksum(encoded) {
  let hash = 2166136261;
  for (let i = 0; i < encoded.length; i++) hash = Math.imul(hash ^ encoded.charCodeAt(i), 16777619);
  return hash | 0;
}

globalThis.bench = { start, step, verify };
