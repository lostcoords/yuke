package websocket

import "base:runtime"
import "core:unicode/utf8"

// Largest client frame header: 2 fixed bytes + 8 extended-length bytes + 4 mask bytes.
MAX_HEADER_BYTES :: 14

// Length of the client masking key applied to every outbound payload.
MASK_KEY_BYTES :: 4

// Value of `Header1.payload_len` selecting a following 16-bit big-endian length.
PAYLOAD_LEN_16 :: 126

// Value of `Header1.payload_len` selecting a following 64-bit big-endian length.
PAYLOAD_LEN_64 :: 127

// Which side of the connection a codec surface acts for. Masking is direction-
// strict (RFC 6455 §5.1): a client MUST mask every frame it writes, a server MUST
// NOT. This single distinction drives strictness in both directions — on the read
// side `Role` names which masking a decoder requires; on the write side the same
// rule is carried by whether a masking key is supplied (see `make_header`).
Role :: enum {
    // Reads server->client frames (rejects masked) and writes masked client frames.
    Client,

    // Reads client->server frames (rejects unmasked) and writes unmasked server frames.
    Server,
}

// First frame byte: FIN, three reserved bits, and the 4-bit opcode. Bit_field
// members are LSB-first, so `opcode` is the low nibble.
Header0 :: bit_field u8 {
    // Frame opcode (low 4 bits on the wire).
    opcode: u8   | 4,

    // Reserved; must be 0 unless a negotiated extension defines it.
    rsv3:   u8   | 1,

    // Reserved; must be 0 unless a negotiated extension defines it.
    rsv2:   u8   | 1,

    // Reserved; must be 0 unless a negotiated extension defines it.
    rsv1:   u8   | 1,

    // Final-fragment flag.
    fin:    bool | 1,
}


// Second frame byte: 7-bit payload-length code plus the mask bit. Which value is
// legal depends on direction (RFC 6455 §5.1): a client MUST set `mask`, a server
// MUST leave it clear. `parse_header` enforces the rule for its `Role`.
Header1 :: bit_field u8 {
    // 0-125 is the length; 126 selects a 16-bit and 127 a 64-bit extended length.
    payload_len: u8   | 7,

    // Mask bit. Required on client->server frames, forbidden on server->client.
    mask:        bool | 1,
}

// RFC 6455 opcodes. Control opcodes (close/ping/pong) carry bit 0x8;
// `op_code_is_control` folds that test so callers don't test it inline.
Op_Code :: enum u8 {
    // Continuation of a fragmented data message.
    Continuation     = 0x0,

    // Text data; payload must be valid UTF-8 (checked during reassembly).
    Text             = 0x1,

    // Binary data.
    Binary           = 0x2,

    // Close control frame.
    Connection_Close = 0x8,

    // Ping control frame.
    Ping             = 0x9,

    // Pong control frame.
    Pong             = 0xA,
}

// A decoded frame header. Payload is not included; the caller consumes `payload_length`
// bytes after the header from the same buffer.
Frame_Header :: struct {
    // Opcode of this frame.
    opcode:         Op_Code,

    // Payload length in bytes.
    payload_length: int,

    // Whether this is the final fragment of its message.
    fin:            bool,

    // True when the frame carried a masking key (only server-role reads). The
    // payload following the header is masked and must be unmasked with `mask_key`.
    masked:         bool,

    // Masking key copied out of the header when `masked`; unused otherwise. Fixed
    // array, so it is owned by the value and outlives the source buffer.
    mask_key:       [MASK_KEY_BYTES]byte,
}

// Whether `parse_header` decoded a header or needs more buffered bytes.
Header_Status :: enum {
    // A full header was decoded; `Frame_Header` and `header_length` are valid.
    Ready,

    // The buffer is shorter than the encoded header; feed more bytes and retry.
    Need_More,
}

