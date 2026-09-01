//! Vendored from wssup (Unlicense, public domain): https://codeberg.org/hemisputnik/wssup
//! Client-role WebSocket framing over std.Io. yuke adds the server role. See docs/plan.md.
//!
//! **wssup** - simple WebSocket client library. <https://www.rfc-editor.org/info/rfc6455>
//!
//! This library provides both masking and zero-masking (`*ZeroMask`) functions.
//!
//! For masking functions, it is recommended to use CSPRNGs, such as `std.Random.ChaCha`.
//!
//! Zero-masking functions are generally more performant, as they avoid extra computation and use writers more efficiently,
//! but they should not always be used.
//!
//! Before using zero-masking functions, it is recommended to understand the implications of doing so,
//! and how that may affect intermediaries such as HTTP proxies.
//!
//! Further reading: <https://www.rfc-editor.org/info/rfc6455/#section-10.3>

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;

/// The server role: unmask on read, send unmasked frames.
pub const server = @import("server.zig");

pub const sec_websocket_key_len = 16;
pub const sec_websocket_key_encoded_len = std.base64.standard.Encoder.calcSize(sec_websocket_key_len);
pub const sec_websocket_accept_len = std.crypto.hash.Sha1.digest_length;
pub const sec_websocket_accept_encoded_len = std.base64.standard.Encoder.calcSize(sec_websocket_accept_len);

pub const HandshakeOptions = struct {
    extra_headers: []const u8 = "",
};

pub const Handshake = struct {
    result: Result,
    /// The pointers in this structure belong to the reader.
    /// Any further reading invalidates the data.
    head: http.Client.Response.Head,

    pub const Result = enum {
        ok,
        fail_not_switching_protocols,
        fail_bad_headers,
        fail_missing_headers,
    };
};

pub const HandshakeError = Io.Writer.Error || ParseHandshakeResponseError;

/// Simple function to perform a WebSocket handshake.
/// If this function does not return an error and the `result` of the returned handshake is `.success`,
/// the reader and writer may be used for WebSocket communication.
pub fn handshake(
    /// Buffer length of 8192 is recommended.
    reader: *Io.Reader,
    writer: *Io.Writer,
    /// Random bytes needed for the WebSocket handshake.
    random: *const [sec_websocket_key_len]u8,
    /// MUST be percent-encoded beforehand.
    path: []const u8,
    options: HandshakeOptions,
) HandshakeError!Handshake {
    var sec_websocket_key_encoded: [sec_websocket_key_encoded_len]u8 = undefined;
    var sec_websocket_accept_encoded: [sec_websocket_accept_encoded_len]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&sec_websocket_key_encoded, random);
    makeSecWebSocketAccept(&sec_websocket_key_encoded, &sec_websocket_accept_encoded);

    try writer.print(
        "GET {[path]s} HTTP/1.1\r\n" ++
            "upgrade: websocket\r\n" ++
            "connection: Upgrade\r\n" ++
            "sec-websocket-version: 13\r\n" ++
            "sec-websocket-key: {[sec_websocket_key]s}\r\n" ++
            "{[extra_headers]s}\r\n",
        .{
            .path = path,
            .sec_websocket_key = &sec_websocket_key_encoded,
            .extra_headers = options.extra_headers,
        },
    );
    try writer.flush();

    return try parseHandshakeResponse(reader, &sec_websocket_accept_encoded);
}

/// Converts the value of a Sec-WebSocket-Key header to the value of the Sec-WebSocket-Accept header.
pub fn makeSecWebSocketAccept(
    /// Must be base64-encoded beforehand.
    sec_websocket_key_encoded: *const [sec_websocket_key_encoded_len]u8,
    /// Output is base64-encoded.
    sec_websocket_accept_encoded: *[sec_websocket_accept_encoded_len]u8,
) void {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(sec_websocket_key_encoded);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");

    var sec_websocket_accept: [sec_websocket_accept_len]u8 = undefined;
    sha1.final(&sec_websocket_accept);

    _ = std.base64.standard.Encoder.encode(sec_websocket_accept_encoded, &sec_websocket_accept);
}

