// The globals of `yuke:internal/web` besides the events and the URL classes: `TextEncoder`, `TextDecoder`, and
// `performance`, with the base64 functions and the microtasks of the engine.

import { assert, equal, test } from "yuke:test";
import { thrownName } from "./errors.ts";

test("the globals are properties that a script can replace", () => {
  const names = [
    "TextEncoder",
    "TextDecoder",
    "URL",
    "URLSearchParams",
    "ReadableStream",
    "ReadableStreamDefaultReader",
    "ReadableStreamDefaultController",
    "Headers",
    "Request",
    "Response",
    "console",
    "performance",
  ];
  for (const name of names) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
    equal(
      { writable: descriptor?.writable, enumerable: descriptor?.enumerable, configurable: descriptor?.configurable },
      { writable: true, enumerable: false, configurable: true },
      name,
    );
  }
});

test("text encoder gives utf8 and replaces a lone surrogate", () => {
  const encoder = new TextEncoder();
  equal(encoder.encoding, "utf-8");
  equal(encoder.encode("é\uD800x"), new Uint8Array([195, 169, 239, 191, 189, 120]));
  equal(encoder.encode(), new Uint8Array());
  // @ts-expect-error: the encoder converts `null` to the text "null".
  equal(encoder.encode(null), new Uint8Array([110, 117, 108, 108]));
});

test("encode into writes whole characters and counts utf16 units", () => {
  const encoder = new TextEncoder();
  const small = new Uint8Array(5);
  equal(encoder.encodeInto("é😀x", small), { read: 1, written: 2 });
  equal(small, new Uint8Array([195, 169, 0, 0, 0]));
  const large = new Uint8Array(8);
  equal(encoder.encodeInto("é😀x", large.subarray(1)), { read: 4, written: 7 });
  equal(large, new Uint8Array([0, 195, 169, 240, 159, 152, 128, 120]));
});

test("the encoder refuses a destination that is no uint8 array and a value of another class", () => {
  const encoder = new TextEncoder();
  const fake = Object.defineProperties(Object.create(Uint8Array.prototype) as Uint8Array, {
    length: { value: 1 },
    set: { value() {} },
  });
  equal(
    [
      // @ts-expect-error: the destination must be a `Uint8Array`.
      () => encoder.encodeInto("a", new Uint16Array(2)),
      () => encoder.encodeInto("a", fake),
      // @ts-expect-error: the destination is missing.
      () => encoder.encodeInto("a"),
      () => TextEncoder.prototype.encode.call({}, "a"),
      () => Object.getOwnPropertyDescriptor(TextDecoder.prototype, "encoding")?.get?.call({}),
      // @ts-expect-error: a symbol has no text.
      () => encoder.encode(Symbol()),
    ].map(thrownName),
    ["TypeError", "TypeError", "TypeError", "TypeError", "TypeError", "TypeError"],
  );
});

test("text decoder reads views and buffers", () => {
  const decoder = new TextDecoder();
  const bytes = new Uint8Array([0, 104, 105, 0]);
  equal(
    [
      decoder.decode(bytes.subarray(1, 3)),
      decoder.decode(bytes.buffer.slice(1, 3)),
      decoder.decode(new DataView(bytes.buffer, 1, 2)),
      decoder.decode(new Uint16Array(new Uint8Array([0, 0, 104, 105]).buffer, 2, 1)),
      decoder.decode(new SharedArrayBuffer(0)),
      decoder.decode(),
    ],
    ["hi", "hi", "hi", "hi", "", ""],
  );
  equal(
    [
      // @ts-expect-error: a text is no buffer.
      () => decoder.decode("hi"),
      // @ts-expect-error: an array is no buffer.
      () => decoder.decode([104]),
    ].map(thrownName),
    ["TypeError", "TypeError"],
  );
});

