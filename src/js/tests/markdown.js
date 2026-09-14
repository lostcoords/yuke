import { Document } from "yuke:md";

/** @param {string} text @param {number} width */
export function renderRows(text, width) {
  const doc = new Document();
  doc.setText(text);
  return doc.rows(width);
}
