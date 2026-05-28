const std = @import("std");
const http = std.http;

const RateLimiter = @import("http_client.zig").RateLimiter;
const CircuitBreaker = @import("http_client.zig").CircuitBreaker;
const AIMessage = @import("http_client.zig").AIMessage;
const AIResponse = @import("http_client.zig").AIResponse;
const RequestConfig = @import("http_client.zig").RequestConfig;

fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8, output: *std.ArrayList(u8)) !void {
    for (input) |c| {
        switch (c) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            else => try output.append(allocator, c),
        }
    }
}

pub const DeepSeekClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api_key: []const u8,
    endpoint: []const u8 = "https://api.deepseek.com",
    http_client: http.Client,
    rate_limiter: ?*RateLimiter = null,
    circuit_breaker: ?*CircuitBreaker = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8) DeepSeekClient {
        return .{
            .allocator = allocator,
            .io = io,
            .api_key = api_key,
            .http_client = http.Client{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *DeepSeekClient) void {
        self.http_client.deinit();
    }

    pub fn sendMessageWithContext(
        self: *DeepSeekClient,
        prompt: []const u8,
        context: []const AIMessage,
        config: RequestConfig,
    ) !AIResponse {
        if (self.circuit_breaker) |cb| {
            if (cb.isOpen()) return error.CircuitOpen;
        }
        if (self.rate_limiter) |rl| {
            try rl.wait();
        }

        const body = try buildRequestBody(self.allocator, prompt, context, config);
        defer self.allocator.free(body);

        const completions_uri = if (std.mem.endsWith(u8, self.endpoint, "/v1"))
            try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.endpoint})
        else
            try std.fmt.allocPrint(self.allocator, "{s}/v1/chat/completions", .{self.endpoint});
        defer self.allocator.free(completions_uri);

        const uri = try std.Uri.parse(completions_uri);

        const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_value);

        const headers = [_]http.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        };

        var request = try self.http_client.request(.POST, uri, .{
            .extra_headers = &headers,
        });
        try request.sendBodyComplete(body);
        errdefer request.deinit();

        var response = try request.receiveHead(undefined);
        const status = @intFromEnum(response.head.status);
        if (status < 200 or status >= 300) {
            if (self.circuit_breaker) |cb| cb.recordFailure();
            return error.HttpError;
        }
        if (self.circuit_breaker) |cb| cb.recordSuccess();

        const transfer_buffer = try self.allocator.alloc(u8, 65536);
        defer self.allocator.free(transfer_buffer);
        const body_reader = response.reader(transfer_buffer);
        const response_body = try body_reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(10 * 1024 * 1024),
        );
        defer self.allocator.free(response_body);

        return try parseChatResponse(self.allocator, response_body);
    }
};

fn buildRequestBody(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    context: []const AIMessage,
    config: RequestConfig,
) ![]u8 {
    var body = try std.ArrayList(u8).initCapacity(allocator, 2048);
    errdefer body.deinit(allocator);

    try body.appendSlice(allocator, "{\"model\":\"");
    try body.appendSlice(allocator, config.model);
    try body.appendSlice(allocator, "\",\"stream\":false,\"messages\":[");

    var first = true;
    if (config.system_prompt.len > 0) {
        try appendMessage(allocator, &body, "system", config.system_prompt);
        first = false;
    }
    for (context) |msg| {
        if (!first) try body.append(allocator, ',');
        try appendMessage(allocator, &body, msg.role, msg.content);
        first = false;
    }
    if (!first) try body.append(allocator, ',');
    try appendMessage(allocator, &body, "user", prompt);

    try body.appendSlice(allocator, "]}");
    return body.toOwnedSlice(allocator);
}

fn appendMessage(allocator: std.mem.Allocator, body: *std.ArrayList(u8), role: []const u8, content: []const u8) !void {
    try body.appendSlice(allocator, "{\"role\":\"");
    try body.appendSlice(allocator, role);
    try body.appendSlice(allocator, "\",\"content\":\"");
    try escapeJsonString(allocator, content, body);
    try body.appendSlice(allocator, "\"}");
}

const UsageJson = struct {
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
};

const ChatResponseJson = struct {
    choices: []struct {
        message: struct {
            content: ?[]const u8 = null,
        },
        finish_reason: ?[]const u8 = null,
    } = &.{},
    usage: ?UsageJson = null,
};

fn parseChatResponse(allocator: std.mem.Allocator, json_body: []const u8) !AIResponse {
    const parsed = try std.json.parseFromSlice(
        ChatResponseJson,
        allocator,
        json_body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) return error.InvalidResponse;
    const choice = parsed.value.choices[0];
    const content = choice.message.content orelse "";

    const content_copy = try allocator.dupe(u8, content);
    const stop_reason = if (choice.finish_reason) |reason|
        try allocator.dupe(u8, reason)
    else
        null;

    const usage = parsed.value.usage orelse UsageJson{};
    return .{
        .message = .{ .content = content_copy },
        .usage = .{
            .input_tokens = usage.prompt_tokens orelse 0,
            .output_tokens = usage.completion_tokens orelse 0,
        },
        .metadata = .{ .stop_reason = stop_reason },
    };
}

test "build non-stream request body" {
    const alloc = std.testing.allocator;
    const body = try buildRequestBody(alloc, "hello", &.{.{ .role = "assistant", .content = "hi" }}, .{
        .model = "deepseek-chat",
        .system_prompt = "sys",
    });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hello") != null);
}
