/**
 * The global `console`, with the methods of the Console Standard. Each call writes at most one entry for the operator,
 * on stderr in the app. An entry is never a notice. `yuke:internal/web` installs the object.
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
      const entries = [...value].map((entry) => {
        const [key, item] = entry;
        return `${nested(key)} => ${nested(item)}`;
      });
      return `Map(${value.size}) {${entries.length === 0 ? "" : ` ${entries.join(", ")} `}}`;
    }
    if (value instanceof Set) {
      const items = [...value].map(nested);
      return `Set(${value.size}) {${items.length === 0 ? "" : ` ${items.join(", ")} `}}`;
    }
    const fields = Object.entries(Object.getOwnPropertyDescriptors(value))
      .filter((entry) => {
        const [, descriptor] = entry;
        return descriptor.enumerable;
      })
      .map((entry) => {
        const [key, descriptor] = entry;
        return `${key}: ${"value" in descriptor ? nested(descriptor.value) : "[Getter]"}`;
      });
    const name = Object.getPrototypeOf(value)?.constructor?.name;
    const prefix = typeof name === "string" && name !== "Object" ? `${name} ` : "";
    return `${prefix}{${fields.length === 0 ? "" : ` ${fields.join(", ")} `}}`;
  } finally {
    seen.delete(value);
  }
}

/** The engine clock, so a plugin that replaces `performance` changes no timer. */
const now = globalThis.performance.now.bind(globalThis.performance);

/** The number of open groups. */
let depth = 0;
/** The calls of `count` by label. */
const counts = new Map<string, number>();
/** The start of each timer by label. */
const timers = new Map<string, number>();

/** Write `text` at `level`, with two spaces before each line for each open group. */
function write(level: NoticeLevel, text: string): void {
  const indent = "  ".repeat(depth);
  writeConsole(level, indent === "" ? text : text.replace(/^/gm, indent));
}

/** A method of `console` that writes its entry at `level`. */
function method(level: NoticeLevel): (...data: unknown[]) => void {
  return (...data) => write(level, format(data));
}

/** The label of a counter or a timer. */
function labelOf(label: unknown): string {
  return label === undefined ? "default" : guard(() => String(label));
}

/** The time of the timer `label` since its start, or a warning when it does not exist. */
function timeLog(label: string, data: readonly unknown[]): void {
  const start = timers.get(label);
  if (start === undefined) {
    write("warn", `Timer '${label}' does not exist`);
    return;
  }
  const elapsed = `${label}: ${(now() - start).toFixed(3)}ms`;
  write("info", data.length === 0 ? elapsed : `${elapsed} ${format(data)}`);
}

/** A group of entries: the entry of `data`, when there is some, and one more indent. */
function group(...data: unknown[]): void {
  if (data.length > 0) write("debug", format(data));
  depth += 1;
}

/** The text table of the items of `data`, an array or an object. Another value writes as `log`. */
function table(data: unknown, properties?: readonly string[]): void {
  if (typeof data !== "object" || data === null) {
    write("debug", format([data]));
    return;
  }
  const rows = guard(() => {
    const items = Object.entries(data);
    const columns: string[] = [];
    let values = false;
    for (const [, item] of items) {
      if (typeof item === "object" && item !== null) {
        for (const key of Object.keys(item)) if (!columns.includes(key)) columns.push(key);
      } else {
        values = true;
      }
    }
    const shown = properties === undefined ? columns : [...properties];
    const header = ["(index)", ...shown, ...(values && properties === undefined ? ["Values"] : [])];
    const body = items.map((row) => {
      const [index, item] = row;
      const record = typeof item === "object" && item !== null ? (item as Record<string, unknown>) : undefined;
      const cells = shown.map((key) => (record !== undefined && Object.hasOwn(record, key) ? view(record[key]) : ""));
      return [index, ...cells, ...(header.length > shown.length + 1 ? [record === undefined ? view(item) : ""] : [])];
    });
    return renderTable(header, body);
  });
  write("debug", rows);
}

/** Render `header` and `body` as a box table. */
function renderTable(header: readonly string[], body: readonly (readonly string[])[]): string {
  const rows = [header, ...body];
  const widths = header.map((_, column) => Math.max(...rows.map((row) => row[column]?.length ?? 0)));
  const line = (left: string, middle: string, right: string) =>
    `${left}${widths.map((width) => "─".repeat(width + 2)).join(middle)}${right}`;
  const row = (cells: readonly string[]) =>
    `│${widths.map((width, column) => ` ${(cells[column] ?? "").padEnd(width)} `).join("│")}│`;
  return [line("┌", "┬", "┐"), row(header), line("├", "┼", "┤"), ...body.map(row), line("└", "┴", "┘")].join("\n");
}

/** The global `console`. `log` writes a debug entry. */
export const console = {
  log: method("debug"),
  debug: method("debug"),
  info: method("info"),
  warn: method("warn"),
  error: method("error"),
  assert(condition?: unknown, ...data: unknown[]): void {
    if (condition) return;
    const [first, ...rest] = data;
    const message = typeof first === "string" ? [`Assertion failed: ${first}`, ...rest] : ["Assertion failed", ...data];
    write("error", format(message));
  },
  clear(): void {
    depth = 0;
  },
  count(label?: string): void {
    const name = labelOf(label);
    const count = (counts.get(name) ?? 0) + 1;
    counts.set(name, count);
    write("info", `${name}: ${count}`);
  },
  countReset(label?: string): void {
    const name = labelOf(label);
    if (!counts.has(name)) {
      write("warn", `Count for '${name}' does not exist`);
      return;
    }
    counts.set(name, 0);
  },
  dir(item?: unknown): void {
    write("debug", view(item));
  },
  dirxml: method("debug"),
  group,
  groupCollapsed: group,
  groupEnd(): void {
    depth = Math.max(0, depth - 1);
  },
  table,
  time(label?: string): void {
    const name = labelOf(label);
    if (timers.has(name)) {
      write("warn", `Timer '${name}' already exists`);
      return;
    }
    timers.set(name, now());
  },
  timeLog(label?: string, ...data: unknown[]): void {
    timeLog(labelOf(label), data);
  },
  timeEnd(label?: string): void {
    const name = labelOf(label);
    timeLog(name, []);
    timers.delete(name);
  },
  trace(...data: unknown[]): void {
    // The first frame is this method.
    const error = new Error();
    const frames = guard(() => String(error.stack ?? ""))
      .split("\n")
      .slice(1)
      .join("\n")
      .trimEnd();
    const head = data.length === 0 ? "Trace" : `Trace: ${format(data)}`;
    write("error", frames === "" ? head : `${head}\n${frames}`);
  },
} satisfies typeof globalThis.console;
