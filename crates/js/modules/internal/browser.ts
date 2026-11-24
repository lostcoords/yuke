// The browser of the user, for the bundled plugins that send the user to a page.

import { Command } from "yuke:process";

/** Open `url` in the browser. This module cannot read the platform, and `open` on Linux can be another program. */
export async function openBrowser(url: string, folder: string): Promise<boolean> {
  for (const program of ["xdg-open", "open"]) {
    try {
      const output = await new Command(program, { args: [url], cwd: folder, stdout: "null", stderr: "null" }).output();
      return output.success;
    } catch {
      // This program does not start. The next one can.
    }
  }
  return false;
}
