package websocket

import "core:log"
import "core:nbio"
import http "libs:http"
import http_server "libs:http/server"

// Bridging the `libs:http/server` front door to `server_adopt` is the one place this
// package depends on a specific HTTP driver; nothing else here does.

// What answering an upgrade decided. Every arm but `.Adopted` has already answered the
// request or closed the socket, so a caller only reads this to add its own context.
Accept_Result :: enum {
    // The socket belongs to the WebSocket server; `on_open` fires from the loop.
    Adopted,

    // Not a valid upgrade request; answered `400`.
    Not_An_Upgrade,

    // No room to adopt; answered `503`.
    At_Capacity,

    // A valid handshake that `server_adopt` refused; the hijacked socket was closed.
    Adopt_Failed,
}

// Answer an HTTP request that should be a WebSocket upgrade. Capacity is checked before
// the hijack, since a refusal can only go out while the connection can still answer, and
// the connection's pending response headers are forwarded onto the `101`.
accept_upgrade :: proc(
    s: ^Server,
    c: ^http_server.Conn,
    head: http.Request_Head,
    trailing: []byte = nil,
) -> Accept_Result {
    assert(s != nil && c != nil, "accept_upgrade needs a server and a connection")

    upgrade, result := parse_upgrade_request_head(head)
    if result != .Ok {
        log.debugf("websocket server: bad upgrade: %v", result)
        http_server.respond_text(c, .Bad_Request, "expected a websocket upgrade")

        return .Not_An_Upgrade
    }

    if !server_can_adopt(s) {
        log.warn("websocket server: at capacity")
        http_server.respond_text(c, .Service_Unavailable, "at capacity")

        return .At_Capacity
    }

    socket, loop, response_headers := http_server.hijack(c)
    if _, err := server_adopt(s, socket, upgrade.key, trailing, response_headers); err != .None {
        log.errorf("websocket server: adopt failed: %v", err)
        nbio.close(socket, l = loop)

        return .Adopt_Failed
    }

    return .Adopted
}
