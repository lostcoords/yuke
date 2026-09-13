import { check } from "yuke:test";

// The later phase of `attach.test.js`, after the host pumped every attach to its answer.
check("attached", globalThis.ok.spans.length === 1 && globalThis.ok._projection().text === "[PNG #1]");
check("put-once", globalThis.puts.filter((p) => p === "/tmp/a.png").length === 1);

// The span covers the text the user pasted, and the engine reads the path behind it.
check("quoted-attached", globalThis.quoted.spans.length === 1 && globalThis.quoted._projection().text === "[PNG #1]");
check("quoted-keeps-raw", globalThis.quoted.text === "'/tmp/a b.png'" && globalThis.quoted.spans[0].end === 14);
check("quoted-put-resolved", globalThis.puts.indexOf("/tmp/a b.png") >= 0);

check("txt-never-put", globalThis.puts.every((p) => p.indexOf("notes") < 0));

// A refusal reaches the user and leaves the path as text.
check("refused-keeps-text", globalThis.refused.spans.length === 0 && globalThis.refused.text === "/tmp/huge.png");
check("refused-speaks", globalThis.notices.some((m) => m.indexOf("7 MiB") >= 0));

// A gate miss never speaks, so only the refusal said anything.
check("directory-no-span", globalThis.dir.spans.length === 0);
check("missing-no-span", globalThis.gone.spans.length === 0);
check("gate-is-silent", globalThis.notices.length === 1);

check("edited-no-span", globalThis.edited.spans.length === 0 && globalThis.edited.text === "");
