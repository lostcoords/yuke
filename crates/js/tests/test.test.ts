// The assertions of the public module `yuke:test`.

import { readDir, writeTextFile } from "yuke:fs";
import { assert, createHost, equal, folder, rejects, test, throws } from "yuke:test";

/** The message of the failure of `check`. */
function failure(check: () => void): string {
  const error = throws(check);
  assert(error instanceof Error, "the check throws an Error");
  return error.message;
}

test("equal compares deeply and strictly", () => {
  equal({ a: [1, { b: NaN }], c: "x" }, { a: [1, { b: NaN }], c: "x" });
  equal(new Map([[1, { a: 1 }]]), new Map([[1, { a: 1 }]]));
  equal(new Set([1, "a", { b: [2] }]), new Set(["a", { b: [2] }, 1]));
  equal(new Uint8Array([1, 2]), new Uint8Array([1, 2]));
  equal(new Date(5), new Date(5));
  // Each mismatch throws. A mismatch inside a value names its path.
  failure(() => equal(-0, 0));
  failure(() => equal({ a: undefined }, {}));
  failure(() => equal({}, { a: undefined }));
  failure(() => equal([1, 2], [1]));
  failure(() => equal(new Uint8Array([1]), [1]));
  failure(() => equal({ [Symbol.for("s")]: 1 }, {}));
  assert(failure(() => equal({ list: [{ name: "a" }] }, { list: [{ name: "b" }] })).includes(".list[0].name"));
  assert(failure(() => equal(new Map([["k", 1]]), new Map([["k", 2]]))).includes('.get("k")'));
  const named = failure(() => equal({ "a-b": 1 }, { "a-b": 2 }, "the header"));
  assert(named.startsWith("the header"), named);
  assert(named.includes('["a-b"]'), named);
});

test("assert, throws, and rejects fail with a message", async () => {
  failure(() => assert(false));
  failure(() => throws(() => 1));
  equal(
    failure(() => assert(0, "the count is zero")),
    "the count is zero",
  );
  equal(
    throws(() => {
      throw "a text";
    }),
    "a text",
  );
  equal(await rejects(Promise.reject(new RangeError("low"))), new RangeError("low"));
  failure(() => equal(new RangeError("low"), new RangeError("high")));
  assert((await rejects(rejects(Promise.resolve(1)))) instanceof Error);
});

// The two tests run in this order. The first test leaves a global and a file. The second test sees neither.
test("a test leaves a global and a file behind", async () => {
  Reflect.set(globalThis, "leftover", true);
  await writeTextFile("left.txt", "x", { baseDir: folder() });
  equal(Reflect.has(globalThis, "leftover"), true);
});

test("the next test runs in a fresh runtime with an empty folder of its own", async () => {
  equal(Reflect.has(globalThis, "leftover"), false);
  equal(await readDir(".", { baseDir: folder() }), []);
});

test("a host needs the runner of yuke test", async () => {
  const error = await rejects(createHost({ plugins: [] }));
  assert(error instanceof Error);
  equal(error.message, "no test host: run this file with yuke test");
});
