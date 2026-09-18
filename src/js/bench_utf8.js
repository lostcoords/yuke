import { utf8 } from "yuke";

const text = "abc世界😀".repeat(256);
const bytes = utf8.encode(text);
let fresh = false, steps = 0;

/** @param {string} phase */
function start(phase) {
  fresh = phase === "utf8_fresh";
  step();
  steps = 0;
  return bytes.length;
}

function step() {
  const input = fresh ? new Uint8Array(bytes) : bytes;
  const decoded = utf8.decode(input);
  const encoded = utf8.encode(fresh ? decoded : text);
  if (decoded !== text || encoded.length !== bytes.length || encoded[encoded.length - 1] !== bytes[bytes.length - 1]) throw Error("UTF-8 conversion mismatch");
  steps++;
  return bytes.length;
}

function verify() { return steps; }
globalThis.bench = { start, step, verify };
