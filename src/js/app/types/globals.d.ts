type KeyCode =
  | "tab"
  | "enter"
  | "esc"
  | "backspace"
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
  | "f1"
  | "f2"
  | "f3"
  | "f4"
  | "f5"
  | "f6"
  | "f7"
  | "f8"
  | "f9"
  | "f10"
  | "f11"
  | "f12"
  | "unknown"
  | "char";

type HostEvent =
  | {
      type: "key";
      code: KeyCode;
      event: "press" | "release" | "repeat";
      char: string;
      shifted: string;
      baseLayout: string;
      text: string;
      mods: number;
    }
  | {
      type: "mouse";
      col: number;
      row: number;
      button: string;
      event: string;
      mods: number;
      count: number;
    }
  | { type: "focus"; focused: boolean }
  | { type: "paste"; text: string }
  | { type: "resize"; w: number; h: number }
  | { type: "tick" };

declare function onEvent(ev: HostEvent): void;
declare function flushFrame(): void;

/** Runs `callback` once after `ms` milliseconds, never inside this call. A missing, negative, or non-finite delay runs in the next pump. */
/** QuickJS encodes a string of byte values (0 to 255) as base64. */
declare function btoa(data: string): string;
declare function setTimeout<A extends unknown[]>(callback: (...args: A) => void, ms?: number, ...args: A): number;
/** Runs `callback` every `ms` milliseconds until `clearInterval`. */
declare function setInterval<A extends unknown[]>(callback: (...args: A) => void, ms?: number, ...args: A): number;
/** Stops a timer. An unknown or fired id does nothing. */
declare function clearTimeout(id: number | undefined): void;
/** Stops a timer. It shares one id space with `clearTimeout`. */
declare function clearInterval(id: number | undefined): void;
