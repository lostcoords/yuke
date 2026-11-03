# Themes

A theme sets the colors and the text styles of yuke. yuke has one theme, `default`. This theme works on light and dark terminals.

To change the theme, run `/themes`. Use the arrow keys to see a theme. Push Enter to keep the theme. Push Esc to go back to the old theme.

## Write a theme

A theme is a plugin. Create the file `~/.config/yuke/nord/plugin.json`:

```json
{
  "name": "nord",
  "extensions": { "sh.yuke": { "entry": "./index.ts" } }
}
```

In the same folder, create the file `index.ts`. The colors in this file are an example:

```ts
import type { PluginContext } from "yuke:plugins";

export function apply(ctx: PluginContext): void {
  ctx.get("tui")?.styles.addTheme("nord", {
    dark: {
      palette: { fg: "#eceff4", bg: "#2e3440", accent: "#88c0d0", surface: "#3b4252" },
      groups: { "chat.title": { fg: "#ebcb8b" } },
    },
    light: {
      palette: { accent: "#2e6f8e" },
    },
  });
}
```

Add the folder to `~/.config/yuke/config.json`:

```json
{
  "plugins": ["./nord"]
}
```

Run `/reload`. Then select `nord` in `/themes`. Run `/reload` again after each change to the theme.

Set only the values that you want to change. All other values come from `default`. If you set only `dark` or only `light`, yuke uses the same values on the two backgrounds.

## Palette

Start with the palette. A group can name a palette color. When you change `accent`, each group that names `accent` changes, also the groups of other plugins.

This table shows where the `default` theme uses each color. It is not an example.

| Color | Use |
|---|---|
| `fg` | Text with no color of its own |
| `bg` | The screen background |
| `surfaceFg` | Text on `surface`, tool output, selected rows |
| `strongFg` | Added diff lines |
| `accent` | Tool subjects, hints, matched letters, info toasts |
| `accentMuted` | Selected rows and selected text |
| `surface` | User messages and toasts |
| `warn` | Warning toasts |
| `danger` | Errors, removed diff lines, error toasts |
| `pendingBg` | A tool call that did not end |
| `errorBg` | A tool call that failed |
| `diffAddBg` | Added diff lines |
| `diffDelBg` | Removed diff lines |

A color is a hex value (`"#88c0d0"`), a 256-color index (`110`), or `"reset"`. The value `"reset"` gives the color of the terminal. In `default`, `fg` and `bg` are `"reset"`.

A terminal without 24-bit color shows the nearest index for a hex value. To select the index, add `palette256: { accent: 110 }` near `palette`.

## Groups

A group sets the style of one part of the interface. Set only the fields that you want to change. The other fields do not change. To remove a field, set it to `null`.

```ts
groups: {
  "chat.title": { fg: "#ebcb8b" }, // The title stays bold.
  "chat.thought": { italic: null },
  "picker.match": { underline: true },
}
```

The fields are `fg`, `bg`, `underlineColor`, `bold`, `dim`, `italic`, `reverse`, `underline`, and `inherits`. `inherits` names a second group. That group gives the fields that the first group does not set.

[`default-theme.ts`](https://github.com/lostcoords/yuke/blob/main/crates/js/modules/internal/tui/default-theme.ts) has all the groups and all the colors. To change many values, copy this file.

## Start from a different theme

```ts
ctx.get("tui")?.styles.addTheme("my-nord", {
  inherits: "nord",
  dark: { palette: { accent: "#a3be8c" } },
});
```

The order in which the plugins load has no effect.

If two plugins add a theme with the same name, yuke uses the newest theme. You cannot use the name `default`. The call `addTheme("default", ...)` gives an error.

## Plugins and themes

Use `styles.set` to set the style of the groups of your plugin. Use palette names or `inherits`. Your plugin then follows each theme:

```ts
ctx.get("tui")?.styles.set({
  "notes.title": { inherits: "chat.title" },
  "notes.count": { fg: "accent" },
});
```

A hex value does not change with the theme or the background.

A theme has priority over `styles.set`. `styles.set` has priority over `default`.

To set a style for one theme, read `styles.theme` at startup and on the event `theme.changed`. yuke also sends this event when the background of the terminal changes.

```ts
import type { PluginContext } from "yuke:plugins";

export function apply(ctx: PluginContext): void {
  const tui = ctx.get("tui");
  if (tui === undefined) return;
  let undo = (): void => {};
  const look = (): void => {
    undo();
    undo = tui.styles.theme === "nord" ? tui.styles.set({ "notes.title": { fg: "#ebcb8b" } }) : () => {};
  };
  look();
  ctx.on("theme.changed", look);
}
```

If `nord` sets `notes.title` at a later time, the value of `nord` has priority. You can keep this code.

## Known limits

A theme plugin loads after the chat. The first frame can show the colors of `default`.

`bg` fills only the cells of the terminal. The padding of the terminal keeps its color.
