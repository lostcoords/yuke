// The tree transcript: tool calls and thoughts grouped under "N actions" with a ├─ └─ tree, a 3-row preview, and a details window.
// It stacks on the default look through `c.chat.render` alone. CI type-checks this file against yuke.d.ts, and a test renders it.
import { plugins } from "yuke";
import { measure, clip } from "yuke:ui";
import { inputSourceLabel, toolHead, displayPath, displayCommand, wrapRows, diffRows, mediaLabel, errorLabel, isCut, openDetails } from "yuke:chat";

/** @typedef {import("yuke:chat").Render} Render */
/** @typedef {import("yuke:chat").PartEnv} PartEnv */
/** @typedef {Wire.AssistantPart} AssistantPart */
/** @typedef {Extract<AssistantPart, { type: "tool" }>} ToolPart */
/** @typedef {NonNullable<ReturnType<NonNullable<Render["groupHeader"]>>>[number]} Row */

const GUTTER = 2;
const TREE_INDENT = GUTTER + 3;
const PREVIEW_ROWS = 3;
const REPORT_LINES = 8;
const LABEL_W = 7;
// A null prototype keeps a tool named `constructor` on the fallback style.
const TOOL_STYLE = /** @type {Record<string, string>} */ (Object.assign(Object.create(null), { read: "TreeRead", write: "TreeWrite", edit: "TreeWrite", exec: "TreeRun", spawn_agent: "TreeAgent", send_agent_input: "TreeAgent", stop_agent: "TreeAgent" }));

/** @param {PartEnv["group"]} group @returns {Row} */
function headerAttrs(group) {
  if (!group) return { indent: GUTTER, header: true, stop: true };
  return { indent: TREE_INDENT, marker: "  " + (group.last ? "└─" : "├─"), markerGroup: "TxMeta", header: true, stop: true };
}

/** @param {PartEnv["group"]} group @returns {Row} */
function bodyAttrs(group) {
  return { indent: group ? TREE_INDENT : GUTTER, marker: group && !group.last ? "  │" : null, markerGroup: "TxMeta" };
}

// The segments of a body row at source offset `base`: a markdown row has its own, and a wrapped text row is one segment.
/** @param {Row} r @param {number} base @returns {NonNullable<Row["segments"]>} */
function segmentsAt(r, base) {
  if (r.segments) return r.segments.map((s) => (s.src == null ? s : { ...s, src: s.src + base, srcEnd: /** @type {number} */ (s.srcEnd) + base }));
  const text = r.text || "";
  const group = r.group || "TxToolOutput";
  return [r.src == null ? { text, group } : { text, group, src: r.src + base, srcEnd: r.src + base + text.length }];
}

// A duration shows only over one second, and a completed call needs no state word.
/** @param {ToolPart["state"]} state @returns {string} */
function rightLabel(state) {
  const label = state.type === "completed" ? "" : state.type;
  const ms = /** @type {{ duration_ms?: number }} */ (state).duration_ms;
  const took = typeof ms === "number" && ms >= 1000 ? (ms / 1000).toFixed(1) + "s" : "";
  return label && took ? label + " · " + took : label || took;
}

