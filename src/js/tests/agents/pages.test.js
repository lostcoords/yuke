import { check } from "yuke:test";
import { client, allChildren } from "yuke:client";

const original = client.sessionList;
try {
  const calls = [];
  const first = { session: { id: "first" } };
  const second = { session: { id: "second" } };
  client.sessionList = async (params) => {
    calls.push(params);
    return params.cursor ? { items: [second], next_cursor: null } : { items: [first], next_cursor: "next" };
  };
  const items = await allChildren("parent");
  check("children-pages-order", items[0] === first && items[1] === second && items.length === 2);
  check("children-pages-query", calls.length === 2 && calls.every((p) => p.limit === 100 && p.population.type === "children" && p.population.parent_id === "parent"));
  check("children-pages-cursor", calls[0].cursor === undefined && calls[1].cursor === "next");

  client.sessionList = async () => ({ items: [], next_cursor: null });
  check("children-pages-empty", (await allChildren("parent")).length === 0);

  let reads = 0;
  client.sessionList = async () => ({ items: [first], next_cursor: String(++reads) });
  let failure;
  try { await allChildren("parent"); } catch (error) { failure = error; }
  check("children-pages-bound", reads === 32 && failure?.message === "The child list exceeds 32 pages.");

  reads = 0;
  client.sessionList = async () => { reads++; return { items: [first], next_cursor: "same" }; };
  failure = undefined;
  try { await allChildren("parent"); } catch (error) { failure = error; }
  check("children-pages-cycle", reads === 2 && failure?.message === "The child page cursor did not advance.");

  const refused = new Error("unavailable");
  client.sessionList = async () => { throw refused; };
  failure = undefined;
  try { await allChildren("parent"); } catch (error) { failure = error; }
  check("children-pages-refusal", failure === refused);
} finally {
  client.sessionList = original;
}
