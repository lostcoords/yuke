import type { SessionContext } from "yuke:plugins";

export function session(s: SessionContext): undefined {
  s.addHook("prompt.build", (event) => ({
    sections: {
      ...event.sections,
      review: "Run the relevant tests before you report a code change as complete.",
    },
  }));
  return undefined;
}
