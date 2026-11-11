/**
 * The commands of the terminal interface. A key binding names a command, and a list of commands shows them. A run can be
 * async: the caller does not wait, so the keys go on during a dialog of the command.
 */
import { failureOf } from "yuke:internal/failure";
import type { Command, CommandItem } from "yuke:tui";

const NAME = /^[A-Za-z0-9:._-]+$/;

/** A command and its description at the add. A later change of the command object does not change the entry. */
interface Entry {
  readonly command: Command;
  readonly description: string | undefined;
  readonly slash: string | undefined;
  readonly argumentHint: string | undefined;
}

export class Commands {
  readonly #commands = new Map<string, Entry>();
  readonly #fault: (name: string, text: string) => void;
  readonly #changed: () => void;

  /**
   * `fault` gets the name of a failed command and the text of its failure; `changed` asks for a frame after each change
   * and each run.
   */
  constructor(fault: (name: string, text: string) => void, changed: () => void) {
    this.#fault = fault;
    this.#changed = changed;
  }

  /**
   * Add `command` under `name` and return its disposer. `name` is the name of the command, or the qualified form from a
   * plugin surface. A duplicate name throws a `TypeError`. A run is a method call, so a class command keeps its `this`.
   */
  add(command: Command, name: string = command.name): () => void {
    const { description, slash, argumentHint } = command;
    if (!NAME.test(name)) throw new TypeError(`'${name}' is no command name: letters, digits, and : . _ -`);
    // The text after a space is the text of the command, so a word with a space never matches.
    if (slash !== undefined && !NAME.test(slash)) {
      throw new TypeError(`'${slash}' is no slash word: letters, digits, and : . _ -`);
    }
    if (this.#commands.has(name)) throw new TypeError(`the command ${name} exists`);
    const entry: Entry = { command, description, slash, argumentHint };
    this.#commands.set(name, entry);
    this.#changed();
    return () => {
      if (this.#commands.get(name) !== entry) return;
      this.#commands.delete(name);
      this.#changed();
    };
  }

  /** True when the command `name` exists and is enabled. */
  available(name: string): boolean {
    const entry = this.#commands.get(name);
    return entry !== undefined && this.#enabled(entry);
  }

  /**
   * Run the command `name` with `args`. Return `false` when it is missing, disabled, or when its run gives `false`, else
   * `true`, also when it fails.
   */
  run(name: string, args?: unknown): boolean {
    const entry = this.#commands.get(name);
    if (entry === undefined || !this.#enabled(entry)) return false;
    const failed = (error: unknown): void => {
      this.#fault(name, `the command ${name} failed: ${failureOf(error)}`);
      this.#changed();
    };
    let result: unknown;
    try {
      result = entry.command.run(args);
    } catch (error) {
      failed(error);
      return true;
    }
    if (result === false) {
      this.#changed();
      return false;
    }
    if (result === undefined) {
      this.#changed();
    } else {
      // `Promise.resolve` also follows a thenable that is no `Promise`.
      Promise.resolve(result).then(() => this.#changed(), failed);
    }
    return true;
  }

  /** The commands, in the order of their adds. */
  list(): CommandItem[] {
    const claimed = new Set<string | undefined>();
    return [...this.#commands].map(([name, entry]) => {
      // The first command with a word keeps it, and a later one shows its full name.
      const slash = claimed.has(entry.slash) ? name : entry.slash;
      if (slash !== undefined) claimed.add(slash);
      return {
        name,
        ...(entry.description === undefined ? {} : { description: entry.description }),
        ...(slash === undefined ? {} : { slash }),
        ...(entry.argumentHint === undefined ? {} : { argumentHint: entry.argumentHint }),
        enabled: this.#enabled(entry),
      };
    });
  }

  /** True when the command of `entry` can run. */
  #enabled(entry: Entry): boolean {
    return entry.command.enabled === undefined || entry.command.enabled() === true;
  }
}
