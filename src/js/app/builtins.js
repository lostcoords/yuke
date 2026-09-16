// The built-in tools. They use only the asynchronous host primitives.

import { fs } from "yuke:fs";
import { exec as runCommand, start as startJob, stop as stopJob } from "yuke:exec";
import { diff } from "yuke:diff";
import { defineTool, hasTool } from "yuke:tools";
import { client } from "yuke:client";
import { byteLabel } from "yuke:format";

/** @import { DiffFile as ParsedDiffFile } from "yuke:diff" */
/** @import { RangeRead } from "yuke:fs" */
/** @typedef {Record<string, unknown>} ToolArgs */
/** @typedef {{ aborted: boolean }} ToolSignal */
/** @typedef {{ workspaceRoot: string, sessionId?: string, messageId?: number, partId?: number }} ToolContext */
/** @typedef {{ old_start: number, old_lines: number, new_start: number, new_lines: number, lines: string[] }} DiffHunk */
/** @typedef {{ path: string, hunks: DiffHunk[] }} DiffFile */
/** @typedef {{ type: "diff", files: DiffFile[] }} DiffView */
/** @typedef {{ view?: DiffView[], media?: Wire.MediaBlob[] }} ResultExtra */
/** @typedef {{ __yuke_result: true, text: string, extra: ResultExtra | null }} BuiltinResult */
/** @typedef {Omit<import("./types/ext.js").ToolDefinition, "name">} ToolDefinition */

/** @param {string} text @param {ResultExtra | null} extra @returns {BuiltinResult} */
const result = (text, extra) => ({ __yuke_result: true, text, extra });

// A user tool with the same name wins, so the built-in steps aside.
/** @param {string} name @param {ToolDefinition} definition @returns {void} */
function builtin(name, definition) {
  if (!hasTool(name)) defineTool(name, definition);
}

const MAX_FILE_BYTES = 10 * 1024 * 1024;
// Each stream keeps 4 KiB in the result, and a cut result names the log that holds every byte.
const EXEC_STREAM_BYTES = 4096;
const MAX_LINE = 0xffffffff;

/** @param {string} name @param {string} message @returns {never} */
function invalid(name, message) {
  throw new Error(`${name}: ${message}`);
}

/** @param {unknown} error @returns {string} */
function messageOf(error) {
  if (error instanceof Error) return error.message;
  if (error !== null && typeof error === "object" && "message" in error) return String(error.message);
  return String(error);
}

/** @template T @param {string} name @param {Promise<T>} promise @returns {Promise<T>} */
async function hostCall(name, promise) {
  try { return await promise; }
  catch (e) { throw new Error(`${name}: ${messageOf(e)}`); }
}

/** @param {string} name @param {unknown} args @returns {ToolArgs} */
function objectArgs(name, args) {
  if (args == null || typeof args !== "object" || Array.isArray(args)) invalid(name, "the arguments must be an object");
  return /** @type {ToolArgs} */ (args);
}

/** @param {string} name @param {ToolArgs} args @param {readonly string[]} fields @returns {void} */
function only(name, args, fields) {
  for (const key of Object.keys(args)) if (!fields.includes(key)) invalid(name, "the schema lacks the argument");
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

/** @param {string} text @returns {number} */
function utf8Length(text) {
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 0x80) bytes += 1;
    else if (c < 0x800) bytes += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) {
      bytes += 4;
      i++;
    } else bytes += 3;
  }
  return bytes;
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
  args = objectArgs(name, args);
  only(name, args, ["path", "start", "end"]);
  const path = stringArg(name, args, "path");
  const start = lineArg(name, args, "start");
  const end = lineArg(name, args, "end");
  const got = await hostCall(name, fs.readRange(path, { start, end }, context?.workspaceRoot));
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
  args = objectArgs(name, args);
  only(name, args, ["path", "content"]);
  const path = stringArg(name, args, "path");
  const content = stringArg(name, args, "content");
  let old = "";
  let canDiff = true;
  try { old = await fs.readFile(path, context?.workspaceRoot); }
  catch (e) { if (messageOf(e) !== "the path does not exist") canDiff = false; }
  const mapped = canDiff ? await diff(path, old, content) : null;
  const bytes = await hostCall(name, fs.writeFile(path, content, context?.workspaceRoot));
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

