declare module "yuke:internal/native/tools" {
  import type { ToolDefinition } from "yuke:internal/types/ext";

  /** Register one tool and answer its registration id. A function `when` makes it a variant. */
  export function defineTool(name: string, definition: Omit<ToolDefinition, "name">): number;
  /** Remove one registration. It answers false when the registration already left. */
  export function removeTool(id: number): boolean;
  /** True when a global tool, one without `when`, holds the name. */
  export function hasTool(name: string): boolean;
}
