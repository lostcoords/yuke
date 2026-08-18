package daemon

import "core:testing"

@(test)
test_relay_cloud_url_normalization :: proc(t: ^testing.T) {
    Case :: struct {
        source: string,
        want:   string,
        valid:  bool,
    }
    cases := []Case {
        {"https://platform.yuke.sh", "https://platform.yuke.sh", true},
        {"https://platform.yuke.sh/base///", "https://platform.yuke.sh/base", true},
        {"https://[::1]:8443/control", "https://[::1]:8443/control", true},
        {"http://127.0.0.1:8080", "http://127.0.0.1:8080", true},
        {"http://127.9.8.7/dev", "http://127.9.8.7/dev", true},
        {"http://localhost:8080", "", false},
        {"http://192.0.2.1", "", false},
        {"https://user@example.com", "", false},
        {"https://example.com?target=x", "", false},
        {"https://example.com/#fragment", "", false},
        {"https://example.com:", "", false},
        {"https://example.com:0", "", false},
        {"https://example.com:65536", "", false},
        {"https://example.com/a/../b", "", false},
        {"ftp://example.com", "", false},
    }

    for tc in cases {
        normalized, err := relay_cloud_url_normalize(tc.source)
        defer delete(normalized)

        testing.expect_value(t, err == .None, tc.valid)
        if tc.valid do testing.expect_value(t, normalized, tc.want)
    }
}

// Two clients bridged on independent channels stay independent: a per-channel close frees only
// that channel's `Conn` and slot and never disturbs the other's conn or established state.
@(test)
test_relay_channels_are_independent :: proc(t: ^testing.T) {
    d: Daemon
    d.allocator = context.allocator
    d.conns = make(map[Conn_Ticket]^Conn, 8, context.allocator)
    defer delete(d.conns)

    r: Relay
    r.daemon = &d

    for ch in u8(0) ..< 2 {
        conn := conn_register(&d, Relay_Client{relay = &r, channel = ch})
        testing.expect(t, conn != nil, "bridging a channel registers a conn")
        r.peers[ch].active = true
        r.peers[ch].established = true
        r.peers[ch].conn = conn
    }

    kept := r.peers[1].conn

    relay_conn_close(&r, 0)

    testing.expect(t, !r.peers[0].active, "channel 0 is idle after teardown")
    testing.expect(t, r.peers[0].conn == nil, "channel 0 conn is freed")
    testing.expect(t, len(d.conns) == 1, "only channel 0's conn is unregistered")
    testing.expect(t, r.peers[1].active, "channel 1 stays active")
    testing.expect(t, r.peers[1].established, "channel 1 stays established")
    testing.expect(t, r.peers[1].conn == kept, "channel 1 conn is untouched")

    relay_conn_close(&r, 1)

    testing.expect(t, r.peers[1].conn == nil, "channel 1 conn is freed on its own teardown")
    testing.expect(t, len(d.conns) == 0, "no bridged conns remain")
}
