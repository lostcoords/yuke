//! An AI call composes a route, a serializer, a transport, and a stream reducer.

const std = @import("std");
const adapter = @import("adapter.zig");
const event = @import("stream/event.zig");
const ir = @import("request/ir.zig");
const route = @import("route.zig");
const testing_transport = @import("testing.zig");
const transport = @import("transport.zig");
const types = @import("types.zig");

const model_types = @import("model.zig");

pub const Model = struct {
    id: []const u8,
    route: route.Route,
    credential: route.Credential,
    /// The resolved model capabilities.
    caps: model_types.Caps = .{},
    dialect: model_types.Dialect = .{},
};

/// What one call sends. The blocks, the system text, and the tools are the content of the turn.
pub const Request = struct {
    blocks: []const ir.Block,
    system: []const u8 = "",
    tools: []const ir.Tool = &.{},
    options: Options = .{},
};

/// Provider-neutral controls over how the model answers.
pub const Options = struct {
    max_output_tokens: u32 = 1024,
    reasoning: ir.ReasoningControl = .default,
    /// Constrain the response to a schema. A null schema leaves the response free.
    output_schema: ?ir.OutputSchema = null,
    /// Sampling temperature. A null value leaves the endpoint default.
    temperature: ?f64 = null,
    /// Nucleus sampling mass. A null value leaves the endpoint default.
    top_p: ?f64 = null,
    /// One stable key per session. Only Responses reads it, and it routes a repeated prefix to one cache.
    cache_key: []const u8 = "",
    /// One stable id per session. The route decides which header carries it, and some routes carry none.
    session_id: []const u8 = "",
    /// Whether the model may call a tool.
    tool_choice: ir.ToolChoice = .auto,
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

/// Own all returned slices until `deinit` releases storage through the call allocator.
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

/// Own the request bytes and the route data it needs, so a retry can resend it unchanged.
pub const PreparedRequest = struct {
    arena: std.heap.ArenaAllocator,
    protocol: types.Protocol,
    transport_request: transport.Request,

    /// Release the request bytes and route data.
    pub fn deinit(self: *PreparedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Client = struct {
    http: transport.HttpTransport,

    pub const InitOptions = struct {
        idle_timeout: ?std.Io.Duration = null,
        /// The name every request carries. A gateway wants an agent name, not a library name.
        user_agent: []const u8,
    };

    /// Use `gpa` for HTTP state until `deinit` runs after every response body closes.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: InitOptions) Client {
        return .{ .http = .init(gpa, io, options.idle_timeout, options.user_agent) };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
        self.* = undefined;
    }

    /// Use `gpa` for call storage until the caller invokes `Result.deinit`.
    pub fn generate(self: *Client, gpa: std.mem.Allocator, model: Model, request: Request) !Result {
        return generateWithTransport(gpa, self.http.transportFor(), model, request, null);
    }

    /// Use `gpa` for call storage until the caller invokes `Result.deinit`.
    pub fn generateText(self: *Client, gpa: std.mem.Allocator, model: Model, prompt: []const u8, options: Options) !Result {
        return generateTextWithTransport(gpa, self.http.transportFor(), model, prompt, options);
    }

    /// Use `gpa` for call storage until this function returns.
    pub fn stream(
        self: *Client,
        gpa: std.mem.Allocator,
        model: Model,
        request: Request,
        context: anytype,
        comptime onEvent: fn (@TypeOf(context), event.StreamEvent) anyerror!void,
    ) !void {
        return streamWithTransport(gpa, self.http.transportFor(), model, request, null, context, onEvent);
    }
};

/// Use `gpa` for call storage until the caller invokes `Result.deinit`.
pub fn generateTextWithTransport(gpa: std.mem.Allocator, route_transport: transport.Transport, model: Model, prompt: []const u8, options: Options) !Result {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = prompt } }};
    return generateWithTransport(gpa, route_transport, model, .{
        .blocks = &blocks,
        .options = options,
    }, null);
}

