// The declaration of the public module `yuke:tui`.

/**
 * The types of the terminal interface and its stateless helpers. An import of this module starts nothing, so a plugin
 * can import it in each mode. Text offsets are UTF-16 units, as in JavaScript strings.
 */
declare module "yuke:tui" {
  import type { NoticeLevel } from "yuke:plugins";

  /**
   * A key press. The bits of `mods`: shift 1, alt 2, ctrl 4, super 8, hyper 16, meta 32.
   */
  export interface KeyEvent {
    readonly type: "key";
    /** `char` for a key of one character, else a name such as `enter`, `esc`, `up`, `page_down`, or `f5`. */
    readonly code: string;
    /** The character of a `char` key, else "". */
    readonly char: string;
    /** The key with shift on the current layout, from a kitty terminal, else "". */
    readonly shifted: string;
    /** The key at the same place on a US layout, from a kitty terminal, else "". `strokeOf` does not read it. */
    readonly baseLayout: string;
    /** The text that the key types, else "". */
    readonly text: string;
    readonly mods: number;
  }

  /** A mouse press, release, motion, drag, or wheel turn. The bits of `mods`: shift 1, alt 2, ctrl 4. */
  export interface MouseEvent {
    readonly type: "mouse";
    readonly col: number;
    readonly row: number;
    /** `left`, `middle`, `right`, `none`, `wheel_up`, `wheel_down`, `wheel_left`, `wheel_right`, or `button_N`. */
    readonly button: string;
    readonly event: "press" | "release" | "motion" | "drag";
    readonly mods: number;
  }

  /** A paste of the terminal. */
  export interface PasteEvent {
    readonly type: "paste";
    readonly text: string;
  }

  /** The names of the base palette. Each one has a color for a dark and a light background. */
  export type PaletteColor =
    | "fg"
    | "bg"
    | "surfaceFg"
    | "strongFg"
    | "accent"
    | "accentMuted"
    | "surface"
    | "warn"
    | "danger"
    | "pendingBg"
    | "errorBg"
    | "diffAddBg"
    | "diffDelBg";

  /** A color: a palette index from 0 to 255, `#` and six hex digits, `reset`, or a name of the base palette. */
  export type Color = number | `#${string}` | "reset" | PaletteColor;

  /** A style: the colors and the attributes of a cell. `link` names a style group whose fields fill the missing ones. */
  export interface Style {
    readonly fg?: Color;
    readonly bg?: Color;
    /** The underline color. It does not turn the underline on. */
    readonly ul?: Color;
    readonly bold?: boolean;
    readonly dim?: boolean;
    readonly italic?: boolean;
    readonly reverse?: boolean;
    readonly underline?: boolean;
    readonly link?: string;
  }

  /** A change of a style group: a field changes, `null` deletes it, and a missing field stays. */
  export type StylePatch = { readonly [K in keyof Style]?: Style[K] | null };

  /** A command: the palette lists it, and a key binding names it. */
  export interface Command {
    /** The name: letters, digits, and `:`, `-`, `_`, `.`. */
    readonly name: string;
    /** The text of the palette. */
    readonly title?: string;
    /** Run the command. The keymap does not wait for a promise, so the keys go on during the run. */
    readonly run: (args: unknown) => void | Promise<void>;
    /** False when the command cannot run now. A disabled command passes its key on. */
    readonly enabled?: () => boolean;
  }

  /** A notice of the host or of a plugin. A later notice with the same level, source, and text raises `count`. */
  export interface Notice {
    readonly level: NoticeLevel;
    /** The plugin name, `console`, or `host:…`. */
    readonly source: string;
    readonly text: string;
    readonly count: number;
  }

  /** The cells of `text`. */
  export function measure(text: string): number;
  /** The UTF-16 offset, the UTF-16 length, and the cells of each grapheme of `text`, three numbers each. */
  export function graphemes(text: string): Int32Array;
  /** The UTF-16 length of the longest grapheme prefix of `text` that fits in `cells`. */
  export function fit(text: string, cells: number): number;
  /**
   * The rows of `text` at `width` cells, as `[start, end, soft]` triples. A line end ends a row (soft 0). A soft break
   * (soft 1) comes after the last space when the text from that space fits, else before the grapheme that does not
   * fit. With `head`, only the first `head` rows stay.
   */
  export function wrap(text: string, width: number, head?: number): Int32Array;
  /**
   * The strokes of the key spec `spec`, in the form that `strokeOf` gives. White space separates the strokes. A stroke
   * is `ctrl+alt+super+shift+key`: a named key in lower case (`enter`, `esc`, `space`, `page_down`, `f5`), or one
   * character. A character keeps its case, and shift without ctrl, alt, or super folds into it: `shift+g` is `G`. A
   * shifted symbol is its own character: write `!`, not `shift+1`. With ctrl, alt, or super, the character is lower
   * case and shift drops: `ctrl+shift+a` is `ctrl+a`. A spec that names no key throws a `TypeError`.
   */
  export function parseKeys(spec: string): string[];
  /** The stroke of `event`, as `parseKeys` writes it, or "" for a key that no spec names, such as one with hyper. */
  export function strokeOf(event: KeyEvent): string;
}
