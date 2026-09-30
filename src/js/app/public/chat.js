// The public chat targets preserve the objects that advice and event listeners use.
export { ChatView } from "yuke:internal/chat-view";
export { ChatSurface } from "yuke:internal/chat";
export { Transcript, inputSourceLabel } from "yuke:internal/transcript";
export { displayPath, displayCommand, toolHead, wrapRows, viewRows, mediaLabel, errorLabel, isCut, openDetails } from "yuke:internal/transcript-view";
export { attachPath, attachClipboard } from "yuke:internal/attach";


/** @typedef {import("../types/transcript.js").Render} Render */
/** @typedef {import("../types/transcript.js").ToolHead} ToolHead */
/** @typedef {import("../types/transcript.js").ToolHeading} ToolHeading */
/** @typedef {import("../types/transcript.js").PartEnv} PartEnv */
/** @typedef {import("../types/transcript.js").MessageEnv} MessageEnv */
/** @typedef {import("../types/transcript.js").Rendered} Rendered */
/** @typedef {import("../types/transcript.js").PartHit} PartHit */
