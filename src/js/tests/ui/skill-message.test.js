import { check, equal } from "yuke:test";
import { Transcript } from "yuke:transcript";

const body = "<skill_content name=\"pdf\">\n" + "Exact body </skill_content> & text.\n".repeat(40) + "</skill_content>\n\nreport.pdf";
const transcript = new Transcript({ textOf: () => body });
transcript.setOutline([{ id: 1, type: "user", skill_name: "pdf" }], null);
check("skill starts folded", transcript.rowCount(80) < 5);
equal(transcript.textOf(1), body);
transcript.togglePart(1, -1);
const expandedRows = transcript.rowCount(80);
check("skill expands", expandedRows > 40);
transcript.select({ id: 1, row: 1, col: 0 }, { id: 1, row: expandedRows - 2, col: 1000 });
equal(transcript.selectedSource(), body);
transcript.togglePart(1, -1);
check("skill folds again", transcript.rowCount(80) < 5);
const plain = new Transcript({ textOf: () => body });
plain.setOutline([{ id: 2, type: "user" }], null);
check("literal wrapper has no native skill identity", plain.rowCount(80) > 40);
