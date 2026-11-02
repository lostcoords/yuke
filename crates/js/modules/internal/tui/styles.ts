/**
 * The style groups of the terminal interface. The default theme gives the base. Each `set` adds a layer of groups, and
 * the newest layer wins per field. The active theme sits above each layer, and it changes the palette too. A color can
 * name the palette, which follows the color depth and the background of the terminal.
 */
import type { TermColor, TermStyle } from "yuke:internal/native";
import { DEFAULT_THEME, type Palette } from "yuke:internal/tui/default-theme";
import type { CanvasStyle, Color, PaletteColor, Style, StylePatch, Theme, ThemeLook } from "yuke:tui";

const COLORS = ["fg", "bg", "underlineColor"] as const;
/** The field of the cell style for each color field: the native style names the underline color `ul`. */
const CELL_FIELD = { fg: "fg", bg: "bg", underlineColor: "ul" } as const;
const FLAGS = ["bold", "dim", "italic", "reverse", "underline"] as const;
const NO_STYLE: TermStyle = Object.freeze({});

/** The name of the theme that sits below everything. `DEFAULT_THEME` holds it, so `#themes` has no entry for it. */
const DEFAULT = "default";

/** The default theme and the active theme for the color depth and the background now. */
interface Look {
  readonly palette: Palette;
  readonly base: ReadonlyMap<string, StylePatch>;
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
  #active: string = DEFAULT;
  readonly #layers: ReadonlyMap<string, StylePatch>[] = [];
  readonly #cache = new Map<string, TermStyle>();
  /** The look of the cached styles, and the palette of the default theme that it starts from. */
  #look: Look | undefined;
  #base: Palette | undefined;

  /**
   * `truecolor` and `background` give the state of the terminal, which picks the default palette. `changed` asks for a
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

  /** The name of the active theme. A name without a theme gives the default look until that theme comes. */
  get theme(): string {
    return this.#active;
  }

  /** The names of the themes, each one once, the default theme first, then in the order they came. */
  themes(): readonly string[] {
    return [DEFAULT, ...new Set(this.#themes.map((entry) => entry.name))];
  }

  /** Make `name` the active theme. */
  setTheme(name: string): void {
    if (typeof name !== "string" || name === "") throw new TypeError("a theme has a name that is not empty");
    if (name === this.#active) return;
    this.#active = name;
    this.#lookChanged();
  }

  /** Add `theme` as `name`, and return its remover. The newest theme of a name wins. A bad field throws. */
  addTheme(name: string, theme: Theme): () => void {
    if (typeof name !== "string" || name === "") throw new TypeError("a theme has a name that is not empty");
    if (name === DEFAULT) throw new TypeError(`the theme name ${DEFAULT} is reserved: choose another name`);
    const entry: NamedTheme = { name, theme: checkedTheme(theme) };
    this.#themes.push(entry);
    if (this.#chain().includes(entry)) this.#lookChanged();
    return () => {
      const at = this.#themes.indexOf(entry);
      if (at < 0) return;
      const active = this.#chain().includes(entry);
      this.#themes.splice(at, 1);
      if (active) this.#lookChanged();
    };
  }

  #lookChanged(): void {
    this.#look = undefined;
    this.#cache.clear();
    this.#changed();
    this.#themeChanged();
  }

  /** The active theme after the themes that it inherits, the base first. A cycle stops at the first repeated name. */
  #chain(): readonly NamedTheme[] {
    const chain: NamedTheme[] = [];
    const seen = new Set<string>();
    for (let name: string | undefined = this.#active; name !== undefined && !seen.has(name); ) {
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
    const truecolor = this.#truecolor();
    const base = truecolor ? DEFAULT_THEME[background].palette : DEFAULT_THEME[background].palette256;
    if (this.#look !== undefined && base === this.#base) return this.#look;
    const palette: Record<string, TermColor> = { ...base };
    const groups = new Map<string, StylePatch>();
    for (const { theme } of this.#chain()) {
      // A theme with one mode gives it for both.
      const look = theme[background] ?? theme[background === "dark" ? "light" : "dark"];
      Object.assign(palette, look?.palette, truecolor ? undefined : look?.palette256);
      for (const [name, patch] of Object.entries(look?.groups ?? {}))
        groups.set(name, { ...groups.get(name), ...patch });
    }
    this.#base = base;
    this.#look = {
      palette: palette as Palette,
      base: new Map(Object.entries(DEFAULT_THEME[background].groups)),
      groups,
    };
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
   * The cell style of a draw: each item of `style` in order, and a later item wins per field. Each missing `fg` or `bg`
   * then takes its palette color, unless that color is `reset`. It comes last, so a band keeps the color of its text.
   */
  cell(style: CanvasStyle | undefined): TermStyle {
    let merged: TermStyle = NO_STYLE;
    if (Array.isArray(style)) merged = Object.freeze(Object.assign({}, ...style.map((item) => this.resolve(item))));
    else if (style !== undefined) merged = this.resolve(style as string | Style);
    if (merged.fg !== undefined && merged.bg !== undefined) return merged;
    const palette = this.#lookNow().palette;
    const fg = merged.fg === undefined ? palette.fg : "reset";
    const bg = merged.bg === undefined ? palette.bg : "reset";
    if (fg === "reset" && bg === "reset") return merged;
    const shown = (color: TermColor): TermColor => (this.#truecolor() ? color : indexed(color));
    return Object.freeze({
      ...merged,
      ...(fg === "reset" ? {} : { fg: shown(fg) }),
      ...(bg === "reset" ? {} : { bg: shown(bg) }),
    });
  }

  #named(name: string, look: Look, seen: Set<string>): TermStyle {
    // A link cycle stops at the first repeated group.
    if (seen.has(name)) return {};
    seen.add(name);
    const fields: Record<string, unknown> = {};
    for (const layer of [look.base, ...this.#layers, look.groups]) {
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
  knownFields(look, ["palette", "palette256", "groups"], "theme look");
  const palette = checkedPalette(look.palette);
  const palette256 = checkedPalette(look.palette256);
  const groups = Object.entries(look.groups ?? {}).map(([name, patch]) => {
    if (name === "") throw new TypeError("a style group has a name that is not empty");
    return [name, checked(patch, true)] as const;
  });
  return Object.freeze({ palette, palette256, groups: Object.freeze(Object.fromEntries(groups)) });
}

function checkedPalette<P extends ThemeLook["palette"]>(palette: P): P {
  const colors = Object.entries(palette ?? {});
  for (const [name, color] of colors) {
    if (!isPaletteColor(name)) throw new TypeError(`'${name}' is no palette color`);
    if (!isColor(color) || isPaletteColor(color)) {
      throw new TypeError(`the palette color ${name} is an index from 0 to 255, #rrggbb, or reset`);
    }
  }
  return Object.freeze(Object.fromEntries(colors)) as P;
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
  return typeof value === "string" && Object.hasOwn(DEFAULT_THEME.dark.palette, value);
}
