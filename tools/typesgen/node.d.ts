// The Node surface the generator uses, so its type check needs no @types/node.
declare module "node:fs" {
  export function readdirSync(path: string): string[];
  export function readFileSync(path: string, encoding: "utf8"): string;
  export function writeFileSync(path: string, data: string): void;
}
declare module "node:path" {
  export const posix: { join(...parts: string[]): string; normalize(path: string): string };
}
declare module "node:test" {
  export function test(name: string, fn: () => void): void;
}
declare module "node:assert/strict" {
  export function equal(actual: unknown, expected: unknown): void;
}
declare const process: { argv: string[] };
