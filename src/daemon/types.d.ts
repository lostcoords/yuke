// Daemon script types (yuked.js). The shared host modules plus yuke:daemon; see AGENTS.md.
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

  /**
   * A parameter's type, with a trailing `?` marking it optional. Compiled to JSON Schema by
   * the host; this sugar is the only accepted form.
   */
  export type ToolParam =
    | "string" | "integer" | "number" | "boolean"
    | "string?" | "integer?" | "number?" | "boolean?";

  export interface ToolDefinition<A = Record<string, unknown>> {
    /** Shown to the model. Required, and it is what decides whether the tool gets used well. */
    description: string;
    /** Omit for a tool that takes no arguments. */
    params?: Record<string, ToolParam>;
    handler: (args: A, signal: YukeCancelSignal) => unknown | Promise<unknown>;
  }

  // Register a tool the model may call. The name is 1 to 64 characters of [A-Za-z0-9_-], and
  // registering one twice replaces the first. A bad definition fails the daemon's start.
  export function defineTool<A = Record<string, unknown>>(
    name: string,
    definition: ToolDefinition<A>,
  ): ToolDefinition<A>;
}