/** @param {ToolPart} part @param {PartEnv} env */
function toolRows(part, env) {
  const width = Math.max(1, env.width - (env.group ? TREE_INDENT : GUTTER));
  const head = toolHead(part, env.tools);
  const headerSrc = head.subject ? head.verb + " " + head.subject : head.verb;
  const right = rightLabel(part.state);
  const rightW = measure(right);
  const leftW = Math.max(1, width - (rightW > 0 ? rightW + 1 : 0));
  const name = clip(head.verb, leftW);
  /** @type {NonNullable<Row["segments"]>} */
  const segments = [{ text: name, group: TOOL_STYLE[part.name] || "TreeTool", src: 0, srcEnd: head.verb.length }];
  let used = measure(name);
  if (head.subject && used + 1 < leftW) {
    const subject = clip(head.subject, leftW - used - 1);
    segments.push({ text: " " + subject, group: "TxMeta", src: head.verb.length, srcEnd: headerSrc.length });
    used += 1 + measure(subject);
  }
  if (rightW > 0 && used + 1 + rightW <= width) {
    segments.push({ text: " ".repeat(width - used - rightW), group: "TxMeta" });
    segments.push({ text: right, group: part.state.type === "error" ? "TxError" : "TxMeta" });
  }
  /** @type {Row[]} */
  const rows = [{ segments, ...headerAttrs(env.group), kind: "tool-header" }];
  const args = String(part.arguments || "");
  const state = part.state;
  const diff = state.type === "completed" ? state.diff : undefined;
  const text = state.type === "error" ? state.error || "" : String(/** @type {{ output?: string }} */ (state).output || "");
  // A folded block builds no body rows, but its source keeps the body, so a fold never moves a source offset.
  const limit = env.expanded ? PREVIEW_ROWS + 1 : 0;
  const body = diff && diff.length ? diffRows(diff, width - LABEL_W, 0, limit) : { rows: wrapRows(text, width - LABEL_W, state.type === "error" ? "TxError" : "TxToolOutput", 0, limit), source: text };
  let source = headerSrc + "\n" + args;
  const base = source.length + 1;
  if (body.source) source += "\n" + body.source;
  if (!env.expanded) return { rows, source };
  rows.push({ segments: [{ text: "input".padEnd(LABEL_W), group: "TxMeta" }, { text: args.replace(/\s+/g, " ").trim() || "(empty)", group: "TxToolOutput" }], ...bodyAttrs(env.group), kind: "tool-detail" });
  const media = state.type === "completed" ? state.media || [] : [];
  for (let i = 0; i < media.length && body.rows.length <= PREVIEW_ROWS; i++) body.rows.push({ text: mediaLabel(/** @type {Wire.MediaBlob} */ (media[i]), i + 1), group: "TxMeta" });
  body.rows.slice(0, PREVIEW_ROWS).forEach((r, i) => {
    rows.push({ segments: [{ text: (i === 0 ? "output" : "").padEnd(LABEL_W), group: "TxMeta" }, ...segmentsAt(r, base)], ...bodyAttrs(env.group), kind: "tool-body" });
  });
  if (body.rows.length > PREVIEW_ROWS || isCut(part, state.type === "error" ? "error" : "output") || args.indexOf("\n") >= 0) {
    rows.push({ text: "… Enter or click to view all", group: "TxMeta", ...bodyAttrs(env.group), kind: "tool-detail" });
  }
  return { rows, source };
}

/** @param {Extract<AssistantPart, { type: "reasoning" }>} part @param {PartEnv} env */
function reasoningRows(part, env) {
  const ms = part.duration_ms;
  const name = ms != null ? "thought for " + Math.round(ms / 1000) + "s" : env.live ? "thinking" : "thought";
  const text = part.text || "";
  // The engine reads the title of the latest summary section, so the renderer parses no text.
  const headerSrc = part.title ? name + " · " + part.title : name;
  /** @type {Row[]} */
  const rows = [{ segments: [{ text: headerSrc, group: "TxThought", src: 0, srcEnd: headerSrc.length }], ...headerAttrs(env.group), header: text !== "", markerGroup: "TxThought", kind: "reasoning-header" }];
  // The source keeps the text while folded, so a fold never moves a source offset.
  const source = headerSrc + "\n" + text;
  if (!env.expanded) return { rows, source };
  const base = headerSrc.length + 1;
  const body = wrapRows(text, env.width - (env.group ? TREE_INDENT : GUTTER), "TxThought", 0, PREVIEW_ROWS, 1);
  /** @param {Row} r @returns {Row} */
  const decorate = (r) => ({ ...r, ...bodyAttrs(env.group), markerGroup: "TxThought", kind: "reasoning-body", src: /** @type {number} */ (r.src) + base });
  const shown = body.length <= PREVIEW_ROWS ? body : [/** @type {Row} */ (body[0]), /** @type {Row} */ (body[body.length - 1])];
  shown.forEach((r, i) => {
    rows.push(decorate(r));
    if (i === 0 && shown.length < body.length) rows.push({ ...bodyAttrs(env.group), text: "…", group: "TxMeta", kind: "reasoning-body" });
  });
  return { rows, source };
}

