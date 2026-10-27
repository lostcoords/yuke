// The tests of one test file: `test` of `yuke:test` adds each test here, and the runner of yuke runs them by index.

/** One registered test. */
interface Entry {
  readonly name: string;
  readonly fn: () => void | Promise<void>;
}

const entries: Entry[] = [];
let scratch: string | undefined;

/** Add the test `name`. */
export function register(name: string, fn: () => void | Promise<void>): void {
  entries.push({ name, fn });
}

/** The names of the tests, in the order of their registration. */
export function names(): string[] {
  return entries.map((entry) => entry.name);
}

/**
 * Run the test at `index`. The promise fulfills with what the test threw or rejected with, or with `undefined` when it
 * passed. It never rejects, so a failure is no fault of the runtime.
 */
export async function run(index: number): Promise<{ failed: unknown } | undefined> {
  try {
    await entries[index]?.fn();
    return undefined;
  } catch (error) {
    return { failed: error };
  }
}

/** Give the scratch folder of the file. The runner calls it before it imports the file. */
export function setFolder(path: string): void {
  scratch = path;
}

/** The scratch folder of the file: an empty folder that the runner made. A test makes its own subfolder in it. */
export function folder(): string {
  if (scratch === undefined) throw new Error("the runner gave no scratch folder");
  return scratch;
}
