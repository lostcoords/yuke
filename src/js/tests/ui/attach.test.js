import { check } from "yuke:test";
import { Composer } from "yuke:ui";
import { fs } from "yuke:fs";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { term } from "yuke:term";
import { cleanPath, looksLikeImagePath, pasteAttaches } from "yuke:attach";
const paste = (t) => ({ type: "paste", text: t });
const png = { hash: "a".repeat(64), mime: "image/png", bytes: 2048 };

// One quote pair comes off, a drag escape comes out, and the surrounding space goes.
check("plain", cleanPath("/tmp/a.png") === "/tmp/a.png");
check("quoted", cleanPath("'/tmp/a b.png'") === "/tmp/a b.png");
check("escaped", cleanPath("/tmp/a\\ b.png") === "/tmp/a b.png");
check("trimmed", cleanPath("  /tmp/a.png  ") === "/tmp/a.png");
// The host anchors a relative path, so the cleaner leaves it alone.
check("relative", cleanPath("a.png") === "a.png");

// The gate reads the extension and nothing else, so it never touches the disk.
check("gate-png", looksLikeImagePath("/tmp/a.png"));
check("gate-upper", looksLikeImagePath("/tmp/A.PNG"));
check("gate-quoted", looksLikeImagePath("\"/tmp/a b.jpeg\""));
check("gate-txt", looksLikeImagePath("/tmp/a.txt") === false);
check("gate-prose", looksLikeImagePath("look at the file\nand the png") === false);
check("gate-bare-extension", looksLikeImagePath(".png") === false);

globalThis.puts = [];
globalThis.notices = [];
notice.show = (message) => { globalThis.notices.push(message); };
// The host anchors a relative path at the cwd and answers the whole path.
fs.stat = async (path) => {
  const full = path[0] === "/" ? path : (term.cwd || "/cwd").replace(/\/+$/, "") + "/" + path;
  if (path.endsWith("/dir.png")) return { path: full, isDirectory: true, lastModifiedMs: 0 };
  return path.indexOf("missing") < 0 ? { path: full, isDirectory: false, lastModifiedMs: 0 } : null;
};
client.blobPut = async (path) => {
  globalThis.puts.push(path);
  if (path.indexOf("huge") >= 0) throw new Error("the image is larger than 7 MiB");
  return png;
};

const make = () => {
  const c = new Composer({ onSubmit: () => true });
  c.rect = { x: 0, y: 0, w: 40, h: 6 };
  c.onPaste = (text, from) => pasteAttaches(c, text, from);
  return c;
};

// The paste lands at once and only becomes a span after the engine answers.
globalThis.ok = make();
globalThis.ok.onKey(paste("/tmp/a.png"));
check("text-lands-at-once", globalThis.ok.text === "/tmp/a.png");
check("no-span-yet", globalThis.ok.spans.length === 0);

globalThis.quoted = make();
globalThis.quoted.onKey(paste("'/tmp/a b.png'"));

// A path to anything else is prose, so it never reaches the engine.
globalThis.plain = make();
globalThis.plain.onKey(paste("/tmp/notes.txt"));
check("txt-stays-text", globalThis.plain.text === "/tmp/notes.txt" && globalThis.plain.spans.length === 0);

// A large paste that is no path still collapses to its own label.
globalThis.big = make();
globalThis.big.onKey(paste("one\ntwo\nthree\nfour"));
check("paste-still-collapses", globalThis.big.spans.length === 1 && globalThis.big._projection().text === "[Pasted text #1 +4 lines]");

globalThis.refused = make();
globalThis.refused.onKey(paste("/tmp/huge.png"));

globalThis.dir = make();
globalThis.dir.onKey(paste("/tmp/dir.png"));

globalThis.gone = make();
globalThis.gone.onKey(paste("/tmp/missing.png"));

// The buffer moves on before the engine answers, so the attach finds nothing to upgrade.
globalThis.edited = make();
globalThis.edited.onKey(paste("/tmp/late.png"));
globalThis.edited.text = "";
