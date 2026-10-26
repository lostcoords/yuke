/**
 * The style groups of the terminal interface. Each `set` adds a layer, and the newest layer wins per field. A color
 * can name the base palette, which follows the color depth and the background of the terminal.
 */
import type { TermColor, TermStyle } from "yuke:internal/native";
import type { Color, PaletteColor, Style, StylePatch } from "yuke:tui";

type Palette = Readonly<Record<PaletteColor, TermColor>>;

/** The base palettes. Each 256-color pick keeps the hue of its 24-bit color. */
const PALETTES: Readonly<Record<"truecolor" | "256", Readonly<Record<"dark" | "light", Palette>>>> = {
  truecolor: {
    dark: {
      fg: "reset",
      bg: "reset",
      surfaceFg: "#E6EDF3",
      strongFg: "#F6F8FA",
      accent: "#A8CFA0",
      accentMuted: "#355C4A",
      surface: "#343A46",
      warn: "#E3B341",
      danger: "#FF7B72",
      pendingBg: "#3B3520",
      errorBg: "#4A2323",
      diffAddBg: "#20372A",
      diffDelBg: "#3A2426",
    },
    light: {
      fg: "reset",
      bg: "reset",
      surfaceFg: "#1F2328",
      strongFg: "#0D1117",
      accent: "#2D6A4F",
      accentMuted: "#B7D7B0",
      surface: "#E8EAED",
      warn: "#9A6700",
      danger: "#CF222E",
      pendingBg: "#FFF8C5",
      errorBg: "#FFEBE9",
      diffAddBg: "#E6F4EA",
      diffDelBg: "#FFEBE9",
    },
  },
  "256": {
    dark: {
      fg: "reset",
      bg: "reset",
      surfaceFg: 255,
      strongFg: 231,
      accent: 151,
      accentMuted: 23,
      surface: 237,
      warn: 179,
      danger: 209,
      pendingBg: 58,
      errorBg: 52,
      diffAddBg: 22,
      diffDelBg: 52,
    },
    light: {
      fg: "reset",
      bg: "reset",
      surfaceFg: 235,
      strongFg: 233,
      accent: 29,
      accentMuted: 151,
      surface: 255,
      warn: 94,
      danger: 124,
      pendingBg: 230,
      errorBg: 224,
      diffAddBg: 194,
      diffDelBg: 224,
    },
  },
};

const COLORS = ["fg", "bg", "ul"] as const;
const FLAGS = ["bold", "dim", "italic", "reverse", "underline"] as const;

interface Layer {
  readonly name: string;
  readonly patch: StylePatch;
}

export class Styles {
  readonly #truecolor: () => boolean;
  readonly #background: () => "dark" | "light";
  readonly #layers: Layer[] = [];
  readonly #cache = new Map<string, TermStyle>();
  /** The palette of the cached styles. */
  #palette: Palette | undefined;

  /** `truecolor` and `background` give the state of the terminal, which picks the base palette. */
  constructor(truecolor: () => boolean, background: () => "dark" | "light") {
    this.#truecolor = truecolor;
    this.#background = background;
  }

  /** Change the group `name` by `patch`, and return the disposer of the change. A bad field throws a `TypeError`. */
  set(name: string, patch: StylePatch): () => void {
    if (typeof name !== "string" || name === "") throw new TypeError("a style group has a name that is not empty");
    const layer: Layer = { name, patch: checked(patch, true) };
    this.#layers.push(layer);
    this.#cache.clear();
    return () => {
      const at = this.#layers.indexOf(layer);
      if (at < 0) return;
      this.#layers.splice(at, 1);
      this.#cache.clear();
    };
  }

  /** The cell style of the group `group`, or of the style object `group`. A group with no layer has no field. */
  resolve(group: string | Style): TermStyle {
    const palette = PALETTES[this.#truecolor() ? "truecolor" : "256"][this.#background()];
    if (palette !== this.#palette) {
      this.#cache.clear();
      this.#palette = palette;
    }
    if (typeof group !== "string") return this.#cell(checked(group, false) as Style, palette, new Set());
    // Only a whole resolve enters the cache: a group inside a link cycle depends on the group where the cycle starts.
    let style = this.#cache.get(group);
    if (style === undefined) {
      style = this.#named(group, palette, new Set());
      this.#cache.set(group, style);
    }
    return style;
  }

  #named(name: string, palette: Palette, seen: Set<string>): TermStyle {
    // A link cycle stops at the first repeated group.
    if (seen.has(name)) return {};
    seen.add(name);
    const fields: Record<string, unknown> = {};
    for (const { patch } of this.#layers.filter((layer) => layer.name === name)) {
      for (const [field, value] of Object.entries(patch)) {
        if (value === null) delete fields[field];
        else if (value !== undefined) fields[field] = value;
      }
    }
    return this.#cell(fields as Style, palette, seen);
  }

  /** The cell style of `style`: its link first, then its own fields, with each color from the palette. */
  #cell(style: Style, palette: Palette, seen: Set<string>): TermStyle {
    const cell: Record<string, unknown> = style.link === undefined ? {} : { ...this.#named(style.link, palette, seen) };
    for (const field of COLORS) {
      const color = style[field];
      if (color !== undefined) cell[field] = isPaletteColor(color) ? palette[color] : color;
    }
    for (const field of FLAGS) {
      const flag = style[field];
      if (flag !== undefined) cell[field] = flag;
    }
    return Object.freeze(cell) as TermStyle;
  }
}

/** A copy of `value` with its fields checked. `nulls` allows `null`, which a patch uses to delete a field. */
function checked(value: StylePatch, nulls: boolean): StylePatch {
  if (typeof value !== "object" || value === null) throw new TypeError("a style is an object");
  const copy: Record<string, unknown> = {};
  for (const [field, item] of Object.entries(value)) {
    if (item === undefined || (nulls && item === null)) {
      copy[field] = item;
    } else if ((COLORS as readonly string[]).includes(field)) {
      if (!isColor(item)) {
        throw new TypeError(
          `the style field ${field} is a color: an index from 0 to 255, #rrggbb, reset, or a palette name`,
        );
      }
      copy[field] = item;
    } else if ((FLAGS as readonly string[]).includes(field)) {
      if (typeof item !== "boolean") throw new TypeError(`the style field ${field} is a boolean`);
      copy[field] = item;
    } else if (field === "link") {
      if (typeof item !== "string" || item === "") throw new TypeError("the style field link names a style group");
      copy[field] = item;
    } else {
      throw new TypeError(`'${field}' is no style field`);
    }
  }
  return Object.freeze(copy);
}

function isColor(value: unknown): value is Color {
  if (typeof value === "number") return Number.isInteger(value) && value >= 0 && value <= 255;
  if (typeof value !== "string") return false;
  return value === "reset" || /^#[0-9A-Fa-f]{6}$/.test(value) || isPaletteColor(value);
}

function isPaletteColor(value: unknown): value is PaletteColor {
  return typeof value === "string" && Object.hasOwn(PALETTES.truecolor.dark, value);
}
