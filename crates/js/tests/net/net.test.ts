// The public module `yuke:net` against the test server of `yuke:test`: the bytes both ways, the end, the order of the
// writes, the close, the aborts, and a missing socket.

import { ConnectionError, connect, type UnixConnection } from "yuke:net";
import { assert, equal, listenOnTemporarySocket, rejects, test } from "yuke:test";

/** The bytes of `text` as UTF-8. */
function bytes(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

/** Each chunk of `connection` until the end, as UTF-8 text. */
async function readAll(connection: UnixConnection): Promise<string> {
  const decoder = new TextDecoder();
  let text = "";
  for await (const chunk of connection.readable) text += decoder.decode(chunk, { stream: true });
  return text + decoder.decode();
}

test("a request and its reply cross the socket, the writes keep their order, and the end of the peer ends the stream", async () => {
  using server = listenOnTemporarySocket();
  const path = server.path;
  const accepted = server.accept();
  using client = await connect({ path });
  using peer = await accepted;
  await client.write(bytes("ping\n"));
  const reader = peer.readable.getReader();
  equal(new TextDecoder().decode((await reader.read()).value), "ping\n");
  reader.releaseLock();
  // A second write waits for a first write that fills the buffers of the socket.
  const first = peer.write(new Uint8Array(4 * 1024 * 1024).fill(0x61));
  const tail = bytes("end");
  const second = peer.write(tail);
  // A queued write keeps the bytes of its call.
  tail.fill(0x78);
  const received = readAll(client);
  await Promise.all([first, second]);
  peer.close();
  const text = await received;
  equal([text.length, text.endsWith("aend")], [4 * 1024 * 1024 + 3, true]);
});

test("a close ends the stream, rejects each later write, breaks the pipe of the peer, and a second close does nothing", async () => {
  using server = listenOnTemporarySocket();
  const path = server.path;
  const accepted = server.accept();
  const client = await connect({ path });
  using peer = await accepted;
  const reader = client.readable.getReader();
  const read = reader.read();
  client.close();
  client.close();
  equal(await read, { done: true, value: undefined });
  const error = await rejects(client.write(bytes("late")));
  assert(error instanceof ConnectionError);
  equal([error.code, error.message], ["ERR_CLOSED", "the connection is closed"]);
  // The peer sees the end of the closed connection, and its write fails.
  equal(await readAll(peer), "");
  const broken = await rejects(peer.write(bytes("gone")));
  assert(broken instanceof ConnectionError);
  equal(broken.code, "EPIPE");
});

test("an abort stops an open read and an open write with its reason, and closes the connection", async () => {
  using server = listenOnTemporarySocket();
  const path = server.path;
  const accepted = server.accept();
  const controller = new AbortController();
  using client = await connect({ path, signal: controller.signal });
  using peer = await accepted;
  const read = client.readable.getReader().read();
  // The peer reads one chunk only, so the write of 16 MiB runs and waits for room in the socket.
  const write = client.write(new Uint8Array(16 * 1024 * 1024));
  const reader = peer.readable.getReader();
  await reader.read();
  const reason = new Error("stop");
  controller.abort(reason);
  equal([await rejects(read), await rejects(write)], [reason, reason]);
  equal(await rejects(client.write(bytes("late"))), reason);
  // The peer gets the bytes that crossed before the abort, then the end.
  while (!(await reader.read()).done);
});

test("an aborted signal stops the connect, and an option that is not valid throws a TypeError", async () => {
  using server = listenOnTemporarySocket();
  const path = server.path;
  const reason = new Error("before");
  equal(await rejects(connect({ path, signal: AbortSignal.abort(reason) })), reason);
  const error = await rejects(connect({ path: "relative.sock" }));
  assert(error instanceof TypeError);
});

test("a connect to a removed socket fails with ENOENT and names its path", async () => {
  const server = listenOnTemporarySocket();
  server.close();
  const error = await rejects(connect({ path: server.path }));
  assert(error instanceof ConnectionError);
  equal(error.code, "ENOENT");
  assert(error.message.startsWith(`connect ${server.path}: `), error.message);
});
