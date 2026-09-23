import { net, plugins } from "yuke";
import { check, equal } from "yuke:test";

async function refused(promise, code) {
  let error;
  try { await promise; } catch (caught) { error = caught; }
  equal(error?.code, code);
}

async function run() {
  for (const options of [undefined, null, {}, { path: "" }, { path: "x\0y" }, { path: "x".repeat(109) }, { path: socketPath, signal: {} }, { path: socketPath, timeoutMs: 0 }]) {
    await refused(net.connect(options), "INVALID_ARGUMENT");
  }
  await refused(net.connect({ path: socketPath + "-missing" }), "IO_ERROR");
  const socket = await net.connect({ path: socketPath });
  await refused(socket.read({ maxBytes: 0 }), "INVALID_ARGUMENT");
  await refused(socket.read({ maxBytes: 1048577 }), "INVALID_ARGUMENT");
  for (const bytes of [undefined, null, "text", [], new ArrayBuffer(2), new DataView(new ArrayBuffer(2)), new Uint16Array(2), new Uint8ClampedArray(2)]) {
    await refused(socket.write(bytes), "INVALID_ARGUMENT");
  }
  const detached = new Uint8Array(2);
  detached.buffer.transfer();
  await refused(socket.write(detached), "INVALID_ARGUMENT");
  await refused(socket.write(new Uint8Array(1048577)), "INVALID_ARGUMENT");
  const first = socket.read({ maxBytes: 2 });
  await refused(socket.read(), "BUSY");
  const source = new Uint8Array([99, 0, 255, 128, 42, 99]);
  const written = socket.write(source.subarray(1, 5));
  source.fill(7);
  await written;
  const bytes = [...await first];
  while (bytes.length < 4) bytes.push(...await socket.read({ maxBytes: 2 }));
  equal(bytes.join(), "0,255,128,42");
  await socket.write(new Uint8Array());

  const large = new Uint8Array(1048576);
  for (let i = 0; i < 251; i++) large[i] = i;
  for (let filled = 251; filled < large.length;) {
    const copied = Math.min(filled, large.length - filled);
    large.set(large.subarray(0, copied), filled);
    filled += copied;
  }
  let count = 0;
  const consume = (async () => {
    while (count < large.length) {
      const chunk = await socket.read({ maxBytes: 16384 });
      for (let i = 0; i < chunk.length; i++, count++) {
        if (chunk[i] !== count % 251) throw new Error(`Byte ${count}: expected ${count % 251}, got ${chunk[i]}`);
      }
    }
  })();
  const writing = socket.write(large);
  await refused(socket.write(new Uint8Array([1])), "BUSY");
  await writing;
  await consume;
  equal(count, large.length);
  socket.close();
  socket.close();
  await refused(socket.read(), "CLOSED");
  await refused(socket.write(new Uint8Array()), "CLOSED");

  let held;
  const plugin = plugins.use({ name: "socket-owner", async apply(ctx) {
    held = await net.connect({ path: socketPath, signal: ctx.signal });
    ctx.own(() => held.close());
    // Registered last, so it runs first, while the socket is still open.
    ctx.own(async () => {
      check("normal signal is canceled before the release", ctx.signal.aborted);
      await held.write(new Uint8Array([17]), { timeoutMs: 1000 });
      equal((await held.read({ maxBytes: 1, timeoutMs: 1000 }))[0], 17);
    });
  } });
  await plugin.ready;
  socket.close();
  await plugin.dispose();
  await refused(held.read(), "CLOSED");
}
run().then(() => { globalThis.socketDone = true; });
