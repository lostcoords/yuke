import { equal } from "yuke:test";
import { herdr } from "yuke:test-herdr";
import { env, net, plugins, services, utf8 } from "yuke";

const original = { get: env.get, connect: net.connect };
const requests = [];
let closes = 0;
let firstClosed;
const firstClose = new Promise(resolve => { firstClosed = resolve; });
env.get = name => ({ HERDR_ENV: "1", HERDR_SOCKET_PATH: socketPath, HERDR_PANE_ID: "w1:p1" })[name];
net.connect = async options => {
  const socket = await original.connect(options);
  const write = socket.write;
  const close = socket.close;
  let closed = false;
  socket.write = (bytes, options) => { requests.push(JSON.parse(utf8.decode(bytes))); return write(bytes, options); };
  socket.close = () => { if (!closed) { closed = true; closes++; firstClosed(); } close(); };
  return socket;
};
async function run() {
  const off = services.provide("tui", {});
  try {
    const handle = plugins.use(herdr());
    await firstClose;
    if (socketPeerMode === "herdr") {
      // A rejected success response would trigger a retry within this interval.
      await new Promise(resolve => setTimeout(resolve, 300));
      equal(requests.length, 1);
    }
    await handle.dispose();
    equal(requests[0].method, "pane.report_agent");
    equal(requests.at(-1).method, "pane.clear_agent_authority");
    equal(requests.length, 2);
    equal(closes, 2);
  } finally {
    off();
    env.get = original.get;
    net.connect = original.connect;
  }
  globalThis.socketDone = true;
}
run();
