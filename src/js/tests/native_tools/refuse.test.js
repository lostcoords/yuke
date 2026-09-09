import { check } from "yuke:test";
import { defineTool } from "yuke:tools";
const refused = (name, fn) => {
  try { fn(); check(name, false); } catch (e) { check(name, e instanceof TypeError); }
};
const ok = { description: "d", parameters: { type: "object", properties: {} }, execute: () => 1 };
refused("no-definition", () => defineTool("probe"));
refused("name-not-string", () => defineTool(7, ok));
refused("name-has-a-space", () => defineTool("get weather", ok));
refused("name-too-long", () => defineTool("x".repeat(65), ok));
refused("no-description", () => defineTool("probe", { ...ok, description: undefined }));
refused("empty-description", () => defineTool("probe", { ...ok, description: "" }));
refused("schema-not-object", () => defineTool("probe", { ...ok, parameters: "{}" }));
refused("schema-wrong-type", () => defineTool("probe", { ...ok, parameters: { type: "array", properties: {} } }));
refused("schema-no-properties", () => defineTool("probe", { ...ok, parameters: { type: "object" } }));
refused("execute-not-a-function", () => defineTool("probe", { ...ok, execute: 5 }));

defineTool("probe", ok);
refused("duplicate-name", () => defineTool("probe", ok));
