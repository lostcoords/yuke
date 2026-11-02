/**
 * The style groups of the terminal interface. Each `set` adds a layer of groups, and the newest layer wins per field.
 * The active theme sits above each layer, and it changes the palette too. A color can name the palette, which follows
 * the color depth and the background of the terminal.
 */
import type { TermColor, TermStyle } from "yuke:internal/native";
import type { CanvasStyle, Color, PaletteColor, Style, StylePatch, Theme, ThemeLook } from "yuke:tui";

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

const COLORS = ["fg", "bg", "underlineColor"] as const;
/** The field of the cell style for each color field: the native style names the underline color `ul`. */
const CELL_FIELD = { fg: "fg", bg: "bg", underlineColor: "ul" } as const;
const FLAGS = ["bold", "dim", "italic", "reverse", "underline"] as const;
const NO_STYLE: TermStyle = Object.freeze({});

/** What the active theme gives for the background now. Without a theme it is the base palette and no group. */
interface Look {
  readonly palette: Palette;
  readonly groups: ReadonlyMap<string, StylePatch>;
}

interface NamedTheme {
  readonly name: string;
  readonly theme: Theme;
}

export class Styles {
  readonly #truecolor: () => boolean;
  readonly #background: () => "dark" | "light";
  readonly #changed: () => void;
  readonly #themeChanged: () => void;
  readonly #themes: NamedTheme[] = [];
  #active: string | undefined;
  readonly #layers: ReadonlyMap<string, StylePatch>[] = [];
  readonly #cache = new Map<string, TermStyle>();
  /** The look of the cached styles, and the base palette that it starts from. */
  #look: Look | undefined;
  #base: Palette | undefined;

  /**
   * `truecolor` and `background` give the state of the terminal, which picks the base palette. `changed` asks for a
   * frame after each change. `themeChanged` tells each change of the active theme or of its look.
   */
  constructor(
    truecolor: () => boolean,
    background: () => "dark" | "light",
    changed: () => void,
    themeChanged: () => void = () => {},
  ) {
    this.#truecolor = truecolor;
    this.#background = background;
    this.#changed = changed;
    this.#themeChanged = themeChanged;
  }

  /** The name of the active theme. A name that no theme has yet applies when that theme comes. */
  get theme(): string | undefined {
    return this.#active;
  }

  /** The names of the themes, each one once, in the order they came. */
  themes(): readonly string[] {
    return [...new Set(this.#themes.map((entry) => entry.name))];
  }

  /** Make `name` the active theme. `undefined` gives the look without a theme. */
  setTheme(name: string | undefined): void {
    if (name !== undefined && (typeof name !== "string" || name === "")) {
      throw new TypeError("a theme has a name that is not empty");
    }
    if (name === this.#active) return;
    this.#active = name;
    this.#lookChanged();
    this.#themeChanged();
  }

  /** Add `theme` as `name`, and return its remover. The newest theme of a name wins. A bad field throws. */
  addTheme(name: string, theme: Theme): () => void {
    if (typeof name !== "string" || name === "") throw new TypeError("a theme has a name that is not empty");
    const entry: NamedTheme = { name, theme: checkedTheme(theme) };
    this.#themes.push(entry);
    this.#themesChanged(this.#chain().includes(entry));
    return () => {
      const at = this.#themes.indexOf(entry);
      if (at < 0) return;
      const active = this.#chain().includes(entry);
      this.#themes.splice(at, 1);
      this.#themesChanged(active);
    };
  }

  #themesChanged(active: boolean): void {
    if (!active) return;
    this.#lookChanged();
    this.#themeChanged();
  }

  #lookChanged(): void {
    this.#look = undefined;
    this.#cache.clear();
    this.#changed();
  }

  /** The active theme after the themes that it inherits, the base first. A cycle stops at the first repeated name. */
  #chain(): readonly NamedTheme[] {
    const chain: NamedTheme[] = [];
    const seen = new Set<string>();
    for (let name = this.#active; name !== undefined && !seen.has(name); ) {
      seen.add(name);
      const entry = this.#themes.findLast((candidate) => candidate.name === name);
      if (entry === undefined) break;
      chain.unshift(entry);
      name = entry.theme.inherits;
    }
    return chain;
  }

