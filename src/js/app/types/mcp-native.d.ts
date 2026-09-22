declare module "yuke:mcp-native" {
  export type RecordScope = "mcp-trust" | "mcp-oauth";
  export function configPath(): string | undefined;
  /** Answers the private record, or undefined; a trust record belongs to the current workspace. */
  export function readRecord(scope: RecordScope, key: string): string | undefined;
  /** Replaces the private record; at most 64 KiB. */
  export function writeRecord(scope: RecordScope, key: string, text: string): void;
  export function removeRecord(scope: RecordScope, key: string): void;
}
