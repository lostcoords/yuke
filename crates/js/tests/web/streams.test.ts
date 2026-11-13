// The web class `ReadableStream`: a minimal default stream. Many cases follow the web platform tests (WPT) of
// `streams/readable-streams`.

import { assert, assertEquals, assertRejects, test, waitForSettled } from "yuke:test";
import { rejectedName, thrownNames } from "./errors.ts";

/** A stream with `strategy`, and the controller that its source gets at the start. */
function controlled<T>(strategy?: QueuingStrategy<T>): {
  stream: ReadableStream<T>;
  controller: ReadableStreamDefaultController<T>;
} {
  const started: ReadableStreamDefaultController<T>[] = [];
  const stream = new ReadableStream<T>(
    {
      start(controller) {
        started.push(controller);
      },
    },
    strategy,
  );
  const controller = started[0];
  assert(controller !== undefined, "the start runs in the constructor");
  return { stream, controller };
}

test("a reader gives the queued chunks and then done", async () => {
  const stream = new ReadableStream<string>({
    start(controller) {
      controller.enqueue("a");
      controller.enqueue("b");
      controller.close();
    },
  });
  const reader = stream.getReader();
  const reads = [await reader.read(), await reader.read(), await reader.read(), await reader.read()];
  await reader.closed;
  assertEquals(stream.locked, true);
  assertEquals(reads, [
    { done: false, value: "a" },
    { done: false, value: "b" },
    { done: true, value: undefined },
    { done: true, value: undefined },
  ]);
});

test("pull fills the queue up to the high water mark and runs once at a time", async () => {
  let pulls = 0;
  let finish = (): void => {
    throw new Error("no pull waits");
  };
  const stream = new ReadableStream<number>(
    {
      pull(controller) {
        pulls++;
        return new Promise<void>((resolve) => {
          finish = () => {
            controller.enqueue(pulls);
            resolve();
          };
        });
      },
    },
    { highWaterMark: 2 },
  );
  await waitForSettled();
  const first = pulls;
  const reader = stream.getReader();
  const reads = [reader.read(), reader.read()];
  await waitForSettled();
  const waiting = pulls;
  finish();
  await waitForSettled();
  finish();
  const values = (await Promise.all(reads)).map((read) => read.value);
  await waitForSettled();
  // A third pull starts after the two reads take their chunks, because the queue has space again.
  assertEquals([first, waiting, values, pulls], [1, 1, [1, 2], 3]);
});

test("a high water mark of zero pulls only for a read", async () => {
  let pulls = 0;
  const stream = new ReadableStream<number>(
    {
      pull(controller) {
        controller.enqueue(++pulls);
      },
    },
    { highWaterMark: 0 },
  );
  await waitForSettled();
  const before = pulls;
  const read = await stream.getReader().read();
  await waitForSettled();
  assertEquals([before, read.value, pulls], [0, 1, 1]);
});

test("async iteration gives each chunk and a break cancels the stream", async () => {
  const seen: unknown[] = [];
  const source = (chunks: number[]): UnderlyingDefaultSource<number> => ({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk);
    },
    cancel(reason) {
      seen.push(["cancel", reason]);
    },
  });
  const all = new ReadableStream<number>({
    start(controller) {
      controller.enqueue(1);
      controller.enqueue(2);
      controller.close();
    },
  });
  for await (const chunk of all) seen.push(chunk);
  seen.push(all.locked);
  const broken = new ReadableStream(source([3, 4]));
  for await (const chunk of broken) {
    seen.push(chunk);
    break;
  }
  seen.push(broken.locked);
  const kept = new ReadableStream(source([5, 6]));
  for await (const chunk of kept.values({ preventCancel: true })) {
    seen.push(chunk);
    break;
  }
  seen.push((await kept.getReader().read()).value);
  assertEquals(seen, [1, 2, false, 3, ["cancel", undefined], false, 5, 6]);
});