  /** The look for the color depth and the background now. A new base palette drops the cached styles. */
  #lookNow(): Look {
    const background = this.#background();
    const base = PALETTES[this.#truecolor() ? "truecolor" : "256"][background];
    if (this.#look !== undefined && base === this.#base) return this.#look;
    const palette: Record<string, TermColor> = { ...base };
    const groups = new Map<string, StylePatch>();
    for (const { theme } of this.#chain()) {
      // A theme with one mode gives it for both.
      const look = theme[background] ?? theme[background === "dark" ? "light" : "dark"];
      Object.assign(palette, look?.palette);
      for (const [name, patch] of Object.entries(look?.groups ?? {}))
        groups.set(name, { ...groups.get(name), ...patch });
    }
    this.#base = base;
    this.#look = { palette: palette as Palette, groups };
    this.#cache.clear();
    return this.#look;
  }

  /** Change `groups`, and return the disposer of the change. A bad name or field throws and changes nothing. */
  set(groups: Readonly<Record<string, StylePatch>>): () => void {
    if (typeof groups !== "object" || groups === null) throw new TypeError("the style groups are an object");
    const layer = new Map<string, StylePatch>();
    for (const [name, patch] of Object.entries(groups)) {
      if (name === "") throw new TypeError("a style group has a name that is not empty");
      layer.set(name, checked(patch, true));
    }
    this.#layers.push(layer);
    this.#cache.clear();
    this.#changed();
    return () => {
      const at = this.#layers.indexOf(layer);
      if (at < 0) return;
      this.#layers.splice(at, 1);
      this.#cache.clear();
      this.#changed();
    };
  }

  /** The cell style of the group `group`, or of the style object `group`. A group with no layer has no field. */
  resolve(group: string | Style): TermStyle {
    const look = this.#lookNow();
    if (typeof group !== "string") return this.#cell(checked(group, false) as Style, look, new Set());
    // Only a whole resolve enters the cache: a group inside a link cycle depends on the group where the cycle starts.
    let style = this.#cache.get(group);
    if (style === undefined) {
      style = this.#named(group, look, new Set());
      this.#cache.set(group, style);
    }
    return style;
  }

  /**
   * The cell style of a draw: each item of `style` in order, and a later item wins per field. A cell without a color
   * then takes the palette color `fg`, unless it is `reset`. It comes last, so a band keeps the color of its text.
   */
  cell(style: CanvasStyle | undefined): TermStyle {
    let merged: TermStyle = NO_STYLE;
    if (Array.isArray(style)) merged = Object.freeze(Object.assign({}, ...style.map((item) => this.resolve(item))));
    else if (style !== undefined) merged = this.resolve(style as string | Style);
    if (merged.fg !== undefined) return merged;
    const fg = this.#lookNow().palette.fg;
    if (fg === "reset") return merged;
    return Object.freeze({ ...merged, fg: this.#truecolor() ? fg : indexed(fg) });
  }

  #named(name: string, look: Look, seen: Set<string>): TermStyle {
    // A link cycle stops at the first repeated group.
    if (seen.has(name)) return {};
    seen.add(name);
    const fields: Record<string, unknown> = {};
    for (const layer of [...this.#layers, look.groups]) {
      for (const [field, value] of Object.entries(layer.get(name) ?? {})) {
        if (value === null) delete fields[field];
        else if (value !== undefined) fields[field] = value;
      }
    }
    return this.#cell(fields as Style, look, seen);
  }

  /** The cell style of `style`: its link first, then its own fields, with each color from the palette. */
  #cell(style: Style, look: Look, seen: Set<string>): TermStyle {
    const cell: Record<string, unknown> = style.link === undefined ? {} : { ...this.#named(style.link, look, seen) };
    for (const field of COLORS) {
      const color = style[field];
      if (color === undefined) continue;
      const value = isPaletteColor(color) ? look.palette[color] : color;
      cell[CELL_FIELD[field]] = this.#truecolor() ? value : indexed(value);
    }
    for (const field of FLAGS) {
      const flag = style[field];
      if (flag !== undefined) cell[field] = flag;
    }
    return Object.freeze(cell) as TermStyle;
  }
}

/** The steps of the color cube of the 256-color palette, which starts at index 16. */
const CUBE = [0, 95, 135, 175, 215, 255];

/** `color` for a terminal without 24-bit color: a `#rrggbb` becomes the nearest index of the cube or the grays. */
function indexed(color: TermColor): TermColor {
  if (typeof color !== "string" || !color.startsWith("#")) return color;
  const parts = [1, 3, 5].map((at) => Number.parseInt(color.slice(at, at + 2), 16));
  const distance = (others: readonly number[]): number =>
    others.reduce((sum, other, at) => sum + (other - (parts[at] as number)) ** 2, 0);
  const steps = parts.map((part) =>
    CUBE.reduce((best, step, at) => (Math.abs(step - part) < Math.abs((CUBE[best] as number) - part) ? at : best), 0),
  );
  const [red, green, blue] = steps as [number, number, number];
  const gray = Math.min(23, Math.max(0, Math.round((parts.reduce((sum, part) => sum + part, 0) / 3 - 8) / 10)));
  const level = 8 + 10 * gray;
  const cube = distance(steps.map((step) => CUBE[step] as number));
  return cube <= distance([level, level, level]) ? 16 + 36 * red + 6 * green + blue : 232 + gray;
}

/** A copy of `theme` with its fields checked. */
function checkedTheme(theme: Theme): Theme {
  if (typeof theme !== "object" || theme === null) throw new TypeError("a theme is an object");
  knownFields(theme, ["inherits", "dark", "light"], "theme");
  const { inherits, dark, light } = theme;
  if (inherits !== undefined && (typeof inherits !== "string" || inherits === "")) {
    throw new TypeError("the theme field inherits names a theme");
  }
  return Object.freeze({
    ...(inherits === undefined ? {} : { inherits }),
    ...(dark === undefined ? {} : { dark: checkedLook(dark) }),
    ...(light === undefined ? {} : { light: checkedLook(light) }),
  });
}

/** Throw for a field of `value` outside `fields`, so a typing error in a theme does not pass in silence. */
function knownFields(value: object, fields: readonly string[], what: string): void {
  for (const field of Object.keys(value)) {
    if (!fields.includes(field)) throw new TypeError(`'${field}' is no ${what} field`);
  }
}

function checkedLook(look: ThemeLook): ThemeLook {
  if (typeof look !== "object" || look === null) throw new TypeError("the look of a theme is an object");
  knownFields(look, ["palette", "groups"], "theme look");
  const palette = Object.entries(look.palette ?? {});
  for (const [name, color] of palette) {
    if (!isPaletteColor(name)) throw new TypeError(`'${name}' is no palette color`);
    if (!isColor(color) || isPaletteColor(color)) {
      throw new TypeError(`the palette color ${name} is an index from 0 to 255, #rrggbb, or reset`);
    }
  }
  const groups = Object.entries(look.groups ?? {}).map(([name, patch]) => {
    if (name === "") throw new TypeError("a style group has a name that is not empty");
    return [name, checked(patch, true)] as const;
  });
  return Object.freeze({
    palette: Object.freeze(Object.fromEntries(palette)),
    groups: Object.freeze(Object.fromEntries(groups)),
  });
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
