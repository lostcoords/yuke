// The web classes of `yuke:internal/events`: events, event targets, and abort signals. Many cases follow the web
// platform tests (WPT) of `dom/events` and `dom/abort`.

import { assert, equal, test, throws } from "yuke:test";
import { thrownName } from "./errors.ts";

// Classes, construction, and the shape of an event.

test("the web classes are globals that a script can replace", () => {
  for (const name of ["AbortController", "AbortSignal", "CustomEvent", "Event", "EventTarget"]) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
    const value: unknown = descriptor?.value;
    assert(typeof value === "function", `${name} is a function`);
    equal(
      {
        name: value.name,
        writable: descriptor?.writable,
        enumerable: descriptor?.enumerable,
        configurable: descriptor?.configurable,
      },
      { name, writable: true, enumerable: false, configurable: true },
    );
  }
});

test("each class names itself in its string form", () => {
  const controller = new AbortController();
  equal(
    [new Event("x"), new CustomEvent("x"), new EventTarget(), controller.signal, controller].map((value) =>
      Object.prototype.toString.call(value),
    ),
    [
      "[object Event]",
      "[object CustomEvent]",
      "[object EventTarget]",
      "[object AbortSignal]",
      "[object AbortController]",
    ],
  );
});

test("the members of a web class are enumerable on its prototype", () => {
  const members: string[] = [];
  for (const key in new AbortController().signal) members.push(key);
  for (const key of ["aborted", "reason", "throwIfAborted", "addEventListener"]) {
    assert(members.includes(key), `${key} is enumerable`);
  }
  assert(!members.includes("constructor"), "constructor is not enumerable");
});

test("an event needs a type and an init that is an object", () => {
  equal(
    [
      // @ts-expect-error: the type is missing.
      () => new Event(),
      // @ts-expect-error: the init is no object.
      () => new Event("x", 1),
      // @ts-expect-error: a symbol has no text.
      () => new Event(Symbol()),
      // @ts-expect-error: the type is missing.
      () => new CustomEvent(),
    ].map(thrownName),
    ["TypeError", "TypeError", "TypeError", "TypeError"],
  );
  // @ts-expect-error: the event converts `undefined` to the text "undefined".
  equal(new Event(undefined).type, "undefined");
  // @ts-expect-error: the event reads `null` as an empty init.
  equal(new Event("x", null).bubbles, false);
});

test("an event takes its flags from the init", () => {
  const plain = new Event("x");
  // @ts-expect-error: the event converts each flag to a boolean.
  const set = new Event("x", { bubbles: 1, cancelable: "yes", composed: {} });
  equal(
    [plain.bubbles, plain.cancelable, plain.composed, set.bubbles, set.cancelable, set.composed],
    [false, false, false, true, true, true],
  );
});

test("a custom event carries its detail", () => {
  const detail = { path: "a" };
  assert(new CustomEvent("x", { detail }).detail === detail, "the detail is the value of the init");
  equal(new CustomEvent("x").detail, null);
  equal(new CustomEvent("x", { detail: undefined }).detail, null);
  equal(new CustomEvent("x", { bubbles: true }).bubbles, true);
  assert(new CustomEvent("x") instanceof Event, "a custom event is an event");
});

test("an event names its phases on the class and on each event", () => {
  const event = new Event("x");
  const names = ["NONE", "CAPTURING_PHASE", "AT_TARGET", "BUBBLING_PHASE"] as const;
  equal(
    names.map((name) => Event[name]),
    [0, 1, 2, 3],
  );
  equal(
    names.map((name) => event[name]),
    [0, 1, 2, 3],
  );
  for (const owner of [Event, Event.prototype]) {
    for (const name of names) {
      const descriptor = Object.getOwnPropertyDescriptor(owner, name);
      equal(
        { writable: descriptor?.writable, enumerable: descriptor?.enumerable, configurable: descriptor?.configurable },
        { writable: false, enumerable: true, configurable: false },
        name,
      );
    }
  }
});

test("is trusted is an own property that a script cannot redefine", () => {
  const event = new Event("x");
  equal(Object.getOwnPropertyDescriptor(event, "isTrusted")?.configurable, false);
  equal(
    thrownName(() => Object.defineProperty(event, "isTrusted", { value: true })),
    "TypeError",
  );
  equal(event.isTrusted, false);
});

// Dispatch.

