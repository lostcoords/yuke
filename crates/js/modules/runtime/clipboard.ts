/** The code of the public module `yuke:clipboard`. Its declaration is `types/clipboard.d.ts`, and the check at the end compares the two. */

import type { ClipboardImage } from "yuke:clipboard";
import { clipboardReadImage } from "yuke:internal/native";

export async function readImage(): Promise<ClipboardImage | undefined> {
  const bytes = await clipboardReadImage();
  return bytes === undefined ? undefined : Object.freeze({ bytes, mime: "image/png" });
}

// The check against `types/clipboard.d.ts` keeps this code and the declarations of the authors in step.
const declared = { readImage } satisfies typeof import("yuke:clipboard");
void declared;
