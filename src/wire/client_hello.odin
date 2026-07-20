package wire

import "core:strings"

// Client `client.hello` opening frame.
//
// The first frame sent on the wire after the WebSocket upgrade. Includes the
// connection-level identity and the protocol version this client speaks.

// Connection-level client identity carried inside `client.hello`.
Client :: struct {
    // Client connection name (e.g. `"yuke-tui"`). @bounded 64
    name:    string,

    // Client build/version string. @bounded 32
    version: string,
}

// Verify annotated field bounds.
client_validate :: proc(self: Client) -> Validation_Error {
    enforce_bounded(64, self.name) or_return

    return enforce_bounded(32, self.version)
}

// Decode the client identity object straight from the token stream.
client_from_reader :: proc(d: ^Decoder) -> (out: Client, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Name,
        Version,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "name":
            out.name = dec_string(d) or_return
            seen += {.Name}

        case "version":
            out.version = dec_string(d) or_return
            seen += {.Version}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Name, .Version} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Write the client identity object.
client_emit :: proc(e: ^Emitter, self: Client) {
    object_begin(e)
    field_string(e, "name", self.name)
    field_string(e, "version", self.version)
    object_end(e)
}

// Deep-copy into `allocator`.
client_clone :: proc(self: Client, allocator := context.allocator) -> Client {
    return Client{name = strings.clone(self.name, allocator), version = strings.clone(self.version, allocator)}
}

// First client frame. Discriminator `type` must be `"client.hello"`.
// Non-owning.
Client_Hello :: struct {
    // Discriminator; must be `"client.hello"`.
    type:     string,

    // Protocol version this client speaks. Must equal `PROTOCOL_VERSION`.
    protocol: u32,

    // Connection-level client identity.
    client:   Client,
}

// Build a client hello with the fixed discriminator and current protocol version.
client_hello_build :: proc(client: Client) -> Client_Hello {
    return Client_Hello{type = "client.hello", protocol = PROTOCOL_VERSION, client = client}
}

// Verify discriminator, protocol, and annotated field bounds.
client_hello_validate :: proc(self: Client_Hello) -> Validation_Error {
    if self.type != "client.hello" {
        return .Bad_Frame_Type
    }

    if self.protocol != PROTOCOL_VERSION {
        return .Unsupported_Protocol
    }

    return client_validate(self.client)
}

// Decode straight from the token stream. `type` and `protocol` default when absent.
client_hello_from_reader :: proc(d: ^Decoder) -> (out: Client_Hello, err: Validation_Error) {
    out.type = "client.hello"
    out.protocol = PROTOCOL_VERSION

    Field :: enum {
        Client,
    }

    seen: bit_set[Field]
    dec_object_begin(d) or_return
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "type":
            out.type = dec_string(d) or_return

        case "protocol":
            out.protocol = u32(dec_u64(d) or_return)

        case "client":
            out.client = client_from_reader(d) or_return
            seen += {.Client}

        case:
            dec_skip(d) or_return
        }
    }

    if .Client not_in seen {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Write `type` first, then `protocol`, then the client object.
client_hello_emit :: proc(e: ^Emitter, self: Client_Hello) {
    object_begin(e)
    field_string(e, "type", self.type)
    field_u64(e, "protocol", u64(self.protocol))
    key(e, "client")
    client_emit(e, self.client)
    object_end(e)
}