// Protocol violations for the codec (header decode + message reassembly). Any
// non-`.None` value must fail the connection (RFC 6455 §5). `parse_header` returns
// the header subset; the decoder adds reassembly and policy-limit variants.
Protocol_Error :: enum {
    // No error.
    None,

    // Internal buffering or message materialization could not be allocated.
    Out_Of_Memory,

    // Opcode is not in the assigned set.
    Unrecognized_Opcode,

    // A reserved bit was set without a negotiated extension.
    Reserved_Bit_Set,

    // A client received a masked frame; a server never masks (RFC 6455 §5.1).
    Masked,

    // A server received an unmasked frame; a client MUST mask (RFC 6455 §5.1).
    Unmasked,

    // A control frame had FIN cleared (control frames may not fragment).
    Control_Frame_Fragmented,

    // A control frame used an extended length (control payloads are <= 125).
    Control_Frame_Too_Big,

    // Announced length does not fit in a host int.
    Frame_Length_Overflow,

    // Extended length used where a smaller form could encode the same value
    // (RFC 6455 §5.2 forbids non-minimal encoding).
    Non_Minimal_Length,

    // Close frame body was exactly one byte, too short for a status code.
    Bad_Close,

    // Close status code not valid on the wire (reserved, synthesized-only,
    // unassigned, or outside the private-use range).
    Invalid_Close_Code,

    // A single frame's payload exceeded the configured `max_frame_bytes`.
    Frame_Too_Big,

    // A reassembled message exceeded the configured `max_message_bytes`.
    Message_Too_Big,

    // A continuation frame arrived with no fragmented message open.
    Invalid_Continuation,

    // A new data frame arrived while a fragmented message was still open.
    Interrupted,

    // A text message's payload was not valid UTF-8.
    Invalid_Utf8,
}

// Map a 4-bit wire opcode to `Op_Code`; ok is false for an unassigned opcode.
op_code_from_u8 :: proc(v: u8) -> (Op_Code, bool) {
    switch v {
    case u8(Op_Code.Continuation):
        return .Continuation, true

    case u8(Op_Code.Text):
        return .Text, true

    case u8(Op_Code.Binary):
        return .Binary, true

    case u8(Op_Code.Connection_Close):
        return .Connection_Close, true

    case u8(Op_Code.Ping):
        return .Ping, true

    case u8(Op_Code.Pong):
        return .Pong, true
    }

    return .Continuation, false
}

// True for close/ping/pong — opcodes with bit 0x8 set.
op_code_is_control :: proc(op: Op_Code) -> bool {
    return (u8(op) & 0x8) != 0
}

