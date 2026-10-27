// The web classes `URL` and `URLSearchParams`. Many cases follow the web platform tests (WPT) of `url`.

import { assert, equal, test, throws } from "yuke:test";
import { thrownNames } from "./errors.ts";

test("a URL resolves against its base and gives each component", () => {
  const url = new URL("../c d?x=1#f", "HTTPS://user:pw@EXAMPLE.com:8080/a/b/");
  equal(
    {
      href: url.href,
      origin: url.origin,
      protocol: url.protocol,
      username: url.username,
      password: url.password,
      host: url.host,
      hostname: url.hostname,
      port: url.port,
      pathname: url.pathname,
      search: url.search,
      hash: url.hash,
    },
    {
      href: "https://user:pw@example.com:8080/a/c%20d?x=1#f",
      origin: "https://example.com:8080",
      protocol: "https:",
      username: "user",
      password: "pw",
      host: "example.com:8080",
      hostname: "example.com",
      port: "8080",
      pathname: "/a/c%20d",
      search: "?x=1",
      hash: "#f",
    },
  );
});

test("a host with unicode becomes punycode and an opaque origin is null", () => {
  equal(new URL("https://bücher.example/").hostname, "xn--bcher-kva.example");
  equal(new URL("https://faß.de/").hostname, "xn--fa-hia.de");
  equal(new URL("https://example.com:443/").port, "");
  equal(new URL("data:text/plain,x").origin, "null");
});

test("an invalid URL throws and parse gives null", () => {
  equal(thrownNames([() => new URL("no scheme"), () => new URL("/a", "no base"), () => new URL("https://a b/")]), [
    "TypeError",
    "TypeError",
    "TypeError",
  ]);
  const error = throws(() => new URL("/a", "no base"));
  assert(error instanceof Error);
  equal(error.message, "'/a' with the base 'no base' is not a valid URL");
  equal(URL.parse("no scheme"), null);
  equal(URL.parse("/a", "https://a.example/b")?.href, "https://a.example/a");
  assert(URL.parse("https://a.example/") instanceof URL);
  equal(URL.canParse("no scheme"), false);
  equal(URL.canParse("/a", "https://a.example/"), true);
});

test("a setter parses its component and a refused value keeps the URL", () => {
  const url = new URL("https://a.example/p");
  url.port = "8080";
  url.port = "x";
  url.protocol = "ftp";
  url.protocol = "mailto";
  url.username = "me";
  url.hostname = "b.example";
  url.pathname = "a b";
  url.search = "q=1";
  url.hash = "top";
  equal(url.href, "ftp://me@b.example:8080/a%20b?q=1#top");
  url.port = "";
  url.search = "";
  url.hash = "";
  equal(url.href, "ftp://me@b.example/a%20b");
});

test("an href that is not a URL throws and keeps the URL", () => {
  const url = new URL("https://a.example/");
  equal(
    thrownNames([
      () => {
        url.href = "no scheme";
      },
    ]),
    ["TypeError"],
  );
  equal(url.href, "https://a.example/");
  url.href = "http://b.example/x";
  equal(url.href, "http://b.example/x");
  equal(String(url), "http://b.example/x");
  equal(JSON.stringify({ url }), '{"url":"http://b.example/x"}');
});

test("the search params of a URL follow its query and set it", () => {
  const url = new URL("https://a.example/?a=1&b=2");
  const params = url.searchParams;
  assert(params === url.searchParams, "each read gives the same object");
  params.append("c", "x y");
  equal(url.search, "?a=1&b=2&c=x+y");
  url.search = "?z=9";
  equal([params.get("z"), params.has("a")], ["9", false]);
  params.delete("z");
  equal(url.href, "https://a.example/");
  url.href = "https://b.example/?q=1";
  equal([params.get("q"), params.size], ["1", 1]);
});

test("the search params of an opaque path drop its trailing spaces with the query", () => {
  const url = new URL("data:space    ?query");
  url.searchParams.delete("query");
  equal(url.href, "data:space");
});

test("search params take a query string, pairs, or a record", () => {
  equal(new URLSearchParams("?a=1&a=2").getAll("a"), ["1", "2"]);
  equal(new URLSearchParams("b=%20+x&%zz=%C3").get("b"), "  x");
  equal(new URLSearchParams("%zz=%C3").toString(), "%25zz=%EF%BF%BD");
  equal(new URLSearchParams([["a", "1"], new Set(["b", "2"])]).toString(), "a=1&b=2");
  // @ts-expect-error: a record value converts to a string.
  equal(new URLSearchParams({ x: "1", y: 2 }).toString(), "x=1&y=2");
  equal(new URLSearchParams(new URLSearchParams("k=v")).toString(), "k=v");
  // @ts-expect-error: `null` converts to the string `null`.
  equal(new URLSearchParams(null).toString(), "null=");
  equal(new URLSearchParams().size, 0);
  equal(new URLSearchParams({ b: "1", 2: "x", 1: "y" }).toString(), "1=y&2=x&b=1");
  // @ts-expect-error: a function with properties is a record too.
  equal(new URLSearchParams(Object.assign(() => {}, { f: "1" })).toString(), "f=1");
});

