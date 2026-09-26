import { root, command } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { chatPlugin } from "yuke:internal/chat";
import { sessionsPlugin } from "yuke:internal/session";
globalThis.root = root;
plugins.use(sessionsPlugin);
plugins.use(chatPlugin);
command.perform("ui:sessions");