test("text decoder replaces an invalid sequence unless it is fatal", () => {
  equal(new TextDecoder().decode(new Uint8Array([0x61, 0x80, 0xe2, 0x82])), "a\uFFFD\uFFFD");
  const fatal = new TextDecoder("utf-8", { fatal: true });
  equal(fatal.fatal, true);
  equal(
    thrownName(() => fatal.decode(new Uint8Array([0x61, 0x80]))),
    "TypeError",
  );
  equal(fatal.decode(new Uint8Array([0x61])), "a");
  equal(fatal.decode(new Uint8Array([0xe2]), { stream: true }), "");
  equal(
    thrownName(() => fatal.decode(new Uint8Array([0x41]))),
    "TypeError",
  );
  equal(fatal.decode(new Uint8Array([0x42])), "B");
});

test("a stream decode keeps a split character for the next call", () => {
  const decoder = new TextDecoder();
  equal(
    [
      decoder.decode(new Uint8Array([0x61, 0xe2, 0x82]), { stream: true }),
      decoder.decode(new Uint8Array([0xac]), { stream: true }),
      decoder.decode(new Uint8Array([0xe2])),
    ],
    ["a", "€", "\uFFFD"],
  );
});

test("a decoder removes one byte order mark at the start of each stream unless it ignores it", () => {
  const bom = [0xef, 0xbb, 0xbf];
  const decoder = new TextDecoder();
  const split = [
    decoder.decode(new Uint8Array([0xef]), { stream: true }),
    decoder.decode(new Uint8Array([0xbb, 0xbf, 0x61, ...bom])),
  ];
  const again = decoder.decode(new Uint8Array([...bom, 0x62]));
  const kept = new TextDecoder("utf-8", { ignoreBOM: true }).decode(new Uint8Array([...bom, 0x63]));
  equal([...split, again, kept], ["", "a\uFEFF", "b", "\uFEFFc"]);
});

test("text decoder accepts each utf8 label and refuses other encodings", () => {
  // @ts-expect-error: the type has no label with spaces or capitals, but the runtime accepts it.
  equal(new TextDecoder(" UTF8 ").encoding, "utf-8");
  equal(new TextDecoder("unicode-1-1-utf-8").encoding, "utf-8");
  equal(
    [
      // @ts-expect-error: yuke decodes UTF-8 only.
      () => new TextDecoder("latin1"),
      // @ts-expect-error: yuke decodes UTF-8 only.
      () => new TextDecoder("utf-16le"),
    ].map(thrownName),
    ["RangeError", "RangeError"],
  );
});

test("performance gives its origin as epoch time", async () => {
  const gap = Math.abs(performance.timeOrigin + performance.now() - Date.now());
  const first = performance.now();
  await new Promise<void>((resolve) => setTimeout(resolve, 5));
  assert(gap < 50, `the gap is ${gap} ms`);
  assert(performance.now() > first, "the clock goes on");
  equal(performance.toJSON(), { timeOrigin: performance.timeOrigin });
});

test("the engine gives base64 and microtasks", async () => {
  const order: string[] = [];
  queueMicrotask(() => order.push("microtask"));
  order.push("now");
  await new Promise<void>((resolve) => setTimeout(resolve, 0));
  equal([btoa("hi"), atob("aGk="), order], ["aGk=", "hi", ["now", "microtask"]]);
});

test("a resizable buffer throws and a detached one has no bytes", () => {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const resizable = () => new ArrayBuffer(2, { maxByteLength: 4 });
  equal(
    [
      () => decoder.decode(resizable()),
      () => decoder.decode(new Uint8Array(resizable())),
      () => encoder.encodeInto("a", new Uint8Array(resizable())),
    ].map(thrownName),
    ["TypeError", "TypeError", "TypeError"],
  );

  const buffer = new ArrayBuffer(2);
  const view = new Uint8Array(buffer);
  const data = new DataView(buffer);
  buffer.transfer();
  const written = encoder.encodeInto("a", view);
  equal([decoder.decode(view), decoder.decode(buffer), decoder.decode(data)], ["", "", ""]);
  equal(written, { read: 0, written: 0 });

  const shared = new SharedArrayBuffer(3);
  new Uint8Array(shared).set([0, 104, 105]);
  equal(decoder.decode(shared), "\u0000hi");
  equal(decoder.decode(new Uint8Array(shared, 1)), "hi");
});
