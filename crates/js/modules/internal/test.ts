// The tests of one test file: `test` of `yuke:test` adds each test here. The runner of yuke runs one test by its index.

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
 * Run the test at `index`, which has the name `name`. The promise fulfills with what the test threw or rejected with, or
 * with `undefined` when the test passed. The promise never rejects, so a failure is no fault of the runtime.
 */
export async function run(index: number, name: string): Promise<{ failed: unknown } | undefined> {
  const entry = entries[index];
  if (entry?.name !== name) {
    return { failed: new Error(`the file registers no test "${name}" at position ${index} in this runtime`) };
  }
  try {
    await entry.fn();
    return undefined;
  } catch (error) {
    return { failed: error };
  }
}

/** Keep `path` as the scratch folder of the test. The runner calls this function before the import of the file. */
export function setFolder(path: string): void {
  scratch = path;
}

/** The scratch folder of the test: an empty folder that the runner made for this test alone. */
export function folder(): string {
  if (scratch === undefined) throw new Error("the runner gave no scratch folder");
  return scratch;
}
