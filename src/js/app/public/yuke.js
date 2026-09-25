// The public root has no UI dependency or default plugin activation. Every registration goes through a plugin context.
export { defineConfig, config } from "yuke:internal/kernel";
export { plugins } from "yuke:internal/ext";
export { fs } from "yuke:internal/native/fs";
export { env } from "yuke:internal/native/env";
export { fetch } from "yuke:internal/http";
export { utf8 } from "yuke:internal/native/utf8";
export { net } from "yuke:internal/net";
export { exec } from "yuke:internal/native/exec";
export { spawn, lines } from "yuke:internal/spawn";
export { jobs } from "yuke:internal/jobs";
export { diff } from "yuke:internal/native/diff";
export { client } from "yuke:internal/client";

/** @typedef {import("yuke:internal/ext").Context} Context */
/** @typedef {import("../types/ext.js").InjectContext} InjectContext */
/** @typedef {import("../types/ext.js").ToolContext} ToolContext */
/** @typedef {import("../types/ext.js").ToolDefinition} ToolDefinition */
/** @typedef {import("../types/ext.js").ToolExecute} ToolExecute */
/** @typedef {import("../types/ext.js").Plugin} Plugin */
/** @typedef {import("../types/ext.js").PluginHandle} PluginHandle */
/** @typedef {import("yuke:internal/native/cancellation").CancellationSignal} CancellationSignal */
/** @typedef {import("../types/ext.js").Disposer} Disposer */
/** @typedef {import("../types/ext.js").AdviceWhere} AdviceWhere */
/** @typedef {import("../types/ext.js").AdviceOptions} AdviceOptions */
/** @typedef {import("../types/ext.js").InteractionSurface} InteractionSurface */
/** @typedef {import("../types/ext.js").InteractionOptions} InteractionOptions */
/** @typedef {import("../types/ext.js").Release} Release */
/** @typedef {import("../types/ext.js").HookPoint} HookPoint */
/** @typedef {import("../types/ext.js").HookHandler} HookHandler */
/** @typedef {import("yuke:internal/kernel").ConfigPatch} ConfigPatch */
/** @typedef {import("yuke:internal/native/jobs").Job} Job */