test makeSecWebSocketAccept {
    // Example taken from section 1.3 of RFC 6455.
    const sec_websocket_key_encoded = "dGhlIHNhbXBsZSBub25jZQ==";
    var sec_websocket_accept_encoded: [sec_websocket_accept_encoded_len]u8 = undefined;
    makeSecWebSocketAccept(sec_websocket_key_encoded, &sec_websocket_accept_encoded);

    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &sec_websocket_accept_encoded);
}

pub const ParseHandshakeResponseError = http.Reader.HeadError || http.Client.Response.Head.ParseError;

pub fn parseHandshakeResponse(
    reader: *Io.Reader,
    sec_websocket_accept_encoded: *const [sec_websocket_accept_encoded_len]u8,
) ParseHandshakeResponseError!Handshake {
    var http_reader: http.Reader = .{
        .in = reader,
        .state = .ready,
        .interface = undefined,
        .max_head_len = reader.buffer.len,
    };

    const head_bytes = try http_reader.receiveHead();
    const head: http.Client.Response.Head = try .parse(head_bytes);

    if (head.status != .switching_protocols)
        return .{ .result = .fail_not_switching_protocols, .head = head };

    var has_upgrade = false;
    var has_connection = false;
    var has_sec_websocket_accept = false;
    var header_iter = head.iterateHeaders();
    while (header_iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
            if (has_upgrade or !std.ascii.eqlIgnoreCase(header.value, "websocket"))
                return .{ .result = .fail_bad_headers, .head = head };

            has_upgrade = true;
        } else if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
            if (has_connection or !std.ascii.eqlIgnoreCase(header.value, "upgrade"))
                return .{ .result = .fail_bad_headers, .head = head };

            has_connection = true;
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-accept")) {
            if (has_sec_websocket_accept or !std.mem.eql(u8, header.value, sec_websocket_accept_encoded))
                return .{ .result = .fail_bad_headers, .head = head };

            has_sec_websocket_accept = true;
        }

        if (has_upgrade and has_connection and has_sec_websocket_accept) break;
    } else return .{ .result = .fail_missing_headers, .head = head };

    return .{ .result = .ok, .head = head };
}

const Header0 = packed struct { opcode: u4, rsv: u3 = 0, fin: bool };
const Header1 = packed struct { payload_len: PayloadLen, mask: bool };
const PayloadLen = enum(u7) { len16 = 126, len64 = 127, _ };

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    connection_close = 8,
    ping = 9,
    pong = 10,

    pub fn isControl(opcode: Opcode) bool {
        return (@intFromEnum(opcode) & 0b1000) != 0;
    }
};

pub const Frame = struct {
    opcode: Opcode,
    len: usize,
    fin: bool,
};

pub const TakeFrameHeaderError = error{
    /// An unrecognized opcode was received, e.g a value not in the `Opcode` enum.
    ///
    /// RFC 6455: If an unknown opcode is received, the receiving endpoint MUST _Fail the WebSocket Connection_.
    UnrecognizedOpcode,
    /// One of the reserved bits was toggled on.
    ///
    /// RFC 6455: If a nonzero value is received and none of the negotiated extensions defines the meaning of such a nonzero value,
    /// the receiving endpoint MUST _Fail the WebSocket Connection_.
    ReservedBitSet,
    /// Received a masked frame. The server is not allowed to send masked frames.
    ///
    /// RFC 6455: A client MUST close a connection if it detects a masked frame.
    Masked,
    /// A control frame was received with the `fin` bit cleared.
    ///
    /// RFC 6455: Control frames [...] MUST NOT be fragmented.
    ControlFrameFragmented,
    /// A control frame was received with a length of 126 bytes or more.
    ///
    /// RFC 6455: All control frames MUST have a payload length of 125 bytes or less and MUST NOT be fragmented.
    ControlFrameTooBig,
    /// The frame length can't fit into a `usize`.
    FrameTooBig,
    /// A `connection_close` frame has been received that is not empty but is too short to store the close code (at least 2 bytes).
    ///
    /// RFC 6455: The Close frame MAY contain a body [...]
    /// If there is a body, the first two bytes of the body MUST be a 2-byte unsigned integer
    BadClose,
} || Io.Reader.Error;

