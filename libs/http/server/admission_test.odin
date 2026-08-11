package http_server

import "core:net"
import "core:testing"

// The bind-address arm cannot be reached by binding a non-loopback address portably, so
// it is checked directly.
@(test)
test_http_admits_its_own_bind_address :: proc(t: ^testing.T) {
    bound := net.IP4_Address{192, 168, 1, 50}

    testing.expect(t, address_is_local(bound, net.IP4_Address{192, 168, 1, 50}), "its own bind address")
    testing.expect(t, address_is_local(bound, net.IP4_Loopback), "loopback regardless of bind")
    testing.expect(t, !address_is_local(bound, net.IP4_Address{192, 168, 1, 51}), "a neighbour")
    testing.expect(t, !address_is_local(bound, net.IP4_Any), "the unspecified address")

    testing.expect(t, !address_is_local(net.IP4_Any, net.IP4_Any), "a wildcard bind admits no wildcard Host")
    testing.expect(t, address_is_local(net.IP4_Any, net.IP4_Loopback), "a wildcard bind still admits loopback")
}

@(test)
test_loopback_address_admission :: proc(t: ^testing.T) {
    testing.expect(t, address_is_loopback(net.IP4_Address{127, 4, 3, 2}), "all IPv4 loopback is local")
    testing.expect(t, address_is_loopback(net.IP6_Loopback), "IPv6 loopback is local")
    testing.expect(t, !address_is_loopback(net.IP4_Address{192, 168, 1, 1}), "LAN peers are not loopback")
}

// `localhost` is exempt as a bare name only, and a `:port` never reaches the literal.
@(test)
test_http_host_literal_admission :: proc(t: ^testing.T) {
    bound := net.IP4_Loopback

    testing.expect(t, host_is_literal(bound, "localhost"), "the one exempt name")
    testing.expect(t, host_is_literal(bound, "LocalHost:8080"), "case-insensitive, port stripped")
    testing.expect(t, host_is_literal(bound, "127.0.0.1:80"), "a literal with a port")
    testing.expect(t, host_is_literal(bound, "[::1]"), "a bracketed IPv6 loopback")
    testing.expect(t, host_is_literal(bound, "[::ffff:127.0.0.1]:80"), "mapped loopback by another spelling")

    testing.expect(t, !host_is_literal(bound, "[localhost]"), "brackets enclose a literal only")
    testing.expect(t, !host_is_literal(bound, "rebind.example"), "a name that could resolve anywhere")
    testing.expect(t, !host_is_literal(bound, ""), "an empty Host")
    testing.expect(t, !host_is_literal(bound, "]:80"), "the shape that panics net.split_port")
}
