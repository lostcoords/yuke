// The built-in tools. They use only the asynchronous host primitives.

import { fs } from "yuke:internal/native/fs";
import { exec as runCommand } from "yuke:internal/native/exec";
import { start as startJob, stop as stopJob, wait as waitJob, list as listJobs, get as getJob, name as jobName, endLabel, shortCommand } from "yuke:internal/jobs";
import { own, stop } from "yuke:internal/stop";
import { diff } from "yuke:internal/native/diff";
import { hasTool } from "yuke:internal/native/tools";
import { client } from "yuke:internal/client";
import { byteLabel } from "yuke:internal/format";
import { utf8Length } from "yuke:internal/interaction";

/** @import { DiffFile as ParsedDiffFile } from "yuke:internal/native/diff" */
/** @typedef {Record<string, unknown>} ToolArgs */
/** @import { CancellationSignal as ToolSignal } from "yuke:internal/native/cancellation" */
/** @import { Context } from "yuke:internal/ext" */
/** @import { Job } from "yuke:internal/native/jobs" */
/** @import { ToolContext, ToolDefinition, ToolOutcome } from "./types/ext.js" */
/** @typedef {Omit<ToolDefinition, "name" | "execute"> & { execute: (args: ToolArgs, signal: ToolSignal, context: ToolContext) => Promise<string | ToolOutcome> }} BuiltinTool */

// A user tool with the same name wins, so the built-in steps aside.
/** @param {Context} ctx @param {string} name @param {BuiltinTool} definition @returns {void} */
function builtin(ctx, name, definition) {
  if (hasTool(name)) return;
  const properties = /** @type {{ properties: Record<string, unknown> }} */ (definition.parameters);
  const fields = new Set(Object.keys(properties.properties));
  const execute = definition.execute;
  ctx.tools.define({
    name,
    ...definition,
    execute: (args, signal, context) => {
      if (args == null || typeof args !== "object" || Array.isArray(args)) invalid("Pass the arguments as a JSON object.");
      for (const key of Object.keys(args)) if (!fields.has(key)) invalid(`Remove ${key}. The arguments are: ${[...fields].join(", ")}.`);
      return execute(/** @type {ToolArgs} */ (args), signal, context);
    },
  });
}

const MAX_FILE_BYTES = 10 * 1024 * 1024;
// The output stays under the 50 KiB engine cap, with room for the cut marker and the status line.
const EXEC_OUTPUT_BYTES = 48 * 1024;
const MAX_LINE = 0xffffffff;

/** @param {string} message @returns {never} */
function invalid(message) {
  throw new Error(message);
}

/** @param {ToolArgs} args @param {string} key @returns {string} */
function stringArg(args, key) {
  if (typeof args[key] !== "string") invalid(`Set ${key} to a string.`);
  return /** @type {string} */ (args[key]);
}

/** @param {ToolArgs} args @param {string} key @returns {number | null} */
function lineArg(args, key) {
  const value = args[key];
  if (value == null) return null;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1 || value > MAX_LINE) invalid(`Set ${key} to an integer from 1 to ${MAX_LINE}.`);
  return value;
}

/** @param {ParsedDiffFile} file @returns {Wire.DiffFile[]} */
function diffOf(file) {
  if (file.hunks.length === 0) return [];
  return [{
    path: file.path,
    hunks: file.hunks.map(h => ({
      old_start: h.oldStart,
      old_lines: h.oldLines,
      new_start: h.newStart,
      new_lines: h.newLines,
      lines: h.lines,
    })),
  }];
}

/** @param {ToolArgs} args @param {ToolSignal} _signal @param {ToolContext} context @returns {Promise<string | ToolOutcome>} */
async function read(args, _signal, context) {
  const path = stringArg(args, "path");
  const start = lineArg(args, "start");
  const end = lineArg(args, "end");
  const got = await fs.readRange(path, { start, end, lineNumbers: true, workspaceRoot: context.workspaceRoot });
  if ("imagePath" in got) {
    const blob = await client.blobPut(got.imagePath);
    const kind = blob.mime.slice(blob.mime.indexOf("/") + 1).toUpperCase();
    return { output: `${kind} image, ${byteLabel(blob.bytes)}`, media: [blob] };
  }
  // The native read numbers each line and ends each line with a newline. The result drops the last newline.
  let text = got.text.slice(0, -1);
  if (got.longLines !== 0) text += `\n[read cut: ${got.longLines} line(s) at 8000 bytes.]`;
  if (got.next !== null) text += `\n[read more: start at ${got.next}.]`;
  return text;
}

