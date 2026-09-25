import { root, command } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { chatPlugin } from "yuke:internal/chat";
globalThis.root = root;
plugins.use(chatPlugin);
command.perform("ui:sessions");
