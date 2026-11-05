// Add a tool to each session. This plugin needs no service in `uses`.

/** @param {import("yuke:plugins").SessionContext} session */
export function session(session) {
  session.tools.define({
    name: "count_words",
    description: "Count the words in a text, split at whitespace.",
    parameters: {
      type: "object",
      properties: { text: { type: "string" } },
      required: ["text"],
    },
    concurrency: "parallel",
    execute: (args) => {
      const text = args.text.trim();
      return String(text === "" ? 0 : text.split(/\s+/u).length);
    },
  });
  return undefined;
}
