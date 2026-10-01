//! The default transcript renderer: full-width blocks, a one-row fold of each thought, and a short folded preview of each tool.
//! It is a plugin on the render API, so a user replaces it or stacks a renderer on top of it. The helpers serve any look.
import { term } from "yuke:internal/native/term";
import { root } from "yuke:internal/core";
import { Document, normalizeSource } from "yuke:internal/md";
import { RowsView, Window } from "yuke:internal/ui";
import { byteLabel } from "yuke:internal/format";
import { clip } from "yuke:internal/text-input";
import { inputSourceLabel } from "yuke:internal/transcript";

/** @import { Segment, TranscriptRow } from "./types/pager.js" */
/** @import { Render, Rendered, ToolHead, ToolHeading, ToolPart } from "./types/transcript.js" */
/** @import { MessagePart } from "yuke:internal/native/engine" */
/** @import { Context } from "yuke:internal/ext" */

// The process directory. A path under it drops this prefix.
const CWD = String(term.cwd || "");
const CWD_PREFIX = CWD === "/" ? "/" : CWD + "/";
// The folded preview: the tail of a shell output, and the head of any other output.
const EXEC_PREVIEW_LINES = 5;
const PREVIEW_LINES = 10;
// Every row starts one column in, so a block background frames its text.
const PAD = 1;
const USER_PAD = 2;

/**
 * A path for a header: relative under the process directory, else complete.
 * @param {unknown} path @returns {string}
 */
export function displayPath(path) {
  const s = String(path || "");
  if (s.length === 0 || s.charCodeAt(0) !== 47 || CWD.length === 0) return s;
  if (s === CWD || s === CWD_PREFIX) return ".";
  if (s.startsWith(CWD_PREFIX)) return s.slice(CWD_PREFIX.length);
  return s;
}

/**
 * A complete shell command on one header line. It changes line feeds to spaces and preserves every other byte.
 * @param {unknown} raw @returns {string}
 */
export function displayCommand(raw) {
  const s = String(raw || "");
  return s.indexOf("\n") < 0 ? s : s.split("\n").join(" ");
}

/**
 * The heading of a tool call from `tools`, else the tool name and its path, command, or raw arguments.
 * `args` holds the parsed JSON arguments, or `{}` when they do not parse.
 * @param {ToolPart} part @param {Record<string, ToolHead>} tools @returns {ToolHeading}
 */
export function toolHead(part, tools) {
  const raw = String(part.arguments || "");
  /** @type {Record<string, any>} */
  let args = {};
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === "object") args = parsed;
  } catch (_) {}
  const verb = String(part.name || "tool");
  const head = tools[verb];
  if (head) {
    const out = head(args, part);
    return { verb: out.verb, subject: out.subject, category: out.category, input: displayCommand(out.input) === out.subject ? out.input : "" };
  }
  if (typeof args.path === "string") return { verb, subject: displayPath(args.path), category: "other", input: "" };
  if (typeof args.command === "string") return { verb, subject: displayCommand(args.command), category: "other", input: args.command };
  return { verb, subject: displayCommand(raw), category: "other", input: raw };
}

/**
 * Wrap `text` to `width` columns as rows of one segment in `group`. Each segment indexes `text`, so a selection copies the text.
 * `limit` keeps that many rows from the head, and `tail` also keeps that many rows from the end.
 * @param {string} text @param {number} width @param {string} group @param {number} indent @param {number} [limit] @param {number} [tail] @returns {TranscriptRow[]}
 */
export function wrapRows(text, width, group, indent, limit = Infinity, tail = 0) {
  if (limit === 0) return [];
  // The native wrap answers flat [start, end, soft] triples, so a row costs one object and its text.
  const wrapped = term.wrap(text, Math.max(1, width), limit === Infinity ? 0 : limit, tail).rows;
  /** @type {TranscriptRow[]} */
  const rows = [];
  for (let i = 0; i < wrapped.length; i += 3) {
    const start = /** @type {number} */ (wrapped[i]);
    rows.push({ text: text.slice(start, wrapped[i + 1]), group, src: start, indent });
  }
  return rows;
}

