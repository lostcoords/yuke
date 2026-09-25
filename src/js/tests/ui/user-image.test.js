import { check } from "yuke:internal/test";
import { Transcript } from "yuke:internal/transcript";
const png = { hash: "a".repeat(64), mime: "image/png", bytes: 12288 };
const jpg = { hash: "b".repeat(64), mime: "image/jpeg", bytes: 2200000 };
const tiny = { hash: "c".repeat(64), mime: "image/gif", bytes: 900 };

const parts = {};
const t = new Transcript({ partsOf: (id) => parts[id] || [] });
const body = (id, width = 80) => {
  t.setOutline([{ id, type: "user" }], null);
  return t.rows(width, 0, 20).map((r) => (r.text != null ? r.text : (r.segments || []).map((s) => s.text).join(""))).join("");
};

// A message with no attachment reads exactly as it always did.
parts.a = [{ type: "text", id: 0, text: "just words" }];
check("text-only", body("a").indexOf("just words") >= 0 && body("a").indexOf("[") < 0);

// The label lands where the part sits, between the two runs of text.
parts.b = [
  { type: "text", id: 0, text: "before" },
  { type: "image", id: 1, source: png },
  { type: "text", id: 2, text: "after" },
];
check("interleaved", body("b").indexOf("before[PNG #1 · 12 KiB]after") >= 0);

// Images number by position, and each names its own type and its own size.
parts.c = [
  { type: "image", id: 0, source: png },
  { type: "image", id: 1, source: jpg },
  { type: "image", id: 2, source: tiny },
];
check("numbered", body("c").indexOf("[PNG #1 · 12 KiB][JPEG #2 · 2.1 MiB][GIF #3 · 900 B]") >= 0);

