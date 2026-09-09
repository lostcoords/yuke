import { plugins } from "yuke:ext";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);
client.sessionList = async () => ({ items: [
  { session: { id: "parent", title: "parent", origin: { type: "root" } }, activity: { state: { type: "idle" } } },
  { session: { id: "child", title: "child", origin: { type: "child" } }, activity: { state: { type: "idle" } } },
], total: 2 });
