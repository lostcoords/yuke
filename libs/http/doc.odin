/*
package http contains the sans-I/O HTTP/1.1 boundary: a head parser and
validator. It parses complete request and response heads into borrowed views,
validates field syntax and origin-form request targets, and reports duplicate
fields without silently choosing one.

Request methods stay raw tokens (`Request_Head.method` is a `string`). The parser
only checks token syntax; application policy (for example GET-only) belongs to the
caller. A closed `Method` enum is deliberately not part of this package.

The `libs:http/server` subpackage is the deliberately small `core:nbio` driver. It
accepts one HTTP/1.1 request per connection (optional Content-Length body via
`receive_body`), then either writes one `Connection: close` response or hands the
socket to another protocol (`hijack`). Reading is bounded on every axis:
`max_head_bytes` and `max_body_bytes` cap the head and the declared body,
`request_timeout` is the head deadline and per-write timeout, and `body_timeout` is
the absolute ceiling on a whole body transfer. A body over its cap is refused with
413 on the declared length, before any of it is read.

`request_is_local` is the admission predicate for a server meant to be reached only
from the machine it runs on: it refuses a request carrying `Origin`, and one whose
`Host` names the server rather than addressing it by IP literal or `localhost`.

Optional routing (`Router(T)`, bound with `router_listen`) adds pre-handler middleware
and a small method+path table, both parameterized on the application type so every
callback receives it typed as `Context(T).user_data`. Middleware always runs before
match so applications can
authenticate before disclosing routes or methods. Path patterns are exact (`/ws`)
or a single star prefix capture (`/blob/<rest>` via a trailing star segment). A 405
carries `Allow` for the matched pattern. There is no post-handler middleware chain,
keep-alive, transfer codings, ranges, compression, proxy-form targets, or TLS.

The `libs:http/sse` subpackage is a sans-I/O `text/event-stream` parser.
*/
package http
