import { equal } from "yuke:test";
import { Document } from "yuke:md";
// Every block kind, with lookahead cases: a setext heading, a table, and a fence that closes late.
const text = "Intro para\nsecond line\n\n# Head\n\nSetext\n===\n\n- one\n- two\n\n1. first\n2. second\n\n> quoted\n> more\n\n" +
  "a | b\n---|---\n1 | 2\n\n```zig\nconst x = 1;\nconst y = 2;\n```\n\n---\n\nlast **bold** para\nwith a|pipe\n---|---\nx|y\n";
const stream = new Document();
const fails = [];
for (let n = 1; n <= text.length; n++) {
  const head = text.slice(0, n);
  stream.setText(head);
  const fresh = new Document();
  fresh.setText(head);
  const same = JSON.stringify(stream.blocks()) === JSON.stringify(fresh.blocks()) &&
    JSON.stringify(stream.rows(24)) === JSON.stringify(fresh.rows(24)) &&
    JSON.stringify(stream.codeBlocks()) === JSON.stringify(fresh.codeBlocks());
  if (!same) fails.push(n);
}
// A rewrite that is not an append parses from the start again.
stream.setText("changed\n\n" + text);
const fresh = new Document();
fresh.setText("changed\n\n" + text);
if (JSON.stringify(stream.rows(24)) !== JSON.stringify(fresh.rows(24))) fails.push("rewrite");
equal(fails.length ? "differs at " + fails.join(",") : "ok", "ok");
