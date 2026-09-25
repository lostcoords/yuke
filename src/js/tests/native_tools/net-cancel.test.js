import { net, plugins } from "yuke";
import { equal } from "yuke:internal/test";
import * as cancellation from "yuke:internal/native/cancellation";

async function refused(promise, code) {
  let error;
  try { await promise; } catch (caught) { error = caught; }
  equal(error?.code, code);
}

async function run() {
  const prior = cancellation.create();
  cancellation.cancel(prior);
  await refused(net.connect({ path: socketPath, signal: prior }), "CANCELED");
  const during = cancellation.create();
  const connecting = net.connect({ path: socketPath, signal: during });
  cancellation.cancel(during);
  await refused(connecting, "CANCELED");
  await cancellation.drain(during);
  const socket = await net.connect({ path: socketPath });
  const read = refused(socket.read({ timeoutMs: 20 }), "TIMED_OUT");
  const write = refused(socket.write(new Uint8Array(1048576)), "CANCELED");
  await Promise.all([read, write]);
  await refused(socket.read(), "CLOSED");

  const blockedWrite = await net.connect({ path: socketPath });
  await refused(blockedWrite.write(new Uint8Array(1048576), { timeoutMs: 20 }), "TIMED_OUT");
  await refused(blockedWrite.read(), "CLOSED");

  const manual = await net.connect({ path: socketPath });
  const pending = refused(manual.read(), "CANCELED");
  manual.close();
  await pending;

  const aborted = await net.connect({ path: socketPath });
  await refused(aborted.read({ signal: prior }), "CANCELED");
  await refused(aborted.read(), "CLOSED");

  let signal;
  let readCanceled;
  const plugin = plugins.use({ name: "socket-cancel", async apply(ctx) {
    signal = ctx.signal;
    const socket = await net.connect({ path: socketPath, signal });
    ctx.own(() => socket.close());
    readCanceled = refused(socket.read({ signal }), "CANCELED");
  } });
  await plugin.ready;
  await plugin.dispose();
  await readCanceled;
  await cancellation.drain(signal);

  const sockets = [];
  for (let i = 0; i < 64; i++) sockets.push(await net.connect({ path: socketPath }));
  await refused(net.connect({ path: socketPath }), "LIMIT");
  for (const socket of sockets) socket.close();
  globalThis.socketCleanupReady = true;
  await new Promise(resolve => { globalThis.resumeSocketTest = resolve; });
  const reused = await net.connect({ path: socketPath });
  reused.close();

  globalThis.unowned = await net.connect({ path: socketPath });
  unowned.read({ timeoutMs: 600000 }).catch(error => { equal(error.code, "CANCELED"); });
  unowned.write(new Uint8Array(1048576), { timeoutMs: 600000 }).catch(error => { equal(error.code, "CANCELED"); });
}
run().then(() => { globalThis.socketDone = true; });
