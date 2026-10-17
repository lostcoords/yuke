/**
 * The global `console`: `debug`, `log`, `info`, `warn`, and `error`. Each call writes one entry for the operator, on
 * stderr in the app. An entry is never a notice. `yuke:internal/web` installs the object.
 */
import { writeConsole } from "yuke:internal/native";
import type { NoticeLevel } from "yuke:plugins";

/** The depth of nested objects that a line shows. A deeper object shows as `[Object]`. */
const DEPTH = 4;

/**
 * The text of `args` with the directives of the Console Standard: `%s` (`String`), `%d` and `%i` (`parseInt`), `%f`
 * (`parseFloat`), `%o` and `%O` (an object view), `%c` (no output), `%%`.
 */
function format(args: readonly unknown[]): string {
  const rest = [...args];
  const parts: string[] = [];
  const first = rest[0];
  if (typeof first === "string" && first.includes("%")) {
    rest.shift();
    parts.push(
      first.replace(/%[sdifoOc%]/g, (directive) => {
        if (directive === "%%") return "%";
        if (rest.length === 0) return directive;
        const value = rest.shift();
        switch (directive) {
          case "%s":
            return guard(() => String(value));
          case "%d":
          case "%i":
            return typeof value === "symbol" ? "NaN" : guard(() => `${Number.parseInt(value as string, 10)}`);
          case "%f":
            return typeof value === "symbol" ? "NaN" : guard(() => `${Number.parseFloat(value as string)}`);
          case "%c":
            return "";
          default:
            return view(value);
        }
      }),
    );
  }
  for (const value of rest) parts.push(typeof value === "string" ? value : view(value));
  return parts.join(" ");
}

/** The text of `read()`, or `[unreadable]` when it throws, so a call of `console` never throws. */
function guard(read: () => string): string {
  try {
    return read();
  } catch {
    return "[unreadable]";
  }
}

/** The object view of `value`. */
function view(value: unknown): string {
  return guard(() => inspect(value, new Set(), 0));
}

/** A readable text of `value` with a bounded depth. A cycle shows as `[Circular]`, and an accessor as `[Getter]`. */
function inspect(value: unknown, seen: Set<object>, depth: number): string {
  switch (typeof value) {
    case "string":
      return JSON.stringify(value);
    case "bigint":
      return `${value}n`;
    case "symbol":
      return value.toString();
    case "function":
      return `[Function ${value.name || "(anonymous)"}]`;
    case "object":
      break;
    default:
      return String(value);
  }
  if (value === null) return "null";
  if (value instanceof Error) {
    // The engine gives only the frames in `stack`, so the line names the error first.
    const head = `${value.name}: ${value.message}`;
    return typeof value.stack === "string" && value.stack.length > 0 ? `${head}\n${value.stack.trimEnd()}` : head;
  }
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? "Invalid Date" : value.toISOString();
  if (seen.has(value)) return "[Circular]";
  if (depth >= DEPTH) return Array.isArray(value) ? "[Array]" : "[Object]";
  seen.add(value);
  try {
    const nested = (item: unknown) => inspect(item, seen, depth + 1);
    if (Array.isArray(value)) return `[${value.map(nested).join(", ")}]`;
    if (value instanceof Map) {
      const entries = [...value].map(([key, item]) => `${nested(key)} => ${nested(item)}`);
      return `Map(${value.size}) {${entries.length === 0 ? "" : ` ${entries.join(", ")} `}}`;
    }
    if (value instanceof Set) {
      const items = [...value].map(nested);
      return `Set(${value.size}) {${items.length === 0 ? "" : ` ${items.join(", ")} `}}`;
    }
    const fields = Object.entries(Object.getOwnPropertyDescriptors(value))
      .filter(([, descriptor]) => descriptor.enumerable)
      .map(([key, descriptor]) => `${key}: ${"value" in descriptor ? nested(descriptor.value) : "[Getter]"}`);
    const name = Object.getPrototypeOf(value)?.constructor?.name;
    const prefix = typeof name === "string" && name !== "Object" ? `${name} ` : "";
    return `${prefix}{${fields.length === 0 ? "" : ` ${fields.join(", ")} `}}`;
  } finally {
    seen.delete(value);
  }
}

/** A method of `console` that writes its entry at `level`. */
function method(level: NoticeLevel): (...data: unknown[]) => void {
  return (...data) => writeConsole(level, format(data));
}

/** The global `console`. `log` writes a debug entry. */
export const console = {
  log: method("debug"),
  debug: method("debug"),
  info: method("info"),
  warn: method("warn"),
  error: method("error"),
} satisfies typeof globalThis.console;
