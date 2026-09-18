import { check, equal } from "yuke:test";
import { herdr } from "yuke:test-herdr";
import { client, env, events, net, plugins, services, utf8 } from "yuke";
import { Context, Scope, interaction } from "yuke:ext";

const original = { connect: net.connect, get: env.get, busy: client.isBusy, setTimeout, clearTimeout };
const timers = new Map();
let timerId = 0;
globalThis.setTimeout = (fn, ms) => { const id = ++timerId; timers.set(id, { fn, ms }); return id; };
globalThis.clearTimeout = id => timers.delete(id);
const flush = async () => { for (let i = 0; i < 300; i++) await Promise.resolve(); };
async function tick() {
  const due = [...timers.entries()].filter(([, timer]) => timer.ms === 250);
  for (const [id, timer] of due) if (timers.delete(id)) timer.fn();
  await flush();
}
let enabled = true;
let busy = false;
env.get = name => enabled ? { HERDR_ENV: "1", HERDR_SOCKET_PATH: "/test", HERDR_PANE_ID: 'pane"世' }[name] : undefined;
client.isBusy = () => busy;
const requests = [];
let response = request => utf8.encode(JSON.stringify({ id: request.id, result: { type: "ok" } }) + "\n");
let live = 0;
let chunkSize = 1;
let hold;
net.connect = async options => {
  equal(options.timeoutMs, 250);
  live++;
  let closed = false;
  let request;
  let bytes;
  let offset = 0;
  let rejectRead;
  return {
    async write(data, options) {
      request = JSON.parse(utf8.decode(data));
      check("string ID", typeof request.id === "string");
      equal(request.params.source, "custom:yuke");
      equal(request.params.pane_id, 'pane"世');
      check("no sequence or unsupported status field", !("seq" in request.params) && !("custom_status" in request.params));
      if (request.method === "pane.clear_agent_authority") {
        check("cleanup has no canceled signal", !options.signal);
        equal(Object.keys(request.params).sort().join(), "pane_id,source");
      }
      requests.push(request);
      bytes = response(request);
    },
    async read() {
      if (bytes === null) {
        bytes = new Uint8Array(0);
        return await new Promise((resolve, reject) => { hold = resolve; rejectRead = reject; });
      }
      if (offset === bytes.length) return null;
      // One-byte reads split multibyte text and force repeated reads under one deadline.
      const start = offset;
      offset = Math.min(bytes.length, offset + chunkSize);
      return bytes.subarray(start, offset);
    },
    close() {
      if (closed) return;
      closed = true;
      live--;
      rejectRead?.(new Error("closed"));
    },
  };
};

async function run() {
  let handle = plugins.use(herdr());
  await handle.dispose();
  equal(requests.length, 0);
  const tui = services.provide("tui", {});
  enabled = false;
  handle = plugins.use(herdr());
  await handle.dispose();
  equal(requests.length, 0);
  enabled = true;

  response = () => null;
  handle = plugins.use(herdr());
  await flush();
  equal(requests.at(-1).params.state, "idle");
  busy = true;
  events.emit("engine.activity.changed");
  const requester = new Context(new Scope("herdr-question"), "herdr-question");
  let answer;
  const uninstall = interaction.install({ interactive: true, notify() {}, open(request, ctx, options, resolve) { answer = resolve; return () => {}; } });
  const pending = requester.interaction.confirm("Continue?");
  const firstId = requests.at(-1).id;
  response = request => utf8.encode(JSON.stringify({ id: request.id, result: { type: "ok", message: "世😀" } }) + "\n");
  hold(utf8.encode(JSON.stringify({ id: firstId, result: { type: "ok" } }) + "\n"));
  await flush();
  equal(requests.at(-1).params.state, "blocked");
  equal(requests.length, 2);
  answer(true);
  await pending;
  await flush();
  equal(requests.at(-1).params.state, "working");
  busy = false;
  events.emit("engine.activity.changed");
  await flush();
  equal(requests.at(-1).params.state, "idle");
  const count = requests.length;
  events.emit("engine.activity.changed");
  await flush();
  equal(requests.length, count);
  uninstall();
  requester.scope.dispose();
  await handle.dispose();
  equal(requests.at(-1).method, "pane.clear_agent_authority");
  equal(live, 0);
  equal(timers.size, 0);

  chunkSize = 4097;
  for (const invalid of [
    () => '{"id":"wrong","result":{"type":"ok"}}\n',
    request => JSON.stringify({ id: request.id, error: { code: "missing", message: "no pane" } }) + "\n",
    request => JSON.stringify({ id: request.id, result: { type: "ok" }, error: null }) + "\n",
    () => '{]\n',
    () => 'null\n',
    () => '7\n',
    request => JSON.stringify({ id: request.id, result: { type: "ok" } }) + '\n{}\n',
    () => 'x'.repeat(4097),
    () => '{"id":',
    () => new Uint8Array([255, 10]),
  ]) {
    const start = requests.length;
    response = request => { const value = invalid(request); return typeof value === "string" ? utf8.encode(value) : value; };
    handle = plugins.use(herdr());
    await flush();
    await tick();
    await flush();
    await tick();
    await flush();
    equal(requests.length - start, 3);
    equal(timers.size, 0);
    events.emit("engine.activity.changed");
    await flush();
    equal(requests.length - start, 3);
    await handle.dispose();
    equal(live, 0);
    equal(timers.size, 0);
  }

  // Trailing bytes also reject when the next read follows a complete response.
  chunkSize = 1;
  response = request => utf8.encode(JSON.stringify({ id: request.id, result: { type: "ok" } }) + "\n{}\n");
  const beforeTrailing = requests.length;
  handle = plugins.use(herdr());
  await flush();
  await tick();
  await tick();
  equal(requests.length - beforeTrailing, 3);
  equal(timers.size, 0);
  await handle.dispose();
  equal(live, 0);
  chunkSize = 4097;

  // A new state can retry after the previous state's retry budget is exhausted.
  let connects = 0;
  const connect = net.connect;
  net.connect = async () => { connects++; throw new Error("unavailable"); };
  handle = plugins.use(herdr());
  await flush();
  await tick();
  await tick();
  equal(connects, 3);
  busy = true;
  events.emit("engine.activity.changed");
  await flush();
  equal(connects, 4);
  await handle.dispose();
  equal(connects, 5);
  equal(timers.size, 0);
  net.connect = connect;
  busy = false;

  // A complete frame at the limit succeeds, and stop cancels a live read.
  response = request => utf8.encode((JSON.stringify({ id: request.id, result: { type: "ok" } })).padEnd(4096) + "\n");
  handle = plugins.use(herdr());
  await flush();
  equal(timers.size, 0);
  response = () => null;
  busy = true;
  events.emit("engine.activity.changed");
  await flush();
  equal(live, 1);
  response = request => utf8.encode(JSON.stringify({ id: request.id, result: { type: "ok" } }) + "\n");
  await handle.dispose();
  equal(live, 0);
  equal(timers.size, 0);
  busy = false;

  response = () => null;
  handle = plugins.use(herdr());
  await flush();
  await tick();
  equal(live, 0);
  const stopped = handle.dispose();
  await flush();
  equal(requests.at(-1).method, "pane.clear_agent_authority");
  await tick();
  await stopped;
  equal(live, 0);
  equal(timers.size, 0);
  tui();
}
async function main() {
  try { await run(); } finally {
    net.connect = original.connect;
    env.get = original.get;
    client.isBusy = original.busy;
    globalThis.setTimeout = original.setTimeout;
    globalThis.clearTimeout = original.clearTimeout;
  }
  globalThis.herdrDone = true;
}
main();