test("a pair without exactly two values or a symbol key throws a TypeError", () => {
  equal(
    thrownNames([
      () => new URLSearchParams([["a"]]),
      () => new URLSearchParams([["a", "b", "c"]]),
      // @ts-expect-error: a pair is iterable.
      () => new URLSearchParams([1]),
      // @ts-expect-error: a pair is iterable.
      () => new URLSearchParams([{ length: 2, 0: "a", 1: "b" }]),
      // @ts-expect-error: the iterator method is a function.
      () => new URLSearchParams({ [Symbol.iterator]: 1 }),
      () => new URLSearchParams({ [Symbol()]: "x" }),
    ]),
    new Array<string>(6).fill("TypeError"),
  );
});

test("search params encode as application/x-www-form-urlencoded", () => {
  equal(new URLSearchParams({ "a b": "é&=+*-._~?" }).toString(), "a+b=%C3%A9%26%3D%2B*-._%7E%3F");
});

test("set, delete, has, and sort keep the order of the other pairs", () => {
  const params = new URLSearchParams("b=1&a=2&b=3&c=4&a=5");
  params.set("b", "x");
  equal(params.toString(), "b=x&a=2&c=4&a=5");
  params.sort();
  equal(params.toString(), "a=2&a=5&b=x&c=4");
  params.delete("a", "5");
  equal(
    [params.toString(), params.has("a", "2"), params.has("a", "5"), params.has("c"), params.get("z")],
    ["a=2&b=x&c=4", true, false, true, null],
  );
  params.delete("a", undefined);
  equal(params.toString(), "b=x&c=4");
});

test("an iterator and forEach see a change of the pairs", () => {
  const params = new URLSearchParams("a=1&b=2");
  const keys = params.keys();
  const first = keys.next().value;
  params.append("c", "3");
  const rest = [...keys];
  const visited: [string, string, boolean, string][] = [];
  params.forEach(
    function (this: { mark: string }, value, name, parent) {
      visited.push([name, value, parent === params, this.mark]);
      if (name === "a") params.append("d", "4");
    },
    { mark: "!" },
  );
  equal(first, "a");
  equal(rest, ["b", "c"]);
  equal(visited, [
    ["a", "1", true, "!"],
    ["b", "2", true, "!"],
    ["c", "3", true, "!"],
    ["d", "4", true, "!"],
  ]);
  equal(
    [...params],
    [
      ["a", "1"],
      ["b", "2"],
      ["c", "3"],
      ["d", "4"],
    ],
  );
  equal([...params.values()], ["1", "2", "3", "4"]);
  assert(params[Symbol.iterator] === params.entries);
  equal(Object.prototype.toString.call(params.entries()), "[object URLSearchParams Iterator]");
  assert(params.entries() instanceof Iterator);
});

test("a method refuses a value of another class and a missing argument", () => {
  const href = Object.getOwnPropertyDescriptor(URL.prototype, "href")?.get;
  assert(href !== undefined, "href is an accessor");
  const params = new URLSearchParams();
  equal(
    thrownNames([
      () => href.call({}),
      () => URLSearchParams.prototype.get.call({}, "a"),
      () => params.entries().next.call({}),
      // @ts-expect-error: a URL takes a url.
      () => new URL(),
      // @ts-expect-error: an append takes a value.
      () => params.append("a"),
      // @ts-expect-error: a get takes a name.
      () => params.get(),
      // @ts-expect-error: a forEach takes a function.
      () => params.forEach(1),
      // @ts-expect-error: a URL needs `new`.
      () => URL("https://a.example/"),
    ]),
    new Array<string>(8).fill("TypeError"),
  );
});

test("the static methods are enumerable as Web IDL operations", () => {
  equal(Object.keys(URL), ["parse", "canParse"]);
});

test("each class names itself in its string form", () => {
  equal(
    [new URL("https://a.example/"), new URLSearchParams()].map((value) => Object.prototype.toString.call(value)),
    ["[object URL]", "[object URLSearchParams]"],
  );
});
