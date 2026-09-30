//! The default transcript renderer: full-width blocks, thinking in full, and a short folded preview of each tool.
//! It is a plugin on the render API, so a user replaces it or stacks a renderer on top of it. The helpers serve any look.
import { term } from "yuke:internal/native/term";
import { root } from "yuke:internal/core";
import { Document, normalizeSource } from "yuke:internal/md";
import { RowsView, Window } from "yuke:internal/ui";
import { byteLabel } from "yuke:internal/format";
import { clip } from "yuke:internal/text-input";
import { inputSourceLabel } from "yuke:internal/transcript";

/** @import { Segment, TranscriptRow } from "./types/pager.js" */
/** @import { Render, Rendered, ToolHead, ToolPart } from "./types/transcript.js" */
/** @import { MessagePart } from "yuke:internal/native/engine" */
/** @import { Context } from "yuke:internal/ext" */

// The process directory. A path under it drops this prefix.
const CWD = String(term.cwd || "");
const CWD_PREFIX = CWD + "/";
// Bound the command scan. The header clips to the pane width, so a longer pipeline carries nothing.
const COMMAND_MAX = 160;
// The folded preview: the tail of a shell output, and the head of any other output.
const EXEC_PREVIEW_LINES = 5;
const PREVIEW_LINES = 10;
// Every row starts one column in, so a block background frames its text.
const PAD = 1;

/**
 * A path for a header: relative under the process directory, else its base name.
 * @param {unknown} path @returns {string}
 */
export function shortPath(path) {
  const s = String(path || "");
  if (s.length === 0 || s.charCodeAt(0) !== 47) return s;
  if (CWD.length !== 0 && s.length > CWD_PREFIX.length && s.charCodeAt(CWD.length) === 47 && s.startsWith(CWD)) return s.slice(CWD_PREFIX.length);
  return s.slice(s.lastIndexOf("/") + 1);
}

// True for a space, a tab, or a line feed.
/** @param {number} code @returns {boolean} */
function blank(code) {
  return code === 32 || code === 9 || code === 10;
}

// Skip a leading run of blank lines and `#` comments, so a script header shows its first real command.
/** @param {string} s @returns {number} */
function skipComments(s) {
  let i = 0;
  for (;;) {
    while (i < s.length && blank(s.charCodeAt(i))) i++;
    if (s.charCodeAt(i) !== 35) return i;
    const nl = s.indexOf("\n", i);
    if (nl < 0) return i;
    i = nl + 1;
  }
}

// Skip a leading run of `NAME=value` assignments, because they are the environment and not the command.
/** @param {string} s @param {number} from @returns {number} */
function skipAssignments(s, from) {
  let i = from;
  for (;;) {
    while (i < s.length && blank(s.charCodeAt(i))) i++;
    let j = i;
    let eq = -1;
    while (j < s.length && !blank(s.charCodeAt(j))) {
      if (eq < 0 && s.charCodeAt(j) === 61) eq = j;
      j++;
    }
    // A name holds no separator, so `bin/x=y` is a path and closes the run.
    if (eq <= i || s.lastIndexOf("/", eq) >= i) return i;
    i = j;
  }
}

/**
 * A shell command for a header: the program base name and its arguments on one line, without leading comments and environment assignments.
 * @param {unknown} raw @returns {string}
 */
export function shortCommand(raw) {
  const s = String(raw || "");
  const start = skipAssignments(s, skipComments(s));
  const cut = s.slice(start, start + COMMAND_MAX);
  const line = cut.indexOf("\n") < 0 ? cut : cut.split("\n").join(" ");
  // A path under the process directory reads relative to it, as it does on its own header.
  const flat = CWD.length !== 0 && line.indexOf(CWD_PREFIX) >= 0 ? line.split(CWD_PREFIX).join("") : line;
  let end = 0;
  while (end < flat.length && !blank(flat.charCodeAt(end))) end++;
  const program = flat.slice(0, end);
  return program.slice(program.lastIndexOf("/") + 1) + flat.slice(end) + (s.length > start + COMMAND_MAX ? "…" : "");
}

