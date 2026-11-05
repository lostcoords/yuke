import type { SessionContext } from "yuke:plugins";

export function session(s: SessionContext): undefined {
  s.hook("tool.before", async (event) => {
    if (event.call.name !== "exec") return undefined;
    const answers = await s.ask(
      {
        questions: [
          {
            id: "exec",
            header: "Exec",
            question: `Allow exec with these arguments? ${JSON.stringify(event.call.arguments)}`,
            options: [{ label: "Allow" }, { label: "Deny" }],
          },
        ],
      },
      { signal: event.signal },
    );
    return answers?.[0]?.values.includes("Allow") ? undefined : { block: "The user did not approve exec." };
  });
  return undefined;
}