/** @param {string} text @param {string} old @param {string} replacement @param {boolean} all @returns {{ count: number, text: string }} */
function replaceAt(text, old, replacement, all) {
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
  args = objectArgs(name, args);
  only(name, args, ["path", "old_string", "new_string", "replace_all"]);
  const path = stringArg(name, args, "path");
  const oldString = stringArg(name, args, "old_string");
  const newString = stringArg(name, args, "new_string");
  const replaceAll = args.replace_all ?? false;
  if (typeof replaceAll !== "boolean") invalid(name, "the argument replace_all has the wrong type or range");
  if (oldString.length === 0) invalid(name, "the argument old_string has the wrong type or range");
  if (oldString === newString) invalid(name, "old_string and new_string match. The edit changes nothing");
  const old = await hostCall(name, fs.readFile(path, context?.workspaceRoot));
  const replaced = replaceAt(old, oldString, newString, replaceAll);
  if (replaced.count === 0) invalid(name, "the file lacks old_string");
  if (replaced.count > 1 && !replaceAll) invalid(name, "old_string appears more than one time. You must add context or set replace_all");
  if (utf8Length(replaced.text) > MAX_FILE_BYTES) invalid(name, "the file exceeds the size limit");
  const mapped = await diff(path, old, replaced.text);
  await hostCall(name, fs.writeFile(path, replaced.text, context?.workspaceRoot));
  const view = viewOf(mapped);
  const text = view == null ? `The tool replaced ${replaced.count} match(es).` : `The tool replaced ${replaced.count} match(es) and changed ${changedLines(view)} line(s).`;
  return result(text, view == null ? null : { view });
}

/** @param {string} text @returns {string} */
function endLine(text) {
  return text.length === 0 || text.endsWith("\n") ? text : `${text}\n`;
}

// Background jobs, in start order. A job keeps its entry after it ends, so the model can read its final state.
/** @typedef {{ id: string, native: number, command: string, root: string | undefined, sessionId: string | undefined, log: string, state: "running" | "exited" | "stopped", code: number | null, signal: number | null }} Job */
/** @type {Map<string, Job>} */
const jobs = new Map();
let jobCount = 0;
const MAX_ENDED_JOBS = 32;
const JOB_TAIL_LINES = 20;

/** @param {string} command @returns {string} */
function shortCommand(command) {
  const text = command.trim();
  const end = text.indexOf("\n");
  const line = end < 0 ? text : text.slice(0, end);
  return line.length > 60 || end >= 0 ? `${line.slice(0, 57)}...` : line;
}

/** @param {string | undefined} sessionId @returns {Job[]} */
function sessionJobs(sessionId) {
  return [...jobs.values()].filter(j => j.sessionId === sessionId);
}

/** @param {Job} job @returns {string} */
function jobState(job) {
  if (job.state !== "exited") return `${job.id} ${job.state}: ${shortCommand(job.command)}`;
  const end = job.signal !== null ? `signal ${job.signal}` : `exit code ${job.code}`;
  return `${job.id} exited (${end}): ${shortCommand(job.command)}`;
}

