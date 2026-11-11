// The listeners of the public module `yuke:net`: the bytes both ways, several clients, the close, the abort, the socket
// file, and the failures. src/tests/network.rs holds the shutdown of the runtime and the failed removal.

import * as fs from "yuke:fs";
import { ConnectionError, connect, listen, type UnixConnection } from "yuke:net";
import { assert, equal, rejects, test, listenOnTemporarySocket as testServer, throws, waitForSettled } from "yuke:test";

/** A new short socket path with no file. The scratch folder of a test can be too long for a socket. */
function freePath(): string {
  using server = testServer();
  return server.path;
}

/** The next chunk of `connection`, as UTF-8 text. */
async function readChunk(connection: UnixConnection): Promise<string> {
  const reader = connection.readable.getReader();
  const { value } = await reader.read();
  reader.releaseLock();
  return new TextDecoder().decode(value);
}

/** Write `text` to `connection`. */
function send(connection: UnixConnection, text: string): Promise<void> {
  return connection.write(new TextEncoder().encode(text));
}

/** The code of the `FileSystemError` of a stat of `path`, or `found`. */
function fileAt(path: string): Promise<string | undefined> {
  return fs.lstat(path).then(
    () => "found",
    (error: fs.FileSystemError) => error.code,
  );
}

test("a connection of a listener exchanges bytes both ways, also after the listener closes", async () => {
  const path = freePath();
  const listener = listen({ path });
  const accepted = listener.accept();
  using client = await connect({ path });
  using peer = await accepted;
  const exchange = async () => {
    await send(client, "ping");
    equal(await readChunk(peer), "ping");
    await send(peer, "pong");
    equal(await readChunk(client), "pong");
  };
  await exchange();
  listener.close();
  await exchange();
});

test("two pending accepts each get a client", async () => {
  const path = freePath();
  using listener = listen({ path });
  const pending = [listener.accept(), listener.accept()] as const;
  // Both native accepts wait before the first client comes, so each one must wake.
  await waitForSettled();
  using one = await connect({ path });
  using two = await connect({ path });
  using left = await pending[0];
  using right = await pending[1];
  await send(one, "one");
  await send(two, "two");
  equal([await readChunk(left), await readChunk(right)].sort(), ["one", "two"]);
});

test("a close rejects each pending and later accept and removes the file, and a second close does nothing", async () => {
  const path = freePath();
  const listener = listen({ path });
  equal(await fileAt(path), "found");
  const pending = [listener.accept(), listener.accept()];
  // The native accepts start to wait, so the close must stop them.
  await waitForSettled();
  listener.close();
  listener.close();
  for (const accept of [...pending, listener.accept()]) {
    const reason = await rejects(accept);
    assert(reason instanceof ConnectionError);
    equal([reason.code, reason.message], ["ERR_CLOSED", "the listener is closed"]);
  }
  equal(await fileAt(path), "ENOENT");
});

test("an abort rejects each accept, closes an accepted connection with its reason, and removes the file", async () => {
  const path = freePath();
  const controller = new AbortController();
  using listener = listen({ path, signal: controller.signal });
  const accepted = listener.accept();
  using client = await connect({ path });
  using peer = await accepted;
  const pending = listener.accept();
  const read = peer.readable.getReader().read();
  // The native accept and read start to wait, so the abort must stop them.
  await waitForSettled();
  const reason = new Error("stop");
  controller.abort(reason);
  for (const stopped of [pending, read, listener.accept()]) assert((await rejects(stopped)) === reason);
  equal(await fileAt(path), "ENOENT");
  equal((await client.readable.getReader().read()).done, true);
});

test("an aborted signal throws its reason and creates no file", async () => {
  const path = freePath();
  const reason = new Error("before");
  assert(throws(() => listen({ path, signal: AbortSignal.abort(reason) })) === reason);
  equal(await fileAt(path), "ENOENT");
});

test("a listen at an occupied path fails with EADDRINUSE and leaves the path as it is", async () => {
  const path = freePath();
  await fs.writeTextFile(path, "kept");
  const error = throws(() => listen({ path }));
  assert(error instanceof ConnectionError);
  equal(error.code, "EADDRINUSE");
  equal(await fs.readTextFile(path), "kept");
  await fs.remove(path);
});

test("a close succeeds when another owner already removed the socket file", async () => {
  const path = freePath();
  const listener = listen({ path });
  await fs.remove(path);
  listener.close();
});

test("a relative path throws a TypeError, and a failed bind throws a ConnectionError", () => {
  const path = freePath();
  assert(throws(() => listen({ path: "relative.sock" })) instanceof TypeError);
  const missing = `${path}/a`;
  const noFolder = throws(() => listen({ path: missing }));
  assert(noFolder instanceof ConnectionError);
  equal(noFolder.code, "ENOENT");
  assert(noFolder.message.startsWith(`listen ${missing}: `), noFolder.message);
});
