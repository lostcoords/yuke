import { toolResult } from "yuke:mcp";

let wire = "", fresh = false, steps = 0, length = 0;
/** @type {any} */
let result;

/** @param {string} phase @param {number} scale */
function start(phase, scale) {
  fresh = phase === "mcp_result_fresh";
  length = scale * 1024;
  wire = JSON.stringify({ content: [{ type: "text", text: "x".repeat(length) }] });
  result = JSON.parse(wire);
  step();
  steps = 0;
  return length;
}

function step() {
  const text = toolResult(fresh ? JSON.parse(wire) : result);
  if (length <= 100000 && text.length !== length) throw Error("MCP result mismatch");
  steps++;
  return text.length;
}

function verify() { return steps; }
globalThis.bench = { start, step, verify };
