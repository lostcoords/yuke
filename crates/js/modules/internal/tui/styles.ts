/**
 * The style groups of the terminal interface. The default theme gives the base. Each `set` adds a layer of groups, and
 * the newest layer wins per field. The active theme sits above each layer, and it changes the palette too. A color can
 * name the palette, which follows the color depth and the background of the terminal.
 */
import type { TermColor, TermStyle } from "yuke:internal/native";
import { DEFAULT_THEME, type Palette } from "yuke:internal/tui/default-theme";
import type { CanvasStyle, PaletteColor, Style, StylePatch, Theme, ThemeLook } from "yuke:tui";

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
    if (name === this.#active) return;
    this.#active = name;
    this.#lookChanged();
  }

  /** Add `theme` as `name`, and return its remover. The newest theme of a name wins. */
  addTheme(name: string, theme: Theme): () => void {
    if (name === DEFAULT) throw new TypeError(`the theme name ${DEFAULT} is reserved: choose another name`);
    const entry: NamedTheme = { name, theme: { ...theme, dark: copyLook(theme.dark), light: copyLook(theme.light) } };
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

  /** Change `groups`, and return the disposer of the change. */
  set(groups: Readonly<Record<string, StylePatch>>): () => void {
    const layer = new Map<string, StylePatch>();
    for (const [name, patch] of Object.entries(groups)) {
      layer.set(name, { ...patch });
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
    if (typeof group !== "string") return this.#cell(group, look, new Set());
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

/** Copy the registered look so later plugin changes do not change cached styles. */
function copyLook(look: ThemeLook | undefined): ThemeLook | undefined {
  if (look === undefined) return undefined;
  return {
    ...look,
    palette: { ...look.palette },
    palette256: { ...look.palette256 },
    groups: Object.fromEntries(Object.entries(look.groups ?? {}).map(([name, patch]) => [name, { ...patch }])),
  };
}

function isPaletteColor(value: unknown): value is PaletteColor {
  return typeof value === "string" && Object.hasOwn(DEFAULT_THEME.dark.palette, value);
}
