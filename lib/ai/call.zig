//! An AI call composes a route, a serializer, a transport, and a stream reducer.

const std = @import("std");
const adapter = @import("adapter.zig");
const event = @import("stream/event.zig");
const http_transport = @import("transport/http.zig");
const instance = @import("instance/instance.zig");
const ir = @import("request/ir.zig");
const resolve = @import("instance/resolve.zig");
const transport = @import("transport.zig");
const types = @import("types.zig");

pub const Model = struct {
    id: []const u8,
    provider: instance.ProviderInstance,
    credential: resolve.Credential,
};

pub const Request = struct {
    blocks: []const ir.Block,
    system: []const u8 = "",
    tools: []const ir.Tool = &.{},
    max_output_tokens: u32,
    reasoning: ir.ReasoningControl = .default,
    thinking_format: ir.ThinkingFormat = .none,
    reasoning_replay: ir.ReasoningReplay = .none,
    max_tokens_field: ir.MaxTokensField = .max_tokens,
    /// Constrain the response to a schema. A null schema leaves the response free.
    output_schema: ?ir.OutputSchema = null,
};

pub const TextOptions = struct {
    system: []const u8 = "",
    max_output_tokens: u32 = 1024,
    reasoning: ir.ReasoningControl = .default,
    thinking_format: ir.ThinkingFormat = .none,
    max_tokens_field: ir.MaxTokensField = .max_tokens,
};

pub const Content = union(enum) {
    text: []const u8,
    reasoning: Reasoning,
    redacted_reasoning: []const u8,
    tool_call: ToolCall,

    pub const Reasoning = struct {
        text: []const u8,
        signature: []const u8,
    };

    pub const ToolCall = struct {
        call_id: []const u8,
        name: []const u8,
        arguments: []const u8,
    };
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    content: []const Content,
    text: []const u8,
    finish_reason: types.FinishReason,
    raw_finish_reason: []const u8,
    usage: types.Usage,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Client = struct {
    http: http_transport.HttpTransport,

    pub const Options = struct {
        idle_timeout: ?std.Io.Duration = null,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) Client {
        return .{ .http = .init(gpa, io, options.idle_timeout) };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
        self.* = undefined;
    }

    pub fn generate(self: *Client, gpa: std.mem.Allocator, model: Model, request: Request) !Result {
        return generateWithTransport(gpa, self.http.transportFor(), model, request);
    }

    pub fn generateText(self: *Client, gpa: std.mem.Allocator, model: Model, prompt: []const u8, options: TextOptions) !Result {
        return generateTextWithTransport(gpa, self.http.transportFor(), model, prompt, options);
    }

    pub fn stream(
        self: *Client,
        gpa: std.mem.Allocator,
        model: Model,
        request: Request,
        context: anytype,
        comptime onEvent: fn (@TypeOf(context), event.StreamEvent) anyerror!void,
    ) !void {
        return streamWithTransport(gpa, self.http.transportFor(), model, request, context, onEvent);
    }
};

pub fn generateTextWithTransport(gpa: std.mem.Allocator, route_transport: transport.Transport, model: Model, prompt: []const u8, options: TextOptions) !Result {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = prompt } }};
    return generateWithTransport(gpa, route_transport, model, .{
        .blocks = &blocks,
        .system = options.system,
        .max_output_tokens = options.max_output_tokens,
        .reasoning = options.reasoning,
        .thinking_format = options.thinking_format,
        .max_tokens_field = options.max_tokens_field,
    });
}

pub fn generateWithTransport(gpa: std.mem.Allocator, route_transport: transport.Transport, model: Model, request: Request) !Result {
    var collector = Collector.init(gpa);
    errdefer collector.deinit();
    try streamWithTransport(gpa, route_transport, model, request, &collector, Collector.onEvent);
    return collector.result();
}

/// Event slices expire when `onEvent` returns; this function releases the response body before it returns.
pub fn streamWithTransport(
    gpa: std.mem.Allocator,
    route_transport: transport.Transport,
    model: Model,
    request: Request,
    context: anytype,
    comptime onEvent: fn (@TypeOf(context), event.StreamEvent) anyerror!void,
) !void {
    if (request.blocks.len == 0) return error.EmptyRequest;
    var call_arena = std.heap.ArenaAllocator.init(gpa);
    defer call_arena.deinit();
    const arena = call_arena.allocator();

    var headers: std.ArrayList(instance.Header) = .empty;
    try resolve.authHeaders(arena, &model.provider, model.credential, &headers);
    const body_bytes = try requestBody(arena, model, request);
    const http_request: transport.Request = .{
        .url = try resolve.endpointUrl(arena, &model.provider),
        .headers = headers.items,
        .body = body_bytes,
    };
    var info: transport.AttemptInfo = .{};
    const body = try route_transport.open(arena, http_request, &info);
    defer body.deinit();

    try reduce(gpa, body, model.provider.protocol, context, onEvent);
}

