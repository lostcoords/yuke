declare module "yuke:internal/native/env" {
  /** The effective environment of the host, read-only. */
  export const env: {
    /** Read one variable. A missing name answers undefined, and an empty value stays empty. An empty name or a name with NUL or = throws a TypeError. */
    get(name: string): string | undefined;
  };
}
