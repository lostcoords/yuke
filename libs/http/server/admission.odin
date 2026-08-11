package http_server

import "core:net"
import "core:strings"
import http "libs:http"

// Refuse traffic a browser can be made to send. `Origin` marks a page-driven request,
// which CORS does not block for the WebSocket handshake; a named `Host` is the
// DNS-rebinding shape, which needs a name resolving at this server.
request_is_local :: proc(c: ^Conn, head: http.Request_Head) -> bool {
    assert(c != nil && c.server != nil, "admission needs an owned connection")
    assert(head.consumed == len(head.bytes), "admission received an inconsistent parsed head")

    if _, lookup := http.request_header(head, "origin"); lookup != .Missing {
        return false
    }

    host, host_lookup := http.request_header(head, "host")
    assert(host_lookup == .One, "head parser admitted a request without exactly one Host")

    return host_is_literal(c.server.bind_address, host)
}

// Whether a `Host` addresses `bind_address` by IP literal rather than naming it.
// `localhost` is the one name a browser cannot be made to resolve elsewhere.
host_is_literal :: proc(bind_address: net.IP4_Address, host: string) -> bool {
    name, bracketed := http.split_host(host) or_return

    // Brackets enclose an IP-literal only, so `[localhost]` gets no name exemption.
    if !bracketed && strings.equal_fold(name, "localhost") {
        return true
    }

    addr := net.parse_address(name)
    if addr == nil {
        return false
    }

    return address_is_local(bind_address, addr)
}

// Whether `addr` is a way a server bound to `bind_address` can legitimately be reached:
// loopback, or the address it bound. The unspecified address is a bind wildcard, never a
// destination — and `0.0.0.0` reaches a loopback-bound socket while escaping the browser
// local-network gating that `127.0.0.1` receives.
address_is_local :: proc(bind_address: net.IP4_Address, addr: net.Address) -> bool {
    assert(addr != nil, "address admission needs an address")

    switch a in addr {
    case net.IP4_Address:
        if a == net.IP4_Any {
            return false
        }
        return a[0] == 127 || a == bind_address

    case net.IP6_Address:
        if a == net.IP6_Any {
            return false
        }
        // The listen socket is IPv4 only, so loopback is the whole legitimate IPv6 set.
        return a == net.IP6_Loopback || ip6_maps_loopback(a)
    }

    return false
}

// Whether an accepted peer address is loopback, including IPv4-mapped IPv6 loopback.
address_is_loopback :: proc(addr: net.Address) -> bool {
    return address_is_local(net.IP4_Loopback, addr)
}

// Whether `a` is an IPv4-mapped loopback literal (`::ffff:127.0.0.1`), which addresses
// loopback by another spelling.
@(private)
ip6_maps_loopback :: proc(a: net.IP6_Address) -> bool {
    for i in 0 ..< 5 {
        if a[i] != 0 {
            return false
        }
    }
    return a[5] == 0xffff && u16(a[6]) >> 8 == 127
}
