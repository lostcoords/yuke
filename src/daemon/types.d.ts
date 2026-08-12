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

  export type ProviderProtocol = "anthropic-messages" | "openai-chat" | "openai-responses";

  export interface ProviderModelCost {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
  }

  export interface ProviderModelDefinition {
    id: string;
    upstreamId: string;
    name: string;
    contextWindow: number;
    maxOutputTokens: number;
    reasoningLevels: string[];
    defaultReasoning: string;
    supportsVision: boolean;
    supportsTools: boolean;
    cost: ProviderModelCost;
  }

  export interface ProviderDefinition {
    name?: string;
    baseUrl?: string;
    protocol?: ProviderProtocol;
    credentialEnv?: string[];
    modelsDev?: string;
    models?: ProviderModelDefinition[];
  }

  // Register one provider during initial yuked.js evaluation. Provider and model IDs must be unique.
  export function defineProvider(id: string, definition: ProviderDefinition): ProviderDefinition;
}
