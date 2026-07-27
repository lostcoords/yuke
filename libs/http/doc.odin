/*
package http contains the sans-I/O HTTP/1.1 boundary shared by the yuke front door
and the WebSocket handshake. It parses complete request and response heads into
borrowed views, validates field syntax and origin-form request targets, and reports
duplicate fields without silently choosing one.

Request methods stay raw tokens (`Request_Head.method` is a `string`). The parser
only checks token syntax; application policy (for example GET-only) belongs to the
caller. A closed `Method` enum is deliberately not part of this package.

The `libs:http/server` subpackage is the deliberately small `core:nbio` driver. It
accepts one HTTP/1.1 request per connection (optional Content-Length body via
`receive_body`), then either writes one `Connection: close` response or hands the
socket to another protocol (`hijack`). Reading is bounded on both phases:
`request_timeout` is the head deadline and per-write timeout, `body_timeout` the
absolute ceiling on a whole body transfer.

Optional routing (`Router`, `router_on_request`) adds pre-handler middleware and a
small method+path table. Middleware always runs before match so applications can
authenticate before disclosing routes or methods. Path patterns are exact (`/ws`)
or a single star prefix capture (`/blob/<rest>` via a trailing star segment). A 405
carries `Allow` for the matched pattern. There is no post-handler middleware chain,
keep-alive, transfer codings, ranges, compression, proxy-form targets, or TLS.
*/
package http
