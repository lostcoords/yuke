// The unnamed register. A yank or a delete fills it and `p` reads it. OSC 52 is write only, so a
// paste can never read the terminal's own clipboard.
/** @type {{ text: string, linewise: boolean, set: (text: unknown, linewise: unknown) => void }} */
export const register = {
  text: "",
  linewise: false,
  set(text, linewise) {
    this.text = String(text == null ? "" : text);
    this.linewise = !!linewise;
  },
};