/// Take a frame header, validating it.
pub fn takeFrame(reader: *Io.Reader) TakeFrameHeaderError!Frame {
    const header0: Header0 = @bitCast(try reader.takeByte());
    const header1: Header1 = @bitCast(try reader.takeByte());

    const opcode = std.enums.fromInt(Opcode, header0.opcode) orelse
        return error.UnrecognizedOpcode;

    if (header0.rsv != 0)
        return error.ReservedBitSet;

    if (header1.mask)
        return error.Masked;

    if (!header0.fin and opcode.isControl())
        return error.ControlFrameFragmented;

    const len: usize = switch (header1.payload_len) {
        else => |len| @intFromEnum(len),
        .len16 => len16: {
            if (opcode.isControl())
                return error.ControlFrameTooBig;

            break :len16 std.math.cast(usize, try reader.takeInt(u16, .big)) orelse
                return error.FrameTooBig;
        },
        .len64 => len64: {
            if (opcode.isControl())
                return error.ControlFrameTooBig;

            break :len64 std.math.cast(usize, try reader.takeInt(u64, .big)) orelse
                return error.FrameTooBig;
        },
    };

    if (opcode == .connection_close and len == 1)
        return error.BadClose;

    return .{
        .opcode = opcode,
        .len = len,
        .fin = header0.fin,
    };
}

/// A structure that stores frames in a growing buffer in order to form a complete messages.
/// Always call `MessageIterator.deinit` to free remaining data (if any.)
///
/// `next` can return early if a control frame is found, in which case the buffer will contain data.
pub const AllocatingMessageIterator = struct {
    continuing_what: ?Opcode = null,
    /// Buffers text or binary data. Control frames are allocated directly.
    buffer: std.ArrayList(u8),
    /// The maximum size individual frames can have, or `null` for no cap.
    /// Setting this to `null` is NOT recommended, as servers controlled by attackers can cause a denial-of-service attack by allocating infinite memory.
    max_frame_len: ?usize,
    /// The maximum size messages can have, or `null` for no cap.
    /// Setting this to `null` is NOT recommended, as servers controlled by attackers can cause a denial-of-service attack by allocating infinite memory.
    ///
    /// If this is `null`, `error.MessageTooBig` will never be returned from `next`.
    max_message_len: ?usize,

    pub fn init(max_frame_len: ?usize, max_message_len: ?usize) AllocatingMessageIterator {
        return .{
            .buffer = .empty,
            .max_frame_len = max_frame_len,
            .max_message_len = max_message_len,
        };
    }

    pub fn deinit(iter: *AllocatingMessageIterator, gpa: Allocator) void {
        iter.buffer.deinit(gpa);
    }

    pub const Message = struct {
        opcode: Opcode,
        data: []u8,

        pub fn deinit(message: *const Message, gpa: Allocator) void {
            gpa.free(message.data);
        }
    };

    pub const NextError = error{
        /// A `continuation` frame was received with nothing to continue.
        InvalidContinuation,
        /// A non-control frame was received without ending the previous message.
        Interrupted,
        /// The frame length exceeds the limit or can't fit into a `usize`.
        FrameTooBig,
        /// The message length (the length of buffered data plus the received frame length) exceeds the limit.
        MessageTooBig,
    } || TakeFrameHeaderError || Allocator.Error;

    /// Caller owns the returned data.
    /// Note that this function may still leave some data in the buffer, if a control frame is found.
    pub fn next(iter: *AllocatingMessageIterator, gpa: Allocator, reader: *Io.Reader) NextError!Message {
        const message_opcode = while (true) {
            const frame_header = try takeFrame(reader);

            if (iter.max_frame_len) |max_frame_len|
                if (frame_header.len > max_frame_len)
                    return error.FrameTooBig;

            // Control frames cannot be fragmented, so there's no point in buffering them.
            if (frame_header.opcode.isControl()) return .{
                .opcode = frame_header.opcode,
                .data = try reader.readAlloc(gpa, frame_header.len),
            };

            if (iter.max_message_len) |max_message_len|
                if (iter.buffer.items.len +| frame_header.len > max_message_len)
                    return error.MessageTooBig;

            const message_opcode: Opcode = if (frame_header.opcode == .continuation) recall: {
                const recalled_opcode = iter.continuing_what orelse return error.InvalidContinuation;
                if (frame_header.fin) iter.continuing_what = null;
                break :recall recalled_opcode;
            } else validate: {
                if (iter.continuing_what != null) return error.Interrupted;
                if (!frame_header.fin) iter.continuing_what = frame_header.opcode;
                break :validate frame_header.opcode;
            };

            try reader.appendExact(gpa, &iter.buffer, frame_header.len);

            if (frame_header.fin)
                break message_opcode;
        };

        return .{
            .opcode = message_opcode,
            .data = try iter.buffer.toOwnedSlice(gpa),
        };
    }
};

