import { client } from "yuke:internal/client";
import { native } from "yuke:internal/native/engine";
import { equal } from "yuke:internal/test";

const sid = globalThis.PROJECTION_SESSION;
const source = globalThis.PROJECTION_TEXT;
const previous = client.sessionPart(sid, 2, 0);
globalThis.previousPart = previous;
const held = { type: "text", id: 0, text: "x".repeat(source.length) };
const fresh = client.sessionPart(sid, 2, 0, held);
equal(fresh.text, source);
equal(fresh.id, 0);
equal(fresh.type, "text");
equal("text_generation" in fresh, false);
equal(held.text, "x".repeat(source.length));
equal(client.sessionPart(sid, 1, 0, previous).text, source);
const initial = JSON.parse(native.sessionPart(sid, 2, 0))[0];
const same = JSON.parse(native.sessionPart(sid, 2, 0, initial.text_generation, initial.text_bytes))[0];
equal(same.text_offset, initial.text_bytes);
equal(same.text, "");
equal(client.sessionPart(sid, 2, 0, previous).text, source);
equal(client.sessionPart(sid, 2, 0, { ...previous }).text, source);
const modified = client.sessionPart(sid, 2, 0);
modified.text = "x".repeat(source.length);
equal(client.sessionPart(sid, 2, 0, modified).text, source);
// The offset follows UTF-8 bytes, and the next page offset stays relative to the whole field.
const prefix = "A paragraph 世界 é 👩‍💻.\n\n";
const partial = JSON.parse(native.sessionPart(sid, 2, 0, initial.text_generation, 37))[0];
equal(partial.text_offset, 37);
let actual = prefix + partial.text;
let offset = partial.cut[0].next;
while (offset != null) {
  const page = client.partTextPage(sid, 2, 0, "text", offset);
  actual += page.text;
  offset = page.next;
}
equal(actual, source);
for (const [generation, bytes] of [[initial.text_generation + 1, 37], [initial.text_generation, 13], [initial.text_generation, initial.text_bytes + 1], [initial.text_generation, -1], [initial.text_generation, 1.5], [NaN, 37]]) {
  equal(JSON.parse(native.sessionPart(sid, 2, 0, generation, bytes))[0].text_offset, 0);
}
// Invalid numeric hints must not call user code while native code holds the session.
let coerced = false;
const hint = { valueOf() { coerced = true; return 37; } };
native.sessionPart(sid, 2, 0, hint, hint);
equal(coerced, false);
for (const part of client.sessionParts(sid, 2)) {
  equal("text_generation" in part, false);
  equal("text_bytes" in part, false);
  equal("text_offset" in part, false);
}

const reasoning = client.sessionPart(sid, 2, 1, { type: "reasoning", id: 1, text: "why ", signature: "" });
equal(reasoning.type, "reasoning");
equal(reasoning.text, "why 世界");
equal("text_generation" in reasoning, false);
const tool = client.sessionPart(sid, 2, 2, previous);
equal(tool.type, "tool");
equal(tool.arguments, "{}");
equal("text_generation" in tool, false);

equal(client.sessionPart(sid, 2, 1, reasoning).text, "why 世界");
