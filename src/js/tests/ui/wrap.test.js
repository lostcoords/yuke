import { wrapText, caretRowCol } from "yuke:internal/text-input";
const join = (s, rows) => rows.map((r) => s.slice(r.start, r.end)).join("|");
// A row plus its break covers the whole string, so no byte is lost.
const covers = (s, rows) => {
  let out = "";
  for (let i = 0; i < rows.length; i++) {
    out += s.slice(rows[i].start, rows[i].end);
    if (i + 1 < rows.length && !rows[i].soft) out += "\n";
  }
  return out === s;
};
const indent = "  keep   spaces";
const para = "hello world";
const rows = wrapText(para, 5);
globalThis.result = (
  join(para, rows) === "hello |world" &&
  rows[0].soft === true &&
  covers(para, rows) &&
  covers(indent, wrapText(indent, 7)) &&
  join(indent, wrapText(indent, 7)) === "  keep   |spaces" &&
  join("abcdefghij", wrapText("abcdefghij", 4)) === "abcd|efgh|ij" &&
  join("a\nb", wrapText("a\nb", 9)) === "a|b" &&
  wrapText("a\nb", 9)[0].soft === false &&
  covers("a\nb", wrapText("a\nb", 9)) &&
  join("", wrapText("", 5)) === "" &&
  covers("one\n\ntwo words", wrapText("one\n\ntwo words", 4)) &&
  caretRowCol(para, rows, 0).row === 0 &&
  caretRowCol(para, rows, 3).col === 3 &&
  caretRowCol(para, rows, 6).row === 1 &&
  caretRowCol(para, rows, 6).col === 0 &&
  caretRowCol(para, rows, 11).row === 1 &&
  caretRowCol(para, rows, 11).col === 5
) ? 1 : 0;
