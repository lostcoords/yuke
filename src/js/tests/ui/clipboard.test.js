import { check } from "yuke:test";
import { Composer } from "yuke:ui";
import { fs } from "yuke:fs";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { clipboard } from "yuke:clipboard";
import { attachClipboard } from "yuke:attach";
const png = { hash: "c".repeat(64), mime: "image/png", bytes: 4096 };

globalThis.removed = [];
globalThis.notices = [];
notice.show = (message) => { globalThis.notices.push(message); };
fs.removeFile = async (path) => { globalThis.removed.push(path); return true; };
client.blobPut = async (path) => {
  if (path.indexOf("bad") >= 0) throw new Error("the file holds no image");
  return png;
};

const make = () => {
  const c = new Composer({ onSubmit: () => true });
  c.rect = { x: 0, y: 0, w: 40, h: 6 };
  return c;
};

// The clipboard holds an image: it becomes a blob, and the temporary file goes with it.
clipboard.readImage = async () => ({ path: "/tmp/yuke-paste-aaa" });
globalThis.good = make();
globalThis.goodDone = attachClipboard(globalThis.good);
check("nothing-before-the-answer", globalThis.good.text === "");

// The clipboard holds no image: the composer never hears about it beyond the notice.
clipboard.readImage = async () => ({ error: "no image on the clipboard" });
globalThis.empty = make();
globalThis.emptyDone = attachClipboard(globalThis.empty);

// The engine refuses the file: nothing enters the buffer, and the temporary file still goes.
clipboard.readImage = async () => ({ path: "/tmp/yuke-paste-bad" });
globalThis.refused = make();
globalThis.refusedDone = attachClipboard(globalThis.refused);
