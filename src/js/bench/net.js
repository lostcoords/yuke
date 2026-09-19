import { net } from "yuke:net";

let fresh = false, steps = 0;
let bytes = new Uint8Array();
/** @type {import("../app/net.js").Socket | undefined} */
let connection;

/** @param {string} name @param {number} scale */
async function start(name, scale) {
  connection?.close();
  connection = undefined;
  fresh = name === "net_echo_fresh";
  bytes = new Uint8Array(4096 * scale).fill(97);
  if (!fresh) connection = await net.connect({ path: SOCKET_PATH });
  await step();
  await step();
  steps = 0;
  return 1;
}

async function step() {
  const socket = connection ?? await net.connect({ path: SOCKET_PATH });
  const sent = socket.write(bytes);
  let received = 0;
  while (received < bytes.length) {
    const chunk = await socket.read({ maxBytes: bytes.length });
    if (!chunk) throw Error("early socket EOF");
    for (const byte of chunk) if (byte !== 97) throw Error("socket byte mismatch");
    received += chunk.length;
  }
  await sent;
  if (received !== bytes.length) throw Error("socket byte count");
  if (fresh) socket.close();
  return ++steps;
}

function verify() {
  if (steps < 1) throw Error("no socket steps");
  return steps;
}
globalThis.bench = { start, step, verify };