fn requestBody(arena: std.mem.Allocator, model: Model, request: Request) ![]u8 {
    const value: ir.Request = .{
        .model = model.id,
        .system = request.system,
        .tools = request.tools,
        .max_output_tokens = request.max_output_tokens,
        .reasoning = request.reasoning,
        .thinking_format = request.thinking_format,
        .reasoning_replay = request.reasoning_replay,
        .max_tokens_field = request.max_tokens_field,
        .responses_dialect = model.provider.responses_dialect,
        .cache = model.provider.cache.marksBreakpoints(),
        .output_schema = request.output_schema,
    };
    return adapter.serialize(arena, model.provider.protocol, value, .{ .blocks = request.blocks });
}

fn reduce(
    gpa: std.mem.Allocator,
    body: transport.ResponseBody,
    protocol: types.Protocol,
    context: anytype,
    comptime onEvent: fn (@TypeOf(context), event.StreamEvent) anyerror!void,
) !void {
    switch (protocol) {
        inline else => |value| {
            var reducer = adapter.Adapter(value).Reducer.init(gpa);
            defer reducer.deinit();
            try transport.stream(gpa, body, &reducer, context, onEvent);
        },
    }
}

const Collector = struct {
    arena: std.heap.ArenaAllocator,
    blocks: std.ArrayList(Block) = .empty,
    done: ?event.Done = null,

    const Block = struct {
        kind: event.BlockKind,
        bytes: std.ArrayList(u8) = .empty,
        stopped: bool = false,
        result: ?event.BlockResult = null,
    };

    fn init(gpa: std.mem.Allocator) Collector {
        return .{ .arena = .init(gpa) };
    }

    fn deinit(self: *Collector) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn onEvent(self: *Collector, value: event.StreamEvent) !void {
        const arena = self.arena.allocator();
        switch (value) {
            .block_started => |started| {
                std.debug.assert(started.block == self.blocks.items.len);
                try self.blocks.append(arena, .{ .kind = started.kind });
            },
            .text_delta => |delta| try self.append(delta.block, delta.text),
            .reasoning_delta => |delta| try self.append(delta.block, delta.text),
            .tool_input_delta => {},
            .block_stopped => |stopped| {
                const current = self.getBlock(stopped.block);
                std.debug.assert(!current.stopped);
                current.stopped = true;
                current.result = try dupeResult(arena, stopped.result);
            },
            .done => |done| {
                std.debug.assert(self.done == null);
                self.done = .{
                    .stop_reason = done.stop_reason,
                    .raw_stop_reason = try arena.dupe(u8, done.raw_stop_reason),
                    .usage = done.usage,
                };
            },
        }
    }

    fn append(self: *Collector, id: event.BlockId, bytes: []const u8) !void {
        const current = self.getBlock(id);
        std.debug.assert(!current.stopped);
        try current.bytes.appendSlice(self.arena.allocator(), bytes);
    }

    fn getBlock(self: *Collector, id: event.BlockId) *Block {
        const index: usize = @intCast(id);
        std.debug.assert(index < self.blocks.items.len);
        return &self.blocks.items[index];
    }

    fn result(self: *Collector) !Result {
        const done = self.done.?;
        const arena = self.arena.allocator();
        const content = try arena.alloc(Content, self.blocks.items.len);
        var text_len: usize = 0;
        for (self.blocks.items, content) |current, *part| {
            std.debug.assert(current.stopped);
            const final = current.result.?;
            part.* = switch (final) {
                .text => blk: {
                    text_len = try std.math.add(usize, text_len, current.bytes.items.len);
                    break :blk .{ .text = current.bytes.items };
                },
                .reasoning => |reasoning| .{ .reasoning = .{ .text = current.bytes.items, .signature = reasoning.signature } },
                .redacted_reasoning => |redacted| .{ .redacted_reasoning = redacted.data },
                .tool => |tool| .{ .tool_call = .{ .call_id = tool.call_id, .name = tool.name, .arguments = tool.arguments } },
            };
        }
        const text_content = try arena.alloc(u8, text_len);
        var text_offset: usize = 0;
        for (content) |part| switch (part) {
            .text => |text_part| {
                @memcpy(text_content[text_offset..][0..text_part.len], text_part);
                text_offset += text_part.len;
            },
            else => {},
        };
        std.debug.assert(text_offset == text_content.len);
        const result_value: Result = .{
            .arena = self.arena,
            .content = content,
            .text = text_content,
            .finish_reason = done.stop_reason,
            .raw_finish_reason = done.raw_stop_reason,
            .usage = done.usage,
        };
        self.* = undefined;
        return result_value;
    }
};