/**
 * The header words of a tool call from `tools`, else the tool name and its `path`, its `command`, or its raw arguments cut to 48 characters.
 * `args` holds the parsed JSON arguments, or `{}` when they do not parse.
 * @param {ToolPart} part @param {Record<string, ToolHead>} tools @returns {{ verb: string, subject: string, category: string }}
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
    return { verb: out.verb, subject: out.subject, category: out.category ?? "other" };
  }
  if (typeof args.path === "string") return { verb, subject: shortPath(args.path), category: "other" };
  if (typeof args.command === "string") return { verb, subject: shortCommand(args.command), category: "other" };
  return { verb, subject: raw.length > 48 ? raw.slice(0, 47) + "…" : raw, category: "other" };
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
 * The rows of the views of a tool result: a diff, markdown, or plain text. `limit` bounds the row count, and the source holds only the text of the rows it answers.
 * @param {readonly Wire.View[]} views @param {number} width @param {number} indent @param {number} [limit] @returns {Rendered}
 */
export function viewRows(views, width, indent, limit = Infinity) {
  /** @type {TranscriptRow[]} */
  const rows = [];
  let source = "";
  /** @param {string} text @param {string} group @returns {void} */
  const add = (text, group) => {
    if (rows.length >= limit) return;
    if (source) source += "\n";
    const shown = wrapRows(text, width, group, indent, limit - rows.length);
    moveSrc(shown, source.length);
    source += text;
    for (const r of shown) rows.push(r);
  };
  for (const v of views) {
    if (v.type === "diff") {
      for (const f of v.files) {
        if (f.path) add(f.path, "TxToolTitle");
        for (const h of f.hunks) for (const line of h.lines) add(line, line[0] === "+" ? "TxDiffAdd" : line[0] === "-" ? "TxDiffDel" : "TxDiffContext");
      }
    } else if (v.type === "markdown") {
      if (rows.length >= limit) continue;
      if (source) source += "\n";
      const base = source.length;
      const chunk = normalizeSource(v.text || "");
      source += chunk;
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

// The rows of `wrapRows` show `body` in order, so the first and the last row bound the text they show.
/** @param {TranscriptRow[]} rows @param {TranscriptRow[]} shown @param {string} body @param {string} source @returns {string} The source with the shown text. */
function addShown(rows, shown, body, source) {
  const first = shown[0], last = shown[shown.length - 1];
  if (!first || !last) return source;
  const from = /** @type {number} */ (first.src);
  const end = /** @type {number} */ (last.src) + /** @type {string} */ (last.text).length;
  moveSrc(shown, source.length + 1 - from);
  for (const r of shown) rows.push(r);
  return source + "\n" + body.slice(from, end);
}

// The body of a tool block is the tail of a shell output, the whole diff of an edit, or the head of any other output; the source holds only the shown text, so a folded preview copies no more than the preview.
/** @param {ToolPart} part @param {string} verb @param {number} width @param {boolean} expanded @param {TranscriptRow[]} rows @param {string} source @returns {string} */
function toolBody(part, verb, width, expanded, rows, source) {
  const state = part.state;
  const name = String(part.name || "");
  const views = /** @type {{ view?: readonly Wire.View[] }} */ (state).view;
  const text = state.type === "error" ? state.error || "" : String(/** @type {{ output?: string }} */ (state).output || "");
  const group = state.type === "error" ? "TxToolError" : "TxToolOutput";
  if (name === "read" && !expanded && state.type !== "error") return source;
  if (views && views.length && state.type !== "error") {
    const all = expanded || name === "edit";
    const built = viewRows(views, width, PAD, all ? Infinity : PREVIEW_LINES + 1);
    const more = built.rows.length > PREVIEW_LINES && !all;
    if (more) built.rows.length = PREVIEW_LINES;
    moveSrc(built.rows, source.length + 1);
    source += "\n" + built.source;
    for (const r of built.rows) rows.push(r);
    if (more) hint(rows, "… (more lines, ctrl+o to expand)");
  } else if (name === "exec" && !expanded && text) {
    // The tail lines wrap into rows, and a long last line can fill the preview alone.
    const lines = text.slice(tailStart(text, EXEC_PREVIEW_LINES));
    const tail = wrapRows(lines, width, group, PAD);
    const kept = tail.slice(-EXEC_PREVIEW_LINES);
    if (lines.length < text.length || kept.length < tail.length) hint(rows, "… (earlier lines, ctrl+o to expand)");
    source = addShown(rows, kept, lines, source);
  } else if (text) {
    const shown = wrapRows(text, width, group, PAD, expanded ? Infinity : PREVIEW_LINES + 1);
    const more = !expanded && shown.length > PREVIEW_LINES;
    if (more) shown.length = PREVIEW_LINES;
    source = addShown(rows, shown, text, source);
    if (more) hint(rows, "… (more lines, ctrl+o to expand)");
  }
  const field = state.type === "error" ? "error" : "output";
  if (expanded && isCut(part, field)) hint(rows, "… (the output is cut at 64 KiB)");
  const media = state.type === "completed" ? state.media : undefined;
  if (media) media.forEach((blob, i) => {
    const label = mediaLabel(blob, i + 1);
    source = addShown(rows, wrapRows(label, width, "TxToolHint", PAD), label, source);
  });
  const ms = /** @type {{ duration_ms?: number }} */ (state).duration_ms;
  if (verb === "$" && typeof ms === "number" && state.type !== "running") hint(rows, "Took " + (ms / 1000).toFixed(1) + "s");
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
    read: (o) => ({ verb: "read", subject: shortPath(o.path) + (typeof o.start === "number" ? ":" + o.start + (typeof o.end === "number" ? "-" + o.end : "") : ""), category: "read" }),
    write: (o) => ({ verb: "write", subject: shortPath(o.path), category: "write" }),
    edit: (o) => ({ verb: "edit", subject: shortPath(o.path) + (o.replace_all ? " (all)" : ""), category: "write" }),
    exec: (o) => ({ verb: "$", subject: shortCommand(o.command), category: "run" }),
    skill: (o) => ({ verb: "skill", subject: String(o.name || ""), category: "other" }),
  },

  part(part, env) {
    const width = Math.max(1, env.width - 2 * PAD);
    if (part.type === "reasoning") return stopRows(part.text || "", width, "TxThought");
    const head = toolHead(part, env.tools);
    const title = head.verb;
    const source = head.subject ? title + " " + head.subject : title;
    /** @type {Segment[]} */
    const segments = [{ text: title, group: "TxToolTitle", src: 0, srcEnd: title.length }];
    // The header clips here and not in the draw, so a frame allocates no cut string for a long command.
    if (head.subject) segments.push({ text: " " + clip(head.subject, Math.max(1, width - term.measure(title) - 1)), group: "TxToolArg", src: title.length, srcEnd: source.length });
    /** @type {TranscriptRow[]} */
    const rows = [{ segments, indent: PAD, header: true, stop: true }];
    const all = toolBody(part, title, width, env.expanded, rows, source);
    const type = part.state.type;
    const bg = type === "error" || type === "canceled" ? "TxToolErrorBg" : type === "completed" ? "TxToolSuccessBg" : "TxToolPendingBg";
    for (const r of rows) r.bg = bg;
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
      const rows = [{ text: clip((env.expanded ? "▾ " : "▸ ") + label, width), group: "TxMeta", indent: PAD, header: true, stop: true }];
      const limit = env.expanded ? Infinity : m.skill_name ? 0 : PREVIEW_LINES;
      const body = wrapRows(text, width, "TxToolOutput", PAD, limit === Infinity ? Infinity : limit + 1);
      for (const r of body.slice(0, limit)) rows.push(r);
      if (body.length > limit) rows.push({ text: "… (ctrl+o or a click expands)", group: "TxToolHint", indent: PAD });
      return { rows, source: text };
    }
    // Each attachment label takes the place of its part. The number counts media alone, as the composer does.
    let image = 0;
    let text = "";
    for (const part of parts) {
      if (part.type === "text") text += part.text;
      else if (part.type === "image" || part.type === "audio" || part.type === "file") text += mediaLabel(part.source, part.type === "image" ? ++image : 0);
    }
    const rows = wrapRows(text, width, "TxUser", PAD);
    if (!rows.length) rows.push({ text: "", indent: PAD });
    // A parent-sent task reads like user input, so one label row says where it came from.
    if (source) rows.unshift({ text: clip(inputSourceLabel(source), width), group: "TxMeta", indent: PAD });
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
