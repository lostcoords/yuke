declare module "yuke:term" {
  interface Style {
    fg?: Color;
    bg?: Color;
    // The underline color does not enable the underline.
    ul?: Color;
    bold?: boolean;
    dim?: boolean;
    italic?: boolean;
    reverse?: boolean;
    underline?: boolean;
  }

  // Native code validates six hex digits and integer indices from 0 to 255.
  type RgbColor = `#${string}`;
  type Color = number | ColorName | RgbColor;

  type ColorName =
    | "reset"
    | "black"
    | "red"
    | "green"
    | "yellow"
    | "blue"
    | "magenta"
    | "cyan"
    | "gray"
    | "grey"
    | "dark_gray"
    | "dark_grey"
    | "light_red"
    | "light_green"
    | "light_yellow"
    | "light_blue"
    | "light_magenta"
    | "light_cyan"
    | "white";

  export const term: {
    beginFrame(): void;
    endFrame(): void;
    fill(x: number, y: number, w: number, h: number, style?: Style): void;
    text(x: number, y: number, s: string, style?: Style): void;
    measure(s: string): number;
    graphemes(s: string): Int32Array;
    wrap(s: string, width: number, head?: number, tail?: number): { rows: Int32Array; omitted: boolean };
    cursor(x: number, y: number, visible: boolean): void;
    setNeedsTick(enabled: boolean, periodMs?: number): void;
    copy(text: string): number;
    quit(): void;
    clipboardMax: number;
    cwd: string;
    width: number;
    height: number;
  };

  export { Style, Color, ColorName, RgbColor };
}
