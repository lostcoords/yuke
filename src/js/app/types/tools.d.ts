declare module "yuke:tools" {
  import type { ToolDefinition } from "yuke";

  export function defineTool(name: string, definition: Omit<ToolDefinition, "name">): void;
  export function removeTool(name: string): boolean;
  export function hasTool(name: string): boolean;
}
