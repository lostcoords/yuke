import { client } from "yuke:client";
import { native } from "yuke:engine-native";
import { equal } from "yuke:test";

const sid = globalThis.PROJECTION_SESSION;
const source = globalThis.PROJECTION_TEXT;
const previous = client.sessionPart(sid, 2, 0);
globalThis.previousPart = previous;
for (const text of ["", source, source.slice(0, 13), source + "extra", "replacement", "x".repeat(source.length), "A paragraph 世界 é 👩‍💻.\n\n"]) {
  const held = { type: "text", id: 0, text };
  const fresh = client.sessionPart(sid, 2, 0, held);
  equal(fresh.text, source);
  equal(fresh.id, 0);
  equal(fresh.type, "text");
  equal("text_prefix" in fresh, false);
  equal(held.text, text);
}
const same = JSON.parse(native.sessionPart(sid, 2, 0, source))[0];
equal(same.text_prefix, true);
equal(same.text, "");
// The prefix has multibyte characters; the next offset stays relative to the whole field.
const prefix = "A paragraph 世界 é 👩‍💻.\n\n";
const partial = JSON.parse(native.sessionPart(sid, 2, 0, prefix))[0];
equal(partial.text_prefix, true);
let actual = prefix + partial.text;
let offset = partial.cut[0].next;
while (offset != null) {
  const page = client.partTextPage(sid, 2, 0, "text", offset);
  actual += page.text;
  offset = page.next;
}
equal(actual, source);
// A non-string hint must not call user code while native code holds the session.
let coerced = false;
native.sessionPart(sid, 2, 0, { toString() { coerced = true; return source; } });
equal(coerced, false);

const reasoning = client.sessionPart(sid, 2, 1, { type: "reasoning", id: 1, text: "why ", signature: "" });
equal(reasoning.type, "reasoning");
equal(reasoning.text, "why 世界");
equal("text_prefix" in reasoning, false);
const tool = client.sessionPart(sid, 2, 2, previous);
equal(tool.type, "tool");
equal(tool.arguments, "{}");
equal("text_prefix" in tool, false);
