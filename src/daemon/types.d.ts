// Daemon script types (yuked.js). The shared host plus the daemon's own yuke:daemon; see AGENTS.md.
/// <reference path="../js/types.d.ts" />

declare module "yuke:daemon" {
  // Daemon configuration. Every field is optional; an omitted field takes the daemon default.
  export interface DaemonConfig {
    host?: string;
    port?: number;
    dbPath?: string;
    blobDir?: string;
    authToken?: string;
    logLevel?: "debug" | "info" | "warn" | "error";
  }

  // Register the daemon configuration, returning it so `export default defineConfig({...})` reads
  // naturally. Call at most once, at module top level.
  export function defineConfig(config: DaemonConfig): DaemonConfig;
}
