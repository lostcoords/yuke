import { net } from "yuke";
import { equal } from "yuke:test";
async function run() {
  const socket = await net.connect({ path: socketPath });
  equal(await socket.read(), null);
  equal(await socket.read(), null);
}
run().then(() => { globalThis.socketDone = true; });
