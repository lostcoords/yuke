// The doc rewrite keeps prose, `{@link}`, and tag text, and drops what only repeats the signature.
import { test } from "node:test";
import { equal } from "node:assert/strict";
import { cleanDocs } from "./docs.ts";

test("cleanDocs keeps meaning and drops repeated types", () => {
  const input = [
    "  /** @param {string} id @returns {Session | null} */",
    "  open(id: string): Session | null;",
    "  /**",
    "   * Show a pane. See {@link Pane}.",
    "   * @param {{ rows: number }} opts - The size. Rows start at 1.",
    "   * @param {string} [title]",
    "   * @template {object} T",
    "   * @returns {boolean} False when the pane is closed.",
    "   */",
    "  show<T>(opts: { rows: number }, title?: string): boolean;",
    "  bindTo: (/** @type {Context} */ ctx: Context) => Surface;",
    "",
  ].join("\n");
  const want = [
    "  open(id: string): Session | null;",
    "  /**",
    "   * Show a pane. See {@link Pane}.",
    "   * @param opts - The size. Rows start at 1.",
    "   * @returns False when the pane is closed.",
    "   */",
    "  show<T>(opts: { rows: number }, title?: string): boolean;",
    "  bindTo: (ctx: Context) => Surface;",
    "",
  ].join("\n");
  equal(cleanDocs(input), want);
});
