import { root } from "yuke:core";

// The unnamed register. A yank or a delete fills it and `p` reads it. OSC 52 is write only, so a
// paste can never read the terminal's own clipboard.
export const register = {
  text: "",
  linewise: false,
  set(text, linewise) {
    this.text = String(text == null ? "" : text);
    this.linewise = !!linewise;
  },
};

// The mounted chat pane. Splits insert a placeholder, so the tree holds one chat.
export function chatView() {
  const v = root.active;
  if (v && v.name === "chat") return v;
  const rn = root.root_node;
  if (!rn) return null;
  for (const leaf of rn.leaves()) if (leaf.view && leaf.view.name === "chat") return leaf.view;
  return null;
}
