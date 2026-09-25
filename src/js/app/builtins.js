// The built-in tools. They use only the asynchronous host primitives.

import { fs } from "yuke:fs";
import { exec as runCommand } from "yuke:exec";
import { start as startJob, stop as stopJob, list as listJobs, get as getJob, name as jobName, endLabel, tail as jobTail, shortCommand } from "yuke:jobs";
import { events } from "yuke:kernel";
import { diff } from "yuke:diff";
import { hasTool } from "yuke:tools";
import { client } from "yuke:client";
import { byteLabel, errorText } from "yuke:format";
import { utf8Length } from "yuke:interaction";

/** @import { DiffFile as ParsedDiffFile } from "yuke:diff" */
/** @import { RangeRead } from "yuke:fs" */
/** @typedef {Record<string, unknown>} ToolArgs */
/** @import { CancellationSignal as ToolSignal } from "yuke:cancellation-native" */
/** @import { Context } from "yuke:ext" */
/** @import { Job } from "yuke:jobs-native" */
/** @import { ToolContext, ToolDefinition } from "./types/ext.js" */
/** @typedef {{ old_start: number, old_lines: number, new_start: number, new_lines: number, lines: string[] }} DiffHunk */
/** @typedef {{ path: string, hunks: DiffHunk[] }} DiffFile */
/** @typedef {{ type: "diff", files: DiffFile[] }} DiffView */
/** @typedef {{ view?: DiffView[], media?: Wire.MediaBlob[] }} ResultExtra */
/** @typedef {{ __yuke_result: true, text: string, extra: ResultExtra | null }} BuiltinResult */
/** @typedef {Omit<ToolDefinition, "name">} BuiltinTool */

/** @param {string} text @param {ResultExtra | null} extra @returns {BuiltinResult} */
const result = (text, extra) => ({ __yuke_result: true, text, extra });

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
      if (args == null || typeof args !== "object" || Array.isArray(args)) invalid(name, "the arguments must be an object");
      for (const key of Object.keys(args)) if (!fields.has(key)) invalid(name, `the argument ${key} does not exist. The arguments are: ${[...fields].join(", ")}.`);
      return execute(args, signal, context);
    },
  });
}

const MAX_FILE_BYTES = 10 * 1024 * 1024;
// Each stream keeps 4 KiB in the result, and a cut result names the log that holds every byte.
const EXEC_STREAM_BYTES = 4096;
const MAX_LINE = 0xffffffff;

/** @param {string} name @param {string} message @returns {never} */
function invalid(name, message) {
  throw new Error(`${name}: ${message}`);
}


/** @template T @param {string} name @param {Promise<T>} promise @returns {Promise<T>} */
async function hostCall(name, promise) {
  try { return await promise; }
  catch (e) { throw new Error(`${name}: ${errorText(e)}`); }
}

/** @param {string} name @param {ToolArgs} args @param {string} key @returns {string} */
function stringArg(name, args, key) {
  if (typeof args[key] !== "string") invalid(name, `the argument ${key} must be a string`);
  return /** @type {string} */ (args[key]);
}

/** @param {string} name @param {ToolArgs} args @param {string} key @returns {number | null} */
function lineArg(name, args, key) {
  const value = args[key];
  if (value == null) return null;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1 || value > MAX_LINE) invalid(name, `the argument ${key} has the wrong type or range`);
  return value;
}

/** @param {ParsedDiffFile} file @returns {DiffView[] | null} */
function viewOf(file) {
  if (file.hunks.length === 0) return null;
  return [{
    type: "diff",
    files: [{
      path: file.path,
      hunks: file.hunks.map(h => ({
        old_start: h.oldStart,
        old_lines: h.oldLines,
        new_start: h.newStart,
        new_lines: h.newLines,
        lines: h.lines,
      })),
    }],
  }];
}