/// Use `gpa` for call storage until the caller invokes `Result.deinit`; a failure fills `diagnostics` when the caller passes one.
pub fn generateWithTransport(gpa: std.mem.Allocator, route_transport: transport.Transport, model: Model, request: Request, diagnostics: ?*Diagnostics) !Result {
    var collector = Collector.init(gpa);
    errdefer collector.deinit();
    try streamWithTransport(gpa, route_transport, model, request, diagnostics, &collector, Collector.onEvent);
    return collector.result();
}

/// Hold the provider answer of a failed call; the call copies it into `arena` only on a failure.
pub const Diagnostics = struct {
    arena: std.mem.Allocator,
    info: transport.AttemptInfo = .{},

    fn keep(self: *Diagnostics, info: *const transport.AttemptInfo) void {
        self.info = info.*;
        self.info.request_id = if (info.request_id) |id| self.arena.dupe(u8, id) catch unreachable else null;
        self.info.body = if (info.body) |body| self.arena.dupe(u8, body) catch unreachable else null;
    }
};

/// Use `gpa` to own the validated request and route data until `PreparedRequest.deinit` runs.
pub fn prepare(gpa: std.mem.Allocator, model: Model, request: Request) !PreparedRequest {
    if (request.blocks.len == 0) return error.EmptyRequest;
    var call_arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer call_arena.deinit();
    const arena = call_arena.allocator();

    const body_bytes = try requestBody(arena, model, request);
    // `route.request` copies the URL and every header, so the route and the credential may change.
    const http_request = try route.request(arena, &model.route, model.credential, request.options.session_id, body_bytes);
    return .{
        .arena = call_arena,
        .protocol = model.route.protocol,
        .transport_request = http_request,
    };
}

/// Use `gpa` until return; event slices expire after each callback and this function closes the response body.
pub fn streamWithTransport(
    gpa: std.mem.Allocator,
    route_transport: transport.Transport,
    model: Model,
    request: Request,
    diagnostics: ?*Diagnostics,
    context: anytype,
    comptime onEvent: fn (@TypeOf(context), event.StreamEvent) anyerror!void,
) !void {
    var prepared = try prepare(gpa, model, request);
    defer prepared.deinit();

    // The attempt storage dies with this call, while the prepared request outlives every attempt.
    var attempt: std.heap.ArenaAllocator = .init(gpa);
    defer attempt.deinit();
    var info: transport.AttemptInfo = .{};
    // The attempt arena dies here, so a failure copies what the provider answered first.
    errdefer if (diagnostics) |d| d.keep(&info);
    const body = try route_transport.open(attempt.allocator(), prepared.transport_request, &info);
    defer body.deinit();

    try consume(gpa, attempt.allocator(), body, &info, prepared.protocol, context, onEvent);
}

fn requestBody(arena: std.mem.Allocator, model: Model, request: Request) ![]u8 {
    const options = request.options;
    const value: ir.Request = .{
        .model = model.id,
        .system = request.system,
        .tools = request.tools,
        .max_output_tokens = options.max_output_tokens,
        .reasoning = options.reasoning,
        .thinking_format = model.dialect.thinking_format,
        .reasoning_replay = model.dialect.reasoning_replay,
        .max_tokens_field = model.dialect.max_tokens_field,
        .responses_dialect = model.route.responses_dialect,
        .cache = route.CachePolicy.markerFor(model.route.cache, model.caps.cache_breakpoint),
        .cache_key = options.cache_key,
        .output_schema = options.output_schema,
        .temperature = options.temperature,
        .top_p = options.top_p,
        .tool_choice = options.tool_choice,
    };
    return adapter.serialize(arena, model.route.protocol, value, request.blocks);
}

