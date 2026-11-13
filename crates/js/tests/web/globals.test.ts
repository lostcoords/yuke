// The globals of `yuke:internal/web` besides the events and the URL classes: `TextEncoder`, `TextDecoder`, and
// `performance`, with the base64 functions and the microtasks of the engine.

import { assert, assertEquals, test } from "yuke:test";
import { thrownName } from "./errors.ts";

test("text encoder gives utf8 and replaces a lone surrogate", () => {
  const encoder = new TextEncoder();
  assertEquals(encoder.encoding, "utf-8");
  assertEquals(encoder.encode("é\uD800x"), new Uint8Array([195, 169, 239, 191, 189, 120]));
  assertEquals(encoder.encode(), new Uint8Array());
  // @ts-expect-error: the encoder converts `null` to the text "null".
  assertEquals(encoder.encode(null), new Uint8Array([110, 117, 108, 108]));
});

test("encode into writes whole characters and counts utf16 units", () => {
  const encoder = new TextEncoder();
  const small = new Uint8Array(5);
  assertEquals(encoder.encodeInto("é😀x", small), { read: 1, written: 2 });
  assertEquals(small, new Uint8Array([195, 169, 0, 0, 0]));
  const large = new Uint8Array(8);
  assertEquals(encoder.encodeInto("é😀x", large.subarray(1)), { read: 4, written: 7 });
  assertEquals(large, new Uint8Array([0, 195, 169, 240, 159, 152, 128, 120]));
});

test("text decoder reads views and buffers", () => {
  const decoder = new TextDecoder();
  const bytes = new Uint8Array([0, 104, 105, 0]);
  assertEquals(
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
  assertEquals(
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
  assertEquals(new TextDecoder().decode(new Uint8Array([0x61, 0x80, 0xe2, 0x82])), "a\uFFFD\uFFFD");
  const fatal = new TextDecoder("utf-8", { fatal: true });
  assertEquals(fatal.fatal, true);
  assertEquals(
    thrownName(() => fatal.decode(new Uint8Array([0x61, 0x80]))),
    "TypeError",
  );
  assertEquals(fatal.decode(new Uint8Array([0x61])), "a");
  assertEquals(fatal.decode(new Uint8Array([0xe2]), { stream: true }), "");
  assertEquals(
    thrownName(() => fatal.decode(new Uint8Array([0x41]))),
    "TypeError",
  );
  assertEquals(fatal.decode(new Uint8Array([0x42])), "B");
});

test("a stream decode keeps a split character for the next call", () => {
  const decoder = new TextDecoder();
  assertEquals(
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
  assertEquals([...split, again, kept], ["", "a\uFEFF", "b", "\uFEFFc"]);
});

test("text decoder accepts each utf8 label and refuses other encodings", () => {
  assertEquals(new TextDecoder(" UTF8 ").encoding, "utf-8");
  assertEquals(new TextDecoder("unicode-1-1-utf-8").encoding, "utf-8");
  assertEquals([() => new TextDecoder("latin1"), () => new TextDecoder("utf-16le")].map(thrownName), [
    "RangeError",
    "RangeError",
  ]);
});

test("performance gives its origin as epoch time", () => {
  const gap = Math.abs(performance.timeOrigin + performance.now() - Date.now());
  const first = performance.now();
  assert(gap < 1000, `the gap is ${gap} ms`);
  assert(performance.now() >= first, "the clock does not go back");
  assertEquals(performance.toJSON(), { timeOrigin: performance.timeOrigin });
});