// Move the source offsets of new rows by `base`. The rows are new, so the move writes them in place and allocates nothing.
/** @param {readonly TranscriptRow[]} rows @param {number} base @returns {void} */
function moveSrc(rows, base) {
  if (base === 0) return;
  for (let i = 0; i < rows.length; i++) {
    const r = /** @type {TranscriptRow} */ (rows[i]);
    if (r.src != null) r.src += base;
    else if (r.segments) for (const seg of r.segments) if (seg.src != null) {
      seg.src += base;
      seg.srcEnd = /** @type {number} */ (seg.srcEnd) + base;
    }
  }
}

/**
 * The rows of tool-result views. A one-file diff omits its path. A multi-file or mixed view keeps file paths.
 * `limit` bounds the rows alone. The source keeps every chunk, so a fold never moves a source offset.
 * @param {readonly Wire.View[]} views @param {number} width @param {number} indent @param {number} [limit] @returns {Rendered}
 */
export function viewRows(views, width, indent, limit = Infinity) {
  /** @type {TranscriptRow[]} */
  const rows = [];
  let source = "";
  /** @param {string} text @param {string} group @returns {void} */
  const add = (text, group) => {
    if (source) source += "\n";
    if (rows.length < limit) {
      const shown = wrapRows(text, width, group, indent, limit - rows.length);
      moveSrc(shown, source.length);
      for (const r of shown) rows.push(r);
    }
    source += text;
  };
  for (const v of views) {
    if (v.type === "diff") {
      for (const f of v.files) {
        if (f.path && (views.length !== 1 || v.files.length !== 1)) add(f.path, "TxToolTitle");
        for (const h of f.hunks) for (const line of h.lines) add(line, line[0] === "+" ? "TxDiffAdd" : line[0] === "-" ? "TxDiffDel" : "TxDiffContext");
      }
    } else if (v.type === "markdown") {
      if (source) source += "\n";
      const base = source.length;
      const chunk = normalizeSource(v.text || "");
      source += chunk;
      if (rows.length >= limit) continue;
      const doc = new Document();
      doc.setText(chunk);
      // The document is new, so its rows belong to this call alone.
      const shown = doc.rows(Math.max(1, width), limit - rows.length).map((r) => ({ segments: r.segments, indent }));
      moveSrc(shown, base);
      for (const r of shown) rows.push(r);
    } else add(/** @type {{ text?: string }} */ (v).text ?? "", "TxToolOutput");
  }
  return { rows, source };
}

/**
 * `[PNG #1 · 2 KiB]`: the type comes from the mime, because an image part carries no file name on the wire. `n` 0 leaves out the number.
 * @param {Wire.MediaBlob} blob @param {number} n @returns {string}
 */
export function mediaLabel(blob, n) {
  const mime = blob.mime;
  const slash = mime.indexOf("/");
  const kind = (slash < 0 ? mime : mime.slice(slash + 1)).toUpperCase();
  return "[" + kind + (n > 0 ? " #" + n : "") + " · " + byteLabel(blob.bytes) + "]";
}

/**
 * The one-line text of a failed message: the message, the HTTP status, the detail, and the request id.
 * @param {Wire.MessageError} error @returns {string}
 */
export function errorLabel(error) {
  const parts = [error.message || error.type || "run failed"];
  if (error.status != null) parts.push("HTTP " + error.status);
  if (error.detail) parts.push(error.detail);
  if (error.request_id) parts.push("request " + error.request_id);
  return "⚠ " + parts.join(" · ");
}

/**
 * True when the engine cut field `field` of `part`, so its whole text needs `transcript.readField`.
 * @param {Wire.AssistantPart} part @param {string} field @returns {boolean}
 */
export function isCut(part, field) {
  const cuts = /** @type {{ cut?: readonly { field?: string, next?: number | null }[] }} */ (part).cut || [];
  return cuts.some((c) => c.field === field && c.next != null);
}

/**
 * Open a scrolling window over labeled sections of text, such as the whole input and output of a tool.
 * @param {string} title @param {readonly { label: string, text: string }[]} sections @returns {void}
 */
