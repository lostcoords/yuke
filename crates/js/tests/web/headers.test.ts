// The web class `Headers`. Many cases follow the web platform tests (WPT) of `fetch/api/headers`.

import { assert, equal, test } from "yuke:test";
import { thrownNames } from "./errors.ts";

test("a name ignores case and get joins the values", () => {
  const headers = new Headers({ "Content-Type": "text/plain" });
  headers.append("X-A", "1");
  headers.append("x-a", "2");
  equal([headers.get("x-a"), headers.has("CONTENT-TYPE"), headers.get("missing")], ["1, 2", true, null]);
  headers.delete("X-a");
  equal(headers.has("x-a"), false);
});

test("iteration gives sorted lower case names and keeps each set-cookie", () => {
  const headers = new Headers([
    ["B", "1"],
    ["Set-Cookie", "x=1"],
    ["a", "2"],
    ["b", "3"],
    ["set-cookie", "y=2"],
  ]);
  const visited: [string, string, boolean][] = [];
  headers.forEach((value, name, parent) => {
    visited.push([name, value, parent === headers]);
  });
  const keys = headers.keys();
  const first = keys.next().value;
  headers.append("c", "4");
  equal(
    [...headers],
    [
      ["a", "2"],
      ["b", "1, 3"],
      ["c", "4"],
      ["set-cookie", "x=1"],
      ["set-cookie", "y=2"],
    ],
  );
  equal(visited, [
    ["a", "2", true],
    ["b", "1, 3", true],
    ["set-cookie", "x=1", true],
    ["set-cookie", "y=2", true],
  ]);
  equal(headers.getSetCookie(), ["x=1", "y=2"]);
  equal(headers.get("set-cookie"), "x=1, y=2");
  equal([first, ...keys], ["a", "b", "c", "set-cookie", "set-cookie"]);
  equal(Object.prototype.toString.call(keys), "[object Headers Iterator]");
  assert(keys instanceof Iterator);
});

test("set replaces the first value and removes the others", () => {
  const headers = new Headers([
    ["A", "1"],
    ["b", "2"],
    ["a", "3"],
  ]);
  headers.set("a", "x");
  headers.set("c", "y");
  const copy = new Headers(headers);
  copy.append("d", "5");
  equal(
    [...headers],
    [
      ["a", "x"],
      ["b", "2"],
      ["c", "y"],
    ],
  );
  equal(headers.has("d"), false);
  equal([...copy.keys()], ["a", "b", "c", "d"]);
});

test("a value loses its outer whitespace and an invalid name or value throws", () => {
  const headers = new Headers([["a", " \t v w \r\n"]]);
  equal(headers.get("a"), "v w");
  equal(headers.get("a"), new Headers({ a: "v w" }).get("a"));
  equal(
    thrownNames([
      () => headers.append("bad name", "x"),
      () => headers.append("a", "x\ny"),
      () => headers.append("a", "x\0y"),
      () => headers.append("a", "€"),
      () => headers.get("bad name"),
      () => headers.has(""),
      () => new Headers([["a"]]),
      () => new Headers("a: b"),
      () => new Headers({ [Symbol()]: "x" }),
      // @ts-expect-error: an append takes a value.
      () => headers.append("a"),
    ]),
    new Array<string>(10).fill("TypeError"),
  );
  equal(new Headers({ a: "é" }).get("a"), "é");
});

test("immutable headers refuse each change", () => {
  const headers = Response.redirect("https://a.example/x").headers;
  equal(thrownNames([() => headers.append("a", "1"), () => headers.set("a", "1"), () => headers.delete("location")]), [
    "TypeError",
    "TypeError",
    "TypeError",
  ]);
  equal(headers.get("location"), "https://a.example/x");
});

test("a method refuses a value of another class", () => {
  equal(
    thrownNames([
      () => Headers.prototype.get.call({}, "a"),
      () => Headers.prototype.entries.call({}),
      () => new Headers().keys().next.call({}),
      () => Headers.prototype.forEach.call({}, () => {}),
    ]),
    ["TypeError", "TypeError", "TypeError", "TypeError"],
  );
  equal(Object.prototype.toString.call(new Headers()), "[object Headers]");
  assert(Headers.prototype[Symbol.iterator] === Headers.prototype.entries);
});