/// A structure that stores frames in a buffer in order to form a complete messages.
///
/// `next` can return early if a control frame is found, in which case `end` will not be 0.
pub const StaticMessageIterator = struct {
    continuing_what: ?Opcode = null,
    buffer: []u8,
    end: usize = 0,

    pub fn init(buffer: []u8) StaticMessageIterator {
        return .{ .buffer = buffer };
    }

    fn bufferedLen(iter: *StaticMessageIterator) usize {
        return iter.buffer.len - iter.end;
    }

    pub const Message = struct { opcode: Opcode, data: []u8 };

    pub const NextError = error{
        /// A `continuation` frame was received with nothing to continue.
        InvalidContinuation,
        /// A non-control frame was received without ending the previous message.
        Interrupted,
        /// The frame length can't fit into a `usize`, or there's not enough space in the buffer for the frame.
        MessageTooBig,
    } || TakeFrameHeaderError;

    /// Each subsequent call to this function will invalidate previously returned data.
    pub fn next(iter: *StaticMessageIterator, reader: *Io.Reader) NextError!Message {
        const message_opcode = while (true) {
            const frame_header = try takeFrame(reader);

            if (iter.bufferedLen() < frame_header.len)
                return error.FrameTooBig;

            const frame_data = iter.buffer[iter.end..][0..frame_header.len];
            try reader.readSliceAll(frame_data);

            // Return control frames immediately.
            if (frame_header.opcode.isControl()) return .{
                .opcode = frame_header.opcode,
                .data = frame_data,
            };

            iter.end += frame_header.len;

            const message_opcode: Opcode = if (frame_header.opcode == .continuation) recall: {
                const recalled_opcode = iter.continuing_what orelse return error.InvalidContinuation;
                if (frame_header.fin) iter.continuing_what = null;
                break :recall recalled_opcode;
            } else validate: {
                if (iter.continuing_what != null) return error.Interrupted;
                if (!frame_header.fin) iter.continuing_what = frame_header.opcode;
                break :validate frame_header.opcode;
            };

            if (frame_header.fin)
                break message_opcode;
        };

        defer iter.end = 0;
        return .{
            .opcode = message_opcode,
            .data = iter.buffer[0..iter.end],
        };
    }
};

pub const ParsedClose = struct {
    code: CloseCode,
    reason: []const u8,
};