/** @param {ToolArgs} args @param {ToolSignal} _signal @param {ToolContext} context @returns {Promise<string | ToolOutcome>} */
async function write(args, _signal, context) {
  const path = stringArg(args, "path");
  const content = stringArg(args, "content");
  const root = { workspaceRoot: context.workspaceRoot };
  // A new file has an empty old text. The tool shows no diff when it cannot stat or read the file, and it still writes.
  const old = await fs.stat(path, root).then((stat) => stat == null ? "" : fs.readFile(path, root)).catch(() => null);
  const mapped = old == null ? null : await diff(path, old, content);
  const bytes = await fs.writeFile(path, content, root);
  const files = mapped == null ? [] : diffOf(mapped);
  const text = files.length === 0 ? `The tool wrote ${bytes} bytes.` : `The tool wrote ${bytes} bytes and changed ${changedLines(files)} line(s).`;
  return files.length === 0 ? text : { output: text, diff: files };
}

/** @param {readonly Wire.DiffFile[]} files @returns {number} */
function changedLines(files) {
  let count = 0;
  for (const file of files) for (const hunk of file.hunks) for (const line of hunk.lines) if (line[0] !== " ") count++;
  return count;
}

/** @param {string} text @param {string} old @param {string} replacement @returns {{ count: number, text: string }} */
function replaceAt(text, old, replacement) {
  let count = 0;
  let out = "";
  let at = 0;
  while (true) {
    const hit = text.indexOf(old, at);
    if (hit < 0) break;
    count++;
    out += text.slice(at, hit) + replacement;
    at = hit + old.length;
  }
  return { count, text: count === 0 ? text : out + text.slice(at) };
}

/** @param {ToolArgs} args @param {ToolSignal} _signal @param {ToolContext} context @returns {Promise<string | ToolOutcome>} */
async function edit(args, _signal, context) {
  const path = stringArg(args, "path");
  const oldString = stringArg(args, "old_string");
  const newString = stringArg(args, "new_string");
  const replaceAll = args.replace_all ?? false;
  if (typeof replaceAll !== "boolean") invalid("Set replace_all to true or false.");
  if (oldString.length === 0) invalid("Set old_string to a nonempty string.");
  if (oldString === newString) invalid("Set new_string to a value that differs from old_string.");
  const old = await fs.readFile(path, { workspaceRoot: context.workspaceRoot });
  const replaced = replaceAt(old, oldString, newString);
  if (replaced.count === 0) invalid("The file has no match for old_string. Read the file and copy the exact text.");
  if (replaced.count > 1 && !replaceAll) invalid("old_string matches more than one place. Add context to old_string, or set replace_all to true.");
  if (utf8Length(replaced.text) > MAX_FILE_BYTES) invalid("The edit makes the file larger than 10 MiB. Make a smaller edit.");
  const mapped = await diff(path, old, replaced.text);
  await fs.writeFile(path, replaced.text, { workspaceRoot: context.workspaceRoot });
  const files = diffOf(mapped);
  const text = files.length === 0 ? `The tool replaced ${replaced.count} match(es).` : `The tool replaced ${replaced.count} match(es) and changed ${changedLines(files)} line(s).`;
  return files.length === 0 ? text : { output: text, diff: files };
}

/** @param {string} text @returns {string} */
function endLine(text) {
  return text.length === 0 || text.endsWith("\n") ? text : `${text}\n`;
}


/** @param {string} sessionId @returns {Job[]} */
function sessionJobs(sessionId) {
  return listJobs().filter(j => j.session_id === sessionId);
}

/** @param {string} command @param {ToolContext} context @returns {Promise<string>} */
async function startBackground(command, context) {
  const root = context.workspaceRoot;
  const same = sessionJobs(context.sessionId).find(j => j.state === "running" && j.command === command && j.cwd === root);
  if (same) return `[${jobName(same)} already runs this command. Log: ${same.log}]`;
  const job = await startJob(command, context.sessionId, { workspaceRoot: root });
  const name = jobName(job);
  return `[${name} started: ${shortCommand(command)}. Log: ${job.log}. Its end arrives as a message, so never sleep or poll. Use stop with ${name} to end it.]`;
}

/** The stop owner of `job-` ids. A job of another session reads as absent. @type {import("./stop.js").StopOwner} */
const jobOwner = {
  owns: (id) => /^job-[0-9a-z]{4}$/.test(id),
  stop: async (id, context) => {
    const found = getJob(parseInt(id.slice(4), 36));
    if (!found || found.session_id !== context.sessionId) return null;
    if (found.state === "running") await stopJob(found.id);
    const job = /** @type {Job} */ (await waitJob(found.id));
    return `[${id} ${endLabel(job)}.] Log: ${job.log}`;
  },
  ids: async (context) => sessionJobs(context.sessionId).filter(j => j.state === "running").map(jobName),
};