/// Use `gpa` for scratch until return; the caller owns the body, `arena`, and `info`, which keeps an error event.
pub fn consume(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: transport.ResponseBody,
    info: *transport.AttemptInfo,
    protocol: types.Protocol,
    context: anytype,
    comptime onEvent: fn (@TypeOf(context), event.StreamEvent) anyerror!void,
) !void {
    switch (protocol) {
        inline else => |value| {
            var reducer = adapter.Adapter(value).Reducer.init(gpa);
            defer reducer.deinit();
            try transport.stream(gpa, arena, body, info, &reducer, context, onEvent);
        },
    }
}

const Collector = struct {
    gpa: std.mem.Allocator,
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
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    fn deinit(self: *Collector) void {
        self.deinitBlocks();
        self.arena.deinit();
        self.* = undefined;
    }

    fn deinitBlocks(self: *Collector) void {
        for (self.blocks.items) |*block| block.bytes.deinit(self.gpa);
        self.blocks.deinit(self.gpa);
    }

    fn onEvent(self: *Collector, value: event.StreamEvent) !void {
        const arena = self.arena.allocator();
        switch (value) {
            .block_started => |started| {
                std.debug.assert(started.block == self.blocks.items.len);
                try self.blocks.append(self.gpa, .{ .kind = started.kind });
            },
            .text_delta => |delta| try self.append(delta.block, delta.text),
            .reasoning_delta => |delta| try self.append(delta.block, delta.text),
            .tool_input_delta => {},
            .block_stopped => |stopped| {
                const current = self.getBlock(stopped.block);
                std.debug.assert(!current.stopped);
                current.stopped = true;
                current.result = try stopped.result.cloneLeaky(arena);
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
        try current.bytes.appendSlice(self.gpa, bytes);
    }

    fn getBlock(self: *Collector, id: event.BlockId) *Block {
        const index: usize = @intCast(id);
        std.debug.assert(index < self.blocks.items.len);
        return &self.blocks.items[index];
    }

    /// Copy every accumulated block into one arena buffer, so `Result` owns its bytes as a whole.
    fn result(self: *Collector) !Result {
        const done = self.done.?;
        const arena = self.arena.allocator();
        var content_len: usize = 0;

        // The text blocks lead the buffer, so `Result.text` is the joined prefix and needs no second copy.
        var text_len: usize = 0;
        var total_len: usize = 0;
        for (self.blocks.items) |current| {
            if (!current.stopped) {
                if (current.kind == .tool) continue;
                return error.Protocol;
            }
            content_len += 1;
            switch (current.result.?) {
                .text => text_len = try std.math.add(usize, text_len, current.bytes.items.len),
                .reasoning => {},
                else => continue,
            }
            total_len = try std.math.add(usize, total_len, current.bytes.items.len);
        }
        const content = try arena.alloc(Content, content_len);
        const bytes = try arena.alloc(u8, total_len);
        var text_offset: usize = 0;
        var tail_offset: usize = text_len;

        var content_index: usize = 0;
        for (self.blocks.items) |current| {
            if (!current.stopped) continue;
            content[content_index] = switch (current.result.?) {
                .text => .{ .text = take(bytes, &text_offset, current.bytes.items) },
                .reasoning => |reasoning| .{ .reasoning = .{
                    .text = take(bytes, &tail_offset, current.bytes.items),
                    .signature = reasoning.signature,
                } },
                .redacted_reasoning => |redacted| .{ .redacted_reasoning = redacted.data },
                .tool => |tool| .{ .tool_call = .{ .call_id = tool.call_id, .name = tool.name, .arguments = tool.arguments } },
            };
            content_index += 1;
        }
        std.debug.assert(content_index == content.len);
        std.debug.assert(text_offset == text_len);
        std.debug.assert(tail_offset == total_len);

        const result_value: Result = .{
            .arena = self.arena,
            .content = content,
            .text = bytes[0..text_len],
            .finish_reason = done.stop_reason,
            .raw_finish_reason = done.raw_stop_reason,
            .usage = done.usage,
        };
        self.deinitBlocks();
        self.* = undefined;
        return result_value;
    }

    /// Copy `source` into `bytes` at `offset`, and advance `offset` past it.
    fn take(bytes: []u8, offset: *usize, source: []const u8) []const u8 {
        const target = bytes[offset.*..][0..source.len];
        @memcpy(target, source);
        offset.* += source.len;
        return target;
    }
};

const LifecycleTransport = struct {
    bytes: []const u8,
    open_count: usize = 0,
    deinit_count: usize = 0,

    fn transportFor(self: *LifecycleTransport) transport.Transport {
        return .{ .ctx = self, .vtable = &transport_vtable };
    }

    const Body = struct {
        reader: testing_transport.ReplayReader,
        owner: *LifecycleTransport,

        fn responseBody(self: *Body) transport.ResponseBody {
            return .{ .ctx = self, .vtable = &body_vtable };
        }

        fn peek(ctx: *anyopaque) anyerror![]const u8 {
            const self: *Body = @ptrCast(@alignCast(ctx));
            return self.reader.body().peek();
        }

        fn toss(ctx: *anyopaque, count: usize) void {
            const self: *Body = @ptrCast(@alignCast(ctx));
            self.reader.body().toss(count);
        }

        fn deinit(ctx: *anyopaque) void {
            const self: *Body = @ptrCast(@alignCast(ctx));
            self.owner.deinit_count += 1;
        }

        const body_vtable: transport.ResponseBody.VTable = .{ .peek = peek, .toss = toss, .deinit = deinit };
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
        .route = .{ .base_url = "https://example.test/v1", .protocol = protocol, .auth = .none },
        .credential = .none,
    };
}

test "generate dispatches every protocol through its serializer and reducer" {
    const chat_reply = comptime testing_transport.sseFrame(
        \\{"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":"stop"}]}
    ) ++ "data: [DONE]\n\n";
    const responses_reply = comptime testing_transport.sseFrame(
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}
    ) ++ testing_transport.sseFrame(
        \\{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}
    ) ++ testing_transport.sseFrame(
        \\{"type":"response.output_text.delta","output_index":0,"delta":"Hello"}
    ) ++ testing_transport.sseFrame(
        \\{"type":"response.output_text.done","output_index":0}
    ) ++ testing_transport.sseFrame(
        \\{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}
    );

    inline for (.{
        .{ types.Protocol.anthropic_messages, testing_transport.canned_reply, "Hello from the yuke mock provider.", 8 },
        .{ types.Protocol.openai_chat, chat_reply, "Hello", 0 },
        .{ types.Protocol.openai_responses, responses_reply, "Hello", 1 },
    }) |case| {
        var canned = testing_transport.CannedTransport{ .bytes = case[1] };
        var result_value = try generateTextWithTransport(std.testing.allocator, canned.transport(), testModel(case[0]), "hello", .{});
        defer result_value.deinit();
        try std.testing.expectEqualStrings(case[2], result_value.text);
        try std.testing.expectEqual(types.FinishReason.stop, result_value.finish_reason);
        try std.testing.expectEqual(@as(u64, case[3]), result_value.usage.output);
    }
}

