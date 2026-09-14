declare module "yuke:tools" {
  export function defineTool(name: string, definition: Omit<import("./ext.js").ToolDefinition, "name">): void;
  export function removeTool(name: string): boolean;
}
