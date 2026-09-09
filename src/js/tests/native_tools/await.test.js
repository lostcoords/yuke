import { defineTool } from "yuke:tools";
import { fs } from "yuke:fs";
defineTool("read_note", {
  description: "Read the note.",
  parameters: { type: "object", properties: { path: { type: "string", description: "The path to read." } } },
  execute: async ({ path }) => ({ text: await fs.readFile(path) }),
});