export function openDetails(title, sections) {
  /** @param {number} width @returns {TranscriptRow[]} */
  const rows = (width) => {
    /** @type {TranscriptRow[]} */
    const out = [];
    for (const section of sections) {
      if (out.length) out.push({ text: "" });
      out.push({ text: section.label, group: "TxToolTitle" });
      for (const row of wrapRows(section.text || "(empty)", width - 2, "TxToolOutput", 2)) out.push(row);
    }
    return out;
  };
  const content = new RowsView(rows, () => root.popOverlay(win));
  const win = new Window({ title, footer: "j/k scroll · pgup/pgdn · esc close", border: "rounded", width: (max) => Math.round(max * 0.9), height: (max) => Math.round(max * 0.85), content });
  root.pushOverlay(win);
}

// Join the text parts of a message; a single part returns its string without a copy.
/** @param {readonly MessagePart[]} parts @returns {string} */
function textOfParts(parts) {
  /** @type {string | null} */
  let text = null;
  for (const part of parts) if (part.type === "text") text = text === null ? part.text : text + part.text;
  return text ?? "";
}

// The offset after the line feed that starts the last `lines` lines, or 0 when the text has no more.
/** @param {string} text @param {number} lines @returns {number} */
function tailStart(text, lines) {
  let at = text.length;
  for (let n = 0; n < lines; n++) {
    at = text.lastIndexOf("\n", at - 1);
    if (at < 0) return 0;
  }
  return at + 1;
}

// Add one hint row to a tool body.
/** @param {TranscriptRow[]} rows @param {string} line @returns {void} */
function hint(rows, line) {
  rows.push({ text: line, group: "TxToolHint", indent: PAD });
}

// The source keeps all of `body` whatever the rows show, so a fold never moves a source offset. `shown` wraps `body` from offset `from`.
/** @param {TranscriptRow[]} rows @param {TranscriptRow[]} shown @param {string} body @param {number} from @param {string} source @returns {string} The source with `body`. */
function addBody(rows, shown, body, from, source) {
  moveSrc(shown, source.length + 1 + from);
  for (const r of shown) rows.push(r);
  return source + "\n" + body;
}

// The body of a tool block is the tail of a shell output, the whole diff of an edit, or the head of any other output. A folded read shows no body.
// The source is the same folded and open, so a cursor and a selection keep their text across a fold.
/** @param {ToolPart} part @param {number} width @param {boolean} expanded @param {TranscriptRow[]} rows @param {string} source @returns {string} */
function toolBody(part, width, expanded, rows, source) {
  const state = part.state;
  const name = String(part.name || "");
  const views = /** @type {{ view?: readonly Wire.View[] }} */ (state).view;
  const text = state.type === "error" ? state.error || "" : String(/** @type {{ output?: string }} */ (state).output || "");
  const group = state.type === "error" ? "TxToolError" : "TxToolOutput";
  const cap = expanded ? Infinity : name === "read" && state.type !== "error" ? 0 : PREVIEW_LINES;
  if (views && views.length && state.type !== "error") {
    const limit = name === "edit" ? Infinity : cap;
    // One row past the limit tells whether more rows exist, and a zero limit wraps nothing.
    const built = viewRows(views, width, PAD, limit && limit + 1);
    const more = built.rows.length > limit;
    if (more) built.rows.length = limit;
    source = addBody(rows, built.rows, built.source, 0, source);
    if (more) hint(rows, "… (more lines, ctrl+o to expand)");
  } else if (name === "exec" && !expanded && text) {
    // The tail lines wrap into rows, and a long last line can fill the preview alone.
    const from = tailStart(text, EXEC_PREVIEW_LINES);
    const tail = wrapRows(text.slice(from), width, group, PAD);
    const kept = tail.slice(-EXEC_PREVIEW_LINES);
    if (from > 0 || kept.length < tail.length) hint(rows, "… (earlier lines, ctrl+o to expand)");
    source = addBody(rows, kept, text, from, source);
  } else if (text) {
    const shown = wrapRows(text, width, group, PAD, cap && cap + 1);
    const more = shown.length > cap;
    if (more) shown.length = cap;
    source = addBody(rows, shown, text, 0, source);
    if (more) hint(rows, "… (more lines, ctrl+o to expand)");
  }
  const field = state.type === "error" ? "error" : "output";
  if (expanded && isCut(part, field)) hint(rows, "… (the output is cut at 64 KiB)");
  const media = state.type === "completed" ? state.media : undefined;
  if (media) media.forEach((blob, i) => {
    const label = mediaLabel(blob, i + 1);
    source = addBody(rows, cap === 0 ? [] : wrapRows(label, width, "TxToolHint", PAD), label, 0, source);
  });
  const ms = /** @type {{ duration_ms?: number }} */ (state).duration_ms;
  if (name === "exec" && typeof ms === "number" && state.type !== "running") hint(rows, "Took " + (ms / 1000).toFixed(1) + "s");
  return source;
}

