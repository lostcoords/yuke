import { check, equal } from "yuke:test";
import { root } from "yuke:core";
import { client } from "yuke:client";
import { catalogOf, loadCatalog } from "yuke:catalog";

const catalog = catalogOf();
check("starts-idle", !catalog.loading && catalog.rev === null && catalog.models.length === 0);
client.catalogList = async () => ({ type: "full", catalog_rev: "r1", models: [{ selector: "model" }] });
equal(await loadCatalog(), catalog);
client.catalogList = () => Promise.reject(new Error("offline"));
root._needsDraw = false;
equal(await loadCatalog(), catalog);
check("refusal-repaints", !catalog.loading && root._needsDraw);
check("refusal-retains-models", catalog.rev === "r1" && catalog.models[0].selector === "model");
