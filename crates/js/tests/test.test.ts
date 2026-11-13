// The assertions of the public module `yuke:test`.

import { readDir, writeTextFile } from "yuke:fs";
import { assert, assertEquals, assertRejects, assertThrows, createHost, folder, test } from "yuke:test";

/** The message of the failure of `check`. */
function failure(check: () => void): string {
  const error = assertThrows(check);
  assert(error instanceof Error, "the check throws an Error");
  return error.message;
}

test("equal compares deeply and strictly", () => {
  assertEquals({ a: [1, { b: NaN }], c: "x" }, { a: [1, { b: NaN }], c: "x" });
  assertEquals(new Map([[1, { a: 1 }]]), new Map([[1, { a: 1 }]]));
  assertEquals(new Set([1, "a", { b: [2] }]), new Set(["a", { b: [2] }, 1]));
  assertEquals(new Uint8Array([1, 2]), new Uint8Array([1, 2]));
  assertEquals(new Date(5), new Date(5));
  // Each mismatch throws. A mismatch inside a value names its path.
  failure(() => assertEquals(-0, 0));
  failure(() => assertEquals({ a: undefined }, {}));
  failure(() => assertEquals({}, { a: undefined }));
  failure(() => assertEquals([1, 2], [1]));
  failure(() => assertEquals(new Uint8Array([1]), [1]));
  failure(() => assertEquals({ [Symbol.for("s")]: 1 }, {}));
  assert(failure(() => assertEquals({ list: [{ name: "a" }] }, { list: [{ name: "b" }] })).includes(".list[0].name"));
  assert(failure(() => assertEquals(new Map([["k", 1]]), new Map([["k", 2]]))).includes('.get("k")'));
  const named = failure(() => assertEquals({ "a-b": 1 }, { "a-b": 2 }, "the header"));
  assert(named.startsWith("the header"), named);
  assert(named.includes('["a-b"]'), named);
});

test("assert, throws, and rejects fail with a message", async () => {
  failure(() => assert(false));
  failure(() => assertThrows(() => 1));
  assertEquals(
    failure(() => assert(0, "the count is zero")),
    "the count is zero",
  );
  assertEquals(
    assertThrows(() => {
      throw "a text";
    }),
    "a text",
  );
  assertEquals(await assertRejects(() => Promise.reject(new RangeError("low"))), new RangeError("low"));
  failure(() => assertEquals(new RangeError("low"), new RangeError("high")));
  assert((await assertRejects(() => assertRejects(() => Promise.resolve(1)))) instanceof Error);
});

// The two tests run in this order. The first test leaves a global and a file. The second test sees neither.
test("a test leaves a global and a file behind", async () => {
  Reflect.set(globalThis, "leftover", true);
  await writeTextFile("left.txt", "x", { cwd: folder() });
  assertEquals(Reflect.has(globalThis, "leftover"), true);
});

test("the next test runs in a fresh runtime with an empty folder of its own", async () => {
  assertEquals(Reflect.has(globalThis, "leftover"), false);
  assertEquals(await readDir(".", { cwd: folder() }), []);
});

test("a host needs the runner of yuke test", async () => {
  const error = await assertRejects(() => createHost({ plugins: [] }));
  assert(error instanceof Error);
  assertEquals(error.message, "no test host: run this file with yuke test");
});
