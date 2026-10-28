// The timers of the runtime, and the stack check of the engine.

import { assert, equal, test } from "yuke:test";

/** A promise that fulfills after `delay` milliseconds. */
function sleep(delay: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, delay));
}

test("a deep recursion throws a catchable range error", () => {
  const deep = (depth: number): number => deep(depth + 1) + 1;
  let name = "none";
  try {
    deep(0);
  } catch (error) {
    assert(error instanceof Error);
    name = error.name;
  }
  equal(name, "RangeError");
});

test("timers with one delay fire in the order of their set", async () => {
  const order: number[] = [];
  for (let index = 0; index < 20; index += 1) setTimeout(() => order.push(index), 5);
  // A timer set later with the same delay fires after them.
  await sleep(5);
  equal(
    order,
    Array.from({ length: 20 }, (_item, index) => index),
  );
});

test("a promise reaction of a timer callback runs before the next callback", async () => {
  const order: string[] = [];
  setTimeout(() => {
    order.push("first");
    void Promise.resolve().then(() => order.push("job"));
  }, 5);
  setTimeout(() => order.push("second"), 5);
  await sleep(5);
  equal(order, ["first", "job", "second"]);
});

// The first callback clears a timer of the same round.
test("a cleared timer does not fire", async () => {
  const fired: string[] = [];
  let later: ReturnType<typeof setTimeout> | undefined;
  setTimeout(() => {
    fired.push("first");
    clearTimeout(later);
  }, 5);
  later = setTimeout(() => fired.push("later"), 5);
  const never = setTimeout(() => fired.push("never"), 10);
  clearTimeout(never);
  await sleep(10);
  equal(fired, ["first"]);
});

test("an interval repeats until its own callback clears it", async () => {
  let count = 0;
  await new Promise<void>((resolve) => {
    const interval = setInterval(() => {
      count += 1;
      if (count === 3) {
        clearInterval(interval);
        resolve();
      }
    }, 2);
  });
  // A call after the clear would come within the next delays.
  await sleep(10);
  equal(count, 3);
});

test("an interval waits its delay between calls", async () => {
  const begin = Date.now();
  await new Promise<void>((resolve) => {
    let count = 0;
    const interval = setInterval(() => {
      count += 1;
      if (count === 3) {
        clearInterval(interval);
        resolve();
      }
    }, 30);
  });
  // The third call comes 90 ms or later after the set. `Date.now` counts whole milliseconds.
  const elapsed = Date.now() - begin;
  assert(elapsed >= 89, `the third call came after ${elapsed} ms`);
});

test("a timer callback gets the extra arguments", async () => {
  const values = await new Promise<string[]>((resolve) =>
    setTimeout((...values: string[]) => resolve(values), undefined, "a", "b"),
  );
  equal(values, ["a", "b"]);
});
