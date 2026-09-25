import { defineTool } from "yuke:internal/native/tools";
import { fs } from "yuke:internal/native/fs";
defineTool("read_note", {
  description: "Read the note.",
  parameters: { type: "object", properties: { path: { type: "string", description: "The path to read." } } },
  execute: async ({ path }) => ({ text: await fs.readFile(path) }),
});