/** @type {Render} */
const treeLook = {
  indent: GUTTER,
  gap: 0,
  tools: {
    read: (o) => ({ verb: "Read", subject: displayPath(o.path) + (typeof o.start === "number" ? " (" + o.start + "-" + (typeof o.end === "number" ? o.end : "") + ")" : ""), input: "" }),
    write: (o) => ({ verb: "Write", subject: displayPath(o.path), input: "" }),
    edit: (o) => ({ verb: "Edit", subject: displayPath(o.path) + (o.replace_all ? " (all)" : ""), input: "" }),
    exec: (o) => ({ verb: "Run", subject: displayCommand(o.command), input: "" }),
    skill: (o) => ({ verb: "Skill", subject: String(o.name || ""), input: "" }),
  },
  // Tool calls and thoughts group as actions, and text closes the group.
  groupKey: (part) => (part.type === "text" ? null : "actions"),
  groupHeader: (group) => [{ text: group.count + (group.count === 1 ? " action" : " actions"), group: "TxMeta", indent: GUTTER }],
  // A call that runs or fails shows open. A thought stays folded, also while it streams.
  fold: (part) => part.type === "tool" && ["running", "error", "canceled"].includes(part.state.type),
  part: (part, env) => (part.type === "tool" ? toolRows(part, env) : reasoningRows(part, env)),

  message(m, parts, env) {
    const width = Math.max(1, env.width - GUTTER);
    const texts = /** @type {Extract<(typeof parts)[number], { type: "text" }>[]} */ (parts.filter((p) => p.type === "text"));
    const all = texts.map((p) => p.text).join("");
    if (m.type === "compaction") return { rows: wrapRows(all, width, "TxThought", GUTTER).map((r, i) => ({ ...r, stop: i === 0 })), source: all };
    if (m.skill_name || (m.source && m.source.type !== "parent_instruction")) {
      // An engine end message starts with a header. The rows show only its body.
      const text = (m.source?.type === "child_report" || m.source?.type === "job_ended") && texts.length >= 2 ? /** @type {{ text: string }} */ (texts[texts.length - 1]).text : all;
      const body = wrapRows(text, width, "TxToolOutput", GUTTER, env.expanded ? Infinity : REPORT_LINES + 1);
      const shown = env.expanded ? body : body.slice(0, m.skill_name ? 0 : REPORT_LINES);
      /** @type {Row[]} */
      const rows = [{ text: m.skill_name ? "Skill · " + m.skill_name : inputSourceLabel(m.source), group: "TxMeta", indent: GUTTER, header: true, stop: true }, ...shown];
      if (!env.expanded && body.length > shown.length) rows.push({ text: "… click the header to expand", group: "TxMeta", indent: GUTTER });
      return { rows, source: text };
    }
    let image = 0;
    const text = parts.map((p) => (p.type === "text" ? p.text : p.type === "image" || p.type === "audio" || p.type === "file" ? mediaLabel(p.source, p.type === "image" ? ++image : 0) : "")).join("");
    /** @type {Row[]} */
    const rows = wrapRows(text, width, "TxUser", GUTTER).map((r, i) => ({ ...r, bg: "TxUser", marker: i === 0 ? "⟩" : null, markerGroup: "TreeUserMarker", stop: i === 0 }));
    // A parent-sent task reads like user input, so one label row says where it came from.
    if (m.source) rows.unshift({ text: inputSourceLabel(m.source), group: "TxMeta", indent: GUTTER });
    return { rows, source: text };
  },

  error(error, env) {
    const text = errorLabel(error);
    return { rows: [{ text: "" }, ...wrapRows(text, env.width - GUTTER, "TxError", GUTTER).map((r, i) => ({ ...r, stop: i === 0 }))], source: text };
  },

  // A detail or output row opens a window with the whole fields; a header row falls through to the fold toggle.
  activate(hit, transcript) {
    const kind = hit.row.kind;
    if (kind === "tool-detail" || kind === "tool-body") {
      const input = transcript.readField(hit.id, hit.partId, "arguments");
      // A failed call has an error and no output.
      const output = transcript.readField(hit.id, hit.partId, "output") || transcript.readField(hit.id, hit.partId, "error");
      openDetails("tool details", [{ label: "input", text: input }, { label: "output", text: output }]);
    } else if (kind === "reasoning-body") {
      openDetails("thought · reasoning details", [{ label: "reasoning", text: transcript.readField(hit.id, hit.partId, "text") }]);
    } else return undefined;
    return transcript.partHeader(hit.id, hit.partId);
  },
};

export { treeLook };

plugins.use({
  name: "tree-transcript",
  apply(ctx) {
    ctx.inject(["tui", "chat"], (ctx) => {
      const bold = { fg: "fg", bold: true };
      ctx.tui.style.set({ TreeTool: bold, TreeRead: bold, TreeWrite: bold, TreeRun: bold, TreeAgent: bold, TreeUserMarker: { reverse: true, bold: true } }, { default: true });
      ctx.chat.render(treeLook);
    });
  },
});
