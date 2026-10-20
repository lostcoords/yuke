import { mkdir, readTextFile, writeTextFile } from "yuke:fs";
import { callOf } from "yuke:internal/call";
import { defineTool } from "yuke:internal/define";
import { TextEncoder } from "yuke:internal/encoding";
import { readLines } from "yuke:internal/native";

/** The most bytes of the output of `read` and `exec`. A cut adds one line that tells the model what the cut left out. */
const OUTPUT_BYTES = 50 * 1024;

/** The largest line number. */
const LAST_LINE = 4_294_967_295;

/** The default and the longest deadline of a command, in milliseconds. */
const DEFAULT_TIMEOUT = 120_000;
const LONGEST_TIMEOUT = 600_000;

/** The description of the `path` argument of each tool. */
const PATH = "A relative path resolves against the workspace.";

defineTool({
  name: "read",
  description:
    "Read a file with 1-indexed line numbers. Pass offset and limit for a line range. One read returns at most " +
    `${OUTPUT_BYTES / 1024} KiB. A capped read gives the next offset. A PNG, JPEG, GIF, or WebP file returns the image.`,
  parameters: {
    type: "object",
    properties: {
      path: { type: "string", description: PATH },
      offset: { type: "integer", minimum: 1, maximum: LAST_LINE, description: "The first line." },
      limit: { type: "integer", minimum: 1, maximum: LAST_LINE, description: "The most lines to read." },
    },
    required: ["path"],
  },
  concurrency: "parallel",
  async execute(args, context) {
    const read = await readLines(args.path, context.folder, args.offset ?? 1, args.limit ?? LAST_LINE, OUTPUT_BYTES);
    if ("image" in read) return { text: "Image read successfully", media: [read.image] };

    // The native read ends each line with a line feed. The result drops the last one.
    let text = read.text.endsWith("\n") ? read.text.slice(0, -1) : read.text;
    if (read.cut !== undefined) text += `\n[read cut: line ${read.cut} at ${OUTPUT_BYTES / 1024} KiB.]`;
    if (read.next !== undefined) text += `\n[read more: offset ${read.next}.]`;
    return text;
  },
});

defineTool({
  name: "write",
  description: "Create a file or replace its content. Pass the complete content. Missing parent folders are created.",
  parameters: {
    type: "object",
    properties: {
      path: { type: "string", description: PATH },
      content: { type: "string" },
    },
    required: ["path", "content"],
  },
  concurrency: "serial",
  async execute(args, context) {
    const options = { baseDir: context.folder, signal: context.signal };
    // The tool makes the missing parent folders, so the model can write a new file in a new folder.
    const slash = args.path.lastIndexOf("/");
    if (slash > 0) await mkdir(args.path.slice(0, slash), { ...options, recursive: true });
    await writeTextFile(args.path, args.content, options);
    return `The tool wrote ${new TextEncoder().encode(args.content).length} bytes.`;
  },
});

defineTool({
  name: "edit",
  description: "Replace an exact string in a file. old_string must appear exactly once unless replace_all is true.",
  parameters: {
    type: "object",
    properties: {
      path: { type: "string", description: PATH },
      old_string: { type: "string" },
      new_string: { type: "string" },
      replace_all: { type: "boolean", description: "Replace every non-overlapping match." },
    },
    required: ["path", "old_string", "new_string"],
  },
  concurrency: "serial",
  async execute(args, context) {
    const { path, old_string: oldString, new_string: newString, replace_all: replaceAll = false } = args;
    if (oldString.length === 0) throw new Error("Set old_string to a nonempty string.");
    if (oldString === newString) throw new Error("Set new_string to a value that differs from old_string.");

    const options = { baseDir: context.folder, signal: context.signal };
    const parts = (await readTextFile(path, options)).split(oldString);
    const count = parts.length - 1;
    if (count === 0) throw new Error("The file has no match for old_string. Read the file and copy the exact text.");
    if (count > 1 && !replaceAll) {
      throw new Error("old_string matches more than one place. Add context to old_string, or set replace_all to true.");
    }
    await writeTextFile(path, parts.join(newString), options);
    return `The tool replaced ${count} match(es).`;
  },
});

defineTool({
  name: "exec",
  description:
    "Run a shell command in the workspace. Return stdout and stderr in write order, and the exit status. " +
    "Each call starts a fresh shell and ends every process it starts. For a server or watcher, set background to " +
    "true. Do not use &, nohup, or setsid.",
  parameters: {
    type: "object",
    properties: {
      command: { type: "string" },
      timeout_ms: {
        type: "integer",
        minimum: 1,
        maximum: LONGEST_TIMEOUT,
        description: `The default is ${DEFAULT_TIMEOUT}.`,
      },
      background: { type: "boolean", description: "Run a server or watcher as a job and return at once." },
    },
    required: ["command"],
  },
  concurrency: "serial",
  async execute(args, context) {
    const command = args.command;
    if (command.trim().length === 0) throw new Error("Set command to a nonempty string.");
    if (args.background === true) {
      if (args.timeout_ms !== undefined) throw new Error("Remove timeout_ms, or set background to false.");
      const job = await callOf(context).startJob(command);
      return (
        `[${job.id} started: ${shortCommand(command)}. Log: ${job.log}. Its end arrives as a message, so never ` +
        `sleep or poll. Use stop with ${job.id} to end it.]`
      );
    }

    const timeout = args.timeout_ms ?? DEFAULT_TIMEOUT;
    const end = await callOf(context).exec(command, { timeoutMs: timeout, maxBytes: OUTPUT_BYTES }, context.output);
    const output = end.output.length === 0 ? "[no output]" : end.output;
    const text = output.endsWith("\n") ? output : `${output}\n`;
    // Only a command that exits with 0 succeeds.
    switch (end.cause) {
      case "cancelled":
        return { text: `${text}[stopped: the tool call was cancelled.]`, isError: true };
      case "timeout":
        return {
          text:
            `${text}[timeout: ${timeout} ms. yuke stopped the process group. Run a smaller command. Raise ` +
            `timeout_ms up to ${LONGEST_TIMEOUT}. Set background to true for a server or watcher.]`,
          isError: true,
        };
      case "signal":
        return { text: `${text}[signal: ${end.signal}]`, isError: true };
      case "exit":
        return { text: `${text}[exit code: ${end.code}]`, isError: end.code !== 0 };
    }
  },
});

defineTool({
  name: "stop",
  description:
    "Stop background work by the id that its start result names. A job ends in the result, and no end message follows.",
  parameters: {
    type: "object",
    properties: {
      id: { type: "string" },
    },
    required: ["id"],
  },
  concurrency: "serial",
  async execute(args, context) {
    const id = args.id;
    const call = callOf(context);
    const stopped = await call.stopJob(id);
    if (stopped === undefined) {
      const ids = call.runningJobs();
      throw new Error(
        `The id ${id} does not exist. ${ids.length === 0 ? "Nothing runs." : `The ids are: ${ids.join(", ")}.`}`,
      );
    }
    return `[${id} ${stopped.label}.] Log: ${stopped.log}`;
  },
});

/** The first line of `command`, at most 60 characters, for a job start. */
function shortCommand(command: string): string {
  const text = command.trim();
  const end = text.indexOf("\n");
  const line = end < 0 ? text : text.slice(0, end);
  return line.length > 60 || end >= 0 ? `${line.slice(0, 57)}...` : line;
}
