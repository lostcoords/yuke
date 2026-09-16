// The public root has no UI dependency or default plugin activation.
export { defineConfig, config, events, Emitter } from "yuke:kernel";
import { rootScope, toolRegistry } from "yuke:ext";
export { plugins, Scope, Context, advice, services } from "yuke:ext";
export { fs } from "yuke:fs";
export { exec } from "yuke:exec";
export { spawn, lines } from "yuke:spawn";
export { jobs } from "yuke:jobs";
export { diff } from "yuke:diff";
export { client } from "yuke:client";

/** @typedef {import("./types/ext.js").ToolDefinition} ToolDefinition */
/** @typedef {import("./types/ext.js").ToolExecute} ToolExecute */
/** @typedef {import("./types/ext.js").Plugin} Plugin */
/** @typedef {import("./types/ext.js").Disposer} Disposer */
/** @typedef {import("./types/ext.js").AdviceWhere} AdviceWhere */
/** @typedef {import("./types/ext.js").AdviceOptions} AdviceOptions */
/** @typedef {import("./types/ext.js").InteractionSurface} InteractionSurface */
/** @typedef {import("yuke:kernel").ConfigPatch} ConfigPatch */
/** @typedef {import("yuke:jobs").Job} Job */

export const tools = toolRegistry(rootScope);
