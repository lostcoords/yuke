import { plugins, spawn, lines } from "yuke";

const env = { PATH: "/usr/bin:/bin" };
// The server prints one line that is not JSON, then answers each request line with a CRLF-ended response.
const SERVER = `echo 'server log line'; while IFS= read -r line; do id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p'); printf '{"jsonrpc":"2.0","id":%s,"result":{"ok":true}}\\r\\n' "$id"; done`;

/** @param {number} ms */
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** @param {string[]} argv @param {number} graceMs */
function connect(argv, graceMs) {
  const child = spawn(argv, { env });
  const waiting = new Map();
  let nextId = 1;
  child.onStdout(lines((line) => {
    let message;
    // The SDK transport skips a line that does not parse.
    try { message = JSON.parse(line); } catch { return; }
    const resolve = waiting.get(message.id);
    if (!resolve) return;
    waiting.delete(message.id);
    resolve(message);
  }));
  child.exited.then(() => {
    for (const resolve of waiting.values()) resolve({ error: { message: "the server exited" } });
    waiting.clear();
  });
  return {
    /** @param {string} method @param {unknown} params */
    async request(method, params) {
      const id = nextId++;
      const answer = new Promise((resolve) => waiting.set(id, resolve));
      await child.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
      return answer;
    },
    // The MCP stdio shutdown: stdin EOF, a wait, then `kill`, which sends TERM and KILL after its grace period.
    async close() {
      child.closeStdin();
      const exited = await Promise.race([child.exited.then(() => true), sleep(graceMs).then(() => false)]);
      if (!exited) child.kill();
      return child.exited;
    },
  };
}

globalThis.proof = { disposeExit: null, termExit: null, killExit: null };

plugins.use({
  name: "mcp-proof",
  apply(ctx) {
    const server = connect(["sh", "-c", SERVER], 100);
    ctx.effect(() => () => { server.close().then((exit) => { proof.disposeExit = exit.code; }); });
    ctx.tools.define({
      name: "mcp_echo",
      description: "Call the proof server.",
      parameters: { type: "object", properties: {} },
      execute: async () => JSON.stringify(await server.request("tools/call", { name: "echo" })),
    });
  },
});

(async () => {
  // A server that ignores stdin EOF ends at TERM.
  proof.termExit = (await connect(["sh", "-c", "while :; do sleep 0.05; done"], 100).close()).signal;
  // A server that also ignores TERM ends at KILL.
  proof.killExit = (await connect(["sh", "-c", "trap '' TERM; while :; do sleep 0.05; done"], 100).close()).signal;
})();
