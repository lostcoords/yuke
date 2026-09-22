// yuke:browser — open a URL in the system browser.
import { exec } from "yuke:exec";

// Quote the URL so the shell cannot parse it as syntax; `setsid -f` keeps the browser alive after `exec` ends its group.
/** @param {string} url @returns {void} */
export function openUrl(url) {
  const quoted = "'" + url.replace(/'/g, "'\\''") + "'";
  exec("open " + quoted + " 2>/dev/null || setsid -f xdg-open " + quoted + " >/dev/null 2>&1").catch(() => {});
}