test "generate rejects an empty request before transport I/O" {
    var lifecycle = LifecycleTransport{ .bytes = testing_transport.canned_reply };
    try std.testing.expectError(error.EmptyRequest, generateWithTransport(std.testing.allocator, lifecycle.transportFor(), testModel(.openai_chat), .{
        .blocks = &.{},
        .options = .{ .max_output_tokens = 1 },
    }, null));
    try std.testing.expectEqual(@as(usize, 0), lifecycle.open_count);
    try std.testing.expectEqual(@as(usize, 0), lifecycle.deinit_count);
}

test "stream releases the response body once on success, a callback error, and a truncation" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    const Sink = struct {
        fail: bool,
        seen: usize = 0,
        fn onEvent(self: *@This(), _: event.StreamEvent) !void {
            if (self.fail) return error.CallbackRejected;
            self.seen += 1;
        }
    };
    for ([_]struct { name: []const u8, bytes: []const u8, fail: bool, want: ?anyerror }{
        .{ .name = "success", .bytes = testing_transport.canned_reply, .fail = false, .want = null },
        .{ .name = "callback error", .bytes = testing_transport.canned_reply, .fail = true, .want = error.CallbackRejected },
        .{ .name = "truncation", .bytes = testing_transport.sseFrame(
            \\{"type":"message_start","message":{"usage":{"input_tokens":1}}}
        ), .fail = false, .want = error.IncompleteStream },
    }) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var lifecycle = LifecycleTransport{ .bytes = case.bytes };
        var sink: Sink = .{ .fail = case.fail };
        const result = streamWithTransport(std.testing.allocator, lifecycle.transportFor(), testModel(.anthropic_messages), .{
            .blocks = &blocks,
            .options = .{ .max_output_tokens = 1 },
        }, null, &sink, Sink.onEvent);
        if (case.want) |want| try std.testing.expectError(want, result) else {
            try result;
            try std.testing.expect(sink.seen > 0);
        }
        try std.testing.expectEqual(@as(usize, 1), lifecycle.open_count);
        try std.testing.expectEqual(@as(usize, 1), lifecycle.deinit_count);
    }
}
test "a failed call keeps the provider answer in the caller diagnostics" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const failed_event =
        \\{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
    ;
    var canned = testing_transport.CannedTransport{ .bytes = testing_transport.sseFrame(failed_event) };
    var diagnostics: Diagnostics = .{ .arena = arena.allocator() };
    try std.testing.expectError(error.ServerError, generateWithTransport(std.testing.allocator, canned.transport(), testModel(.anthropic_messages), .{
        .blocks = &.{.{ .role = .user, .value = .{ .text = "hello" } }},
        .options = .{ .max_output_tokens = 1 },
    }, &diagnostics));
    // The attempt arena is gone, so this read proves the copy.
    try std.testing.expectEqualStrings(failed_event, diagnostics.info.body.?);
}

