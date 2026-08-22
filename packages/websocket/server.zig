//! Server-role WebSocket framing over std.Io. The client masks every frame.
//! The server unmasks on read and sends unmasked frames.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ws = @import("websocket.zig");

pub const Opcode = ws.Opcode;
pub const CloseCode = ws.CloseCode;
pub const ParsedClose = ws.ParsedClose;
pub const parseClose = ws.parseClose;

const Header0 = packed struct(u8) { opcode: u4, rsv: u3 = 0, fin: bool };
const Header1 = packed struct(u8) { payload_len: PayloadLen, mask: bool };
const PayloadLen = enum(u7) { len16 = 126, len64 = 127, _ };

pub const Frame = struct {
    opcode: Opcode,
    len: usize,
    fin: bool,
    mask: [4]u8,
};

pub const TakeFrameError = error{
    /// The client sent an unmasked frame. RFC 6455: the server MUST close the connection.
    Unmasked,
    UnrecognizedOpcode,
    ReservedBitSet,
    ControlFrameFragmented,
    ControlFrameTooBig,
    FrameTooBig,
    /// The length uses more bytes than the minimal encoding. RFC 6455 forbids this.
    NonMinimalLength,
    BadClose,
} || Io.Reader.Error;

/// Take one frame header and its mask key. The payload stays in the reader.
pub fn takeFrame(reader: *Io.Reader) TakeFrameError!Frame {
    const header0: Header0 = @bitCast(try reader.takeByte());
    const header1: Header1 = @bitCast(try reader.takeByte());

    const opcode = std.enums.fromInt(Opcode, header0.opcode) orelse
        return error.UnrecognizedOpcode;
    if (header0.rsv != 0) return error.ReservedBitSet;
    if (!header1.mask) return error.Unmasked;
    if (!header0.fin and opcode.isControl()) return error.ControlFrameFragmented;

    const len: usize = switch (header1.payload_len) {
        else => |value| @intFromEnum(value),
        .len16 => len16: {
            if (opcode.isControl()) return error.ControlFrameTooBig;
            const value = try reader.takeInt(u16, .big);
            if (value < 126) return error.NonMinimalLength;
            break :len16 value;
        },
        .len64 => len64: {
            if (opcode.isControl()) return error.ControlFrameTooBig;
            const value = try reader.takeInt(u64, .big);
            if (value & (@as(u64, 1) << 63) != 0) return error.FrameTooBig;
            if (value <= std.math.maxInt(u16)) return error.NonMinimalLength;
            break :len64 std.math.cast(usize, value) orelse return error.FrameTooBig;
        },
    };

    var mask: [4]u8 = undefined;
    try reader.readSliceAll(&mask);

    if (opcode == .connection_close and len == 1) return error.BadClose;

    return .{ .opcode = opcode, .len = len, .fin = header0.fin, .mask = mask };
}

/// Unmask a payload in place with the frame mask key.
pub fn unmask(data: []u8, mask: [4]u8) void {
    for (data, 0..) |*byte, i| byte.* ^= mask[i % 4];
}

/// Reassemble masked frames into complete messages. The buffer grows as frames arrive.
/// `next` returns a control frame early, so the buffer keeps the partial message.
pub const MessageReader = struct {
    continuing_what: ?Opcode = null,
    buffer: std.ArrayList(u8),
    max_frame_len: ?usize,
    max_message_len: ?usize,

    pub fn init(max_frame_len: ?usize, max_message_len: ?usize) MessageReader {
        return .{ .buffer = .empty, .max_frame_len = max_frame_len, .max_message_len = max_message_len };
    }

    pub fn deinit(reader: *MessageReader, gpa: Allocator) void {
        reader.buffer.deinit(gpa);
        reader.* = undefined;
    }

    pub const Message = struct {
        opcode: Opcode,
        data: []u8,

        pub fn deinit(message: *Message, gpa: Allocator) void {
            gpa.free(message.data);
            message.* = undefined;
        }
    };

    pub const NextError = error{
        InvalidContinuation,
        Interrupted,
        FrameTooBig,
        MessageTooBig,
        /// A text message is not valid UTF-8. RFC 6455 requires a 1007 close.
        InvalidUtf8,
    } || TakeFrameError || Allocator.Error;

    /// Read one complete message. The caller owns the data.
    pub fn next(self: *MessageReader, gpa: Allocator, reader: *Io.Reader) NextError!Message {
        const message_opcode = while (true) {
            const frame = try takeFrame(reader);

            if (self.max_frame_len) |max| if (frame.len > max) return error.FrameTooBig;

            // A control frame is never fragmented, so it does not join the buffer.
            if (frame.opcode.isControl()) {
                const data = try reader.readAlloc(gpa, frame.len);
                unmask(data, frame.mask);
                return .{ .opcode = frame.opcode, .data = data };
            }

            if (self.max_message_len) |max|
                if (self.buffer.items.len +| frame.len > max) return error.MessageTooBig;

            const message_opcode: Opcode = if (frame.opcode == .continuation) recall: {
                const recalled = self.continuing_what orelse return error.InvalidContinuation;
                if (frame.fin) self.continuing_what = null;
                break :recall recalled;
            } else validate: {
                if (self.continuing_what != null) return error.Interrupted;
                if (!frame.fin) self.continuing_what = frame.opcode;
                break :validate frame.opcode;
            };

            const start = self.buffer.items.len;
            try reader.appendExact(gpa, &self.buffer, frame.len);
            unmask(self.buffer.items[start..], frame.mask);

            if (frame.fin) break message_opcode;
        };

        // A complete text message must be valid UTF-8. Fragment-boundary checks are deferred.
        if (message_opcode == .text and !std.unicode.utf8ValidateSlice(self.buffer.items))
            return error.InvalidUtf8;

        return .{ .opcode = message_opcode, .data = try self.buffer.toOwnedSlice(gpa) };
    }
};

