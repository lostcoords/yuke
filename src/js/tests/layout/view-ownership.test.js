import { equal } from "yuke:test";
import { claimView, releaseView, root, Node } from "yuke:core";
import { Window } from "yuke:ui";
const view = { layout() {}, draw() {} };
const first = {}, second = {};
claimView(view, first);
claimView(view, first);
let rejected = false;
try { claimView(view, second); } catch (_) { rejected = true; }
releaseView(view, first);
claimView(view, second);
releaseView(view, second);
const leaf = Node.leaf(view);
let duplicate = false;
try { root.setRoot(Node.branch("row", leaf, leaf, 0.5)); } catch (_) { duplicate = true; }
const invalid = new Window({ width: () => NaN });
let dimension = false;
try { invalid.layout({ x: 0, y: 0, w: 10, h: 10 }); } catch (_) { dimension = true; }
equal(rejected && duplicate && dimension && root.root_node === null ? "ok" : "bad", "ok");
