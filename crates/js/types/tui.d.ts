// The declaration of the public module `yuke:tui`.

/**
 * The types of the terminal interface and its stateless helpers. An import of this module starts nothing, so a plugin
 * can import it in each mode. Coordinates are local cells from 0. Text offsets are UTF-16 units, as in JavaScript
 * strings.
 */
declare module "yuke:tui" {
  import type { NoticeLevel } from "yuke:plugins";

  export interface Size {
    readonly width: number;
    readonly height: number;
  }

  export interface Point {
    readonly column: number;
    readonly row: number;
  }

  export interface Rect extends Point, Size {}

  /** Remove a registration. A second call does nothing. */
  export type Disposer = () => void;

  export type Direction = "row" | "column";

  export type FocusDirection = "left" | "right" | "up" | "down";

  /** The modifiers of a key or a mouse event. A terminal reports only shift, alt, and ctrl with a mouse event. */
  export interface Modifiers {
    readonly shift: boolean;
    readonly alt: boolean;
    readonly ctrl: boolean;
    readonly super: boolean;
    readonly hyper: boolean;
    readonly meta: boolean;
  }

  type FunctionNumber =
    | 1
    | 2
    | 3
    | 4
    | 5
    | 6
    | 7
    | 8
    | 9
    | 10
    | 11
    | 12
    | 13
    | 14
    | 15
    | 16
    | 17
    | 18
    | 19
    | 20
    | 21
    | 22
    | 23
    | 24
    | 25
    | 26
    | 27
    | 28
    | 29
    | 30
    | 31
    | 32
    | 33
    | 34
    | 35;

  /** `character` for a key of one character, else the name of the key. A function key past 35 is `unknown`. */
  export type KeyCode =
    | "character"
    | "enter"
    | "tab"
    | "backspace"
    | "esc"
    | "insert"
    | "delete"
    | "left"
    | "right"
    | "up"
    | "down"
    | "page_up"
    | "page_down"
    | "home"
    | "end"
    | "menu"
    | `f${FunctionNumber}`
    | "unknown";

  export interface KeyEvent {
    readonly type: "key";
    readonly code: KeyCode;
    /** The character of a `character` key, else "". */
    readonly character: string;
    /** The key with shift on the current layout, from a kitty terminal, else "". */
    readonly shifted: string;
    /** The key at the same place on a US layout, from a kitty terminal, else "". `strokeOf` does not read it. */
    readonly baseLayout: string;
    /** The text that the key types, else "". */
    readonly text: string;
    readonly modifiers: Modifiers;
  }

  export type MouseButton =
    | "left"
    | "middle"
    | "right"
    | "none"
    | "wheel_up"
    | "wheel_down"
    | "wheel_left"
    | "wheel_right"
    | `button_${number}`;

  /**
   * A mouse event, local to the view. A captured drag can leave the rect of the view, so its coordinates can be
   * negative or past the size.
   */
  export interface MouseEvent extends Point {
    readonly type: "mouse";
    readonly button: MouseButton;
    /** `cancel` ends a capture without a release, as when a modal opens during a drag. */
    readonly action: "press" | "release" | "motion" | "drag" | "cancel";
    readonly modifiers: Modifiers;
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
    readonly fg?: Color | undefined;
    readonly bg?: Color | undefined;
    /** The color of the underline. It does not turn the underline on. */
    readonly underlineColor?: Color | undefined;
    readonly bold?: boolean | undefined;
    readonly dim?: boolean | undefined;
    readonly italic?: boolean | undefined;
    readonly reverse?: boolean | undefined;
    readonly underline?: boolean | undefined;
    readonly link?: string | undefined;
  }

  /** A change of a style group: a field changes, `null` deletes it, and a missing field stays. */
  export type StylePatch = { readonly [K in keyof Style]?: Style[K] | null };

  /** A command: the palette lists it, and a key binding names it. */
  export interface Command {
    /** The name: letters, digits, and `:`, `-`, `_`, `.`. */
    readonly name: string;
    /** The text of the palette. */
    readonly title?: string | undefined;
    /** Run the command. The keymap does not wait for a promise, so the keys go on during the run. */
    readonly run: (args: unknown) => void | Promise<void>;
    /** False when the command cannot run now. A disabled command passes its key on. */
    readonly enabled?: (() => boolean) | undefined;
  }

  /** A command as the palette lists it. */
  export interface CommandItem {
    readonly name: string;
    readonly title: string;
    readonly enabled: boolean;
  }

  /** A notice of the host or of a plugin. A notice with the level, source, and text of the last one raises `count`. */
  export interface Notice {
    readonly level: NoticeLevel;
    /** The plugin name, `console`, or `host:…`. */
    readonly source: string;
    readonly text: string;
    readonly count: number;
  }

  /** What a view draws on. It is valid only during the draw call that gets it. A draw outside its rect is cut off. */
  export interface Canvas extends Size {
    /** Write `text` on one row and return the column after it. `style` is a style group name or a style. */
    readonly text: (column: number, row: number, text: string, style?: string | Style) => number;
    readonly fill: (column: number, row: number, width: number, height: number, style?: string | Style) => void;
    /** A canvas for a part of this one, cut to this one. */
    readonly region: (column: number, row: number, width: number, height: number) => Canvas;
  }

