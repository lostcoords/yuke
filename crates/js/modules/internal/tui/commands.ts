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
  /** True after a throw of `enabled` gave its one fault. */
  faulted: boolean;
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
    const { description, run, enabled } = command;
    if (typeof name !== "string" || !NAME.test(name)) {
      throw new TypeError(`'${String(name)}' is no command name: letters, digits, and : . _ -`);
    }
    if (typeof run !== "function") throw new TypeError(`the command ${name} has no run function`);
    if (description !== undefined && typeof description !== "string") {
      throw new TypeError(`the description of ${name} is a string`);
    }
    if (enabled !== undefined && typeof enabled !== "function") {
      throw new TypeError(`the enabled check of ${name} is a function`);
    }
    if (this.#commands.has(name)) throw new TypeError(`the command ${name} exists`);
    const entry: Entry = { command, description, faulted: false };
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
    return entry !== undefined && this.#enabled(name, entry);
  }

  /**
   * Run the command `name` with `args`. Return `false` when it is missing or disabled, else `true`, also when the run
   * fails.
   */
  run(name: string, args?: unknown): boolean {
    const entry = this.#commands.get(name);
    if (entry === undefined || !this.#enabled(name, entry)) return false;
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
    return [...this.#commands].map(([name, entry]) => ({
      name,
      ...(entry.description === undefined ? {} : { description: entry.description }),
      enabled: this.#enabled(name, entry),
    }));
  }

  /**
   * True when the command of `entry` can run. A throw of `enabled` counts as disabled and gives one fault per
   * registration, because a list of commands checks each command on each frame.
   */
  #enabled(name: string, entry: Entry): boolean {
    const { command } = entry;
    if (command.enabled === undefined) return true;
    try {
      return command.enabled() === true;
    } catch (error) {
      if (!entry.faulted) {
        entry.faulted = true;
        this.#fault(name, `the enabled check of the command ${name} failed: ${failureOf(error)}`);
      }
      return false;
    }
  }
}