// Wrap `text` in `group` and mark the first row as a stop, so the whole text is one part source.
/** @param {string} text @param {number} width @param {string} group @returns {Rendered} */
function stopRows(text, width, group) {
  const rows = wrapRows(text, width, group, PAD);
  if (rows[0]) rows[0].stop = true;
  return { rows, source: text };
}

/**
 * The default renderer. Text indents one column, and one blank row separates two parts.
 * @type {Render}
 */
export const defaultRender = {
  indent: PAD,
  gap: 1,
  tools: {
    read: (o) => ({ verb: "read", subject: displayPath(o.path) + (typeof o.start === "number" ? ":" + o.start + (typeof o.end === "number" ? "-" + o.end : "") : ""), category: "read", input: "" }),
    write: (o) => ({ verb: "write", subject: displayPath(o.path), category: "write", input: "" }),
    edit: (o) => ({ verb: "edit", subject: displayPath(o.path) + (o.replace_all ? " (all)" : ""), category: "write", input: "" }),
    exec: (o) => {
      const command = String(o.command || "");
      return { verb: "$", subject: displayCommand(command), category: "run", input: command };
    },
    skill: (o) => ({ verb: "skill", subject: String(o.name || ""), category: "other", input: "" }),
  },

  part(part, env) {
    const width = Math.max(1, env.width - 2 * PAD);
    if (part.type === "reasoning") {
      const ms = part.duration_ms;
      // A block can stop while it is still the last part of the draft, so its duration wins over `env.live`.
      const label = ms != null ? "thought for " + (ms / 1000).toFixed(1) + "s" : env.live ? "thinking" : "thought";
      const text = clip(part.title ? label + ": " + part.title : label, width);
      // A thought with no text has nothing to open, so its row does not fold.
      if (!part.text) return { rows: [{ text, group: "TxMeta", indent: PAD, header: false, stop: true }], source: "" };
      // A folded thought builds one row, so a delta wraps none of its text. The source is the whole text, folded and open.
      /** @type {TranscriptRow[]} */
      const rows = [{ text, group: "TxMeta", indent: PAD, header: true, stop: true }];
      if (env.expanded) for (const row of wrapRows(part.text, width, "TxThought", PAD)) rows.push(row);
      return { rows, source: part.text };
    }
    const head = toolHead(part, env.tools);
    const title = head.verb;
    const input = head.input;
    const source = input ? title + " " + input : head.subject ? title + " " + head.subject : title;
    /** @type {Segment[]} */
    const segments = [{ text: title, group: "TxToolTitle", src: 0, srcEnd: title.length }];
    const shown = head.subject ? clip(head.subject, Math.max(1, width - term.measure(title) - 1)) : "";
    const revealInput = env.expanded && input !== "" && (shown !== head.subject || input.indexOf("\n") >= 0);
    // The header clips here and not in the draw, so a frame allocates no cut string for a long command.
    if (head.subject) {
      if (revealInput) segments.push({ text: " " + shown, group: "TxToolArg" });
      else segments.push({ text: " " + shown, group: "TxToolArg", src: title.length, srcEnd: source.length });
    }
    /** @type {TranscriptRow[]} */
    const rows = [{ segments, indent: PAD, header: true, stop: true }];
    if (revealInput) {
      const inputRows = wrapRows(input, width, "TxToolArg", PAD);
      moveSrc(inputRows, title.length + 1);
      for (let i = 0; i < inputRows.length; i++) rows.push(/** @type {TranscriptRow} */ (inputRows[i]));
    }
    const all = toolBody(part, width, env.expanded, rows, source);
    const type = part.state.type;
    const bg = type === "error" || type === "canceled" ? "TxToolErrorBg" : type === "completed" ? "TxToolSuccessBg" : "TxToolPendingBg";
    for (let i = 0; i < rows.length; i++) /** @type {TranscriptRow} */ (rows[i]).bg = bg;
    return { rows, source: all };
  },

  message(m, parts, env) {
    const width = Math.max(1, env.width - 2 * PAD);
    if (m.type === "compaction") return stopRows(textOfParts(parts), width, "TxThought");
    const source = m.source;
    // An input from a source other than the parent reads as a report: a label that folds its text.
    if (m.skill_name || (source && source.type !== "parent_instruction")) {
      const label = m.skill_name ? "skill · " + m.skill_name : inputSourceLabel(source);
      const texts = parts.filter((part) => part.type === "text");
      // A child report opens with the preamble of the model, and the rows show only its body.
      const text = source?.type === "child_report" && texts.length >= 2 ? /** @type {Extract<MessagePart, { type: "text" }>} */ (texts[texts.length - 1]).text : textOfParts(parts);
      /** @type {TranscriptRow[]} */
      const rows = [{ text: clip(label, width), group: "TxMeta", indent: PAD, header: true, stop: true }];
      const limit = env.expanded ? Infinity : m.skill_name ? 0 : PREVIEW_LINES;
      const body = wrapRows(text, width, "TxToolOutput", PAD, limit === Infinity ? Infinity : limit + 1);
      for (const r of body.slice(0, limit)) rows.push(r);
      if (body.length > limit) rows.push({ text: "… (ctrl+o or a click expands)", group: "TxToolHint", indent: PAD });
      return { rows, source: text };
    }
    // Each attachment label takes the place of its part. The number counts media alone, as the composer does.
    const userPad = Math.max(0, Math.min(USER_PAD, Math.floor((env.width - 1) / 2)));
    const userWidth = Math.max(1, env.width - 2 * userPad);
    let image = 0;
    let text = "";
    for (const part of parts) {
      if (part.type === "text") text += part.text;
      else if (part.type === "image" || part.type === "audio" || part.type === "file") text += mediaLabel(part.source, part.type === "image" ? ++image : 0);
    }
    const rows = wrapRows(text, userWidth, "TxUser", userPad);
    if (!rows.length) rows.push({ text: "", indent: userPad });
    // A parent-sent task reads like user input, so one label row says where it came from.
    if (source) rows.unshift({ text: clip(inputSourceLabel(source), userWidth), group: "TxMeta", indent: userPad });
    for (const r of rows) r.bg = "TxUser";
    /** @type {TranscriptRow} */ (rows[0]).stop = true;
    return { rows, source: text };
  },

  error(error, env) {
    const out = stopRows(errorLabel(error), Math.max(1, env.width - 2 * PAD), "TxError");
    out.rows.unshift({ text: "" });
    return out;
  },
};

/** The groups of the default look. A tool block background is empty, so a theme gives it a color: `TxToolPendingBg`, `TxToolSuccessBg`, and `TxToolErrorBg`. */
const TX_GROUPS = {
  TxUser: { reverse: true },
  TxThought: { fg: "fg", dim: true, italic: true },
  TxMeta: { fg: "fg", dim: true },
  TxError: { fg: "danger", bold: true },
  TxToolTitle: { fg: "fg", bold: true },
  TxToolArg: { fg: "fg" },
  TxToolOutput: { fg: "fg", dim: true },
  TxToolHint: { fg: "fg", dim: true },
  TxToolError: { fg: "danger" },
  TxToolPendingBg: {},
  TxToolSuccessBg: {},
  TxToolErrorBg: {},
  TxDiffAdd: { fg: "fg", bold: true },
  TxDiffDel: { fg: "fg", dim: true },
  TxDiffContext: { fg: "fg", dim: true },
};

/** The `transcript` plugin: the default look of every chat transcript and its style groups. Dispose it to start a look from nothing. */
export const transcriptView = {
  name: "transcript",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui", "chat"], (ctx) => {
      ctx.tui.style.set(TX_GROUPS, { default: true });
      ctx.chat.render(defaultRender);
    });
  },
};
