// The unnamed register that a yank or delete fills and `p` reads, because OSC 52 cannot read the terminal clipboard.
/** @type {{ text: string, linewise: boolean, set: (text: unknown, linewise: unknown) => void }} */
export const register = {
  text: "",
  linewise: false,
  set(text, linewise) {
    this.text = String(text == null ? "" : text);
    this.linewise = !!linewise;
  },
};
