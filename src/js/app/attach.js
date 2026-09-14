// yuke:attach — a pasted path to an image becomes an attachment on the composer.
import { fs } from "yuke:fs";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { root } from "yuke:core";
import { events } from "yuke:kernel";
import { clipboard } from "yuke:clipboard";

/** @import { Composer } from "yuke:ui" */

// The engine sniffs the magic bytes, so this list decides one thing only: whether a paste is an attach at all.
const IMAGE_EXT = [".png", ".jpg", ".jpeg", ".gif", ".webp"];

// Strip one quote pair and the escapes a drag adds. The host anchors a relative path at the cwd.
/** @param {string} raw @returns {string} */
export function cleanPath(raw) {
  let path = raw.trim();
  const quote = path[0];
  if (path.length > 1 && (quote === '"' || quote === "'") && path[path.length - 1] === quote) path = path.slice(1, -1);
  return path.replace(/\\([ "'\\])/g, "$1");
}

// A path the user meant as prose must stay prose, so this test never speaks and never reads the disk.
/** @param {string} text @returns {boolean} */
export function looksLikeImagePath(text) {
  const path = cleanPath(text).toLowerCase();
  return path.indexOf("\n") < 0 && IMAGE_EXT.some((ext) => path.length > ext.length && path.endsWith(ext));
}

// Copy one image into the blob store. The caller already decided this is an attach, so a refusal reaches the user.
/** @param {string} path @returns {Promise<Wire.MediaBlob | null>} */
async function putImage(path) {
  return client.blobPut(path).catch((e) => {
    notice.show("attach failed · " + ((e && e.message) || "unknown"));
    return null;
  });
}

// Copy the image into the blob store and hang it on the composer at `from`, over the text the caller inserted.
/** @param {Composer} composer @param {string} text @param {number} from @returns {Promise<boolean>} */
export async function attachPath(composer, text, from) {
  // The gate decides "attach or text", so a path that names no file falls back without a word.
  const stat = await fs.stat(cleanPath(text)).catch(() => null);
  if (!stat || stat.isDirectory) return false;
  const blob = await putImage(stat.path);
  return blob !== null && attached(composer, from, text, blob);
}

// Ctrl+V: insert nothing until the blob exists, because no user text depends on the answer.
/** @param {Composer} composer @returns {Promise<boolean>} */
export async function attachClipboard(composer) {
  const read = await clipboard.readImage();
  if (!("path" in read)) {
    notice.show(read.error);
    root.invalidate();
    return false;
  }
  const blob = await putImage(read.path);
  // The engine holds its own copy, so nothing reads the temporary file again.
  await fs.removeFile(read.path).catch(() => false);
  if (blob === null) {
    root.invalidate();
    return false;
  }
  const from = composer.input.caret;
  composer.input.insert(read.path);
  const ok = attached(composer, from, read.path, blob);
  root.invalidate();
  return ok;
}

// Hang the blob on the composer and say so, because an owner may have something to warn about.
/** @param {Composer} composer @param {number} from @param {string} text @param {Wire.MediaBlob} blob @returns {boolean} */
function attached(composer, from, text, blob) {
  if (!composer.attach(from, text, blob)) return false;
  events.emit("composer.attached", composer);
  return true;
}

// The composer offers each paste here first. A path to an image is claimed; everything else stays text.
/** @param {Composer} composer @param {string} text @param {number} from @returns {boolean} */
export function pasteAttaches(composer, text, from) {
  if (!looksLikeImagePath(text)) return false;
  // The paste is already in the buffer, so the attach only upgrades that range once the engine answers.
  attachPath(composer, text, from).then(() => root.invalidate(), () => root.invalidate());
  return true;
}
