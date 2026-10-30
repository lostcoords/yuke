// The web class `ReadableStream`: a minimal default stream. Many cases follow the web platform tests (WPT) of
// `streams/readable-streams`.

import { assert, equal, rejects, test } from "yuke:test";
import { rejectedName, thrownNames } from "./errors.ts";

/** Wait for one timer turn, so the earlier promise reactions and faults run first. */
function tick(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

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
  equal(stream.locked, true);
  equal(reads, [
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
  await tick();
  const first = pulls;
  const reader = stream.getReader();
  const reads = [reader.read(), reader.read()];
  await tick();
  const waiting = pulls;
  finish();
  await tick();
  finish();
  const values = (await Promise.all(reads)).map((read) => read.value);
  await tick();
  // A third pull starts after the two reads take their chunks, because the queue has space again.
  equal([first, waiting, values, pulls], [1, 1, [1, 2], 3]);
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
  await tick();
  const before = pulls;
  const read = await stream.getReader().read();
  await tick();
  equal([before, read.value, pulls], [0, 1, 1]);
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
  equal(seen, [1, 2, false, 3, ["cancel", undefined], false, 5, 6]);
});

test("an iterator holds the stream at once and a break releases it before the cancel ends", async () => {
  let finish = (): void => {};
  const stream = new ReadableStream<number>({
    start(controller) {
      controller.enqueue(1);
    },
    cancel() {
      return new Promise<void>((resolve) => {
        finish = resolve;
      });
    },
  });
  const iterator = stream.values();
  equal(
    [stream.locked, thrownNames([() => stream.values(), () => stream.getReader()])],
    [true, ["TypeError", "TypeError"]],
  );
  equal((await iterator.next()).value, 1);
  const returned = iterator.return?.();
  await tick();
  const lockedDuringCancel = stream.locked;
  finish();
  await returned;
  equal(lockedDuringCancel, false);
});

test("async iteration releases the stream after a read or cancel fails", async () => {
  const failedRead = controlled<number>();
  const next = failedRead.stream.values().next();
  equal(failedRead.stream.locked, true);
  failedRead.controller.error("read failed");
  equal(await rejects(next), "read failed");
  equal(failedRead.stream.locked, false);

  const failedCancel = new ReadableStream<number>({
    start(controller) {
      controller.enqueue(1);
    },
    cancel() {
      throw "cancel failed";
    },
  });
  equal(
    await rejects(
      (async () => {
        for await (const chunk of failedCancel) {
          equal(chunk, 1);
          break;
        }
      })(),
    ),
    "cancel failed",
  );
  equal(failedCancel.locked, false);
});

test("an error rejects each waiting read and the closed promise without a fault", async () => {
  const errored = controlled<string>();
  const reader = errored.stream.getReader();
  const read = rejects(reader.read());
  errored.controller.error("boom");
  equal(await read, "boom");
  equal(await rejects(reader.closed), "boom");
  equal(await rejects(reader.read()), "boom");
  equal(errored.controller.desiredSize, null);
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
  await tick();
  equal(await rejects(failedStart.getReader().read()), "start");
  equal(await rejects(failedPull.getReader().read()), "pull");
  await tick();
});

test("a cancel calls the source once and ends each waiting read", async () => {
  const seen: unknown[] = [];
  const stream = new ReadableStream({
    cancel(reason) {
      seen.push(["cancel", reason]);
    },
  });
  equal(await stream.getReader().cancel("first"), undefined);
  const reader = new ReadableStream({
    cancel(reason) {
      seen.push(["cancel", reason]);
    },
  }).getReader();
  const read = reader.read();
  await reader.cancel("second");
  seen.push((await read).done);
  await reader.cancel("third");
  equal(await new ReadableStream().getReader().cancel(), undefined);
  const locked = new ReadableStream();
  locked.getReader();
  equal(await rejectedName(locked.cancel()), "TypeError");
  await tick();
  equal(seen, [["cancel", "first"], ["cancel", "second"], true]);
});

test("releaseLock rejects each waiting read and keeps the queued chunks", async () => {
  const stream = new ReadableStream();
  const reader = stream.getReader();
  const read = rejectedName(reader.read());
  reader.releaseLock();
  equal(await read, "TypeError");
  equal(await rejectedName(reader.closed), "TypeError");
  equal(await rejectedName(reader.read()), "TypeError");
  equal(stream.locked, false);
  reader.releaseLock();
  const queued = new ReadableStream<string>({
    start(controller) {
      controller.enqueue("kept");
    },
  });
  queued.getReader().releaseLock();
  equal((await queued.getReader().read()).value, "kept");
  await tick();
});

test("enqueue counts the size of each chunk against the high water mark", () => {
  const counted = controlled<string>({ highWaterMark: 5, size: (chunk) => chunk.length });
  const sizes = [counted.controller.desiredSize];
  counted.controller.enqueue("abc");
  sizes.push(counted.controller.desiredSize);
  const failing = controlled<string>({ size: () => -1 });
  const thrown = thrownNames([() => failing.controller.enqueue("x")]);
  // @ts-expect-error: a size is a number.
  const big = controlled<string>({ size: () => 1n });
  let thisValue: unknown = "unset";
  const measured = controlled<string>({
    size(this: unknown) {
      thisValue = this;
      return 1;
    },
  });
  measured.controller.enqueue("x");
  counted.controller.close();
  sizes.push(counted.controller.desiredSize);
  equal(sizes, [5, 2, 2]);
  equal(thrown, ["RangeError"]);
  equal(failing.controller.desiredSize, null);
  equal(thrownNames([() => counted.controller.enqueue("x"), () => counted.controller.close()]), [
    "TypeError",
    "TypeError",
  ]);
  equal(thrownNames([() => big.controller.enqueue("x")]), ["TypeError"]);
  equal(thisValue, undefined);
});

test("the constructors refuse byte streams, bad strategies, and a locked stream", () => {
  const locked = new ReadableStream();
  locked.getReader();
  equal(
    thrownNames([
      // @ts-expect-error: yuke has no byte streams.
      () => new ReadableStream({ type: "bytes" }),
      // @ts-expect-error: a type is `undefined`.
      () => new ReadableStream({ type: "other" }),
      // @ts-expect-error: a pull is a function.
      () => new ReadableStream({ pull: 1 }),
      () => new ReadableStream({}, { highWaterMark: -1 }),
      () => new ReadableStream({}, { highWaterMark: Number.NaN }),
      // @ts-expect-error: a size is a function.
      () => new ReadableStream({}, { size: 1 }),
      // @ts-expect-error: a size is a function.
      () => new ReadableStream({}, { highWaterMark: -1, size: 1 }),
      // @ts-expect-error: a high water mark is a number.
      () => new ReadableStream({}, { highWaterMark: 1n }),
      // @ts-expect-error: yuke has no byte streams.
      () => new ReadableStream({ type: "bytes" }, { highWaterMark: -1 }),
      // @ts-expect-error: a source is an object.
      () => new ReadableStream(null),
      () =>
        new ReadableStream({
          start() {
            throw new SyntaxError("x");
          },
        }),
      // @ts-expect-error: yuke has no BYOB reader.
      () => new ReadableStream().getReader({ mode: "byob" }),
      () => locked.getReader(),
      () => new ReadableStreamDefaultReader(locked),
      // @ts-expect-error: a controller has no public constructor.
      () => new ReadableStreamDefaultController(),
      // @ts-expect-error: a reader takes a stream.
      () => new ReadableStreamDefaultReader(),
    ]),
    [
      "TypeError",
      "TypeError",
      "TypeError",
      "RangeError",
      "RangeError",
      "TypeError",
      "TypeError",
      "TypeError",
      "TypeError",
      "TypeError",
      "SyntaxError",
      "TypeError",
      "TypeError",
      "TypeError",
      "TypeError",
      "TypeError",
    ],
  );
});

test("each class names itself and the async iterator is values", () => {
  const opened = controlled();
  equal(
    [opened.stream, opened.stream.getReader(), opened.controller].map((value) => Object.prototype.toString.call(value)),
    ["[object ReadableStream]", "[object ReadableStreamDefaultReader]", "[object ReadableStreamDefaultController]"],
  );
  assert(ReadableStream.prototype[Symbol.asyncIterator] === ReadableStream.prototype.values);
  assert(Object.keys(ReadableStream.prototype).includes("values"));
  equal(Object.prototype.toString.call(new ReadableStream().values()), "[object AsyncGenerator]");
});