pub const CloseError = error{ BadClose, InvalidCloseCode, InvalidUtf8 };

/// A close code is valid if IANA assigns it or reserves it for private use.
pub fn isValidCloseCode(code: CloseCode) bool {
    return switch (@intFromEnum(code)) {
        1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011 => true,
        3000...4999 => true,
        else => false,
    };
}

/// Parse a close payload. Reject a short payload, a bad code, or bad UTF-8.
pub fn checkedClose(data: []const u8) CloseError!ParsedClose {
    if (data.len == 0) return .{ .code = .no_status_rcvd, .reason = &.{} };
    if (data.len == 1) return error.BadClose;
    const code: CloseCode = @enumFromInt(std.mem.readInt(u16, data[0..2], .big));
    if (!isValidCloseCode(code)) return error.InvalidCloseCode;
    const reason = data[2..];
    if (!std.unicode.utf8ValidateSlice(reason)) return error.InvalidUtf8;
    return .{ .code = code, .reason = reason };
}

/// Make an unmasked server frame header.
pub fn makeHeader(buf: *[1 + 1 + 8]u8, fin: bool, opcode: Opcode, length: usize) []const u8 {
    var len: usize = 2;
    buf[0] = @bitCast(Header0{ .fin = fin, .opcode = @intFromEnum(opcode) });

    if (length > std.math.maxInt(u16)) {
        buf[1] = @bitCast(Header1{ .mask = false, .payload_len = .len64 });
        std.mem.writeInt(u64, buf[2..10], @intCast(length), .big);
        len += @sizeOf(u64);
    } else if (length >= 126) {
        buf[1] = @bitCast(Header1{ .mask = false, .payload_len = .len16 });
        std.mem.writeInt(u16, buf[2..4], @intCast(length), .big);
        len += @sizeOf(u16);
    } else {
        buf[1] = @bitCast(Header1{ .mask = false, .payload_len = @enumFromInt(length) });
    }

    return buf[0..len];
}

/// Write one unmasked server frame.
pub fn writeFrame(writer: *Io.Writer, fin: bool, opcode: Opcode, payload: []const u8) Io.Writer.Error!void {
    if (opcode.isControl()) {
        std.debug.assert(fin); // a control frame is never fragmented
        std.debug.assert(payload.len <= 125); // a control frame is small
    }
    var header_buf: [1 + 1 + 8]u8 = undefined;
    var vec = [_][]const u8{ makeHeader(&header_buf, fin, opcode, payload.len), payload };
    try writer.writeVecAll(&vec);
}

pub const MessageType = enum(u4) {
    text = @intFromEnum(Opcode.text),
    binary = @intFromEnum(Opcode.binary),
};

/// Write a complete server message in one frame.
pub fn writeMessage(writer: *Io.Writer, message_type: MessageType, payload: []const u8) Io.Writer.Error!void {
    try writeFrame(writer, true, @enumFromInt(@intFromEnum(message_type)), payload);
}

pub fn writePing(writer: *Io.Writer, payload: []const u8) Io.Writer.Error!void {
    try writeFrame(writer, true, .ping, payload);
}

pub fn writePong(writer: *Io.Writer, payload: []const u8) Io.Writer.Error!void {
    try writeFrame(writer, true, .pong, payload);
}

