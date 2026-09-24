// The public root has no UI dependency or default plugin activation. Every registration goes through a plugin context.
export { defineConfig, config } from "yuke:kernel";
export { plugins } from "yuke:ext";
export { fs } from "yuke:fs";
export { env } from "yuke:env";
export { fetch } from "yuke:http";
export { utf8 } from "yuke:utf8";
export { net } from "yuke:net";
export { exec } from "yuke:exec";
export { spawn, lines } from "yuke:spawn";
export { jobs } from "yuke:jobs";
export { diff } from "yuke:diff";
export { client } from "yuke:client";

/** @typedef {import("./types/ext.js").ToolDefinition} ToolDefinition */
/** @typedef {import("./types/ext.js").ToolExecute} ToolExecute */
/** @typedef {import("./types/ext.js").Plugin} Plugin */
/** @typedef {import("./types/ext.js").PluginHandle} PluginHandle */
/** @typedef {import("yuke:cancellation-native").CancellationSignal} CancellationSignal */
/** @typedef {import("./types/ext.js").Disposer} Disposer */
/** @typedef {import("./types/ext.js").AdviceWhere} AdviceWhere */
/** @typedef {import("./types/ext.js").AdviceOptions} AdviceOptions */
/** @typedef {import("./types/ext.js").InteractionSurface} InteractionSurface */
/** @typedef {import("yuke:kernel").ConfigPatch} ConfigPatch */
/** @typedef {import("yuke:jobs-native").Job} Job */

