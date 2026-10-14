import { readLines, readText, writeText } from "yuke:internal/native/fs";
import { sessionOf } from "yuke:internal/session";
import { define, OUTPUT_BYTES } from "yuke:tools";

/** The largest line number. */
const LAST_LINE = 4_294_967_295;

/** The default and the longest deadline of a command, in milliseconds. */
const DEFAULT_TIMEOUT = 120_000;
const LONGEST_TIMEOUT = 600_000;

/** The description of the `path` argument of each tool. */
const PATH = "A relative path resolves against the workspace root.";

define({
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
    const read = await readLines(
      args.path as string,
      context.folder,
      (args.offset as number | undefined) ?? 1,
      (args.limit as number | undefined) ?? LAST_LINE,
      OUTPUT_BYTES,
    );
    if ("image" in read) return { output: "Image read successfully", media: [read.image] };

    // The native read ends each line with a line feed. The result drops the last one.
    let text = read.text.endsWith("\n") ? read.text.slice(0, -1) : read.text;
    if (read.cut !== undefined) text += `\n[read cut: line ${read.cut} at ${OUTPUT_BYTES / 1024} KiB.]`;
    if (read.next !== undefined) text += `\n[read more: offset ${read.next}.]`;
    return text;
  },
});

define({
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
    const bytes = await writeText(args.path as string, context.folder, args.content as string);
    return `The tool wrote ${bytes} bytes.`;
  },
});

define({
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
    const path = args.path as string;
    const oldString = args.old_string as string;
    const newString = args.new_string as string;
    const replaceAll = (args.replace_all as boolean | undefined) ?? false;
    if (oldString.length === 0) throw new Error("Set old_string to a nonempty string.");
    if (oldString === newString) throw new Error("Set new_string to a value that differs from old_string.");

    const parts = (await readText(path, context.folder)).split(oldString);
    const count = parts.length - 1;
    if (count === 0) throw new Error("The file has no match for old_string. Read the file and copy the exact text.");
    if (count > 1 && !replaceAll) {
      throw new Error("old_string matches more than one place. Add context to old_string, or set replace_all to true.");
    }
    await writeText(path, context.folder, parts.join(newString));
    return `The tool replaced ${count} match(es).`;
  },
});

define({
  name: "exec",
  description:
    "Run a shell command in the working directory. Return stdout and stderr in write order, and the exit status. " +
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
    const command = args.command as string;
    if (command.trim().length === 0) throw new Error("Set command to a nonempty string.");
    if (args.background === true) {
      if (args.timeout_ms !== undefined) throw new Error("Remove timeout_ms, or set background to false.");
      const job = await sessionOf(context).startJob(command);
      return (
        `[${job.id} started: ${shortCommand(command)}. Log: ${job.log}. Its end arrives as a message, so never ` +
        `sleep or poll. Use stop with ${job.id} to end it.]`
      );
    }

    const timeout = (args.timeout_ms as number | undefined) ?? DEFAULT_TIMEOUT;
    const end = await sessionOf(context).exec(command, timeout, OUTPUT_BYTES, context.signal, context.output);
    let text = end.output.length === 0 ? "[no output]\n" : endLine(end.output);
    if (end.stopped) text += "[stopped: the tool call was cancelled.]";
    else if (end.timedOut) {
      text +=
        `[timeout: ${timeout} ms. yuke stopped the process group. Run a smaller command. Raise timeout_ms up to ` +
        `${LONGEST_TIMEOUT}. Set background to true for a server or watcher.]`;
    } else if (end.signal !== undefined) text += `[signal: ${end.signal}]`;
    else text += `[exit code: ${end.code}]`;
    return text;
  },
});

define({
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
    const id = args.id as string;
    const session = sessionOf(context);
    const stopped = await session.stopJob(id);
    if (stopped === undefined) {
      const ids = session.runningJobs();
      throw new Error(
        `The id ${id} does not exist. ${ids.length === 0 ? "Nothing runs." : `The ids are: ${ids.join(", ")}.`}`,
      );
    }
    return `[${id} ${stopped.label}.] Log: ${stopped.log}`;
  },
});

/** `text` with a final line feed. */
function endLine(text: string): string {
  return text.length === 0 || text.endsWith("\n") ? text : `${text}\n`;
}

/** The first line of `command`, at most 60 characters, for a job start. */
function shortCommand(command: string): string {
  const text = command.trim();
  const end = text.indexOf("\n");
  const line = end < 0 ? text : text.slice(0, end);
  return line.length > 60 || end >= 0 ? `${line.slice(0, 57)}...` : line;
}
