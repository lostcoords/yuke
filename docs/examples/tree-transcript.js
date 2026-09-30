// The tree transcript: tool calls and thoughts grouped under "N actions" with a ├─ └─ tree, a 3-row preview, and a details window.
// It stacks on the default look through `c.chat.render` alone. CI type-checks this file against yuke.d.ts, and a test renders it.
import { plugins } from "yuke";
import { measure, clip } from "yuke:ui";
import { inputSourceLabel, toolHead, shortPath, shortCommand, wrapRows, viewRows, mediaLabel, errorLabel, isCut, openDetails } from "yuke:chat";

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
const CATEGORY = /** @type {Record<string, string>} */ ({ read: "TreeRead", write: "TreeWrite", run: "TreeRun", agent: "TreeAgent" });

/** @param {PartEnv["group"]} group @param {boolean} expanded @returns {Row} */
function headerAttrs(group, expanded) {
  if (!group) return { indent: GUTTER, marker: expanded ? "▾" : "▸", markerGroup: "TxMeta", header: true, stop: true };
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
  const segments = [{ text: name, group: CATEGORY[head.category] || "TreeTool", src: 0, srcEnd: head.verb.length }];
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
  const rows = [{ segments, ...headerAttrs(env.group, env.expanded), kind: "tool-header" }];
  let source = headerSrc;
  if (!env.expanded) return { rows, source };
  const args = String(part.arguments || "");
  source += "\n" + args;
  rows.push({ segments: [{ text: "input".padEnd(LABEL_W), group: "TxMeta" }, { text: args.replace(/\s+/g, " ").trim() || "(empty)", group: "TxToolOutput" }], ...bodyAttrs(env.group), kind: "tool-detail" });
  const state = part.state;
  const views = /** @type {{ view?: readonly Wire.View[] }} */ (state).view;
  const text = state.type === "error" ? state.error || "" : String(/** @type {{ output?: string }} */ (state).output || "");
  const body = views && views.length ? viewRows(views, width - LABEL_W, 0, PREVIEW_ROWS + 1) : { rows: wrapRows(text, width - LABEL_W, state.type === "error" ? "TxError" : "TxToolOutput", 0, PREVIEW_ROWS + 1), source: text };
  const media = state.type === "completed" ? state.media || [] : [];
  for (let i = 0; i < media.length && body.rows.length <= PREVIEW_ROWS; i++) body.rows.push({ text: mediaLabel(/** @type {Wire.MediaBlob} */ (media[i]), i + 1), group: "TxMeta" });
  const base = source.length + 1;
  if (body.source) source += "\n" + body.source;
  body.rows.slice(0, PREVIEW_ROWS).forEach((r, i) => {
    rows.push({ segments: [{ text: (i === 0 ? "output" : "").padEnd(LABEL_W), group: "TxMeta" }, ...segmentsAt(r, base)], ...bodyAttrs(env.group), kind: "tool-body" });
  });
  if (body.rows.length > PREVIEW_ROWS || isCut(part, state.type === "error" ? "error" : "output") || args.indexOf("\n") >= 0) {
    rows.push({ text: "… Enter or click to view all", group: "TxMeta", ...bodyAttrs(env.group), kind: "tool-detail" });
  }
  return { rows, source };
}

// A summary on the OpenAI Responses protocol opens with a bold title; prose falls back to its first line.
/** @param {string} text @returns {string} */
function reasoningTitle(text) {
  const head = text.trimStart().slice(0, 76);
  const bold = head.startsWith("**") ? head.indexOf("**", 2) : -1;
  const title = bold > 2 ? head.slice(2, bold) : head.split("\n")[0] || "";
  return title.length > 72 ? title.slice(0, 72) + "…" : title;
}

