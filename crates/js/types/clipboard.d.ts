// The declaration of the public module `yuke:clipboard`.

/**
 * The image of the system clipboard. The terminal copies text through OSC 52 (`tui.copy`), so this module only reads
 * an image. The read needs a display. It takes PNG, and on macOS also TIFF. It always gives PNG.
 */
declare module "yuke:clipboard" {
  /** An image of the clipboard as PNG. */
  export interface ClipboardImage {
    readonly bytes: Uint8Array;
    readonly mime: "image/png";
  }

  /**
   * The image of the clipboard, or `undefined` when it holds no image, as for text only. On Linux, a display that does
   * not answer also gives `undefined`. A failed read of an image rejects. A PNG over 3,932,160 bytes rejects.
   */
  export function readImage(): Promise<ClipboardImage | undefined>;
}
