// The assertions of the public module `yuke:test`.

import { assert, equal, rejects, test, throws } from "yuke:test";

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
  equal(
    [
      failure(() => equal(-0, 0)),
      failure(() => equal({ a: undefined }, {})),
      failure(() => equal({}, { a: undefined })),
      failure(() => equal([1, 2], [1])),
      failure(() => equal({ list: [{ name: "a" }] }, { list: [{ name: "b" }] })),
      failure(() => equal(new Map([["k", 1]]), new Map([["k", 2]]))),
      failure(() => equal(new Uint8Array([1]), [1])),
      failure(() => equal({ "a-b": 1 }, { "a-b": 2 }, "the header")),
      failure(() => equal({ [Symbol.for("s")]: 1 }, {})),
    ],
    [
      "equal: at the value: expected 0, got -0",
      "equal: at .a: expected no key, got undefined",
      "equal: at .a: expected undefined, got no key",
      "equal: at the value: expected 1 items, got 2",
      'equal: at .list[0].name: expected "b", got "a"',
      'equal: at .get("k"): expected 2, got 1',
      "equal: at the value: expected [1], got [1] (another prototype)",
      'the header: at ["a-b"]: expected 2, got 1',
      "equal: at [Symbol(s)]: expected no key, got 1",
    ],
  );
});

test("assert, throws, and rejects fail with a message", async () => {
  equal(
    [failure(() => assert(false)), failure(() => assert(0, "the count is zero")), failure(() => throws(() => 1))],
    ["assert: the condition is false", "the count is zero", "throws: the function returned"],
  );
  equal(
    throws(() => {
      throw "a text";
    }),
    "a text",
  );
  equal(await rejects(Promise.reject(new RangeError("low"))), new RangeError("low"));
  equal(
    failure(() => equal(new RangeError("low"), new RangeError("high"))),
    'equal: at .message: expected "high", got "low"',
  );
  const error = await rejects(rejects(Promise.resolve(1)));
  assert(error instanceof Error);
  equal(error.message, "rejects: the promise fulfilled");
});