test "prepare and consume split request lifecycle" {
    var canned = testing_transport.CannedTransport{ .bytes = testing_transport.canned_reply };
    var prepared = try prepare(std.testing.allocator, testModel(.anthropic_messages), .{
        .blocks = &.{.{ .role = .user, .value = .{ .text = "hello" } }},
        .options = .{ .max_output_tokens = 1 },
    });
    defer prepared.deinit();

    try std.testing.expectEqual(types.Protocol.anthropic_messages, prepared.protocol);
    try std.testing.expect(std.mem.endsWith(u8, prepared.transport_request.url, "/messages"));
    try std.testing.expect(prepared.transport_request.body.len > 0);

    var attempt: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer attempt.deinit();
    var info: transport.AttemptInfo = .{};
    const body = try canned.transport().open(attempt.allocator(), prepared.transport_request, &info);
    defer body.deinit();
    var event_count: usize = 0;
    const Counter = struct {
        fn onEvent(count: *usize, _: event.StreamEvent) !void {
            count.* += 1;
        }
    };
    try consume(std.testing.allocator, attempt.allocator(), body, &info, prepared.protocol, &event_count, Counter.onEvent);
    try std.testing.expect(event_count > 0);
}

test "a client names its user agent at init" {
    var client = Client.init(std.testing.allocator, std.testing.io, .{ .user_agent = "acme/1.0" });
    defer client.deinit();
    try std.testing.expectEqualStrings("acme/1.0", client.http.user_agent);
}

test "prepare owns route and credential strings" {
    var base_url = [_]u8{ 'h', 't', 't', 'p', 's', ':', '/', '/', 'a', '.', 't', 'e', 's', 't', '/', 'v', '1' };
    var token = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    var header_value = [_]u8{ 'p', 'i', 'n', 'n', 'e', 'd' };
    var prepared = try prepare(std.testing.allocator, .{
        .id = "test-model",
        .route = .{
            .base_url = &base_url,
            .protocol = .openai_chat,
            .auth = .{ .api_key = .authorization_bearer },
            .headers = &.{.{ .name = "x-test", .value = &header_value }},
        },
        .credential = .{ .api_key = &token },
    }, .{ .blocks = &.{.{ .role = .user, .value = .{ .text = "hello" } }} });
    defer prepared.deinit();

    @memset(&base_url, 'x');
    @memset(&token, 'x');
    @memset(&header_value, 'x');
    try std.testing.expectEqualStrings("https://a.test/v1/chat/completions", prepared.transport_request.url);
    try std.testing.expectEqualStrings("Bearer secret", prepared.transport_request.headers[0].value);
    try std.testing.expectEqualStrings("pinned", prepared.transport_request.headers[1].value);
}

