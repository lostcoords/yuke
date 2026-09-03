// yuke — the public facade. User code imports this name, so an internal `yuke:` name never becomes configuration syntax.
import { defineConfig } from "yuke:kernel";
import { plugins } from "yuke:ext";
import { defineTool } from "yuke:tools";

/** @typedef {(args: any, signal: { aborted: boolean }, context: { workspaceRoot: string }) => Promise<unknown>} ToolExecute */
/** @typedef {{ name: string, description: string, parameters: Record<string, unknown>, execute: ToolExecute }} ToolDefinition */

// The tool registry. One object states the whole tool, so the name stays beside the rest of the definition.
export const tools = {
  /** @param {ToolDefinition} definition @returns {void} */
  define(definition) {
    if (definition == null || typeof definition !== "object") {
      throw new TypeError("tools.define expects a tool definition object");
    }
    defineTool(definition.name, definition);
  },
};

export { defineConfig, plugins };
