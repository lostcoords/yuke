// The Node surface the generator uses, so its type check needs no @types/node.
declare module "node:fs" {
  export function readdirSync(path: string): string[];
  export function readFileSync(path: string, encoding: "utf8"): string;
  export function writeFileSync(path: string, data: string): void;
}
declare module "node:path" {
  export const posix: { join(...parts: string[]): string; normalize(path: string): string };
}
declare const process: { argv: string[] };