test("a subclass of event reaches a listener of a subclass of event target", () => {
  class Saved extends Event {
    readonly path: string;
    constructor(path: string) {
      super("saved");
      this.path = path;
    }
  }
  class Notes extends EventTarget {}
  const notes = new Notes();
  const seen: Event[] = [];
  notes.addEventListener("saved", (event) => seen.push(event));
  notes.dispatchEvent(new Saved("a.txt"));
  equal(seen.length, 1);
  const event = seen[0];
  assert(event instanceof Saved, "the listener gets the subclass");
  equal(event.path, "a.txt");
});

test("a dispatch sets the targets and the phase only while it runs", () => {
  const target = new EventTarget();
  const event = new Event("x");
  const seen: unknown[] = [];
  target.addEventListener("x", function (event) {
    const path = event.composedPath();
    seen.push([
      this === target,
      event.target === target,
      event.currentTarget === target,
      event.eventPhase,
      path.length === 1 && path[0] === target,
    ]);
  });
  target.dispatchEvent(event);
  equal(seen, [[true, true, true, 2, true]]);
  assert(event.target === target, "the target stays after the dispatch");
  equal([event.currentTarget, event.eventPhase, event.composedPath()], [null, 0, []]);
});

test("capture listeners run before the other listeners", () => {
  const target = new EventTarget();
  const log: string[] = [];
  target.addEventListener("x", () => log.push("other"));
  target.addEventListener("x", () => log.push("capture"), true);
  target.addEventListener("x", () => log.push("capture2"), { capture: true });
  target.dispatchEvent(new Event("x"));
  equal(log, ["capture", "capture2", "other"]);
});

test("stop propagation ends the dispatch after its pass and resets after a dispatch", () => {
  const target = new EventTarget();
  const log: string[] = [];
  target.addEventListener(
    "x",
    (event) => {
      log.push("capture");
      event.stopPropagation();
    },
    true,
  );
  target.addEventListener("x", () => log.push("capture2"), true);
  target.addEventListener("x", () => log.push("other"));
  const event = new Event("x");
  target.dispatchEvent(event);
  target.dispatchEvent(event);
  const early = new Event("x");
  early.stopPropagation();
  log.push("|");
  target.dispatchEvent(early);
  log.push("|");
  target.dispatchEvent(early);
  equal(log, ["capture", "capture2", "capture", "capture2", "|", "|", "capture", "capture2"]);
});

test("stop immediate propagation ends the dispatch after its listener", () => {
  const target = new EventTarget();
  const log: string[] = [];
  target.addEventListener(
    "x",
    (event) => {
      log.push("first");
      event.stopImmediatePropagation();
    },
    true,
  );
  target.addEventListener("x", () => log.push("capture"), true);
  target.addEventListener("x", () => log.push("other"));
  const event = new Event("x");
  target.dispatchEvent(event);
  target.dispatchEvent(event);
  equal(log, ["first", "first"]);
});

test("a listener cancels only a cancelable event", () => {
  const target = new EventTarget();
  target.addEventListener("x", (event) => event.preventDefault());
  const plain = new Event("x");
  const cancelable = new Event("x", { cancelable: true });
  equal(
    [
      target.dispatchEvent(plain),
      plain.defaultPrevented,
      target.dispatchEvent(cancelable),
      cancelable.defaultPrevented,
    ],
    [true, false, false, true],
  );
});

test("a passive listener cannot cancel and a later call can", () => {
  const target = new EventTarget();
  target.addEventListener("x", (event) => event.preventDefault(), { passive: true });
  const event = new Event("x", { cancelable: true });
  const first = target.dispatchEvent(event);
  event.preventDefault();
  target.addEventListener("x", (event) => event.preventDefault());
  equal(
    [first, event.defaultPrevented, target.dispatchEvent(new Event("x", { cancelable: true }))],
    [true, true, false],
  );
});

test("an event in a dispatch cannot be dispatched again and another event can", () => {
  const target = new EventTarget();
  const event = new Event("x");
  const log: unknown[] = [];
  target.addEventListener("x", () => {
    log.push(throws(() => target.dispatchEvent(event)));
    target.dispatchEvent(new Event("y"));
  });
  target.addEventListener("y", () => log.push("y"));
  target.dispatchEvent(event);
  equal(log.length, 2);
  const error = log[0];
  assert(error instanceof DOMException, "the error is a DOMException");
  equal(error.name, "InvalidStateError");
  equal(log[1], "y");
});

// Listeners.

test("a second add of one listener with one capture flag does nothing", () => {
  const target = new EventTarget();
  let calls = 0;
  const listener = () => {
    calls += 1;
  };
  target.addEventListener("x", listener);
  target.addEventListener("x", listener, { once: true });
  target.addEventListener("x", listener, true);
  target.dispatchEvent(new Event("x"));
  target.dispatchEvent(new Event("x"));
  equal(calls, 4);
});