/// Make a WebSocket frame header with the provided parameters.
///
/// The masking key is written in native endian, as this function is meant to be complementary to `writeMasking`.
pub fn makeHeader(buf: *[1 + 1 + 8 + 4]u8, fin: bool, opcode: Opcode, length: usize, masking_key: u32) []const u8 {
    var len: usize = 2;

    buf[0] = @bitCast(Header0{
        .fin = fin,
        .opcode = @intFromEnum(opcode),
    });

    if (length > std.math.maxInt(u16)) {
        buf[1] = @bitCast(Header1{
            .mask = true,
            .payload_len = .len64,
        });
        std.mem.writeInt(u64, buf[2..10], @intCast(length), .big);
        len += @sizeOf(u64);
    } else if (length >= 126) {
        buf[1] = @bitCast(Header1{
            .mask = true,
            .payload_len = .len16,
        });
        std.mem.writeInt(u16, buf[2..4], @intCast(length), .big);
        len += @sizeOf(u16);
    } else {
        buf[1] = @bitCast(Header1{
            .mask = true,
            .payload_len = @enumFromInt(length),
        });
    }

    @memcpy(buf[len .. len + 4], std.mem.asBytes(&masking_key));
    len += 4;

    return buf[0..len];
}

test makeHeader {
    var buf: [1 + 1 + 8 + 4]u8 = undefined;

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x81, 0x85, 0x00, 0x00, 0x00, 0x00 },
        makeHeader(&buf, true, .text, 5, 0),
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x00, 0xfe, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00 },
        makeHeader(&buf, false, .continuation, 128, 0),
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x80, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        makeHeader(&buf, true, .continuation, std.math.maxInt(u16) + 1, 0),
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x89, 0xfd, 0x00, 0x00, 0x00, 0x00 },
        makeHeader(&buf, true, .ping, 125, 0),
    );
}

/// Write a masked payload using the provided masking key and rotation offset.
///
/// It is assumed that the masking key in the header is written in native endian.
///
/// The rotation offset is useful if you have to call this function multiple times. Use it like this:
/// ```zig
/// const payload_1 = "hello";
/// const payload_2 = ", ";
/// const payload_3 = "world!";
///
/// try writeMasking(writer, payload_1, masking_key, 0);
/// try writeMasking(writer, payload_2, masking_key, @truncate(payload_1.len));
/// try writeMasking(writer, payload_3, masking_key, @truncate(payload_1.len + payload_2.len));
/// ```
pub fn writeMasking(
    writer: *Io.Writer,
    payload: []const u8,
    masking_key: u32,
    offset: u2,
) Io.Writer.Error!void {
    if (payload.len == 0) return;

    var masking_key_rotated: u32 = masking_key;
    std.mem.rotate(u8, std.mem.asBytes(&masking_key_rotated), offset);

    for (0..payload.len / 4) |i| {
        const payload_u32: u32 = @bitCast(payload[i * 4 ..][0..4].*);
        const out: u32 = payload_u32 ^ masking_key_rotated;
        try writer.writeAll(std.mem.asBytes(&out));
    }
    const leftover_len = payload.len % 4;
    for (payload[payload.len - leftover_len ..], std.mem.toBytes(masking_key_rotated)[0..leftover_len]) |leftover_byte, mask_byte| {
        try writer.writeByte(leftover_byte ^ mask_byte);
    }
}

test writeMasking {
    var writer_buf: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&writer_buf);

    writeMasking(&writer, &.{ 0, 0, 0, 0 }, 0x12345678, 0) catch unreachable;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(@as(u32, 0x12345678)),
        writer.buffered(),
    );
    writer.end = 0;

    writeMasking(&writer, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, 0x12345678, 0) catch unreachable;
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(@as(u32, 0x12345678)) ++ std.mem.toBytes(@as(u32, 0x12345678)),
        writer.buffered(),
    );
}

