import { check } from "yuke:test";
import { Transcript } from "yuke:transcript";
const rowText = (row) => (row.segments || []).map((segment) => segment.text).join("");
const parts = [
  { type: "text", id: 1, text: "head" },
  { type: "text", id: 2, text: "tail suffix" },
];
const t = new Transcript({
  partsOf: () => parts,
  partOf: (_id, partId) => parts.find((part) => part.id === partId) || null,
});
t.setOutline([], { id: "m", type: "assistant" });
const allRows = () => t.rows(80, 0, t.rowCount(80));
const beforeRows = allRows();
const beforeSource = t._sourceOf("m");
const beforeBlocks = t.blocksOf("m");
const suffixRow = beforeRows.findIndex((row) => rowText(row).includes("tail suffix"));
const suffixOffset = beforeSource.indexOf("tail suffix");
const suffixPos = t.posAtSource("m", suffixOffset);
const suffixEnd = t.posAtSource("m", beforeSource.length);
check("suffix-position", suffixPos != null && suffixEnd != null);
t.select(suffixPos, suffixEnd);
const selectedText = t.selectedText();
const selectedSource = t.selectedSource();
const state = t._parts.get("m");
const suffixCache = state.rows.get("2");
const suffixCachedRow = suffixCache.rows[0];
const beforePublic = t.sourceAt({ id: "m", row: suffixRow, col: 0 });
parts[0].text = "head expanded";
t.setActive("m", 1);
const unchangedCache = state.rows.get("2") === suffixCache && state.rows.get("2").rows[0] === suffixCachedRow;
const afterRows = allRows();
const afterSource = t._sourceOf("m");
const afterSuffixRow = afterRows.findIndex((row) => rowText(row).includes("tail suffix"));
const afterPublic = t.sourceAt({ id: "m", row: afterSuffixRow, col: 0 });
const delta = "head expanded".length - "head".length;
check("suffix-cache-identity", unchangedCache);
check("suffix-text", rowText(afterRows[afterSuffixRow]) === "tail suffix");
check("suffix-source-shift", afterPublic === beforePublic + delta);
check("suffix-selection-text", t.selectedText() === selectedText);
check("suffix-selection-source", t.selectedSource() === selectedSource);
check("source-shift", afterSource === "head expanded\ntail suffix");
const afterBlocks = t.blocksOf("m");
check("block-count", beforeBlocks.length === 2 && afterBlocks.length === 2);
check("block-source-shift", afterBlocks[0].at === 0 && afterBlocks[0].end === 13 && afterBlocks[1].at === beforeBlocks[1].at + delta && afterBlocks[1].end === afterSource.length);

const replacementParts = [{ type: "text", id: 1, text: "stable prefix" }, { type: "text", id: 2, text: "replace me" }];
const replacement = new Transcript({
  partsOf: () => replacementParts,
  partOf: (_id, partId) => replacementParts.find((part) => part.id === partId) || null,
});
replacement.setOutline([], { id: "replacement", type: "assistant" });
replacement.rows(80, 0, replacement.rowCount(80));
const replacementSource = replacement._sourceOf("replacement");
const replacementStart = replacementSource.indexOf("replace");
replacement.select(replacement.posAtSource("replacement", replacementStart), replacement.posAtSource("replacement", replacementSource.length));
replacementParts[1].text = "x";
replacement.setActive("replacement", 2);
check("replacement-clears-selection", replacement.selection === null && replacement.selectedSource() === "");

const resize = new Transcript({ partsOf: () => [{ type: "text", id: 1, text: "resize keeps this source" }] });
resize.setOutline([], { id: "resize", type: "assistant" });
resize.rows(12, 0, resize.rowCount(12));
const resizeSource = resize._sourceOf("resize");
resize.select(resize.posAtSource("resize", 0), resize.posAtSource("resize", resizeSource.length));
resize.rows(40, 0, resize.rowCount(40));
check("resize-selection", resize.selectedSource() === resizeSource);

const evictionParts = {};
const evictionMessages = [];
for (let i = 0; i < 18; i++) {
  const id = "evict-" + i;
  evictionParts[id] = [{ type: "text", id: 1, text: id + " source" }];
  evictionMessages.push({ id, type: "assistant" });
}
const eviction = new Transcript({ partsOf: (id) => evictionParts[id] || [] });
eviction.setOutline(evictionMessages, null);
eviction.rows(30, 0, eviction.rowCount(30));
const evictionSource = eviction._sourceOf("evict-0");
eviction.select(eviction.posAtSource("evict-0", 0), eviction.posAtSource("evict-0", evictionSource.length));
eviction.rows(30, 0, eviction.rowCount(30));
check("eviction-selection", eviction.selectedSource() === evictionSource);