pub fn writeClose(writer: *Io.Writer, code: CloseCode) Io.Writer.Error!void {
    std.debug.assert(isValidCloseCode(code)); // the server sends only a valid code
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, @intFromEnum(code), .big);
    try writeFrame(writer, true, .connection_close, &payload);
}

test "takeFrame reads a masked client frame and unmask round-trips" {
    // This masked text frame carries "Hi": header 0x81 0x82, mask 0x01020304, payload masked.
    const mask = [4]u8{ 0x01, 0x02, 0x03, 0x04 };
    var payload = [_]u8{ 'H' ^ mask[0], 'i' ^ mask[1] };
    var bytes: [8]u8 = undefined;
    bytes[0] = 0x81;
    bytes[1] = 0x82;
    @memcpy(bytes[2..6], &mask);
    @memcpy(bytes[6..8], &payload);

    var reader: Io.Reader = .fixed(&bytes);
    const frame = try takeFrame(&reader);
    try std.testing.expectEqual(Opcode.text, frame.opcode);
    try std.testing.expectEqual(@as(usize, 2), frame.len);
    try std.testing.expect(frame.fin);

    var got: [2]u8 = undefined;
    try reader.readSliceAll(&got);
    unmask(&got, frame.mask);
    try std.testing.expectEqualStrings("Hi", &got);
}

test "takeFrame rejects an unmasked frame" {
    var bytes = [_]u8{ 0x81, 0x02, 'H', 'i' };
    var reader: Io.Reader = .fixed(&bytes);
    try std.testing.expectError(error.Unmasked, takeFrame(&reader));
}

test "makeHeader writes an unmasked small header" {
    var buf: [1 + 1 + 8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x05 }, makeHeader(&buf, true, .text, 5));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x7e, 0x01, 0x00 }, makeHeader(&buf, true, .binary, 256));
}

test "MessageReader reassembles a fragmented masked message" {
    const mask = [4]u8{ 0xaa, 0xbb, 0xcc, 0xdd };
    // The first text frame is not final; the final continuation carries "llo".
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    {
        var f1 = [_]u8{ 'h' ^ mask[0], 'e' ^ mask[1] };
        try bytes.appendSlice(a, &.{ 0x01, 0x82 });
        try bytes.appendSlice(a, &mask);
        try bytes.appendSlice(a, &f1);
        var f2 = [_]u8{ 'l' ^ mask[0], 'l' ^ mask[1], 'o' ^ mask[2] };
        try bytes.appendSlice(a, &.{ 0x80, 0x83 });
        try bytes.appendSlice(a, &mask);
        try bytes.appendSlice(a, &f2);
    }

    var reader: Io.Reader = .fixed(bytes.items);
    var message_reader: MessageReader = .init(null, 1024);
    defer message_reader.deinit(a);
    var message = try message_reader.next(a, &reader);
    defer message.deinit(a);
    try std.testing.expectEqual(Opcode.text, message.opcode);
    try std.testing.expectEqualStrings("hello", message.data);
}

test "takeFrame rejects a non-minimal 16-bit length" {
    // The 16-bit form carries 16, which fits the 7-bit form, so it is non-minimal.
    var bytes = [_]u8{ 0x82, 0xfe, 0x00, 0x10, 0, 0, 0, 0 };
    var reader: Io.Reader = .fixed(&bytes);
    try std.testing.expectError(error.NonMinimalLength, takeFrame(&reader));
}

test "takeFrame rejects a large control frame" {
    var bytes = [_]u8{ 0x89, 0xfe, 0x00, 0x7f };
    var reader: Io.Reader = .fixed(&bytes);
    try std.testing.expectError(error.ControlFrameTooBig, takeFrame(&reader));
}

test "checkedClose validates the code and the reason" {
    try std.testing.expectError(error.InvalidCloseCode, checkedClose(&[_]u8{ 0x03, 0xed }));
    const parsed = try checkedClose(&[_]u8{ 0x03, 0xe8 });
    try std.testing.expectEqual(CloseCode.normal_closure, parsed.code);
    try std.testing.expectError(error.InvalidUtf8, checkedClose(&[_]u8{ 0x03, 0xe8, 0xff }));
}

test "MessageReader rejects invalid UTF-8 text" {
    var bytes = [_]u8{ 0x81, 0x82, 0, 0, 0, 0, 0xff, 0xfe };
    var reader: Io.Reader = .fixed(&bytes);
    var message_reader: MessageReader = .init(null, null);
    defer message_reader.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidUtf8, message_reader.next(std.testing.allocator, &reader));
}

test {
    std.testing.refAllDecls(@This());
}