  /** A child of a view and its rect, local to the view. */
  export interface Placement {
    readonly view: View;
    readonly rect: Rect;
  }

  /** Anything that draws. An object (`satisfies View`) or a class. */
  export interface View {
    /** The children and their rects. The core draws each child after its parent, routes its input, and guards it. */
    readonly layout?: ((size: Size) => readonly Placement[]) | undefined;
    /** Draw the view. `focused` is true when the view or a child has the focus. */
    readonly draw: (canvas: Canvas, focused: boolean) => void;
    /** True when a click or `tui.focus` can give the view the focus. The view of a pane can take it without this. */
    readonly focusable?: boolean | undefined;
    readonly focusChanged?: ((focused: boolean) => void) | undefined;
    /** The context atoms of the keymap while the view is on the focus path. */
    readonly contexts?: readonly string[] | undefined;
    /** True when the view takes the key. */
    readonly key?: ((event: KeyEvent) => boolean) | undefined;
    readonly mouse?: ((event: MouseEvent) => boolean) | undefined;
    readonly paste?: ((text: string) => boolean) | undefined;
    /** The cursor of the focused view, or `undefined` for none. */
    readonly cursor?: (() => Point | undefined) | undefined;
    /** The type and the state that restore the view after a reload. */
    readonly snapshot?: (() => ViewSnapshot) | undefined;
  }

  /** A mounted view. `close()` runs once by any path, and `signal` aborts at the close. */
  export interface Mount {
    readonly close: () => void;
    readonly signal: AbortSignal;
  }

  /** Make the view of a new mount. A throw closes the mount and gives one fault. */
  export type ViewFactory = (mount: Mount) => View;

  export interface Pane extends Mount {
    readonly view: View;
    readonly focus: () => void;
  }

  /** The pane tree of the core. */
  export interface Panes {
    /** The view of the tree, for a root layout. */
    readonly view: View;
    /** The active pane beneath any modal. */
    readonly active: Pane | undefined;
    /** Split the active pane. The new pane gets the focus. The last pane stays when it closes. */
    readonly split: (create: ViewFactory, options?: { readonly direction?: Direction | undefined }) => Pane;
    readonly focus: (direction: FocusDirection) => boolean;
    readonly focusNext: () => void;
  }

  export interface OverlayOptions {
    /** Default true: a modal takes the focus and all input below it. A float takes only what it handles. */
    readonly modal?: boolean | undefined;
    /** The rect of the overlay. Default: the full screen. */
    readonly place?: ((size: Size) => Rect) | undefined;
  }

  /** The size of a child of `stack`: cells, a share of the rest, or cells from the size of the stack. */
  export type StackSize = number | "fill" | ((size: Size) => number);

  export interface StackChild {
    readonly view: View;
    readonly size: StackSize;
  }

  /** A JSON value. */
  export type JsonValue =
    | null
    | boolean
    | number
    | string
    | readonly JsonValue[]
    | { readonly [key: string]: JsonValue };

  export interface ViewSnapshot {
    /** A view type of `tui.views.register`. */
    readonly type: string;
    readonly state: JsonValue;
  }

  /** Make a view from its saved state. The state can come from an older version of the plugin. */
  export type RestoreView = (state: unknown, mount: Mount) => View;

  /** The surface of one plugin: `ctx.get("tui")`. Each registration and mount belongs to the plugin. */
  export interface Tui extends Size {
    readonly background: "dark" | "light";
    readonly truecolor: boolean;
    readonly panes: Panes;
    /** The deepest view on the focus path. */
    readonly focused: View | undefined;
    readonly focus: (view: View) => boolean;
    /** Set the root view. Its close gives the default root back: the pane tree alone. */
    readonly setRoot: (create: ViewFactory) => Mount;
    readonly overlay: (create: ViewFactory, options?: OverlayOptions) => Mount;
    readonly commands: {
      readonly add: (command: Command) => Disposer;
      /** Run a command. `false` when it is missing or disabled, else `true`, also when the run fails later. */
      readonly run: (name: string, args?: unknown) => boolean;
      readonly list: () => readonly CommandItem[];
    };
    readonly keys: {
      readonly bind: (spec: string, command: string, options?: { readonly in?: string | undefined }) => Disposer;
      /** The keys of the pending sequence, such as `ctrl+k`, or "". */
      readonly pending: () => string;
      readonly keysOf: (name: string) => readonly string[];
    };
    readonly styles: {
      readonly set: (name: string, patch: StylePatch) => Disposer;
    };
    readonly notices: {
      readonly list: () => readonly Notice[];
      readonly on: (listener: (notice: Notice) => void) => Disposer;
    };
    readonly views: {
      readonly register: (type: string, restore: RestoreView) => Disposer;
    };
    /** Ask for a frame in `delay` milliseconds. Many asks give one frame. Ask after a state change outside the input. */
    readonly requestFrame: (delay?: number) => void;
    /** Send `text` to the clipboard of the terminal. */
    readonly copy: (text: string) => void;
  }

  /** A layout of children in a row or a column. Sized children take their cells in order; `fill` shares the rest. */
  export function stack(direction: Direction, children: readonly StackChild[]): View;

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
  export function parseKeys(spec: string): readonly string[];
  /** The stroke of `event`, as `parseKeys` writes it, or "" for a key that no spec names, such as one with hyper. */
  export function strokeOf(event: KeyEvent): string;
}