/** @param {Extract<AssistantPart, { type: "reasoning" }>} part @param {PartEnv} env */
function reasoningRows(part, env) {
  const name = env.live ? "thinking" : "thought";
  const text = part.text || "";
  const title = reasoningTitle(text);
  const headerSrc = title ? name + " · " + title : name;
  /** @type {Row[]} */
  const rows = [{ segments: [{ text: headerSrc, group: "TxThought", src: 0, srcEnd: headerSrc.length }], ...headerAttrs(env.group, env.expanded), markerGroup: "TxThought", kind: "reasoning-header" }];
  if (!env.expanded) return { rows, source: headerSrc };
  const base = headerSrc.length + 1;
  const body = wrapRows(text, env.width - (env.group ? TREE_INDENT : GUTTER), "TxThought", 0, PREVIEW_ROWS, 1);
  /** @param {Row} r @returns {Row} */
  const decorate = (r) => ({ ...r, ...bodyAttrs(env.group), markerGroup: "TxThought", kind: "reasoning-body", src: /** @type {number} */ (r.src) + base });
  const shown = body.length <= PREVIEW_ROWS ? body : [/** @type {Row} */ (body[0]), /** @type {Row} */ (body[body.length - 1])];
  shown.forEach((r, i) => {
    rows.push(decorate(r));
    if (i === 0 && shown.length < body.length) rows.push({ ...bodyAttrs(env.group), text: "…", group: "TxMeta", kind: "reasoning-body" });
  });
  return { rows, source: headerSrc + "\n" + text };
}

/** @type {Render} */
const treeLook = {
  indent: GUTTER,
  gap: 0,
  tools: {
    read: (o) => ({ verb: "Read", subject: shortPath(o.path) + (typeof o.start === "number" ? " (" + o.start + "-" + (typeof o.end === "number" ? o.end : "") + ")" : ""), category: "read" }),
    write: (o) => ({ verb: "Write", subject: shortPath(o.path), category: "write" }),
    edit: (o) => ({ verb: "Edit", subject: shortPath(o.path) + (o.replace_all ? " (all)" : ""), category: "write" }),
    exec: (o) => ({ verb: "Run", subject: shortCommand(o.command), category: "run" }),
    skill: (o) => ({ verb: "Skill", subject: String(o.name || ""), category: "other" }),
  },
  // Tool calls and thoughts group as actions, and text closes the group.
  groupKey: (part) => (part.type === "text" ? null : "actions"),
  groupHeader: (group) => [{ text: group.count + (group.count === 1 ? " action" : " actions"), group: "TxMeta", indent: GUTTER }],
  // A call that runs or fails shows open, and so does the thought that still streams.
  fold: (part, live) => (part.type === "tool" ? ["running", "error", "canceled"].includes(part.state.type) : live),
  // A folded call shows only its name, arguments, state, and time, so an output delta changes nothing on screen.
  sameVisible(before, fresh, expanded) {
    if (expanded || before.type !== "tool" || fresh.type !== "tool") return undefined;
    const ms = (/** @type {ToolPart} */ p) => /** @type {{ duration_ms?: number }} */ (p.state).duration_ms;
    return before.name === fresh.name && before.arguments === fresh.arguments && before.state.type === fresh.state.type && ms(before) === ms(fresh);
  },
  part: (part, env) => (part.type === "tool" ? toolRows(part, env) : reasoningRows(part, env)),

  message(m, parts, env) {
    const width = Math.max(1, env.width - GUTTER);
    const texts = /** @type {Extract<(typeof parts)[number], { type: "text" }>[]} */ (parts.filter((p) => p.type === "text"));
    const all = texts.map((p) => p.text).join("");
    if (m.type === "compaction") return { rows: wrapRows(all, width, "TxThought", GUTTER).map((r, i) => ({ ...r, stop: i === 0 })), source: all };
    if (m.skill_name || (m.source && m.source.type !== "parent_instruction")) {
      // A child report opens with the preamble of the model, and the rows show only its body.
      const text = m.source?.type === "child_report" && texts.length >= 2 ? /** @type {{ text: string }} */ (texts[texts.length - 1]).text : all;
      const body = wrapRows(text, width, "TxToolOutput", GUTTER, env.expanded ? Infinity : REPORT_LINES + 1);
      const shown = env.expanded ? body : body.slice(0, m.skill_name ? 0 : REPORT_LINES);
      /** @type {Row[]} */
      const rows = [{ text: m.skill_name ? "Skill · " + m.skill_name : inputSourceLabel(m.source), group: "TxMeta", marker: env.expanded ? "▾" : "▸", markerGroup: "TxMeta", indent: GUTTER, header: true, stop: true }, ...shown];
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
