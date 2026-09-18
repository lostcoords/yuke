declare module "yuke:env" {
  export const env: {
    /** Read the effective environment; a missing key returns undefined and an empty value stays empty. */
    get(name: string): string | undefined;
  };
}
