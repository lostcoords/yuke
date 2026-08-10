package relay

import "core:testing"

import ws "libs:websocket"

@(test)
test_relay_url_parse :: proc(t: ^testing.T) {
    Case :: struct {
        url:    string,
        ok:     bool,
        scheme: ws.Scheme,
        host:   string,
        port:   int,
    }

    cases := []Case {
        {"ws://127.0.0.1:8787", true, .Ws, "127.0.0.1", 8787},
        {"wss://relay.yuke.sh", true, .Wss, "relay.yuke.sh", 443},
        {"ws://localhost", true, .Ws, "localhost", 80},
        {"wss://relay.yuke.sh:9443/link", true, .Wss, "relay.yuke.sh", 9443},
        {"ws://127.0.0.1:8787/anything?x=1", true, .Ws, "127.0.0.1", 8787},
        {"http://127.0.0.1", false, {}, "", 0},
        {"ws://", false, {}, "", 0},
        {"wss://host:0", false, {}, "", 0},
        {"wss://host:70000", false, {}, "", 0},
        {"ws://host:abc", false, {}, "", 0},
        {"", false, {}, "", 0},
    }

    for c in cases {
        ep, ok := endpoint_parse(c.url)
        testing.expectf(t, ok == c.ok, "%q: ok = %v, want %v", c.url, ok, c.ok)
        if !c.ok {
            continue
        }

        testing.expectf(t, ep.scheme == c.scheme, "%q: scheme = %v, want %v", c.url, ep.scheme, c.scheme)
        testing.expectf(t, ep.host == c.host, "%q: host = %q, want %q", c.url, ep.host, c.host)
        testing.expectf(t, ep.port == c.port, "%q: port = %d, want %d", c.url, ep.port, c.port)
    }
}

// The pump's policy: text is fatal, a SEALED needs a live peer, CONTROL routes by type,
// and every malformed envelope maps to `.Fail` with its distinct error.
@(test)
test_link_dispatch :: proc(t: ^testing.T) {
    binary :: ws.Message_Kind.Binary

    action: Link_Action
    payload: []u8
    reason: string
    err: Error

    // A text data frame is a protocol violation regardless of its bytes.
    action, payload, reason, err = link_dispatch(.Text, transmute([]u8)string("hello"), true, context.temp_allocator)
    testing.expect_value(t, action, Link_Action.Fail)
    testing.expect_value(t, err, Error.Text)

    // A SEALED before peer_attached is misordered and dropped, not delivered.
    action, payload, reason, err = link_dispatch(
        binary,
        []u8{u8(Frame_Type.Sealed), 0xaa},
        false,
        context.temp_allocator,
    )
    testing.expect_value(t, action, Link_Action.Drop)
    testing.expect_value(t, err, Error.None)

    // The same SEALED once attached is delivered, payload aliasing the source bytes.
    msg := []u8{u8(Frame_Type.Sealed), 0xaa, 0xbb}
    action, payload, reason, err = link_dispatch(binary, msg, true, context.temp_allocator)
    testing.expect_value(t, action, Link_Action.Sealed)
    testing.expect_value(t, err, Error.None)
    testing.expect(t, raw_data(payload) == raw_data(msg[1:]), "sealed payload must alias the message")

    // CONTROL peer_attached routes to `.Peer_Attached`.
    action, payload, reason, err = link_dispatch(
        binary,
        control_frame(`{"type":"peer_attached"}`),
        false,
        context.temp_allocator,
    )
    testing.expect_value(t, action, Link_Action.Peer_Attached)
    testing.expect_value(t, err, Error.None)

    // CONTROL peer_gone routes to `.Peer_Gone` and carries its reason.
    action, payload, reason, err = link_dispatch(
        binary,
        control_frame(`{"type":"peer_gone","reason":"replaced"}`),
        true,
        context.temp_allocator,
    )
    testing.expect_value(t, action, Link_Action.Peer_Gone)
    testing.expect_value(t, err, Error.None)
    testing.expect(t, reason == "replaced", "peer_gone must carry its reason")

    // An unknown CONTROL type and malformed CONTROL both fail with their distinct error.
    action, payload, reason, err = link_dispatch(
        binary,
        control_frame(`{"type":"nope"}`),
        true,
        context.temp_allocator,
    )
    testing.expect_value(t, action, Link_Action.Fail)
    testing.expect_value(t, err, Error.Control_Unknown)

    action, payload, reason, err = link_dispatch(binary, control_frame(`not json`), true, context.temp_allocator)
    testing.expect_value(t, action, Link_Action.Fail)
    testing.expect_value(t, err, Error.Control_Malformed)

    // Envelope-level malformations surface through `.Fail` with the decode error.
    Case :: struct {
        msg:  []u8,
        want: Error,
    }
    envelope_cases := []Case {
        {[]u8{}, .Empty},
        {[]u8{u8(Frame_Type.Sealed)}, .Empty_Payload},
        {[]u8{0x03, 0x00}, .Unknown_Type},
    }
    for c in envelope_cases {
        a, _, _, e := link_dispatch(binary, c.msg, true, context.temp_allocator)
        testing.expect_value(t, a, Link_Action.Fail)
        testing.expectf(t, e == c.want, "envelope %v: got %v, want %v", c.msg, e, c.want)
    }

    free_all(context.temp_allocator)
}

// Wrap a CONTROL JSON body in a CONTROL envelope frame for a dispatch test.
@(private = "file")
control_frame :: proc(body: string) -> []u8 {
    return frame_encode(Frame{type = .Control, payload = transmute([]u8)body}, context.temp_allocator)
}
