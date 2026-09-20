// The public chat targets preserve the objects that advice and slots use.
export { Chat, chats, focusedChat, focusedChatView, focusedSessionId, chatOf, chatEntry } from "yuke:chat";
export { ChatView } from "yuke:chat-view";
export { Transcript, presentation, presenters, sources, ROLE_NONE, ROLE_ACTION, ROLE_TEXT } from "yuke:transcript";
export { attachPath, attachClipboard } from "yuke:attach";
export { composerVim, composerMode, setComposerMode } from "yuke:composer-vim";
export { transcriptVim } from "yuke:transcript-vim";
export { agents } from "yuke:agents";

/** @typedef {import("yuke:chat-view").PresentationContext} PresentationContext */
/** @typedef {import("yuke:chat-view").ChatViewOptions} ChatViewOptions */