/** @param {Job} job @returns {Promise<string>} */
async function jobTail(job) {
  const quoted = "'" + job.log.replace(/'/g, "'\\''") + "'";
  const r = await runCommand(`tail -n ${JOB_TAIL_LINES} ${quoted}`, { maxBytes: 4096 }).catch(() => null);
  if (r === null || r.stdout.length === 0) return "[no output yet]";
  return endLine(r.stdout).slice(0, -1);
}

/** @param {Job} job @param {{ code: number | null, signal: number | null } | null} exit @returns {void} */
function endJob(job, exit) {
  if (job.state !== "running") return; // A stopped job sends no message.
  job.state = "exited";
  job.code = exit?.code ?? null;
  job.signal = exit?.signal ?? null;
  const ended = [...jobs.values()].filter(j => j.state !== "running");
  for (const old of ended.slice(0, Math.max(0, ended.length - MAX_ENDED_JOBS))) jobs.delete(old.id);
  const sessionId = job.sessionId;
  if (!sessionId) return;
  jobTail(job)
    .then(tail => client.sessionSendInput(sessionId, client.textContent(`[job ${jobState(job)}. Log: ${job.log}]\n${tail}`)))
    .catch(() => {});
}

/** @param {string | undefined} sessionId @returns {string} */
function liveIds(sessionId) {
  const ids = sessionJobs(sessionId).map(j => j.id);
  return ids.length === 0 ? "No job exists." : `The jobs are: ${ids.join(", ")}.`;
}

/** @param {string} command @param {ToolContext} context @returns {Promise<string>} */
async function startBackground(command, context) {
  const root = context?.workspaceRoot;
  const sessionId = context?.sessionId;
  for (const job of jobs.values()) {
    if (job.state === "running" && job.command === command && job.root === root && job.sessionId === sessionId)
      return `[job ${job.id} already runs this command. Log: ${job.log}]`;
  }
  const handle = await hostCall("exec", startJob(command, {}, root));
  const job = /** @type {Job} */ ({ id: `j${++jobCount}`, native: handle.id, command, root, sessionId, log: handle.log, state: "running", code: null, signal: null });
  jobs.set(job.id, job);
  handle.exited.then(exit => endJob(job, exit), () => endJob(job, null));
  return `[job ${job.id} started: ${shortCommand(command)}. Log: ${job.log}. A message arrives when it exits by itself. Use the job tool to read or stop it.]`;
}

/** @param {ToolArgs} args @param {ToolSignal} _signal @param {ToolContext} context @returns {Promise<string>} */
async function job(args, _signal, context) {
  const name = "job";
  args = objectArgs(name, args);
  only(name, args, ["id", "stop"]);
  const sessionId = context?.sessionId;
  const id = args.id ?? null;
  const stop = args.stop ?? false;
  if (id !== null && typeof id !== "string") invalid(name, "the argument id must be a string");
  if (typeof stop !== "boolean") invalid(name, "the argument stop must be a boolean");
  if (id === null) {
    if (stop) invalid(name, `stop needs an id. ${liveIds(sessionId)}`);
    const list = sessionJobs(sessionId);
    return list.length === 0 ? "[no jobs]" : list.map(j => `${jobState(j)}. Log: ${j.log}`).join("\n");
  }
  const found = jobs.get(/** @type {string} */ (id));
  if (!found || found.sessionId !== sessionId) invalid(name, `the job ${id} does not exist. ${liveIds(sessionId)}`);
  const entry = /** @type {Job} */ (found);
  if (!stop) return `[${jobState(entry)}. Log: ${entry.log}]\n${await jobTail(entry)}`;
  if (entry.state === "running") {
    entry.state = "stopped";
    await hostCall(name, stopJob(entry.native));
  }
  return `[${jobState(entry)}]`;
}

/** @param {ToolArgs} args @param {ToolSignal} signal @param {ToolContext} context @returns {Promise<string>} */
async function exec(args, signal, context) {
  const name = "exec";
  args = objectArgs(name, args);
  only(name, args, ["command", "timeout_ms", "background"]);
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
  const r = await hostCall(name, runCommand(command, { timeoutMs: timeout, signal, maxBytes: EXEC_STREAM_BYTES, log: true }, context?.workspaceRoot));
  let text = r.stdout;
  if (r.stderr.length !== 0) text = `${endLine(text)}[stderr]\n${r.stderr}`;
  const empty = text.length === 0;
  text = endLine(text);
  if (empty) text += "[no output]\n";
  if (r.timedOut) text += `[The command passed its ${timeout} ms timeout. The tool stopped the process group. Run a smaller command, raise timeout_ms up to 600000, or set background: true for a server or watcher.]`;
  else if (r.signal !== null) text += `[A signal ended the command: ${r.signal}.]`;
  else text += `[exit code: ${r.code}]`;
  if (r.log !== null) text += `\n[The tool cut the output. Full log: ${r.log}. Use grep or read on it.]`;
  const running = sessionJobs(context?.sessionId).filter(j => j.state === "running");
  if (running.length !== 0) text += `\n[running jobs: ${running.map(j => `${j.id} ${shortCommand(j.command)}`).join(", ")}]`;
  return text;
}

// The engine wraps the body, so the tool and an explicit `/skill:name` produce one form in the transcript.
/** @param {ToolArgs} args @param {ToolSignal} _signal @param {ToolContext} context @returns {Promise<string>} */
async function skill(args, _signal, context) {
  const name = "skill";
  args = objectArgs(name, args);
  only(name, args, ["name"]);
  const skillName = stringArg(name, args, "name");
  if (!context?.sessionId) invalid(name, "the tool has no session");
  const loaded = await hostCall(name, client.skillLoad(context.sessionId, skillName));
  return loaded.content;
}

builtin("read", {
  description: "Read a file with 1-indexed line numbers. Pass the start and end values for a line range. A PNG, JPEG, GIF, or WebP file returns the image.",
  parameters: { type: "object", properties: {
    path: { type: "string", description: "The file path. A relative path resolves against the workspace root." },
    start: { type: ["integer", "null"], minimum: 1, maximum: MAX_LINE, description: "The first line to read, 1-indexed." },
    end: { type: ["integer", "null"], minimum: 1, maximum: MAX_LINE, description: "The last line to read, 1-indexed and inclusive." },
  }, required: ["path"], additionalProperties: false }, execute: read,
});
builtin("write", {
  description: "Create a file or replace its content. Pass the complete content.",
  parameters: { type: "object", properties: {
    path: { type: "string", description: "The file path. A relative path resolves against the workspace root." },
    content: { type: "string", description: "The complete content for the file." },
  }, required: ["path", "content"], additionalProperties: false }, execute: write,
});
builtin("edit", {
  description: "Replace an exact string in a file. old_string must appear exactly once unless replace_all is true.",
  parameters: { type: "object", properties: {
    path: { type: "string", description: "The file path. A relative path resolves against the workspace root." },
    old_string: { type: "string", description: "The exact text to replace." },
    new_string: { type: "string", description: "The replacement text." },
    replace_all: { type: "boolean", description: "Replace every non-overlapping match." },
  }, required: ["path", "old_string", "new_string"], additionalProperties: false }, execute: edit,
});
builtin("exec", {
  description: "Run a shell command in the working directory and return stdout, stderr, and the exit code. Each call starts a fresh shell. No process outlives the call unless background is true.\n\n`timeout_ms` is optional (default 120000, max 600000).",
  parameters: { type: "object", properties: {
    command: { type: "string", description: "The shell command to run." },
    timeout_ms: { type: ["integer", "null"], minimum: 1, maximum: 600000, description: "The timeout in milliseconds." },
    background: { type: "boolean", description: "Run a server or watcher as a job and return at once." },
  }, required: ["command"], additionalProperties: false }, execute: exec,
});
builtin("job", {
  description: "Manage background jobs. No id lists them. An id shows the state and the last 20 log lines. An id with stop: true stops the job.",
  parameters: { type: "object", properties: {
    id: { type: "string", description: "The job id, for example j1." },
    stop: { type: "boolean", description: "Stop the job." },
  }, additionalProperties: false }, execute: job,
});
builtin("skill", {
  description: "Load the full instructions for a skill listed in the system prompt. Use this tool when the task matches the skill description.",
  parameters: { type: "object", properties: {
    name: { type: "string", description: "Pass the name from an available_skills entry." },
  }, required: ["name"], additionalProperties: false }, execute: skill, needsSkills: true,
});
