/**
 * The keymap: it sees each key before the focused view. A binding names a command in one context atom. Among the
 * bindings of a key, the deepest active atom wins, then the newest binding. The first enabled command runs. `key`
 * returns `false` when no enabled command takes the key, and the caller then gives it to the focused view.
 */
import type { Commands } from "yuke:internal/tui/commands";
import { parseKeys, strokeOf } from "yuke:internal/tui/keys";
import type { KeyEvent } from "yuke:tui";

/** The wait for the next stroke of a sequence. Then the prefix runs alone. */
const SEQUENCE_MS = 1000;

interface Binding {
  readonly strokes: readonly string[];
  readonly command: string;
  readonly atom: string;
  readonly order: number;
}

export class Keymap {
  readonly #commands: Commands;
  readonly #changed: () => void;
  readonly #bindings: Binding[] = [];
  #order = 0;
  /** The strokes of a sequence so far, and the atoms of its last stroke. */
  #pending: readonly string[] = [];
  #atoms: readonly string[] = [];
  #timer: ReturnType<typeof setTimeout> | undefined;

  /** `changed` asks for a frame when the pending keys change. */
  constructor(commands: Commands, changed: () => void) {
    this.#commands = commands;
    this.#changed = changed;
  }

  /** Bind `spec` to the command `command` in the context atom `in` (`root` by default), and return the disposer. */
  bind(spec: string, command: string, options: { readonly in?: string } = {}): () => void {
    const { in: atom = "root" } = options;
    if (typeof command !== "string" || command === "") throw new TypeError("a binding names a command");
    if (typeof atom !== "string" || atom === "") throw new TypeError("a context atom is a string that is not empty");
    const binding: Binding = { strokes: parseKeys(spec), command, atom, order: this.#order++ };
    this.#bindings.push(binding);
    return () => {
      const at = this.#bindings.indexOf(binding);
      if (at < 0) return;
      this.#bindings.splice(at, 1);
      // The wait may belong to this binding, as when its plugin stops.
      this.cancel();
    };
  }

  /**
   * Run the binding of `event`, and return `true` when the keymap takes the key. `atoms` are the active context atoms,
   * the shallowest first.
   */
  key(event: KeyEvent, atoms: readonly string[]): boolean {
    const stroke = strokeOf(event);
    if (stroke === "") return false;
    if (this.#pending.length > 0) {
      const strokes = [...this.#pending, stroke];
      this.cancel();
      if (stroke === "esc" || this.#press(strokes, atoms)) return true;
      // An unmatched second stroke goes on as a new key.
    }
    return this.#press([stroke], atoms);
  }

  /** Drop the pending sequence, as a focus change does. */
  cancel(): void {
    if (this.#pending.length === 0) return;
    clearTimeout(this.#timer);
    this.#pending = [];
    this.#atoms = [];
    this.#changed();
  }

  /** The keys of the pending sequence, such as `ctrl+x`, or "". */
  pending(): string {
    return this.#pending.join(" ");
  }

  /** The specs bound to the command `name`, each one once, the newest first. */
  keysOf(name: string): string[] {
    const specs = this.#bindings
      .filter((binding) => binding.command === name)
      .toReversed()
      .map((binding) => binding.strokes.join(" "));
    return [...new Set(specs)];
  }

  /**
   * Wait for the next stroke when an available longer sequence starts with `strokes`, else run the binding of
   * `strokes`. A deeper binding of exactly `strokes` runs at once.
   */
  #press(strokes: readonly string[], atoms: readonly string[]): boolean {
    let exact = -1;
    let longer = -1;
    for (const binding of this.#bindings) {
      const depth = atoms.lastIndexOf(binding.atom);
      if (depth < 0 || !strokes.every((stroke, at) => binding.strokes[at] === stroke)) continue;
      if (!this.#commands.available(binding.command)) continue;
      if (binding.strokes.length === strokes.length) exact = Math.max(exact, depth);
      else longer = Math.max(longer, depth);
    }
    if (longer >= 0 && longer >= exact) {
      this.#pending = strokes;
      this.#atoms = [...atoms];
      this.#timer = setTimeout(() => {
        const [prefix, prefixAtoms] = [this.#pending, this.#atoms];
        this.cancel();
        this.#run(prefix, prefixAtoms);
      }, SEQUENCE_MS);
      this.#changed();
      return true;
    }
    return this.#run(strokes, atoms);
  }

  /** Run the first enabled command of the bindings of exactly `strokes`, by rank. */
  #run(strokes: readonly string[], atoms: readonly string[]): boolean {
    const ranked = this.#bindings
      .filter(
        (binding) =>
          atoms.includes(binding.atom) &&
          binding.strokes.length === strokes.length &&
          strokes.every((stroke, at) => binding.strokes[at] === stroke),
      )
      .sort((a, b) => atoms.lastIndexOf(b.atom) - atoms.lastIndexOf(a.atom) || b.order - a.order);
    return ranked.some((binding) => this.#commands.run(binding.command));
  }
}