/** @param {ToolArgs} args @param {ToolSignal} signal @param {ToolContext} context @returns {Promise<string>} */
async function exec(args, signal, context) {
  const command = stringArg(args, "command");
  if (command.trim().length === 0) invalid("Set command to a nonempty string.");
  const background = args.background ?? false;
  if (typeof background !== "boolean") invalid("Set background to true or false.");
  const timeoutValue = args.timeout_ms;
  if (background) {
    if (timeoutValue != null) invalid("Remove timeout_ms, or set background to false.");
    return startBackground(command, context);
  }
  const timeout = timeoutValue == null ? 120000 : timeoutValue;
  if (typeof timeout !== "number" || !Number.isInteger(timeout) || timeout < 1 || timeout > 600000) invalid("Set timeout_ms to an integer from 1 to 600000.");
  const r = await runCommand(command, { timeoutMs: timeout, signal, maxBytes: EXEC_OUTPUT_BYTES, mergeStderr: true, log: true, onOutput: context.output, workspaceRoot: context.workspaceRoot });
  let text = r.stdout.length === 0 ? "[no output]\n" : endLine(r.stdout);
  if (r.timedOut) text += `[timeout: ${timeout} ms. yuke stopped the process group. Run a smaller command. Raise timeout_ms up to 600000. Set background to true for a server or watcher.]`;
  else if (r.signal !== null) text += `[signal: ${r.signal}]`;
  else text += `[exit code: ${r.code}]`;
  return text;
}

// The engine wraps the body, so the tool and an explicit `/skill:name` produce one form in the transcript.
/** @param {ToolArgs} args @param {ToolSignal} _signal @param {ToolContext} context @returns {Promise<string>} */
async function skill(args, _signal, context) {
  const skillName = stringArg(args, "name");
  const loaded = await client.skillLoad(context.sessionId, skillName);
  return loaded.content;
}

export const builtins = {
  name: "builtins",
  /** @param {Context} ctx */
  apply(ctx) {
    builtin(ctx, "read", {
      description: "Read a file with 1-indexed line numbers. Pass the start and end values for a line range. One read returns at most 2000 lines or 48 KiB. A capped read gives the next line. A PNG, JPEG, GIF, or WebP file returns the image.",
      parameters: { type: "object", properties: {
        path: { type: "string", description: "A relative path resolves against the workspace root." },
        start: { type: "integer", minimum: 1, maximum: MAX_LINE, description: "The first line." },
        end: { type: "integer", minimum: 1, maximum: MAX_LINE, description: "The last line, inclusive." },
      }, required: ["path"], additionalProperties: false }, execute: read,
    });
    builtin(ctx, "write", {
      description: "Create a file or replace its content. Pass the complete content.",
      parameters: { type: "object", properties: {
        path: { type: "string", description: "A relative path resolves against the workspace root." },
        content: { type: "string" },
      }, required: ["path", "content"], additionalProperties: false }, execute: write,
    });
    builtin(ctx, "edit", {
      description: "Replace an exact string in a file. old_string must appear exactly once unless replace_all is true.",
      parameters: { type: "object", properties: {
        path: { type: "string", description: "A relative path resolves against the workspace root." },
        old_string: { type: "string" },
        new_string: { type: "string" },
        replace_all: { type: "boolean", description: "Replace every non-overlapping match." },
      }, required: ["path", "old_string", "new_string"], additionalProperties: false }, execute: edit,
    });
    builtin(ctx, "exec", {
      description: "Run a shell command in the working directory. Return stdout and stderr in write order, and the exit status. Output above 48 KiB keeps its head and tail. The marker names the full-output file when yuke saves one. Each call starts a fresh shell and ends every process it starts. For a server or watcher, set background to true. Do not use &, nohup, or setsid.",
      parameters: { type: "object", properties: {
        command: { type: "string" },
        timeout_ms: { type: "integer", minimum: 1, maximum: 600000, description: "The default is 120000." },
        background: { type: "boolean", description: "Run a server or watcher as a job and return at once." },
      }, required: ["command"], additionalProperties: false }, execute: exec,
    });
    builtin(ctx, "stop", {
      description: "Stop a background job or a child agent by its id, such as job-k3x9 or explore-a91c07d2. The result is the end of the work. No end message follows.",
      parameters: { type: "object", properties: {
        id: { type: "string" },
      }, required: ["id"], additionalProperties: false }, execute: (args, _signal, context) => stop(stringArg(args, "id"), context),
    });
    ctx.effect(() => own(jobOwner));
    builtin(ctx, "skill", {
      description: "Load one listed skill by name. Skip if its instructions are already in the transcript.",
      parameters: { type: "object", properties: {
        name: { type: "string", description: "Name from an available_skills entry." },
      }, required: ["name"], additionalProperties: false }, execute: skill,
    });

    // The skill tool has nothing to load in a session that lists no skill, so that session never sees it.
    ctx.hook("tools.select", (selection) => selection.context.has_skills ? undefined : { replace: { tools: selection.tools.filter((name) => name !== "skill") } });
  },
};
