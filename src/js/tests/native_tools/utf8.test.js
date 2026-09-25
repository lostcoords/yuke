import { utf8 } from "yuke";
import { check, equal } from "yuke:internal/test";

function rejects(fn) {
  let rejected = false;
  try { fn(); } catch (error) { rejected = error instanceof TypeError; }
  check("invalid UTF-8 input", rejected);
}

const cases = [
  ["", []],
  ["A\0\ufeff", [65, 0, 239, 187, 191]],
  ["\u007f\u0080\u07ff\u0800\ud7ff\ue000\uffff", [127, 194, 128, 223, 191, 224, 160, 128, 237, 159, 191, 238, 128, 128, 239, 191, 191]],
  ["\u{10000}\u{10ffff}", [240, 144, 128, 128, 244, 143, 191, 191]],
  ["世界😀", [228, 184, 150, 231, 149, 140, 240, 159, 152, 128]],
];
for (const [text, bytes] of cases) {
  equal([...utf8.encode(text)].join(","), bytes.join(","));
  equal(utf8.decode(new Uint8Array(bytes)), text);
}
equal(utf8.decode(new Uint8Array([239, 187, 191, 65])), "\ufeffA");
const backing = new Uint8Array([255, 65, 0, 66, 255]);
const decoded = utf8.decode(backing.subarray(1, 4));
backing.fill(255);
equal(decoded, "A\0B");
const first = utf8.encode("abc"), second = utf8.encode("abc");
first.fill(0);
equal(utf8.decode(second), "abc");
for (const text of ["\ud800", "\udfff", "a\ud800b", "\udc00\ud800", "\ud800\ud800"]) rejects(() => utf8.encode(text));
for (const bytes of [[128], [192, 175], [224, 128, 128], [237, 160, 128], [244, 144, 128, 128], [245, 128, 128, 128], [255], [226, 65, 172]]) {
  rejects(() => utf8.decode(new Uint8Array(bytes)));
}
for (const text of ["é", "世", "😀"]) {
  const bytes = utf8.encode(text);
  for (let i = 1; i < bytes.length; i++) {
    rejects(() => utf8.decode(bytes.subarray(0, i)));
    rejects(() => utf8.decode(bytes.subarray(i)));
    const joined = new Uint8Array(bytes.length);
    joined.set(bytes.subarray(0, i));
    joined.set(bytes.subarray(i), i);
    equal(utf8.decode(joined), text);
  }
}
let coerced = false;
for (const value of [undefined, null, 42, {}, { toString() { coerced = true; return "abc"; } }]) {
  rejects(() => utf8.encode(value));
  rejects(() => utf8.decode(value));
}
for (const value of ["abc", [], new ArrayBuffer(2), new DataView(new ArrayBuffer(2)), new Uint16Array(2), new Uint8ClampedArray(2)]) rejects(() => utf8.decode(value));
rejects(() => utf8.encode());
rejects(() => utf8.decode());
const detached = new Uint8Array(2);
detached.buffer.transfer();
rejects(() => utf8.decode(detached));
check("no implicit conversion", !coerced);
equal(utf8.decode(utf8.encode("valid after errors")), "valid after errors");