test("a remove needs the capture flag of the add", () => {
  const target = new EventTarget();
  let calls = 0;
  const listener = () => {
    calls += 1;
  };
  const other = () => {
    calls += 10;
  };
  target.addEventListener("x", listener, true);
  target.addEventListener("x", other, { capture: true });
  target.removeEventListener("x", listener);
  target.dispatchEvent(new Event("x"));
  target.removeEventListener("x", listener, { capture: true });
  target.removeEventListener("x", other, true);
  target.dispatchEvent(new Event("x"));
  equal(calls, 11);
});

test("a once listener is removed before its call", () => {
  const target = new EventTarget();
  let calls = 0;
  target.addEventListener(
    "x",
    () => {
      calls += 1;
      target.dispatchEvent(new Event("x"));
    },
    { once: true },
  );
  target.dispatchEvent(new Event("x"));
  target.dispatchEvent(new Event("x"));
  equal(calls, 1);
});

test("a listener that a listener removes does not run and an added one waits for the next pass", () => {
  const target = new EventTarget();
  const log: string[] = [];
  const later = () => log.push("later");
  target.addEventListener(
    "x",
    () => {
      log.push("capture");
      target.addEventListener("x", () => log.push("added in capture"));
    },
    true,
  );
  target.addEventListener("x", () => {
    log.push("other");
    target.removeEventListener("x", later);
    target.addEventListener("x", () => log.push("added in other"));
  });
  target.addEventListener("x", later);
  target.dispatchEvent(new Event("x"));
  equal(log, ["capture", "other", "added in capture"]);
});

test("a listener object reads its handle event at each call", () => {
  const target = new EventTarget();
  const log: unknown[] = [];
  const listener = {
    handleEvent(event: Event) {
      log.push([this === listener, event.type]);
    },
  };
  target.addEventListener("x", listener);
  target.dispatchEvent(new Event("x"));
  listener.handleEvent = () => log.push("replaced");
  target.dispatchEvent(new Event("x"));
  equal(log, [[true, "x"], "replaced"]);
});

test("a method refuses a value of another class", () => {
  const fake = { aborted: false, reason: undefined };
  const getter = (owner: object, name: string) => Object.getOwnPropertyDescriptor(owner, name)?.get;
  equal(
    [
      () => EventTarget.prototype.addEventListener.call({}, "x", null),
      // @ts-expect-error: a plain object is no event.
      () => new EventTarget().dispatchEvent({ type: "x" }),
      // @ts-expect-error: a plain object is no signal.
      () => new EventTarget().addEventListener("x", () => {}, { signal: fake }),
      // @ts-expect-error: a number is no listener.
      () => new EventTarget().addEventListener("x", 5),
      () => getter(Event.prototype, "type")?.call({}),
      () => getter(AbortSignal.prototype, "aborted")?.call(fake),
      () => getter(AbortController.prototype, "signal")?.call({}),
      // @ts-expect-error: a plain object is no signal.
      () => AbortSignal.any([fake]),
      // @ts-expect-error: the characters of a text are no signals.
      () => AbortSignal.any(""),
      // @ts-expect-error: a number is not iterable.
      () => AbortSignal.any(5),
    ].map(thrownName),
    Array(10).fill("TypeError"),
  );
});

test("a missing argument throws a type error", () => {
  const target = new EventTarget();
  equal(
    [
      // @ts-expect-error: the listener is missing.
      () => target.addEventListener("x"),
      // @ts-expect-error: the listener is missing.
      () => target.removeEventListener("x"),
      // @ts-expect-error: the event is missing.
      () => target.dispatchEvent(),
      // @ts-expect-error: the signals are missing.
      () => AbortSignal.any(),
      // @ts-expect-error: the delay is missing.
      () => AbortSignal.timeout(),
    ].map(thrownName),
    ["TypeError", "TypeError", "TypeError", "TypeError", "TypeError"],
  );
  target.addEventListener("x", null);
});

// Abort signals.

test("an aborted signal adds no listener and an abort removes one", () => {
  const target = new EventTarget();
  let calls = 0;
  target.addEventListener(
    "x",
    () => {
      calls += 1;
    },
    { signal: AbortSignal.abort() },
  );
  const controller = new AbortController();
  target.addEventListener(
    "x",
    () => {
      calls += 10;
    },
    { signal: controller.signal },
  );
  target.dispatchEvent(new Event("x"));
  controller.abort();
  target.dispatchEvent(new Event("x"));
  equal(calls, 10);
});