// Decode a frame header from the front of `buf` without consuming payload. `role`
// selects the direction-strict masking rule (RFC 6455 §5.1): a `.Client` rejects a
// masked frame, a `.Server` rejects an unmasked one and copies the 4-byte masking
// key into the returned header. On `.Need_More`, retry from the same offset after
// more bytes arrive; a non-`.None` `err` must fail the connection (RFC 6455 §5).
parse_header :: proc(
    buf: []byte,
    role: Role,
) -> (
    header: Frame_Header,
    header_length: int,
    status: Header_Status,
    err: Protocol_Error,
) {
    if len(buf) < 2 {
        return {}, 0, .Need_More, .None
    }

    h0 := transmute(Header0)buf[0]
    h1 := transmute(Header1)buf[1]

    opcode, ok := op_code_from_u8(h0.opcode)
    if !ok {
        return {}, 0, .Ready, .Unrecognized_Opcode
    }

    if h0.rsv1 != 0 || h0.rsv2 != 0 || h0.rsv3 != 0 {
        return {}, 0, .Ready, .Reserved_Bit_Set
    }

    // Enforce direction-strict masking before reading anything further.
    switch role {
    case .Client:
        if h1.mask {
            return {}, 0, .Ready, .Masked
        }

    case .Server:
        if !h1.mask {
            return {}, 0, .Ready, .Unmasked
        }
    }

    // A masked frame carries a 4-byte key after any extended length bytes.
    mask_len := h1.mask ? MASK_KEY_BYTES : 0

    control := op_code_is_control(opcode)

    if !h0.fin && control {
        return {}, 0, .Ready, .Control_Frame_Fragmented
    }

    // Validate the length code before requiring the extended and mask bytes, so an
    // illegal control length fails fast. `extended_length_bytes` is its encoded width.
    payload_length: int
    extended_length_bytes := 0

    switch h1.payload_len {
    case PAYLOAD_LEN_16:
        if control {
            return {}, 0, .Ready, .Control_Frame_Too_Big
        }

        extended_length_bytes = 2
        if len(buf) < 2 + extended_length_bytes {
            return {}, 0, .Need_More, .None
        }

        payload_length = int(u16(buf[2]) << 8 | u16(buf[3]))
        if payload_length < PAYLOAD_LEN_16 {
            return {}, 0, .Ready, .Non_Minimal_Length
        }

    case PAYLOAD_LEN_64:
        if control {
            return {}, 0, .Ready, .Control_Frame_Too_Big
        }

        extended_length_bytes = 8
        if len(buf) < 2 + extended_length_bytes {
            return {}, 0, .Need_More, .None
        }

        v: u64
        for i in 0 ..< 8 {
            v = v << 8 | u64(buf[2 + i])
        }

        // Reject the high bit (RFC 6455 forbids it) and anything past int range.
        if v > u64(max(int)) {
            return {}, 0, .Ready, .Frame_Length_Overflow
        }

        payload_length = int(v)
        if payload_length < 1 << 16 {
            return {}, 0, .Ready, .Non_Minimal_Length
        }

    case:
        payload_length = int(h1.payload_len)
    }

    if opcode == .Connection_Close && payload_length == 1 {
        return {}, 0, .Ready, .Bad_Close
    }

    // The full header — fixed bytes, extended length, and any masking key — must be
    // buffered before the caller may consume `header_length` and the payload.
    header_length = 2 + extended_length_bytes + mask_len
    if len(buf) < header_length {
        return {}, 0, .Need_More, .None
    }

    header = Frame_Header {
        opcode         = opcode,
        payload_length = payload_length,
        fin            = h0.fin,
        masked         = h1.mask,
    }
    if h1.mask {
        copy(header.mask_key[:], buf[2 + extended_length_bytes:][:MASK_KEY_BYTES])
    }

    return header, header_length, .Ready, .None
}

// Write a frame header into `buf`, returning the used prefix. The masking key
// carries the direction: a client supplies one — the mask bit is set and the four
// key bytes are appended, pairing with `mask_payload` — while a server passes `nil`
// for an unmasked header with the mask bit clear and no key bytes.
make_header :: proc(
    buf: ^[MAX_HEADER_BYTES]byte,
    fin: bool,
    opcode: Op_Code,
    payload_length: int,
    mask_key: Maybe([MASK_KEY_BYTES]byte),
) -> []byte {
    key, masked := mask_key.?
    assert(payload_length >= 0, "frame payload length must be non-negative")
    assert(!op_code_is_control(opcode) || payload_length <= 125, "control frame payload exceeds 125 bytes")

    buf[0] = transmute(u8)Header0{fin = fin, opcode = u8(opcode)}

    n := 2

    switch {
    case payload_length > int(max(u16)):
        buf[1] = transmute(u8)Header1{mask = masked, payload_len = PAYLOAD_LEN_64}
        u := u64(payload_length)
        for i in 0 ..< 8 {
            buf[2 + i] = byte(u >> uint((7 - i) * 8))
        }

        n = 10

    case payload_length >= PAYLOAD_LEN_16:
        buf[1] = transmute(u8)Header1{mask = masked, payload_len = PAYLOAD_LEN_16}
        buf[2] = byte(u16(payload_length) >> 8)
        buf[3] = byte(payload_length)
        n = 4

    case:
        buf[1] = transmute(u8)Header1{mask = masked, payload_len = u8(payload_length)}
    }

    if masked {
        // `copy` memmoves the four mask bytes; `key` is already an addressable local.
        copy(buf[n:][:MASK_KEY_BYTES], key[:])
        n += MASK_KEY_BYTES
    }

    return buf[:n]
}

// XOR `src` into `dst` under `mask_key` (byte i keyed by `mask_key[i % 4]`).
// Lengths must match. Byte i depends only on `src[i]`, so `dst` may alias `src` for
// in-place unmasking, or be a separate buffer to leave a read-only payload untouched.
mask_payload :: proc(dst, src: []byte, mask_key: [MASK_KEY_BYTES]byte) {
    assert(len(dst) == len(src))

    for i in 0 ..< len(src) {
        dst[i] = src[i] ~ mask_key[i % MASK_KEY_BYTES]
    }
}

