// The web class `WritableStream`: a minimal default stream with a default writer.

import { assert, assertEquals, assertRejects, test, waitForSettled } from "yuke:test";
import { rejectedName, thrownNames } from "./errors.ts";

test("the sink gets each chunk in order, one at a time, and then the close", async () => {
  const log: string[] = [];
  let running = 0;
  const stream = new WritableStream<string>({
    async write(chunk) {
      running += 1;
      assertEquals(running, 1);
      await Promise.resolve();
      log.push(chunk);
      running -= 1;
    },
    close() {
      log.push("close");
    },
  });
  const writer = stream.getWriter();
  const writes = [writer.write("a"), writer.write("b")];
  await writer.close();
  await Promise.all(writes);
  await writer.closed;
  assertEquals(log, ["a", "b", "close"]);
});

test("ready waits while the queue is full", async () => {
  const pending = Promise.withResolvers<void>();
  const stream = new WritableStream<string>({ write: () => pending.promise }, { highWaterMark: 1 });
  const writer = stream.getWriter();
  assertEquals(writer.desiredSize, 1);
  void writer.write("a");
  assertEquals(writer.desiredSize, 0);
  let ready = false;
  void writer.ready.then(() => {
    ready = true;
  });
  await waitForSettled();
  assertEquals(ready, false);
  pending.resolve();
  await writer.ready;
  assertEquals(writer.desiredSize, 1);
});

test("a write that fails errors the stream and rejects the later writes", async () => {
  const failure = new Error("full");
  const stream = new WritableStream<string>({
    write() {
      throw failure;
    },
  });
  const writer = stream.getWriter();
  const first = writer.write("a");
  const second = writer.write("b");
  assertEquals(await assertRejects(() => first), failure);
  assertEquals(await assertRejects(() => second), failure);
  assertEquals(await assertRejects(() => writer.closed), failure);
  assertEquals(await assertRejects(() => writer.write("c")), failure);
  assertEquals(writer.desiredSize, null);
});

test("an abort waits for the write that runs and then aborts the sink with the reason", async () => {
  const log: unknown[] = [];
  const pending = Promise.withResolvers<void>();
  let signal: AbortSignal | undefined;
  const stream = new WritableStream<string>({
    start(controller) {
      signal = controller.signal;
    },
    async write(chunk) {
      await pending.promise;
      log.push(chunk);
    },
    abort(reason) {
      log.push(reason);
    },
  });
  const writer = stream.getWriter();
  const running = writer.write("a");
  await waitForSettled();
  const queued = writer.write("b");
  const reason = new Error("stop");
  const aborted = writer.abort(reason);
  assertEquals(signal?.aborted, true);
  await waitForSettled();
  assertEquals(log, []);
  pending.resolve();
  await running;
  // The queued write rejects after the write that ran, as the Streams Standard says.
  assertEquals(await assertRejects(() => queued), reason);
  await aborted;
  assertEquals(log, ["a", reason]);
  assertEquals(await assertRejects(() => writer.closed), reason);
});

test("a writer holds the stream until it releases it", async () => {
  const stream = new WritableStream();
  const writer = stream.getWriter();
  assert(stream.locked, "the writer holds the stream");
  assertEquals(thrownNames([() => stream.getWriter(), () => new WritableStreamDefaultWriter(stream)]), [
    "TypeError",
    "TypeError",
  ]);
  assertEquals(await rejectedName(stream.close()), "TypeError");
  assertEquals(await rejectedName(stream.abort()), "TypeError");
  writer.releaseLock();
  assertEquals(await rejectedName(writer.closed), "TypeError");
  assertEquals(await rejectedName(writer.write("a")), "TypeError");
  assert(!stream.locked, "the stream is free");
  await stream.close();
});

test("the controller has no public constructor and a start that rejects errors the stream", async () => {
  assertEquals(
    thrownNames([
      // @ts-expect-error: the constructor is private.
      () => new WritableStreamDefaultController(),
    ]),
    ["TypeError"],
  );
  const failure = new Error("no start");
  const writer = new WritableStream({ start: () => Promise.reject(failure) }).getWriter();
  assertEquals(await assertRejects(() => writer.closed), failure);
});