/** @param {RangeRead} got @param {number} first @returns {string} */
function renderRead(got, first) {
  const lines = got.text.length === 0 ? [] : got.text.slice(0, -1).split("\n");
  const out = lines.map((line, i) => `${first + i}: ${line}`).join("\n");
  let text = out;
  if (got.longLines !== 0) text += `\n[The tool cut ${got.longLines} line(s) at 8000 bytes.]`;
  if (got.next !== null) text += `\n[The tool capped the output. Read again with the start value set to ${got.next}.]`;
  return text;
}

/** @param {ToolArgs} args @param {ToolSignal} _signal @param {ToolContext} context @returns {Promise<string | BuiltinResult>} */
async function read(args, _signal, context) {
  const name = "read";
  const path = stringArg(name, args, "path");
  const start = lineArg(name, args, "start");
  const end = lineArg(name, args, "end");
  const got = await hostCall(name, fs.readRange(path, { start, end, workspaceRoot: context.workspaceRoot }));
  if ("imagePath" in got) {
    const blob = await hostCall(name, client.blobPut(got.imagePath));
    const kind = blob.mime.slice(blob.mime.indexOf("/") + 1).toUpperCase();
    return result(`${kind} image, ${byteLabel(blob.bytes)}`, { media: [blob] });
  }
  return renderRead(got, start ?? 1);
}

/** @param {ToolArgs} args @param {ToolSignal} _signal @param {ToolContext} context @returns {Promise<BuiltinResult>} */
async function write(args, _signal, context) {
  const name = "write";
  const path = stringArg(name, args, "path");
  const content = stringArg(name, args, "content");
  let old = "";
  let canDiff = true;
  try { old = await fs.readFile(path, { workspaceRoot: context.workspaceRoot }); }
  catch (e) { if (errorText(e) !== "the path does not exist") canDiff = false; }
  const mapped = canDiff ? await diff(path, old, content) : null;
  const bytes = await hostCall(name, fs.writeFile(path, content, { workspaceRoot: context.workspaceRoot }));
  const view = mapped == null ? null : viewOf(mapped);
  const text = view == null ? `The tool wrote ${bytes} bytes.` : `The tool wrote ${bytes} bytes and changed ${changedLines(view)} line(s).`;
  return result(text, view == null ? null : { view });
}

