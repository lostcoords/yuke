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
/** @type {Transcript} */
let transcript;
let phase = "", width = 0, height = 0, iteration = 0;
/** @type {Wire.AssistantPart | null} */
let projected = null;
const activeId = 0;

/** @returns {import("yuke:transcript").TranscriptOptions} */
function options() {
  return {
    textOf: id => texts.get(id) || "",
    partsOf: id => id === activeId ? live : parts.get(id) || [],
    partOf: (id, pid) => (id === activeId ? live : parts.get(id) || []).find(p => p.id === pid) || null,
  };
}

function fresh() {
  const t = new Transcript(options());
  t.setOutline(outline, phase === "stream" ? { id: activeId, type: "assistant" } : null);
  return t;
}

/** @param {string} name @param {number} scale @param {number} w @param {number} h */
function start(name, scale, w, h) {
  phase = name;
  width = w;
  height = h;
  iteration = 0;
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
  live = [
    { type: "text", id: 1, text: "Stable paragraph.\n\n".repeat(16) + "Tail" },
    { type: "text", id: 2, text: "# Later part\n\nA stable source position." },
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
  if (phase === "stream") {
    const part = /** @type {Extract<Wire.AssistantPart, { type: "text" }>} */ (live[0]);
    live[0] = { ...part, text: part.text + [" word", " 世界", " e\u0301", " 👩‍💻", "\n\n"][i % 5] };
    transcript.setActive(activeId, 1);
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

/** @param {Transcript} view */
function paint(view) {
  term.beginFrame();
  view.pager.stuck = false;
  view.pager.scroll = 0;
  view.draw({ x: 0, y: 0, w: width, h: height });
  term.endFrame();
}

function verify() {
  if (phase === "projection") {
    if (projected?.type !== "text" || projected.text !== globalThis.PROJECTION_TEXT)
      throw new Error("native projection lost text across a page boundary");
    return checksum(projected.text);
  }
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
  return checksum(encoded);
}

/** @param {string} encoded */
function checksum(encoded) {
  let hash = 2166136261;
  for (let i = 0; i < encoded.length; i++) hash = Math.imul(hash ^ encoded.charCodeAt(i), 16777619);
  return hash | 0;
}

globalThis.bench = { start, step, verify };
