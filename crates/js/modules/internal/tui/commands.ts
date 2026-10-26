/**
 * The commands of the terminal interface. A key binding names a command, and the palette lists them. A run can be
 * async: the caller does not wait, so the keys go on during a dialog of the command.
 */
import { failureOf } from "yuke:internal/plugins";
import type { Command } from "yuke:tui";

const NAME = /^[A-Za-z0-9:._-]+$/;

/** A command as the palette lists it. */
export interface CommandItem {
  readonly name: string;
  readonly title: string;
  readonly enabled: boolean;
}

/** A command and its title at the time of its add, so a later change of the object changes neither. */
interface Entry {
  readonly command: Command;
  readonly title: string;
}

export class Commands {
  readonly #commands = new Map<string, Entry>();
  readonly #fault: (text: string) => void;
  readonly #changed: () => void;

  /** `fault` gets the text of a failed command, and `changed` asks for a frame after each run. */
  constructor(fault: (text: string) => void, changed: () => void) {
    this.#fault = fault;
    this.#changed = changed;
  }

  /** Add `command` and return its disposer. A name that another command has throws a `TypeError`. */
  add(command: Command): () => void {
    const { name, title, run, enabled } = command;
    if (typeof name !== "string" || !NAME.test(name)) {
      throw new TypeError(`'${String(name)}' is no command name: letters, digits, and : . _ -`);
    }
    if (typeof run !== "function") throw new TypeError(`the command ${name} has no run function`);
    if (title !== undefined && typeof title !== "string") throw new TypeError(`the title of ${name} is a string`);
    if (enabled !== undefined && typeof enabled !== "function") {
      throw new TypeError(`the enabled check of ${name} is a function`);
    }
    if (this.#commands.has(name)) throw new TypeError(`the command ${name} exists`);
    const entry: Entry = { command, title: title ?? name };
    this.#commands.set(name, entry);
    return () => {
      if (this.#commands.get(name) === entry) this.#commands.delete(name);
    };
  }

  /** True when the command `name` exists and is enabled. */
  available(name: string): boolean {
    const entry = this.#commands.get(name);
    return entry !== undefined && this.#enabled(name, entry.command);
  }

  /**
   * Run the command `name` with `args`. Return `false` when it is missing or disabled, else `true`, also when the run
   * fails.
   */
  run(name: string, args?: unknown): boolean {
    const entry = this.#commands.get(name);
    if (entry === undefined || !this.#enabled(name, entry.command)) return false;
    const failed = (error: unknown): void => {
      this.#fault(`the command ${name} failed: ${failureOf(error)}`);
      this.#changed();
    };
    let result: unknown;
    try {
      result = entry.command.run(args);
    } catch (error) {
      failed(error);
      return true;
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
    return [...this.#commands].map(([name, { command, title }]) => ({
      name,
      title,
      enabled: this.#enabled(name, command),
    }));
  }

  /** True when `command` can run. A throw of `enabled` counts as disabled, and it is a fault. */
  #enabled(name: string, command: Command): boolean {
    if (command.enabled === undefined) return true;
    try {
      return command.enabled() === true;
    } catch (error) {
      this.#fault(`the enabled check of the command ${name} failed: ${failureOf(error)}`);
      return false;
    }
  }
}
