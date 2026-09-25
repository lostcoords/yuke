// The public chat targets preserve the objects that advice and slots use.
export { Chat, chats, focusedChat, focusedChatView, focusedSessionId, chatOf, chatEntry } from "yuke:internal/chat";
export { ChatView } from "yuke:internal/chat-view";
export { Transcript, labels, ROLE_NONE, ROLE_ACTION, ROLE_TEXT } from "yuke:internal/transcript";
export { attachPath, attachClipboard } from "yuke:internal/attach";

/** @typedef {import("yuke:internal/chat-view").PresentationContext} PresentationContext */
/** @typedef {import("yuke:internal/chat-view").ChatViewOptions} ChatViewOptions */