test "generate preserves reasoning and joins every text block" {
    const reply = comptime testing_transport.sseFrame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":4}}}
    ) ++ testing_transport.sseFrame(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"why","signature":"sig"}}
    ) ++ testing_transport.sseFrame(
        \\{"type":"content_block_stop","index":0}
    ) ++ testing_transport.sseFrame(
        \\{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"A"}}
    ) ++ testing_transport.sseFrame(
        \\{"type":"content_block_stop","index":1}
    ) ++ testing_transport.sseFrame(
        \\{"type":"content_block_start","index":2,"content_block":{"type":"text","text":"B"}}
    ) ++ testing_transport.sseFrame(
        \\{"type":"content_block_stop","index":2}
    ) ++ testing_transport.sseFrame(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}
    ) ++ testing_transport.sseFrame(
        \\{"type":"message_stop"}
    );
    var canned = testing_transport.CannedTransport{ .bytes = reply };
    var result_value = try generateTextWithTransport(std.testing.allocator, canned.transport(), testModel(.anthropic_messages), "hello", .{});
    defer result_value.deinit();

    try std.testing.expectEqualStrings("AB", result_value.text);
    try std.testing.expectEqual(@as(usize, 3), result_value.content.len);
    try std.testing.expectEqualStrings("why", result_value.content[0].reasoning.text);
    try std.testing.expectEqualStrings("sig", result_value.content[0].reasoning.signature);
    // Each block keeps its own slice, so the joined text must not blur the block boundary.
    try std.testing.expectEqualStrings("A", result_value.content[1].text);
    try std.testing.expectEqualStrings("B", result_value.content[2].text);
}

test "generate preserves a completed tool call" {
    const reply = comptime testing_transport.sseFrame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":8}}}
    ) ++ testing_transport.sseFrame(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"run"}}
    ) ++ testing_transport.sseFrame(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"cmd\":\"zig test\"}"}}
    ) ++ testing_transport.sseFrame(
        \\{"type":"content_block_stop","index":0}
    ) ++ testing_transport.sseFrame(
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}
    ) ++ testing_transport.sseFrame(
        \\{"type":"message_stop"}
    );
    var canned = testing_transport.CannedTransport{ .bytes = reply };
    var result_value = try generateTextWithTransport(std.testing.allocator, canned.transport(), testModel(.anthropic_messages), "hello", .{});
    defer result_value.deinit();

    try std.testing.expectEqual(types.FinishReason.tool_calls, result_value.finish_reason);
    const tool = result_value.content[0].tool_call;
    try std.testing.expectEqualStrings("toolu_1", tool.call_id);
    try std.testing.expectEqualStrings("run", tool.name);
    try std.testing.expectEqualStrings("{\"cmd\":\"zig test\"}", tool.arguments);
}

test "generate drops a tool call the Responses reducer leaves unfinished" {
    const reply = comptime testing_transport.sseFrame(
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call","name":"read"}}
    ) ++ testing_transport.sseFrame(
        \\{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{}}}
    );
    var canned: testing_transport.CannedTransport = .{ .bytes = reply };
    var result_value = try generateTextWithTransport(std.testing.allocator, canned.transport(), testModel(.openai_responses), "read", .{});
    defer result_value.deinit();
    try std.testing.expectEqual(@as(usize, 0), result_value.content.len);
    try std.testing.expectEqual(types.FinishReason.length, result_value.finish_reason);
}