/// Write a masked raw frame.
pub fn writeFrame(
    writer: *Io.Writer,
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
    masking_key: u32,
) Io.Writer.Error!void {
    var header_buf: [1 + 1 + 8 + 4]u8 = undefined;
    const header = makeHeader(&header_buf, fin, opcode, payload.len, masking_key);
    try writer.writeAll(header);
    try writeMasking(writer, payload, masking_key, 0);
}
/// Write a zero-masked raw frame. Avoids masking operations.
pub fn writeFrameZeroMask(
    writer: *Io.Writer,
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
) Io.Writer.Error!void {
    var header_buf: [1 + 1 + 8 + 4]u8 = undefined;
    var vec = [_][]const u8{
        makeHeader(&header_buf, fin, opcode, payload.len, 0),
        payload,
    };
    try writer.writeVecAll(&vec);
}

pub fn writePing(writer: *Io.Writer, payload: []const u8, masking_key: u32) Io.Writer.Error!void {
    try writeFrame(writer, true, .ping, payload, masking_key);
}
pub fn writePingZeroMask(writer: *Io.Writer, payload: []const u8) Io.Writer.Error!void {
    try writeFrameZeroMask(writer, true, .ping, payload);
}

pub fn writePong(writer: *Io.Writer, payload: []const u8, masking_key: u32) Io.Writer.Error!void {
    try writeFrame(writer, true, .pong, payload, masking_key);
}
pub fn writePongZeroMask(writer: *Io.Writer, payload: []const u8) Io.Writer.Error!void {
    try writeFrameZeroMask(writer, true, .pong, payload);
}

/// <https://www.iana.org/assignments/websocket/websocket.xhtml#close-code-number>
pub const CloseCode = enum(u16) {
    normal_closure = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    reserved = 1004,
    no_status_rcvd = 1005,
    abnormal_closure = 1006,
    invalid_frame_payload_data = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    mandatory_ext = 1010,
    internal_error = 1011,
    service_restart = 1012,
    try_again_later = 1013,
    the_server_was_acting_as_a_gateway_or_proxy_and_received_an_invalid_response_from_the_upstream_server_this_is_similar_to_502_http_status_code = 1014,
    tls_handshake = 1015,

    unauthorized = 3000,
    forbidden = 3003,
    timeout = 3008,

    _,
};

pub fn writeClose(writer: *Io.Writer) Io.Writer.Error!void {
    try writeFrameZeroMask(writer, true, .connection_close, &.{});
}
pub fn writeCloseWithCode(writer: *Io.Writer, code: CloseCode, masking_key: u32) Io.Writer.Error!void {
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, @intFromEnum(code), .big);
    try writeFrame(writer, true, .connection_close, &payload, masking_key);
}
pub fn writeCloseWithCodeZeroMask(writer: *Io.Writer, code: CloseCode) Io.Writer.Error!void {
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, @intFromEnum(code), .big);
    try writeFrameZeroMask(writer, true, .connection_close, &payload);
}
pub fn writeCloseWithCodeAndReason(writer: *Io.Writer, code: CloseCode, reason: []const u8, masking_key: u32) Io.Writer.Error!void {
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, @intFromEnum(code), .big);
    var header_buf: [1 + 1 + 8 + 4]u8 = undefined;
    try writer.writeAll(makeHeader(&header_buf, true, .connection_close, payload.len + reason.len, masking_key));
    try writeMasking(writer, &payload, masking_key, 0);
    try writeMasking(writer, reason, masking_key, 2);
}
pub fn writeCloseWithCodeAndReasonZeroMask(writer: *Io.Writer, code: CloseCode, reason: []const u8) Io.Writer.Error!void {
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, @intFromEnum(code), .big);
    var header_buf: [1 + 1 + 8 + 4]u8 = undefined;
    var vec = [_][]const u8{
        makeHeader(&header_buf, true, .connection_close, payload.len + reason.len, 0),
        &payload,
        reason,
    };
    try writer.writeVecAll(&vec);
}