fn dupeResult(arena: std.mem.Allocator, result_value: event.BlockResult) !event.BlockResult {
    return switch (result_value) {
        .text => .text,
        .reasoning => |reasoning| .{ .reasoning = .{ .signature = try arena.dupe(u8, reasoning.signature) } },
        .redacted_reasoning => |redacted| .{ .redacted_reasoning = .{ .data = try arena.dupe(u8, redacted.data) } },
        .tool => |tool| .{ .tool = .{
            .call_id = try arena.dupe(u8, tool.call_id),
            .name = try arena.dupe(u8, tool.name),
            .arguments = try arena.dupe(u8, tool.arguments),
        } },
    };
}

const LifecycleTransport = struct {
    bytes: []const u8,
    open_count: usize = 0,
    deinit_count: usize = 0,

    fn transportFor(self: *LifecycleTransport) transport.Transport {
        return .{ .ctx = self, .vtable = &transport_vtable };
    }

    const Body = struct {
        reader: transport.ReplayReader,
        owner: *LifecycleTransport,

        fn responseBody(self: *Body) transport.ResponseBody {
            return .{ .ctx = self, .vtable = &body_vtable };
        }

        fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
            const self: *Body = @ptrCast(@alignCast(ctx));
            return self.reader.body().read(buf);
        }

        fn deinit(ctx: *anyopaque) void {
            const self: *Body = @ptrCast(@alignCast(ctx));
            self.owner.deinit_count += 1;
        }

        const body_vtable: transport.ResponseBody.VTable = .{ .read = read, .deinit = deinit };
    };

    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: transport.Request, info: *transport.AttemptInfo) anyerror!transport.ResponseBody {
        _ = .{ request, info };
        const self: *LifecycleTransport = @ptrCast(@alignCast(ctx));
        self.open_count += 1;
        const body = try arena.create(Body);
        body.* = .{ .reader = .{ .bytes = self.bytes }, .owner = self };
        return body.responseBody();
    }

    const transport_vtable: transport.Transport.VTable = .{ .open = open };
};

fn testModel(protocol: types.Protocol) Model {
    return .{
        .id = "test-model",
        .provider = .{ .base_url = "https://example.test/v1", .protocol = protocol, .auth = .none },
        .credential = .none,
    };
}

test "generate text returns owned normalized content" {
    var canned = transport.CannedTransport{ .bytes = transport.canned_reply };
    var result_value = try generateTextWithTransport(std.testing.allocator, canned.transport(), .{
        .id = "claude-test",
        .provider = .{
            .base_url = "https://example.test/v1",
            .protocol = .anthropic_messages,
            .auth = .none,
        },
        .credential = .none,
    }, "hello", .{});
    defer result_value.deinit();

    try std.testing.expectEqualStrings("Hello from the yuke mock provider.", result_value.text);
    try std.testing.expectEqual(types.FinishReason.stop, result_value.finish_reason);
    try std.testing.expectEqual(@as(u64, 8), result_value.usage.output);
}

test "generate rejects an empty request before transport I/O" {
    var lifecycle = LifecycleTransport{ .bytes = transport.canned_reply };
    try std.testing.expectError(error.EmptyRequest, generateWithTransport(std.testing.allocator, lifecycle.transportFor(), testModel(.openai_chat), .{
        .blocks = &.{},
        .max_output_tokens = 1,
    }));
    try std.testing.expectEqual(@as(usize, 0), lifecycle.open_count);
    try std.testing.expectEqual(@as(usize, 0), lifecycle.deinit_count);
}

test "stream releases the response body after success" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    var lifecycle = LifecycleTransport{ .bytes = transport.canned_reply };
    var event_count: usize = 0;
    const Counter = struct {
        fn onEvent(count: *usize, _: event.StreamEvent) !void {
            count.* += 1;
        }
    };

    try streamWithTransport(std.testing.allocator, lifecycle.transportFor(), testModel(.anthropic_messages), .{
        .blocks = &blocks,
        .max_output_tokens = 1,
    }, &event_count, Counter.onEvent);
    try std.testing.expect(event_count > 0);
    try std.testing.expectEqual(@as(usize, 1), lifecycle.open_count);
    try std.testing.expectEqual(@as(usize, 1), lifecycle.deinit_count);
}

