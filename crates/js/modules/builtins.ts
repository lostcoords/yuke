import { readLines, readText, writeText } from "yuke:internal/native/fs";
import { define, OUTPUT_BYTES } from "yuke:tools";

/** The largest line number. */
const LAST_LINE = 4_294_967_295;

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
