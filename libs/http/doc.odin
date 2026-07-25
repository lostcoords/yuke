/*
package http contains the sans-I/O HTTP/1.1 boundary shared by the yuke front door
and the WebSocket handshake. It parses complete request and response heads into
borrowed views, validates field syntax and origin-form request targets, and reports
duplicate fields without silently choosing one.

Request methods stay raw tokens (`Request_Head.method` is a `string`). The parser
only checks token syntax; application policy (for example GET-only) belongs to the
caller. A closed `Method` enum is deliberately not part of this package.

The `libs:http/server` subpackage is the deliberately small `core:nbio` driver. It
accepts one bodyless HTTP/1.1 request per connection, then either writes one
`Connection: close` response or hands the socket to another protocol.

Deliberately absent: keep-alive, HTTP request bodies, transfer codings, ranges,
compression, proxy-form targets, TLS, and a generic middleware stack.
*/
package http
