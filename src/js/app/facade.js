// yuke — the public facade. User code imports this name, so an internal `yuke:` name never becomes configuration syntax.
import { defineConfig } from "yuke:kernel";
import { plugins } from "yuke:ext";
import { defineTool } from "yuke:tools";

/** @typedef {(args: any, signal: { aborted: boolean }, context: { workspaceRoot: string }) => Promise<unknown>} ToolExecute */
/** @typedef {{ name: string, description: string, parameters: Record<string, unknown>, execute: ToolExecute }} ToolDefinition */
/** @typedef {{ name: string, title: string, description: string, slash?: string | null, args?: boolean, run: (arg?: string) => unknown }} CommandDefinition */

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

// The command registry. One definition is one plugin, so a redefinition replaces and the disposer removes.
export const commands = {
  /** @param {CommandDefinition} definition @returns {() => void} */
  define(definition) {
    if (definition == null || typeof definition !== "object") {
      throw new TypeError("commands.define expects a command definition object");
    }
    const { name, title, description, run } = definition;
    if (typeof name !== "string" || name === "") throw new TypeError("commands.define: name must be a non-empty string");
    if (typeof title !== "string" || typeof description !== "string") throw new TypeError("commands.define: title and description must be strings");
    if (typeof run !== "function") throw new TypeError("commands.define: run must be a function");
    const id = "user:" + name;
    const meta = { title, description, slash: definition.slash === undefined ? name : definition.slash, args: !!definition.args };
    return plugins.use({
      name: "command:" + name,
      /** @param {import("yuke:ext").Context} ctx */
      apply(ctx) {
        ctx.inject(["tui"], (ctx) => {
          ctx.tui.command(null, { [id]: run }, { [id]: meta });
        });
      },
    });
  },
};

export { defineConfig, plugins };