test("only an abort of the signal removes a listener", () => {
  const target = new EventTarget();
  let calls = 0;
  const stopped = new AbortController();
  stopped.signal.addEventListener("abort", (event) => {
    event.stopImmediatePropagation();
    target.dispatchEvent(new Event("x"));
  });
  target.addEventListener(
    "x",
    () => {
      calls += 1;
    },
    { signal: stopped.signal },
  );
  const faked = new AbortController();
  target.addEventListener(
    "x",
    () => {
      calls += 10;
    },
    { signal: faked.signal },
  );
  faked.signal.dispatchEvent(new Event("abort"));
  stopped.abort();
  target.dispatchEvent(new Event("x"));
  equal([calls, faked.signal.aborted], [20, false]);
});

test("a signal has no public constructor", () => {
  // @ts-expect-error: the type of `AbortSignal` has no constructor.
  class Mine extends AbortSignal {}
  equal(
    [
      // @ts-expect-error: the type of `AbortSignal` has no constructor.
      () => new AbortSignal(),
      () => new Mine(),
    ].map(thrownName),
    ["TypeError", "TypeError"],
  );
});

test("a controller aborts its signal once with the first reason", () => {
  const controller = new AbortController();
  const signal = controller.signal;
  const reason = { why: 1 };
  let calls = 0;
  signal.addEventListener("abort", () => {
    calls += 1;
  });
  const before = [signal.aborted, signal.reason];
  controller.abort(reason);
  controller.abort("second");
  assert(controller.signal === signal, "each read gives the same signal");
  equal(before, [false, undefined]);
  equal(signal.aborted, true);
  assert(signal.reason === reason, "the reason is the first one");
  equal(calls, 1);
});

test("an abort without a reason gives an abort error and null stays null", () => {
  const controller = new AbortController();
  controller.abort();
  const reason = controller.signal.reason;
  assert(reason instanceof DOMException, "the reason is a DOMException");
  equal([reason.name, reason.code], ["AbortError", 20]);
  const nulled = new AbortController();
  nulled.abort(null);
  equal(nulled.signal.reason, null);

  const object = {};
  const withObject = AbortSignal.abort(object);
  equal(withObject.aborted, true);
  assert(withObject.reason === object, "the reason is the object");
  const withUndefined = AbortSignal.abort(undefined).reason;
  assert(withUndefined instanceof DOMException, "the reason is a DOMException");
  equal(withUndefined.name, "AbortError");
  equal(AbortSignal.abort(null).reason, null);
});

test("an abort event is trusted until a script dispatches it", () => {
  const controller = new AbortController();
  const events: Event[] = [];
  controller.signal.addEventListener("abort", (event) => events.push(event));
  controller.abort();
  equal(events.length, 1);
  const event = events[0];
  assert(event !== undefined);
  equal(
    [event.type, event.isTrusted, event.bubbles, event.cancelable, event.target === controller.signal],
    ["abort", true, false, false, true],
  );
  new EventTarget().dispatchEvent(event);
  equal(event.isTrusted, false);
});

test("a listener added after the abort does not run", async () => {
  const signal = AbortSignal.abort();
  let calls = 0;
  signal.addEventListener("abort", () => {
    calls += 1;
  });
  signal.onabort = () => {
    calls += 1;
  };
  await new Promise<void>((resolve) => setTimeout(resolve, 0));
  equal(calls, 0);
});

test("throw if aborted throws the reason only after the abort", () => {
  const controller = new AbortController();
  const reason = new Error("stop");
  controller.signal.throwIfAborted();
  controller.abort(reason);
  assert(throws(() => controller.signal.throwIfAborted()) === reason, "the throw is the reason");
});

test("onabort keeps its place until a clear", () => {
  const log: unknown[] = [];
  const one = new AbortController();
  one.signal.onabort = () => log.push("old");
  one.signal.addEventListener("abort", () => log.push("listener"));
  one.signal.onabort = function (event) {
    log.push([this === one.signal, event.type]);
  };
  one.abort();
  const two = new AbortController();
  two.signal.onabort = () => log.push("cleared");
  two.signal.addEventListener("abort", () => log.push("second"));
  two.signal.onabort = null;
  two.signal.onabort = () => log.push("third");
  two.abort();
  equal(log, [[true, "abort"], "listener", "second", "third"]);
});

test("onabort keeps an object and clears for another value", () => {
  const signal = new AbortController().signal;
  const handler = () => {};
  const object = {};
  signal.onabort = handler;
  assert(signal.onabort === handler, "the handler stays");
  // @ts-expect-error: the type takes a function only, but the runtime keeps an object.
  signal.onabort = object;
  assert(signal.onabort === object, "the object stays");
  // @ts-expect-error: a number clears the handler.
  signal.onabort = 5;
  equal(signal.onabort, null);
});