// Allocate and return one complete frame (header + payload). A client supplies a
// `mask_key` (masked payload, mask bit set); a server passes `nil` (payload copied
// verbatim, mask bit clear). Caller-owned; under nbio it must stay alive until the
// consuming send completes. Free with `delete(frame, allocator)`.
encode_frame :: proc(
    fin: bool,
    opcode: Op_Code,
    payload: []byte,
    mask_key: Maybe([MASK_KEY_BYTES]byte),
    allocator := context.allocator,
) -> (
    frame: []byte,
    err: runtime.Allocator_Error,
) #optional_allocator_error {
    header_buf: [MAX_HEADER_BYTES]byte
    header := make_header(&header_buf, fin, opcode, len(payload), mask_key)

    out := make([]byte, len(header) + len(payload), allocator) or_return
    copy(out, header)

    if key, masked := mask_key.?; masked {
        mask_payload(out[len(header):], payload, key)
    } else {
        copy(out[len(header):], payload)
    }

    return out, .None
}

// Close status codes (IANA subset plus the open range). Non-exhaustive: unlisted
// codes decode to their numeric value. Not every member is valid on the wire —
// see `close_code_valid_on_wire`.
Close_Code :: enum u16 {
    // 1000 — normal closure.
    Normal_Closure             = 1000,

    // 1001 — endpoint going away.
    Going_Away                 = 1001,

    // 1002 — protocol error.
    Protocol_Error             = 1002,

    // 1003 — unsupported data.
    Unsupported_Data           = 1003,

    // 1005 — no status received; synthesized for an empty close body. Invalid on
    // the wire.
    No_Status_Rcvd             = 1005,

    // 1006 — abnormal closure; synthesized for a connection loss with no close
    // frame. Invalid on the wire.
    Abnormal_Closure           = 1006,

    // 1007 — invalid frame payload data (e.g. bad UTF-8 in a text message).
    Invalid_Frame_Payload_Data = 1007,

    // 1008 — policy violation.
    Policy_Violation           = 1008,

    // 1009 — message too big.
    Message_Too_Big            = 1009,

    // 1010 — mandatory extension missing.
    Mandatory_Ext              = 1010,

    // 1011 — internal server error.
    Internal_Error             = 1011,
}

// Whether `code` may legally appear on the wire (RFC 6455 §7.4.1/§7.4.2):
// 1000-1003, 1007-1014, and 3000-4999 (private-use). Everything else is
// reserved, synthesized-only, or unassigned.
close_code_valid_on_wire :: proc(code: u16) -> bool {
    switch {
    case code >= 1000 && code <= 1003:
        return true

    case code >= 1007 && code <= 1014:
        return true

    case code >= 3000 && code <= 4999:
        return true
    }

    return false
}

// The decoded body of a close frame.
Parsed_Close :: struct {
    // Status code; defaults to `No_Status_Rcvd` when the body is empty.
    code:   Close_Code,

    // Optional reason text, borrowed from the source buffer; validated as UTF-8.
    reason: string,
}

// Decode and validate a close-frame body. A one-byte body is rejected earlier in
// `parse_header`, so `data` is empty or at least the 2-byte status code. Empty is
// legal and synthesizes `.No_Status_Rcvd` (1005) — invalid on the wire but the
// correct in-memory default. A non-empty body's code must pass
// `close_code_valid_on_wire` and any reason bytes must be valid UTF-8.
parse_close :: proc(data: []byte) -> (Parsed_Close, Protocol_Error) {
    if len(data) == 0 {
        return {code = .No_Status_Rcvd, reason = ""}, .None
    }

    code := u16(data[0]) << 8 | u16(data[1])
    if !close_code_valid_on_wire(code) {
        return {}, .Invalid_Close_Code
    }

    reason := string(data[2:])
    if !utf8.valid_string(reason) {
        return {}, .Invalid_Utf8
    }

    return {code = Close_Code(code), reason = reason}, .None
}
