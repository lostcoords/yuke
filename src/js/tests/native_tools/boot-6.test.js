import { defineTool } from "yuke:tools";
const p = { type: "object", properties: {} };
for (const n of ["zulu", "alpha", "mike"]) {
  defineTool(n, { description: "d", parameters: p, execute: async () => ({ text: n }) });
}