pub const MessageType = enum(u4) { text = @intFromEnum(Opcode.text), binary = @intFromEnum(Opcode.binary) };

/// Write a WebSocket message.
pub fn writeMessage(writer: *Io.Writer, comptime @"type": MessageType, payload: []const u8, masking_key: u32) Io.Writer.Error!void {
    try writeFrame(writer, true, @enumFromInt(@intFromEnum(@"type")), payload, masking_key);
}
/// Write a WebSocket message. Avoids masking operations.
pub fn writeMessageZeroMask(writer: *Io.Writer, comptime @"type": MessageType, payload: []const u8) Io.Writer.Error!void {
    try writeFrameZeroMask(writer, true, @enumFromInt(@intFromEnum(@"type")), payload);
}

pub const WriteFragmentedMessageOptions = struct {
    /// Maximum size of each frame.
    /// If the message length exceeds this value, it will be split into multiple frames.
    max_frame_size: usize = 1024,
};

/// Write a fragmented WebSocket message.
pub fn writeFragmentedMessage(
    writer: *Io.Writer,
    masking_key_generator: std.Random,
    comptime @"type": MessageType,
    payload: []const u8,
    options: WriteFragmentedMessageOptions,
) Io.Writer.Error!void {
    const opcode: Opcode = @enumFromInt(@intFromEnum(@"type"));
    if (payload.len == 0) {
        var header_buf: [1 + 1 + 8 + 4]u8 = undefined;
        // No content, so no masking, ergo masking key is unused. Set it to 0.
        try writer.writeAll(makeHeader(&header_buf, true, opcode, 0, 0));
        return;
    }

    var start_idx: usize = 0;
    while (start_idx < payload.len) : (start_idx += options.max_frame_size) {
        const frame_payload = payload[start_idx..@min(start_idx + options.max_frame_size, payload.len)];
        const masking_key = masking_key_generator.int(u32);
        try writeFrame(
            writer,
            start_idx + options.max_frame_size >= payload.len,
            if (start_idx == 0) opcode else .continuation,
            frame_payload,
            masking_key,
        );
    }
}
/// Write a fragmented WebSocket message. Avoids masking operations.
pub fn writeFragmentedMessageZeroMask(
    writer: *Io.Writer,
    comptime @"type": MessageType,
    payload: []const u8,
    options: WriteFragmentedMessageOptions,
) Io.Writer.Error!void {
    const opcode: Opcode = @enumFromInt(@intFromEnum(@"type"));
    if (payload.len == 0) {
        var header_buf: [1 + 1 + 8 + 4]u8 = undefined;
        // No content, so no masking, ergo masking key is unused. Set it to 0.
        try writer.writeAll(makeHeader(&header_buf, true, opcode, 0, 0));
        return;
    }

    var start_idx: usize = 0;
    while (start_idx < payload.len) : (start_idx += options.max_frame_size) {
        const frame_payload = payload[start_idx..@min(start_idx + options.max_frame_size, payload.len)];
        try writeFrameZeroMask(
            writer,
            start_idx + options.max_frame_size >= payload.len,
            if (start_idx == 0) opcode else .continuation,
            frame_payload,
        );
    }
}

