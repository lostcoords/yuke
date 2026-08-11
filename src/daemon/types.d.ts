// Daemon script types (yuked.js). The shared host plus the daemon's own yuke:daemon; see AGENTS.md.
/// <reference path="../js/types.d.ts" />

declare module "yuke:daemon" {
  // Daemon configuration. Every field is optional; an omitted field takes the daemon default.
  export interface DaemonConfig {
    host?: string;
    port?: number;
    /** Base directory for the event-log database and blob store. Omit for the platform data directory. */
    dataDir?: string;
    authToken?: string;
    logLevel?: "debug" | "info" | "warn" | "error";
    relayCloudUrl?: string;
    allowedOrigins?: string[];
  }

  // Register the daemon configuration, returning it so `export default defineConfig({...})` reads
  // naturally. Call at most once, at module top level.
  export function defineConfig(config: DaemonConfig): DaemonConfig;
}
