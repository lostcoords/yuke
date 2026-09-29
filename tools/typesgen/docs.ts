// Rewrite the doc blocks of an emitted declaration file. The signature holds every type, so a `{Type}` in a tag only repeats it.

// These tags can carry a JSDoc type before their text.
const typed = new Set(["param", "arg", "argument", "property", "prop", "template", "returns", "return", "type", "throws", "exception", "this", "yields", "satisfies"]);
// These tags name a parameter before their text.
const named = new Set(["param", "arg", "argument", "property", "prop", "template"]);

type Tag = { name: string; rest: string };

// Remove the `{Type}` part of each tag, drop a typed tag with no text, and drop a block with no prose and no tag left.
export function cleanDocs(text: string): string {
  return text.replace(/([ \t]*)\/\*\*([^]*?)\*\/([ \t]*)(\n?)/g, (_block: string, indent: string, body: string, gap: string, end: string, at: number) => {
    const cleaned = cleanBlock(body);
    // A block on its own line takes its line with it; an inline block takes the space after it.
    const ownLine = at === 0 || text[at - 1] === "\n";
    if (cleaned === null) return ownLine && end === "\n" ? "" : indent + end;
    const oneLine = !body.includes("\n") && !cleaned.includes("\n");
    const doc = oneLine ? `/** ${cleaned} */` : `/**\n${cleaned.split("\n").map((line) => `${indent} *${line === "" ? "" : " " + line}`).join("\n")}\n${indent} */`;
    return `${indent}${doc}${gap}${end}`;
  });
}

// Answer the new block text, or null when nothing in it says more than the signature.
function cleanBlock(body: string): string | null {
  const text = body.split("\n").map((line) => line.replace(/^\s*\*?[ \t]?/, "")).join("\n").trim();
  const starts = tagStarts(text);
  const prose = text.slice(0, starts[0] ?? text.length).trim();
  const tags: string[] = [];
  starts.forEach((start, i) => {
    const kept = cleanTag(splitTag(text.slice(start + 1, starts[i + 1] ?? text.length)));
    if (kept !== null) tags.push(kept);
  });
  const parts = prose === "" ? tags : [prose, ...tags];
  return parts.length === 0 ? null : parts.join(body.includes("\n") ? "\n" : " ");
}

// Answer the prose of the doc block above a declaration, or an empty string when it has none.
export function summaryOf(declaration: string): string {
  const lines = declaration.split("\n");
  const head = lines.slice(0, lines.findIndex((line) => !/^\s*(\/\*\*|\*|\/\/|$)/.test(line) || /\*\/\s*\S/.test(line)) + 1).join("\n");
  const doc = [...head.matchAll(/\/\*\*([^]*?)\*\//g)].at(-1);
  if (doc === undefined) return "";
  const text = doc[1]!.split("\n").map((line) => line.replace(/^\s*\*?[ \t]?/, "")).join("\n").trim();
  return text.slice(0, tagStarts(text)[0] ?? text.length).trim();
}

// A tag starts at `@` outside braces, at the start of the text or after white space, so `{@link x}` stays in its prose.
function tagStarts(text: string): number[] {
  const starts: number[] = [];
  let depth = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "{") depth++;
    else if (c === "}") depth = Math.max(0, depth - 1);
    else if (c === "@" && depth === 0 && (i === 0 || /\s/.test(text[i - 1]!)) && /[A-Za-z]/.test(text[i + 1] ?? "")) starts.push(i);
  }
  return starts;
}

function splitTag(raw: string): Tag {
  const name = /^[A-Za-z]+/.exec(raw)![0];
  return { name, rest: raw.slice(name.length).trim() };
}

// Answer the tag without its type, or null when only the type or the name was there.
function cleanTag(tag: Tag): string | null {
  if (!typed.has(tag.name)) return `@${tag.name}${tag.rest === "" ? "" : " " + tag.rest}`;
  let rest = tag.rest;
  if (rest.startsWith("{")) rest = rest.slice(typeEnd(rest)).trim();
  if (!named.has(tag.name)) return rest === "" ? null : `@${tag.name} ${rest}`;
  const name = /^(\[[^\]]*\]|\S+)/.exec(rest)?.[0];
  if (name === undefined) return null;
  const said = rest.slice(name.length).trim().replace(/^-\s*/, "");
  return said === "" ? null : `@${tag.name} ${name} - ${said}`;
}

// The index after the brace that closes the type at the start of `rest`.
function typeEnd(rest: string): number {
  let depth = 0;
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === "{") depth++;
    else if (rest[i] === "}" && --depth === 0) return i + 1;
  }
  return rest.length;
}