test "stream releases the response body after a callback error" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    var lifecycle = LifecycleTransport{ .bytes = transport.canned_reply };
    const Reject = struct {
        fn onEvent(_: void, _: event.StreamEvent) !void {
            return error.CallbackRejected;
        }
    };

    try std.testing.expectError(error.CallbackRejected, streamWithTransport(std.testing.allocator, lifecycle.transportFor(), testModel(.anthropic_messages), .{
        .blocks = &blocks,
        .max_output_tokens = 1,
    }, {}, Reject.onEvent));
    try std.testing.expectEqual(@as(usize, 1), lifecycle.open_count);
    try std.testing.expectEqual(@as(usize, 1), lifecycle.deinit_count);
}

test "stream releases the response body after a truncated response" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    var lifecycle = LifecycleTransport{ .bytes = sseFrame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":1}}}
    ) };
    const Ignore = struct {
        fn onEvent(_: void, _: event.StreamEvent) !void {}
    };

    try std.testing.expectError(error.IncompleteStream, streamWithTransport(std.testing.allocator, lifecycle.transportFor(), testModel(.anthropic_messages), .{
        .blocks = &blocks,
        .max_output_tokens = 1,
    }, {}, Ignore.onEvent));
    try std.testing.expectEqual(@as(usize, 1), lifecycle.open_count);
    try std.testing.expectEqual(@as(usize, 1), lifecycle.deinit_count);
}

fn sseFrame(comptime json: []const u8) []const u8 {
    return "data: " ++ json ++ "\n\n";
}

test "generate preserves reasoning and joins every text block" {
    const reply = comptime sseFrame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":4}}}
    ) ++ sseFrame(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"why","signature":"sig"}}
    ) ++ sseFrame(
        \\{"type":"content_block_stop","index":0}
    ) ++ sseFrame(
        \\{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"A"}}
    ) ++ sseFrame(
        \\{"type":"content_block_stop","index":1}
    ) ++ sseFrame(
        \\{"type":"content_block_start","index":2,"content_block":{"type":"text","text":"B"}}
    ) ++ sseFrame(
        \\{"type":"content_block_stop","index":2}
    ) ++ sseFrame(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}
    ) ++ sseFrame(
        \\{"type":"message_stop"}
    );
    var canned = transport.CannedTransport{ .bytes = reply };
    var result_value = try generateTextWithTransport(std.testing.allocator, canned.transport(), .{
        .id = "claude-test",
        .provider = .{ .base_url = "https://example.test/v1", .protocol = .anthropic_messages, .auth = .none },
        .credential = .none,
    }, "hello", .{});
    defer result_value.deinit();

    try std.testing.expectEqualStrings("AB", result_value.text);
    try std.testing.expectEqual(@as(usize, 3), result_value.content.len);
    try std.testing.expectEqualStrings("why", result_value.content[0].reasoning.text);
    try std.testing.expectEqualStrings("sig", result_value.content[0].reasoning.signature);
}

test "generate preserves a completed tool call" {
    const reply = comptime sseFrame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":8}}}
    ) ++ sseFrame(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"run"}}
    ) ++ sseFrame(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"cmd\":\"zig test\"}"}}
    ) ++ sseFrame(
        \\{"type":"content_block_stop","index":0}
    ) ++ sseFrame(
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}
    ) ++ sseFrame(
        \\{"type":"message_stop"}
    );
    var canned = transport.CannedTransport{ .bytes = reply };
    var result_value = try generateTextWithTransport(std.testing.allocator, canned.transport(), .{
        .id = "claude-test",
        .provider = .{ .base_url = "https://example.test/v1", .protocol = .anthropic_messages, .auth = .none },
        .credential = .none,
    }, "hello", .{});
    defer result_value.deinit();

    try std.testing.expectEqual(types.FinishReason.tool_calls, result_value.finish_reason);
    const tool = result_value.content[0].tool_call;
    try std.testing.expectEqualStrings("toolu_1", tool.call_id);
    try std.testing.expectEqualStrings("run", tool.name);
    try std.testing.expectEqualStrings("{\"cmd\":\"zig test\"}", tool.arguments);
}
