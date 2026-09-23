//! An AI call composes a route, a serializer, a transport, and a stream reducer.

const std = @import("std");
const event = @import("stream/event.zig");
const ir = @import("request/ir.zig");
const request_wire = @import("request.zig");
const stream_mod = @import("stream.zig");
const route = @import("route.zig");
const testing_transport = @import("testing.zig");
const transport = @import("transport.zig");
const types = @import("types.zig");

const model_types = @import("model.zig");

pub const Model = struct {
    /// The id the wire carries. Send the upstream id, because a gateway may rename the model.
    id: []const u8,
    route: route.Route,
    credential: route.Credential,
    /// The resolved model capabilities.
    caps: model_types.Caps = .{},
    dialect: model_types.Dialect = .{},
    /// The output limit fills a request that names none.
    limits: model_types.Limits = .{},
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
    /// A null limit takes the model limit, or the endpoint default when the model states none.
    max_output_tokens: ?u32 = null,
    reasoning: ir.ReasoningControl = .default,
    /// Constrain the response to a schema. A null schema leaves the response free.
    output_schema: ?ir.OutputSchema = null,
    /// Sampling temperature. A null value leaves the endpoint default.
    temperature: ?f64 = null,
    /// Nucleus sampling mass. A null value leaves the endpoint default.
    top_p: ?f64 = null,
    /// One stable id per session. The route uses it for a header and for the Responses cache key.
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

    /// Use `gpa` for call storage until the caller invokes `Response.deinit`.
    pub fn open(self: *Client, gpa: std.mem.Allocator, model: Model, request: Request) !Response {
        return openWithTransport(gpa, self.http.transportFor(), model, request, null);
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
    var response = try openWithTransport(gpa, route_transport, model, request, diagnostics);
    defer response.deinit();
    var collector = Collector.init(gpa);
    errdefer collector.deinit();
    // Copy the diagnostics before the attempt storage is released.
    errdefer if (diagnostics) |d| d.keep(response.info());
    while (try response.next()) |value| try collector.onEvent(value);
    return collector.result();
}

/// One call in flight. It owns the prepared request, the attempt storage, the response body, and the stream.
pub const Response = struct {
    gpa: std.mem.Allocator,
    /// The stream points into this state, so it has a fixed address.
    state: *State,

    const State = struct {
        prepared: PreparedRequest,
        attempt: std.heap.ArenaAllocator,
        info: transport.AttemptInfo,
        body: transport.ResponseBody,
        stream: stream_mod.Stream,
    };

    /// Answer the next event, or null at the end. Event slices expire at the next call.
    pub fn next(self: Response) !?event.StreamEvent {
        return self.state.stream.next();
    }

    /// What the attempt learned: the retry hints, the request id, and a failed stream's error event.
    pub fn info(self: Response) *const transport.AttemptInfo {
        return &self.state.info;
    }

    pub fn deinit(self: *Response) void {
        const state = self.state;
        // The stream borrows the body, so the stream ends first.
        state.stream.deinit();
        state.body.deinit();
        state.attempt.deinit();
        state.prepared.deinit();
        self.gpa.destroy(state);
        self.* = undefined;
    }
};

/// Use `gpa` for call storage until `Response.deinit`; a failure to open fills `diagnostics` when the caller passes one.
pub fn openWithTransport(gpa: std.mem.Allocator, route_transport: transport.Transport, model: Model, request: Request, diagnostics: ?*Diagnostics) !Response {
    const state = try gpa.create(Response.State);
    errdefer gpa.destroy(state);
    state.prepared = try prepare(gpa, model, request);
    errdefer state.prepared.deinit();
    state.attempt = .init(gpa);
    errdefer state.attempt.deinit();
    state.info = .{};
    // Copy the diagnostics before the attempt storage is released.
    errdefer if (diagnostics) |d| d.keep(&state.info);
    state.body = try route_transport.open(state.attempt.allocator(), state.prepared.transport_request, &state.info);
    state.stream = .init(gpa, state.attempt.allocator(), state.body, &state.info, state.prepared.protocol);
    return .{ .gpa = gpa, .state = state };
}

/// Hold the provider answer of a failed call; the call copies it into `arena` only on a failure.
pub const Diagnostics = struct {
    arena: std.mem.Allocator,
    info: transport.AttemptInfo = .{},

    fn keep(self: *Diagnostics, info: *const transport.AttemptInfo) void {
        self.info = info.*;
        // A caller arena that runs out drops the optional copies; the classification fields stay.
        self.info.request_id = if (info.request_id) |id| self.arena.dupe(u8, id) catch null else null;
        self.info.body = if (info.body) |body| self.arena.dupe(u8, body) catch null else null;
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

fn requestBody(arena: std.mem.Allocator, model: Model, request: Request) ![]u8 {
    const options = request.options;
    const protocol = model.route.protocol;
    const cache = route.CachePolicy.breakpoint(model.route.cache, protocol, model.caps.cache_breakpoint);
    const model_limit: ?u32 = if (model.limits.max_output_tokens) |limit| std.math.cast(u32, limit) orelse std.math.maxInt(u32) else null;
    const value: ir.Request = .{
        .model = model.id,
        .wire = switch (protocol) {
            .anthropic_messages => .{ .anthropic_messages = .{ .cache = cache } },
            .openai_chat => .{ .openai_chat = .{
                .thinking_format = model.dialect.thinking_format,
                .reasoning_replay = model.dialect.reasoning_replay,
                .max_tokens_field = model.dialect.max_tokens_field,
            } },
            .openai_responses => .{ .openai_responses = .{
                .dialect = model.route.responses_dialect,
                .cache = cache,
                .cache_key = options.session_id,
            } },
        },
        .system = request.system,
        .tools = request.tools,
        .max_output_tokens = options.max_output_tokens orelse model_limit,
        .reasoning = options.reasoning,
        .output_schema = options.output_schema,
        .temperature = options.temperature,
        .top_p = options.top_p,
        .tool_choice = options.tool_choice,
    };
    return request_wire.serialize(arena, value, request.blocks);
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
        .limits = .{ .max_output_tokens = 64 },
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
        .{ types.Protocol.anthropic_messages, testing_transport.canned_reply, "Hello from the mock provider.", 8 },
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

test "a response releases its body once after a full read, an early stop, and a truncation" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    for ([_]struct { name: []const u8, bytes: []const u8, stop_early: bool, want: ?anyerror }{
        .{ .name = "success", .bytes = testing_transport.canned_reply, .stop_early = false, .want = null },
        .{ .name = "early stop", .bytes = testing_transport.canned_reply, .stop_early = true, .want = null },
        .{ .name = "truncation", .bytes = testing_transport.sseFrame(
            \\{"type":"message_start","message":{"usage":{"input_tokens":1}}}
        ), .stop_early = false, .want = error.IncompleteStream },
    }) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var lifecycle = LifecycleTransport{ .bytes = case.bytes };
        var response = try openWithTransport(std.testing.allocator, lifecycle.transportFor(), testModel(.anthropic_messages), .{
            .blocks = &blocks,
            .options = .{ .max_output_tokens = 1 },
        }, null);
        var seen: usize = 0;
        const drained: anyerror!void = while (response.next()) |value| {
            if (value == null) break;
            seen += 1;
            if (case.stop_early) break;
        } else |err| err;
        response.deinit();
        if (case.want) |want| try std.testing.expectError(want, drained) else {
            try drained;
            try std.testing.expect(seen > 0);
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

test "prepare and a stream split the request lifecycle" {
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
    var stream = stream_mod.Stream.init(std.testing.allocator, attempt.allocator(), body, &info, prepared.protocol);
    defer stream.deinit();
    var event_count: usize = 0;
    while (try stream.next()) |_| event_count += 1;
    try std.testing.expect(event_count > 0);
}

test "a request without a limit takes the model limit, and an absent one leaves the endpoint default" {
    const blocks = [_]ir.Block{.{ .role = .user, .value = .{ .text = "hello" } }};
    var from_model = try prepare(std.testing.allocator, testModel(.anthropic_messages), .{ .blocks = &blocks });
    defer from_model.deinit();
    try std.testing.expect(std.mem.indexOf(u8, from_model.transport_request.body, "\"max_tokens\":64") != null);
    var bare = testModel(.openai_chat);
    bare.limits = .{};
    var omitted = try prepare(std.testing.allocator, bare, .{ .blocks = &blocks });
    defer omitted.deinit();
    try std.testing.expect(std.mem.indexOf(u8, omitted.transport_request.body, "max_tokens") == null);
    // Anthropic has no endpoint default, so a model without a limit needs one in the request.
    bare.route.protocol = .anthropic_messages;
    try std.testing.expectError(error.InvalidRequest, prepare(std.testing.allocator, bare, .{ .blocks = &blocks }));
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