test("async iteration releases the stream after a read or cancel fails", async () => {
  const failedRead = controlled<number>();
  const next = failedRead.stream.values().next();
  assertEquals(failedRead.stream.locked, true);
  failedRead.controller.error("read failed");
  assertEquals(await assertRejects(() => next), "read failed");
  assertEquals(failedRead.stream.locked, false);

  const failedCancel = new ReadableStream<number>({
    start(controller) {
      controller.enqueue(1);
    },
    cancel() {
      throw "cancel failed";
    },
  });
  assertEquals(
    await assertRejects(() =>
      (async () => {
        for await (const chunk of failedCancel) {
          assertEquals(chunk, 1);
          break;
        }
      })(),
    ),
    "cancel failed",
  );
  assertEquals(failedCancel.locked, false);
});

test("an error rejects each waiting read and the closed promise without a fault", async () => {
  const errored = controlled<string>();
  const reader = errored.stream.getReader();
  const read = assertRejects(() => reader.read());
  errored.controller.error("boom");
  assertEquals(await read, "boom");
  assertEquals(await assertRejects(() => reader.closed), "boom");
  assertEquals(await assertRejects(() => reader.read()), "boom");
  assertEquals(errored.controller.desiredSize, null);
  // The closed promise of a reader of an errored stream rejects, and no one reads it.
  new ReadableStream({
    start(controller) {
      controller.error("quiet");
    },
  }).getReader();
  const failedStart = new ReadableStream({
    start() {
      return Promise.reject("start");
    },
  });
  const failedPull = new ReadableStream({
    pull() {
      throw "pull";
    },
  });
  await waitForSettled();
  assertEquals(await assertRejects(() => failedStart.getReader().read()), "start");
  assertEquals(await assertRejects(() => failedPull.getReader().read()), "pull");
  await waitForSettled();
});

test("a cancel calls the source once and ends each waiting read", async () => {
  const seen: unknown[] = [];
  const stream = new ReadableStream({
    cancel(reason) {
      seen.push(["cancel", reason]);
    },
  });
  assertEquals(await stream.getReader().cancel("first"), undefined);
  const reader = new ReadableStream({
    cancel(reason) {
      seen.push(["cancel", reason]);
    },
  }).getReader();
  const read = reader.read();
  await reader.cancel("second");
  seen.push((await read).done);
  await reader.cancel("third");
  assertEquals(await new ReadableStream().getReader().cancel(), undefined);
  const locked = new ReadableStream();
  locked.getReader();
  assertEquals(await rejectedName(locked.cancel()), "TypeError");
  await waitForSettled();
  assertEquals(seen, [["cancel", "first"], ["cancel", "second"], true]);
});

test("releaseLock rejects each waiting read and keeps the queued chunks", async () => {
  const stream = new ReadableStream();
  const reader = stream.getReader();
  const read = rejectedName(reader.read());
  reader.releaseLock();
  assertEquals(await read, "TypeError");
  assertEquals(await rejectedName(reader.closed), "TypeError");
  assertEquals(await rejectedName(reader.read()), "TypeError");
  assertEquals(stream.locked, false);
  reader.releaseLock();
  const queued = new ReadableStream<string>({
    start(controller) {
      controller.enqueue("kept");
    },
  });
  queued.getReader().releaseLock();
  assertEquals((await queued.getReader().read()).value, "kept");
  await waitForSettled();
});

test("enqueue counts the size of each chunk against the high water mark", () => {
  const counted = controlled<string>({ highWaterMark: 5, size: (chunk) => chunk.length });
  const sizes = [counted.controller.desiredSize];
  counted.controller.enqueue("abc");
  sizes.push(counted.controller.desiredSize);
  const failing = controlled<string>({ size: () => -1 });
  const thrown = thrownNames([() => failing.controller.enqueue("x")]);
  assertEquals(sizes, [5, 2]);
  assertEquals(thrown, ["RangeError"]);
  assertEquals(failing.controller.desiredSize, null);
});

test("a throwing start throws from the constructor, and a locked stream refuses a reader", () => {
  const locked = new ReadableStream();
  locked.getReader();
  assertEquals(
    thrownNames([
      () =>
        new ReadableStream({
          start() {
            throw new SyntaxError("x");
          },
        }),
      () => locked.getReader(),
    ]),
    ["SyntaxError", "TypeError"],
  );
});
