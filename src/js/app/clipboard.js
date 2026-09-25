// Read one image off the OS clipboard into a temporary file.
import { exec } from "yuke:internal/native/exec";
import { fs } from "yuke:internal/native/fs";

/** @typedef {{ path: string } | { error: string }} ClipboardRead */

// A clipboard tool that gives no answer in this time will not answer.
const TIMEOUT_MS = 5000;

// Exit codes the script answers with, because a caller cannot tell a missing tool from an empty clipboard otherwise.
const NO_IMAGE = 1;
const NO_TOOL = 3;

// Chromium apps put only `public.png` on the clipboard, so the read uses NSPasteboard. A TIFF-only clipboard converts to PNG.
const MAC_READ = [
  'ObjC.import("AppKit");',
  "function run(argv) {",
  "  const pb = $.NSPasteboard.generalPasteboard;",
  '  let data = pb.dataForType("public.png");',
  "  if (data.isNil()) {",
  '    const tiff = pb.dataForType("public.tiff");',
  '    if (tiff.isNil()) throw new Error("no image");',
  "    data = $.NSBitmapImageRep.imageRepWithData(tiff).representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());",
  "  }",
  '  if (!data.writeToFileAtomically(argv[0], true)) throw new Error("write failed");',
  "}",
].join("\n");

// The shell picks its own branch, because it alone knows the system. The path prints before the work, so a failure leaves the caller a file to remove.
const READ_IMAGE = [
  'd=${TMPDIR:-/tmp}; d=${d%/}',
  'p=$(mktemp "$d/yuke-paste-XXXXXX") || exit 2',
  'printf %s "$p"',
  'if [ "$(uname)" = Darwin ]; then',
  // The path goes in as an argument, so no quote in it can break the script.
  "  osascript -l JavaScript -e '" + MAC_READ + "' \"$p\" >/dev/null 2>&1 || exit 1",
  'elif [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-paste >/dev/null 2>&1; then',
  "  t=$(wl-paste --list-types 2>/dev/null | grep -m1 -E '^image/(png|jpeg|webp|gif)$') || exit 1",
  '  wl-paste --type "$t" --no-newline >"$p" 2>/dev/null || exit 1',
  'elif command -v xclip >/dev/null 2>&1; then',
  "  t=$(xclip -selection clipboard -t TARGETS -o 2>/dev/null | grep -m1 -E '^image/(png|jpeg|webp|gif)$') || exit 1",
  '  xclip -selection clipboard -t "$t" -o >"$p" 2>/dev/null || exit 1',
  'else',
  '  exit 3',
  'fi',
  '[ -s "$p" ] || exit 1',
].join("\n");

// Read one image off the clipboard. The caller owns the temporary file on success, and a failure removes it here.
/** @returns {Promise<ClipboardRead>} */
async function readImage() {
  const run = await exec(READ_IMAGE, { timeoutMs: TIMEOUT_MS }).catch(() => null);
  if (run === null) return { error: "the clipboard read failed" };
  const path = run.stdout.trim();
  if (run.code === 0 && path !== "") return { path };
  // A timeout also printed the path first, so the removal comes before every error.
  if (path !== "") await fs.removeFile(path).catch(() => false);
  if (run.timedOut) return { error: "the clipboard read timed out" };
  if (run.code === NO_TOOL) return { error: "no clipboard tool · install wl-clipboard or xclip" };
  return { error: run.code === NO_IMAGE ? "no image on the clipboard" : "the clipboard read failed" };
}

// One object, so a test replaces the OS boundary the way it replaces `client` and `fs`.
export const clipboard = { readImage };
