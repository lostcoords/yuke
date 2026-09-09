import { check } from "yuke:test";
import { term } from "yuke:term";
import { Transcript } from "yuke:transcript";

const body = { u1: "ask", a1: "text\n```zig\nconst a = 1;\n```\nmore", a2: "second reply" };
const t = new Transcript({ textOf: (id) => body[id] || "" });
t.setOutline([{ id: "u1", type: "user" }, { id: "a1", type: "assistant" }], null);

check("last-assistant", t.last("assistant").id === "a1");
check("last-any", t.last().id === "a1");
check("text-for", t.textFor(t.last("assistant")) === body.a1);
check("no-user-code", t.messages().length === 2);

// The block body carries no fence line and no language line.
const blocks = t.codeBlocks();
check("one-block", blocks.length === 1);
check("block-lang", blocks[0].lang === "zig");
check("block-text", blocks[0].text === "const a = 1;");
check("block-owner", blocks[0].id === "a1");

// A user turn can hold a fence too, so no turn type is skipped.
const ub = { u2: "look:\n```sh\nls -l\n```", a3: "ok" };
const ut = new Transcript({ textOf: (id) => ub[id] || "" });
ut.setOutline([{ id: "u2", type: "user" }, { id: "a3", type: "assistant" }], null);
check("user-block", ut.codeBlocks().length === 1 && ut.codeBlocks()[0].text === "ls -l");

// `codeBlocks` shares the row cache with the renderer, so a changed source must drop it.
const cb = { a1: "```zig\nold\n```" };
const ct = new Transcript({ textOf: (id) => cb[id] || "" });
ct.setOutline([{ id: "a1", type: "assistant" }], null);
const rowsHave = (rs, want) => rs.some((r) => (r.segments || []).some((sg) => sg.text.indexOf(want) >= 0));
check("rows-old", rowsHave(ct.rows(40, 0, 100), "old"));
const doc0 = ct._rows.get("a1").doc;
cb.a1 = "```zig\nnew\n```";
check("blocks-new", ct.codeBlocks()[0].text === "new");
check("same-doc", ct._rows.get("a1").doc === doc0);
check("rows-new", rowsHave(ct.rows(40, 0, 100), "new"));

// A returned descriptor is a copy, so a caller cannot change the transcript.
const got = t.last("assistant");
got.id = "hacked";
check("no-aliasing", t.last("assistant").id === "a1");

// The streaming draft is the newest message.
t.setOutline([{ id: "u1", type: "user" }, { id: "a1", type: "assistant" }], { id: "a2", type: "assistant" });
check("draft-is-last", t.last("assistant").id === "a2");
check("empty-last", new Transcript({}).last("assistant") === null);

// term.copy writes OSC 52 and returns the byte count. It refuses a payload over the cap.
check("copy-ok", term.copy("hi") === 2);
check("copy-utf8-bytes", term.copy("héllo 🙂") === 11);
check("copy-too-large", term.copy("x".repeat(term.clipboardMax + 1)) === -1);
// A non-string argument is a type error, so a stray object never reaches the clipboard.
const throws = (fn) => { try { fn(); return false; } catch (e) { return true; } };
check("copy-number", throws(() => term.copy(42)));
check("copy-null", throws(() => term.copy(null)));
check("copy-object", throws(() => term.copy({ toString: () => "x" })));
