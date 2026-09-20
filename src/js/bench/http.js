import { fetch } from "yuke";

let steps = 0, count = 1, fresh = false;
const options = { timeoutMs: 5000 };

/** @param {string} name @param {number} scale */
async function start(name, scale) {
  count = scale;
  fresh = name === "http_fresh";
  await step();
  await step();
  steps = 0;
  return 1;
}

async function request() {
  const response = await fetch(HTTP_URL, fresh ? { ...options } : options);
  if (response.status !== 200 || (await response.json()).ok !== true) throw new Error("HTTP response mismatch");
}

async function step() {
  if (count === 1) await request();
  else await Promise.all(Array.from({ length: count }, request));
  return ++steps;
}

function verify() {
  if (steps < 1) throw new Error("no HTTP steps");
  return steps;
}

globalThis.bench = { start, step, verify };
