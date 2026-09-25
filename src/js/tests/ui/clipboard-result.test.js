import { check } from "yuke:test";

// The later phase of `clipboard.test.js`, after the host pumped every read to its answer.
check("attached", globalThis.good.spans.length === 1 && globalThis.good.projection().text === "[PNG #1]");
check("span-covers-the-temp-path", globalThis.good.text === "/tmp/yuke-paste-aaa");
check("temp-removed", globalThis.removed.indexOf("/tmp/yuke-paste-aaa") >= 0);

check("empty-inserts-nothing", globalThis.empty.text === "" && globalThis.empty.spans.length === 0);
check("empty-speaks", globalThis.notices.indexOf("no image on the clipboard") >= 0);

// A refusal must not leave the temporary file behind, and must not leave a path in the buffer either.
check("refused-inserts-nothing", globalThis.refused.text === "" && globalThis.refused.spans.length === 0);
check("refused-still-removes", globalThis.removed.indexOf("/tmp/yuke-paste-bad") >= 0);
check("refused-speaks", globalThis.notices.some((m) => m.indexOf("holds no image") >= 0));