/** @param {DiffView[]} view @returns {number} */
function changedLines(view) {
  let count = 0;
  for (const file of view[0]?.files || []) for (const hunk of file.hunks) for (const line of hunk.lines) if (line[0] !== " ") count++;
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

/** @param {ToolArgs} args @param {ToolSignal} _signal @param {ToolContext} context @returns {Promise<BuiltinResult>} */
async function edit(args, _signal, context) {
  const name = "edit";
  const path = stringArg(name, args, "path");
  const oldString = stringArg(name, args, "old_string");
  const newString = stringArg(name, args, "new_string");
  const replaceAll = args.replace_all ?? false;
  if (typeof replaceAll !== "boolean") invalid(name, "the argument replace_all has the wrong type or range");
  if (oldString.length === 0) invalid(name, "the argument old_string has the wrong type or range");
  if (oldString === newString) invalid(name, "old_string and new_string match. The edit changes nothing");
  const old = await hostCall(name, fs.readFile(path, { workspaceRoot: context.workspaceRoot }));
  const replaced = replaceAt(old, oldString, newString);
  if (replaced.count === 0) invalid(name, "the file lacks old_string");
  if (replaced.count > 1 && !replaceAll) invalid(name, "old_string appears more than one time. You must add context or set replace_all");
  if (utf8Length(replaced.text) > MAX_FILE_BYTES) invalid(name, "the file exceeds the size limit");
  const mapped = await diff(path, old, replaced.text);
  await hostCall(name, fs.writeFile(path, replaced.text, { workspaceRoot: context.workspaceRoot }));
  const view = viewOf(mapped);
  const text = view == null ? `The tool replaced ${replaced.count} match(es).` : `The tool replaced ${replaced.count} match(es) and changed ${changedLines(view)} line(s).`;
  return result(text, view == null ? null : { view });
}

/** @param {string} text @returns {string} */
function endLine(text) {
  return text.length === 0 || text.endsWith("\n") ? text : `${text}\n`;
}


/** @param {string | undefined} sessionId @returns {Job[]} */
function sessionJobs(sessionId) {
  return listJobs().filter(j => (j.session_id ?? null) === (sessionId ?? null));
}

/** @param {Job} job @returns {string} */
function jobState(job) {
  return job.stop_requested ? `${jobName(job)} ${endLabel(job)}: ${shortCommand(job.command)}` : job.state === "exited" ? `${jobName(job)} exited (${endLabel(job)}): ${shortCommand(job.command)}` : `${jobName(job)} ${job.state}: ${shortCommand(job.command)}`;
}

// A job that exits by itself tells its session once, in exit order, even when its log cannot be read; a stop sends nothing.
/** @type {Promise<unknown>} */
let exitMessages = Promise.resolve();
events.on("jobs.changed", (/** @type {Job} */ job) => {
  const sessionId = job.session_id;
  if (job.state === "running" || job.stop_requested || sessionId === undefined) return;
  const tail = jobTail(job.id, 20).catch(() => "");
  exitMessages = exitMessages
    .then(() => tail)
    .then(out => client.sessionSendInput(sessionId, client.textContent(`[job ${jobState(job)}. Log: ${job.log}]\n${out === "" ? "[no output]" : out}`)))
    .catch(() => {});
});

/** @param {string} command @param {ToolContext} context @returns {Promise<string>} */
async function startBackground(command, context) {
  const root = context.workspaceRoot;
  const sessionId = context.sessionId;
  const same = sessionJobs(sessionId).find(j => j.state === "running" && j.command === command && j.cwd === root);
  if (same) return `[job ${jobName(same)} already runs this command. Log: ${same.log}]`;
  const job = await hostCall("exec", startJob(command, { workspaceRoot: root, ...(sessionId !== undefined ? { sessionId } : {}) }));
  return `[job ${jobName(job)} started: ${shortCommand(command)}. Log: ${job.log}. Use grep or read on the log. A message arrives when it exits by itself, so never sleep or poll to wait. Use jobs with id and stop: true to request its stop.]`;
}

// A job of another session stays hidden, so its id reads as absent.
/** @param {string} name @param {string} id @param {ToolContext} context @returns {Job} */
function jobOf(name, id, context) {
  const job = /^j[1-9][0-9]*$/.test(id) ? getJob(Number(id.slice(1))) : null;
  if (job && (job.session_id ?? null) === (context.sessionId ?? null)) return job;
  const ids = sessionJobs(context.sessionId).map(jobName);
  return invalid(name, `the job ${id} does not exist. ${ids.length === 0 ? "No job exists." : `The jobs are: ${ids.join(", ")}.`}`);
}

/** @param {Job} job @returns {string} */
function jobLine(job) {
  return `[${jobState(job)}. Log: ${job.log}]`;
}

/** @param {ToolArgs} args @param {ToolSignal} _signal @param {ToolContext} context @returns {Promise<string>} */
async function jobs(args, _signal, context) {
  const name = "jobs";
  const stop = args.stop ?? false;
  if (typeof stop !== "boolean") invalid(name, "the argument stop must be a boolean");
  if (args.id == null) {
    if (stop) invalid(name, "the argument stop needs the argument id");
    const own = sessionJobs(context.sessionId);
    return own.length === 0 ? "[no job]" : own.map(jobLine).join("\n");
  }
  const job = jobOf(name, stringArg(name, args, "id"), context);
  if (!stop) return jobLine(job);
  return `[${jobState(/** @type {Job} */ (await stopJob(job.id)))}]`;
}

/** @param {ToolArgs} args @param {ToolSignal} signal @param {ToolContext} context @returns {Promise<string>} */
async function exec(args, signal, context) {
  const name = "exec";
  const command = stringArg(name, args, "command");
  if (command.trim().length === 0) invalid(name, "the argument command has the wrong type or range");
  const background = args.background ?? false;
  if (typeof background !== "boolean") invalid(name, "the argument background must be a boolean");
  const timeoutValue = args.timeout_ms;
  if (background) {
    if (timeoutValue != null) invalid(name, "timeout_ms does not apply to background: true. Remove one of the two arguments");
    return startBackground(command, context);
  }
  const timeout = timeoutValue == null ? 120000 : timeoutValue;
  if (typeof timeout !== "number" || !Number.isInteger(timeout) || timeout < 1 || timeout > 600000) invalid(name, "the argument timeout_ms has the wrong type or range");
  const r = await hostCall(name, runCommand(command, { timeoutMs: timeout, signal, maxBytes: EXEC_STREAM_BYTES, log: true, onOutput: context.output, workspaceRoot: context.workspaceRoot }));
  let text = r.stdout;
  if (r.stderr.length !== 0) text = `${endLine(text)}[stderr]\n${r.stderr}`;
  const empty = text.length === 0;
  text = endLine(text);
  if (empty) text += "[no output]\n";
  if (r.timedOut) text += `[The command passed its ${timeout} ms timeout. The tool stopped the process group. Run a smaller command, raise timeout_ms up to 600000, or set background: true for a server or watcher.]`;
  else if (r.signal !== null) text += `[A signal ended the command: ${r.signal}.]`;
  else text += `[exit code: ${r.code}]`;
  if (r.log !== null) text += `\n[The tool cut the output. Full log: ${r.log}. Use grep or read on it.]`;
  return text;
}

// The engine wraps the body, so the tool and an explicit `/skill:name` produce one form in the transcript.
/** @param {ToolArgs} args @param {ToolSignal} _signal @param {ToolContext} context @returns {Promise<string>} */
async function skill(args, _signal, context) {
  const name = "skill";
  const skillName = stringArg(name, args, "name");
  if (!context.sessionId) invalid(name, "the tool has no session");
  const loaded = await hostCall(name, client.skillLoad(context.sessionId, skillName));
  return loaded.content;
}

export const builtins = {
  name: "builtins",
  /** @param {Context} ctx */
  apply(ctx) {
    builtin(ctx, "read", {
      description: "Read a file with 1-indexed line numbers. Pass the start and end values for a line range. A PNG, JPEG, GIF, or WebP file returns the image.",
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
      description: "Run a shell command in the working directory and return stdout, stderr, and the exit code. Each call starts a fresh shell and ends every process it started. For a server or watcher, set background: true; never use &, nohup, or setsid.",
      parameters: { type: "object", properties: {
        command: { type: "string" },
        timeout_ms: { type: "integer", minimum: 1, maximum: 600000, description: "The default is 120000." },
        background: { type: "boolean", description: "Run a server or watcher as a job and return at once." },
      }, required: ["command"], additionalProperties: false }, execute: exec,
    });
    builtin(ctx, "jobs", {
      description: "List the background jobs, or stop one. Pass no argument for the list. Pass id alone for one job and its log path. Pass id and stop: true to request the stop of the job and its process group. A requested stop sends no exit message.",
      parameters: { type: "object", properties: {
        id: { type: "string", description: "The job id, for example j1." },
        stop: { type: "boolean" },
      }, required: [], additionalProperties: false }, execute: jobs,
    });
    builtin(ctx, "skill", {
      description: "Load one listed skill by name. Skip if its instructions are already in the transcript.",
      parameters: { type: "object", properties: {
        name: { type: "string", description: "Name from an available_skills entry." },
      }, required: ["name"], additionalProperties: false }, execute: skill,
    });

    // The skill tool has nothing to load in a session that lists no skill, so that session never sees it.
    ctx.hook("tools.select", (selection) => selection.context.has_skills ? null : { replace: { ...selection, tools: selection.tools.filter((name) => name !== "skill") } });
  },
};