test("an onabort handler that returns false cancels a cancelable event", () => {
  const signal = new AbortController().signal;
  signal.onabort = () => false;
  const event = new Event("abort", { cancelable: true });
  equal([signal.dispatchEvent(event), event.defaultPrevented], [false, true]);
});

test("timeout aborts with a timeout error after its delay", async () => {
  const started = performance.now();
  const signal = AbortSignal.timeout(20);
  const zero = AbortSignal.timeout(0);
  equal([signal.aborted, zero.aborted], [false, false]);
  await new Promise((resolve) => signal.addEventListener("abort", resolve));
  assert(performance.now() - started >= 20, "the abort waits for the delay");
  const reason = signal.reason;
  assert(reason instanceof DOMException, "the reason is a DOMException");
  equal([reason.name, reason.code], ["TimeoutError", 23]);
  equal(zero.aborted, true);
});

test("timeout drops the fraction and refuses a value out of range", () => {
  for (const value of [-1, Number.NaN, Number.POSITIVE_INFINITY, 2 ** 53]) {
    equal(
      thrownName(() => AbortSignal.timeout(value)),
      "TypeError",
      String(value),
    );
  }
  equal(
    [
      // @ts-expect-error: a symbol is no number.
      () => AbortSignal.timeout(Symbol()),
      // @ts-expect-error: a bigint is no number.
      () => AbortSignal.timeout(1n),
      // @ts-expect-error: the delay is undefined.
      () => AbortSignal.timeout(undefined),
    ].map(thrownName),
    ["TypeError", "TypeError", "TypeError"],
  );
  AbortSignal.timeout(1.9);
  AbortSignal.timeout(-0.9);
  // @ts-expect-error: the method converts the text to a number.
  AbortSignal.timeout("5");
});

// The dependent signals of `AbortSignal.any`.

test("any takes the reason of the first aborted input", () => {
  const open = new AbortController();
  const signal = AbortSignal.any([open.signal, AbortSignal.abort("b"), AbortSignal.abort("c")]);
  const callable = Object.assign(() => {}, {
    *[Symbol.iterator]() {
      yield AbortSignal.abort("d");
    },
  });
  equal([signal.aborted, signal.reason, AbortSignal.any(callable).reason], [true, "b", "d"]);
});

test("any aborts with the first source that aborts", () => {
  const a = new AbortController();
  const b = new AbortController();
  const signal = AbortSignal.any([a.signal, b.signal]);
  const log: unknown[] = [];
  signal.addEventListener("abort", () => log.push(signal.reason));
  b.abort("b");
  a.abort("a");
  equal(log, ["b"]);
  equal(signal.reason, "b");
});

test("a dependent signal of a dependent aborts before the listeners of the source run", () => {
  const controller = new AbortController();
  const first = AbortSignal.any([controller.signal]);
  const nested = AbortSignal.any([first]);
  const log: unknown[] = [];
  controller.signal.addEventListener("abort", () => log.push(["source", first.aborted, nested.aborted]));
  first.addEventListener("abort", () => log.push("first"));
  nested.addEventListener("abort", () => log.push(["nested", nested.reason]));
  controller.abort("why");
  equal(log, [["source", true, true], "first", ["nested", "why"]]);
});

test("an abort in an abort listener keeps the first reason of a dependent", () => {
  const a = new AbortController();
  const b = new AbortController();
  const signal = AbortSignal.any([a.signal, b.signal]);
  a.signal.addEventListener("abort", () => b.abort("b"));
  a.abort("a");
  equal(signal.reason, "a");
});

test("any checks each value before it asks for the next", () => {
  function* values() {
    yield {};
    throw new Error("late");
  }
  equal(
    // @ts-expect-error: a plain object is no signal.
    thrownName(() => AbortSignal.any(values())),
    "TypeError",
  );
});

test("any takes a truthy done and refuses an iterator result that is no object", () => {
  const iterable = (results: unknown[]) => ({ [Symbol.iterator]: () => ({ next: () => results.shift() }) });
  // @ts-expect-error: `done` is a number, and the runtime reads it as a boolean.
  equal(AbortSignal.any(iterable([{ done: 1 }])).aborted, false);
  equal(
    // @ts-expect-error: a number is no iterator result.
    thrownName(() => AbortSignal.any(iterable([5]))),
    "TypeError",
  );
});
