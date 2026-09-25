import { check, equal } from "yuke:test";
import { root } from "yuke:core";
import { client } from "yuke:client";
import { catalogOf, loadCatalog } from "yuke:catalog";

const sent = [];
const c = catalogOf();
check("starts-idle", !c.loading && c.rev === null && c.models.length === 0);

client.catalogList = (sinceRev) => {
  sent.push(sinceRev);
  return Promise.resolve({ type: "full", catalog_rev: "r1", models: [{ selector: "m1", name: "m1" }] });
};
equal(await loadCatalog(), c);
check("full-stores-models", c.models.length === 1 && c.models[0].selector === "m1");
check("full-stores-rev", c.rev === "r1");
check("load-clears-loading", c.loading === false);

// The second load sends the stored revision, and an unchanged reply keeps what the catalog holds.
client.catalogList = (sinceRev) => { sent.push(sinceRev); return Promise.resolve({ type: "unchanged" }); };
await loadCatalog();
check("unchanged-keeps-models", c.models.length === 1 && c.rev === "r1");
check("sends-since-rev", sent.length === 2 && sent[0] === null && sent[1] === "r1");

// A rejected list leaves the catalog as it was, clears the flag, and still repaints.
client.catalogList = () => Promise.reject(new Error("offline"));
root.needsDraw = false;
equal(await loadCatalog(), c);
check("refusal-keeps-models", c.models.length === 1 && c.rev === "r1" && c.loading === false);
check("refusal-repaints", root.needsDraw);
