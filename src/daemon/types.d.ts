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

  // Reasoning request-body shape. Omit for the protocol's ordinary shape ("native"); the rest
  // are protocol-specific exceptions validated against `protocol`.
  export type ReasoningFormat =
    | "native"
    | "openai-effort-toggle-off"
    | "openrouter-effort"
    | "zai-toggle"
    | "qwen-thinking"
    | "anthropic-adaptive";

  // Assistant field replayed across a tool-use round. Omit for "none".
  export type ReasoningReplay = "none" | "reasoning-content" | "reasoning-details";

  export interface ProviderModelCost {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
  }

  // A complete custom model. The session default reasoning level is derived from
  // `reasoningLevels`, not supplied.
  export interface ProviderModelDefinition {
    id: string;
    upstreamId: string;
    name: string;
    contextWindow: number;
    maxOutputTokens: number;
    reasoningLevels: string[];
    supportsVision: boolean;
    supportsTools: boolean;
    supportsTemperature: boolean;
    reasoningFormat?: ReasoningFormat;
    reasoningReplay?: ReasoningReplay;
    cost: ProviderModelCost;
  }

  // Tune an imported models.dev model in place. Allowed only alongside `modelsDev`.
  export interface ProviderModelOverride {
    id: string;
    reasoningLevels: string[];
  }

  export interface ProviderDefinition {
    name?: string;
    baseUrl?: string;
    protocol?: ProviderProtocol;
    credentialEnv?: string[];
    modelsDev?: string;
    // Custom models require a resolvable endpoint (`baseUrl` + `protocol`).
    models?: ProviderModelDefinition[];
    // Overrides require `modelsDev`.
    modelOverrides?: ProviderModelOverride[];
  }

  // Register one provider during initial yuked.js evaluation. Provider and model IDs must be unique.
  export function defineProvider(id: string, definition: ProviderDefinition): ProviderDefinition;
}
