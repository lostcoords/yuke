/**
 * The `default` theme: the look of yuke. It sits below each `styles.set` and each other theme, so a theme or a plugin
 * changes only what it names. Copy it to start a theme. A plugin gives the look of its own groups with `styles.set`.
 */
import type { TermColor } from "yuke:internal/native";
import type { PaletteColor, Style } from "yuke:tui";

export type Palette = Readonly<Record<PaletteColor, TermColor>>;

/** The style groups of the bundled views, the same on each background. */
const GROUPS: Readonly<Record<string, Style>> = {
  "chat.user": { fg: "surfaceFg", bg: "surface" },
  "chat.meta": { dim: true },
  "chat.title": { bold: true },
  "chat.subject": { fg: "accent" },
  "chat.thought": { dim: true, italic: true },
  "chat.error": { fg: "danger", bold: true },
  "chat.hint": { fg: "accent" },
  "chat.rule": { dim: true },
  "chat.command": { fg: "accent" },
  "chat.tool.output": { fg: "surfaceFg", dim: true },
  "chat.tool.pending": { bg: "pendingBg" },
  "chat.tool.failed": { bg: "errorBg" },
  "chat.diff.header": { bold: true },
  "chat.diff.gutter": { fg: "surfaceFg", dim: true },
  "chat.diff.add": { fg: "strongFg", bg: "diffAddBg" },
  "chat.diff.delete": { fg: "danger", bg: "diffDelBg" },
  "chat.diff.context": { fg: "surfaceFg", dim: true },

  "markdown.strong": { bold: true },
  "markdown.emphasis": { italic: true },
  "markdown.strongEmphasis": { bold: true, italic: true },
  "markdown.code": { dim: true },
  "markdown.heading": { bold: true },
  "markdown.quote": { dim: true },
  "markdown.codeBlock": { dim: true },
  "markdown.rule": { dim: true },
  "markdown.listMark": { dim: true },
  "markdown.tableBorder": { dim: true },
  "markdown.linkText": { underline: true },
  "markdown.link": { dim: true },

  "editor.selection": { reverse: true },
  "editor.label": { fg: "accent" },
  "editor.placeholder": { dim: true },
  "textView.selection": { fg: "surfaceFg", bg: "accentMuted" },
  "picker.match": { fg: "accent", bold: true },
  "picker.detail": { dim: true },
  "picker.selected": { fg: "surfaceFg", bg: "accentMuted" },
  "dialog.title": { dim: true },
  "dialog.keys": { dim: true },
  "dialog.error": { fg: "danger" },
  "panes.divider": { dim: true },

  bar: { dim: true },
  "toast.body": { fg: "surfaceFg", bg: "surface" },
  "toast.title": { bold: true },
  "toast.info": { inherits: "toast.body", fg: "accent" },
  "toast.warn": { inherits: "toast.body", fg: "warn" },
  "toast.error": { inherits: "toast.body", fg: "danger" },
  "plugins.title": { bold: true },
  "plugins.detail": { dim: true },
};

/** The palettes of each background. Each 256-color pick keeps the hue of its 24-bit color. */
export const DEFAULT_THEME: {
  readonly [K in "dark" | "light"]: {
    readonly palette: Palette;
    readonly palette256: Palette;
    readonly groups: typeof GROUPS;
  };
} = {
  dark: {
    palette: {
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
    palette256: {
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
    groups: GROUPS,
  },
  light: {
    palette: {
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
    palette256: {
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
    groups: GROUPS,
  },
};