/// Helper for writing streaming data to a WebSocket. Avoids masking operations.
///
/// It is possible to switch modes after flushing the writer.
pub const FramingWriterZeroMask = struct {
    out: *Io.Writer,
    interface: Io.Writer,
    mode: MessageType,
    first: bool = true,

    const vtable: Io.Writer.VTable = .{
        .drain = drain,
        .flush = flush,
    };

    pub fn init(out: *Io.Writer, buffer: []u8, initial_mode: MessageType) FramingWriterZeroMask {
        return .{
            .out = out,
            .interface = .{
                .vtable = &vtable,
                .buffer = buffer,
            },
            .mode = initial_mode,
        };
    }

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        std.debug.assert(data.len != 0);

        const w: *FramingWriterZeroMask = @fieldParentPtr("interface", io_w);

        const length: usize = io_w.end + Io.Writer.countSplat(data, splat);

        var header_buf: [1 + 1 + 8 + 4]u8 = undefined;
        const header = makeHeader(
            &header_buf,
            false,
            if (w.first) @enumFromInt(@intFromEnum(w.mode)) else .continuation,
            length,
            0,
        );

        var vec = [_][]const u8{
            header,
            io_w.buffered(),
        };
        try w.out.writeVecAll(&vec);
        io_w.end = 0;

        const slice = data[0 .. data.len - 1];
        const pattern = data[slice.len];

        for (slice) |bytes| try w.out.writeAll(bytes);
        try w.out.splatBytesAll(pattern, splat);

        w.first = false;

        return length;
    }

    fn flush(io_w: *Io.Writer) Io.Writer.Error!void {
        const w: *FramingWriterZeroMask = @fieldParentPtr("interface", io_w);

        var header_buf: [1 + 1 + 8 + 4]u8 = undefined;
        const header = makeHeader(
            &header_buf,
            true,
            if (w.first) @enumFromInt(@intFromEnum(w.mode)) else .continuation,
            io_w.end,
            0,
        );

        var vec = [_][]const u8{
            header,
            io_w.buffered(),
        };
        try w.out.writeVecAll(&vec);
        io_w.end = 0;

        w.first = true;
    }
};

/// Helper for writing streaming data to a WebSocket.
///
/// It is possible to switch modes after flushing the writer.
pub const FramingWriter = struct {
    out: *Io.Writer,
    random: std.Random,
    interface: Io.Writer,
    mode: MessageType,
    first: bool = true,

    const vtable: Io.Writer.VTable = .{
        .drain = drain,
        .flush = flush,
    };

    pub fn init(out: *Io.Writer, random: std.Random, buffer: []u8, initial_mode: MessageType) FramingWriter {
        return .{
            .out = out,
            .random = random,
            .interface = .{
                .vtable = &vtable,
                .buffer = buffer,
            },
            .mode = initial_mode,
        };
    }

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        std.debug.assert(data.len != 0);

        const w: *FramingWriter = @fieldParentPtr("interface", io_w);

        const length: usize = io_w.end + Io.Writer.countSplat(data, splat);
        const masking_key = w.random.int(u32);

        var header_buf: [1 + 1 + 8 + 4]u8 = undefined;
        const header = makeHeader(
            &header_buf,
            false,
            if (w.first) @enumFromInt(@intFromEnum(w.mode)) else .continuation,
            length,
            masking_key,
        );
        try w.out.writeAll(header);

        var written: usize = 0;

        try writeMasking(w.out, io_w.buffered(), masking_key, 0);
        written += io_w.end;
        io_w.end = 0;

        const slice = data[0 .. data.len - 1];
        const pattern = data[slice.len];

        for (slice) |bytes| {
            try writeMasking(w.out, bytes, masking_key, @truncate(written));
            written += bytes.len;
        }
        for (0..splat) |_| {
            // We have to splat manually because of masking =.=
            try writeMasking(w.out, pattern, masking_key, @truncate(written));
            written += pattern.len;
        }

        w.first = false;

        return length;
    }

    fn flush(io_w: *Io.Writer) Io.Writer.Error!void {
        const w: *FramingWriter = @fieldParentPtr("interface", io_w);

        const masking_key = w.random.int(u32);
        var header_buf: [1 + 1 + 8 + 4]u8 = undefined;
        const header = makeHeader(
            &header_buf,
            true,
            if (w.first) @enumFromInt(@intFromEnum(w.mode)) else .continuation,
            io_w.end,
            masking_key,
        );
        try w.out.writeAll(header);
        try writeMasking(w.out, io_w.buffered(), masking_key, 0);
        io_w.end = 0;

        w.first = true;
    }
};

test {
    std.testing.refAllDecls(@This());
}
