const std = @import("std");
const c = @import("c");

const SockaddrIn = extern struct {
    sin_len: u8 = @sizeOf(SockaddrIn),
    sin_family: u8,
    sin_port: u16,
    sin_addr: u32,
    sin_zero: [8]u8 = @splat(0),
};

const circuit_breaker_mod = @import("net/circuit_breaker.zig");
const rate_limiter_mod = @import("net/rate_limiter.zig");
const CircuitBreaker = circuit_breaker_mod.CircuitBreaker;
const RateLimiter = rate_limiter_mod.RateLimiter;
const reasonix_mod = @import("cache/reasonix.zig");
const loop_mod = @import("dispatch/cache_first_loop.zig");
const CacheFirstLoop = loop_mod.CacheFirstLoop;

pub const ChatRequest = struct {
    messages: []const ChatMessage,
    model: ?[]const u8 = null,
    stream: ?bool = null,
};

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    port: u16,
    running: std.atomic.Value(bool),
    sockfd: i32 = -1,
    loop: ?*CacheFirstLoop = null,
    reasonix: ?*reasonix_mod.Reasonix = null,
    circuit_breaker: CircuitBreaker,
    rate_limiter: RateLimiter,

    pub fn init(allocator: std.mem.Allocator, port: u16) !HttpServer {
        return .{
            .allocator = allocator,
            .port = port,
            .running = std.atomic.Value(bool).init(false),
            .sockfd = -1,
            .loop = null,
            .reasonix = null,
            .circuit_breaker = CircuitBreaker.init(.{}),
            .rate_limiter = RateLimiter.init(allocator, .{
                .max_requests = 100,
                .window_ms = 60000,
                .burst_size = 10,
            }),
        };
    }

    pub fn deinit(self: *HttpServer) void {
        self.stop();
        if (self.sockfd >= 0) {
            _ = c.close(self.sockfd);
            self.sockfd = -1;
        }
        self.rate_limiter.deinit();
    }

    pub fn setLoop(self: *HttpServer, loop: *CacheFirstLoop) void {
        self.loop = loop;
    }

    pub fn setReasonix(self: *HttpServer, reasonix: *reasonix_mod.Reasonix) void {
        self.reasonix = reasonix;
    }

    pub fn start(self: *HttpServer) !void {
        const sockfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (sockfd < 0) return error.SocketCreateFailed;
        errdefer { _ = c.close(sockfd); }

        var opt: i32 = 1;
        _ = c.setsockopt(sockfd, c.SOL_SOCKET, c.SO_REUSEADDR, @ptrCast(&opt), @sizeOf(i32));

        var addr: SockaddrIn = .{
            .sin_len = @sizeOf(SockaddrIn),
            .sin_family = @as(u8, @intCast(c.AF_INET)),
            .sin_port = c.htons(self.port),
            .sin_addr = 0,
            .sin_zero = @splat(0),
        };
        const bind_result = c.bind(sockfd, @ptrCast(&addr), @sizeOf(SockaddrIn));
        if (bind_result < 0) return error.BindFailed;
        if (c.listen(sockfd, 128) < 0) return error.ListenFailed;

        self.sockfd = sockfd;
        self.running.store(true, .seq_cst);

        std.debug.print("[HTTP] Server listening on http://0.0.0.0:{d}/\n", .{self.port});
        std.debug.print("[HTTP] Endpoints:\n", .{});
        std.debug.print("[HTTP]   GET  /health    - Health check\n", .{});
        std.debug.print("[HTTP]   GET  /sessions - List sessions\n", .{});
        std.debug.print("[HTTP]   POST /chat     - Send chat message\n", .{});

        while (self.running.load(.seq_cst)) {
            const conn_fd = c.accept(sockfd, null, null);
            if (conn_fd < 0) {
                if (self.running.load(.seq_cst)) {
                    std.debug.print("[HTTP] Accept error: errno={d}\n", .{conn_fd});
                }
                continue;
            }
            handleConnection(self, conn_fd);
        }
    }

    pub fn stop(self: *HttpServer) void {
        self.running.store(false, .seq_cst);
        if (self.sockfd >= 0) {
            _ = c.close(self.sockfd);
            self.sockfd = -1;
        }
    }
};

fn handleConnection(ctx: *HttpServer, conn_fd: i32) void {
    defer { _ = c.close(conn_fd); }

    var buf: [8192]u8 = undefined;
    const n = c.read(conn_fd, &buf, buf.len);
    if (n <= 0) return;

    const request = buf[0..@as(usize, @intCast(n))];

    const request_line_end = std.mem.indexOfScalar(u8, request, '\r') orelse return;
    const request_line = request[0..request_line_end];
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return;
    const path = parts.next() orelse "/";

    if (ctx.rate_limiter.check("default")) {
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/health")) {
            handleHealth(conn_fd, ctx) catch return;
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/sessions")) {
            handleListSessions(conn_fd, ctx) catch return;
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/chat")) {
            handleChat(conn_fd, request, ctx) catch return;
        } else {
            sendJson(conn_fd, 404, "{\"error\":\"not found\"}") catch return;
        }
    } else {
        sendJson(conn_fd, 429, "{\"error\":\"rate limit exceeded\"}") catch return;
    }
}

fn sendJson(conn_fd: i32, status: u16, body: []const u8) !void {
    var header_buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 {d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
        .{ status, body.len });
    _ = c.write(conn_fd, header.ptr, header.len);
    _ = c.write(conn_fd, body.ptr, body.len);
}

fn handleHealth(conn_fd: i32, ctx: *HttpServer) !void {
    const cache_hit_rate = if (ctx.reasonix) |r| r.hitRate() else 0.0;
    const state = ctx.circuit_breaker.getState();
    const state_str: []const u8 = switch (state) {
        .closed => "closed",
        .open => "open",
        .half_open => "half_open",
    };
    var body_buf: [128]u8 = undefined;
    var rate_buf: [32]u8 = undefined;
    const rate_result = std.fmt.float.render(&rate_buf, cache_hit_rate, .{ .precision = @as(usize, 4) });
    const rate_str = rate_result catch "0.0000";
    const body = try std.fmt.bufPrint(&body_buf,
        " {{\"status\":\"{s}\",\"version\":\"{s}\",\"cache_hit_rate\":{s},\"circuit_breaker\":\"{s}\"}}",
        .{ "ok", "0.1.0", rate_str, state_str });
    try sendJson(conn_fd, 200, body);
}

fn handleListSessions(conn_fd: i32, ctx: *HttpServer) !void {
    _ = ctx;
    try sendJson(conn_fd, 200, "[{\"id\":\"sess_default\",\"title\":\"Demo Session\"}]");
}

fn handleChat(conn_fd: i32, raw_request: []const u8, ctx: *HttpServer) !void {
    if (!ctx.circuit_breaker.allowRequest()) {
        const remaining = ctx.circuit_breaker.remainingTimeout();
        var body_buf: [128]u8 = undefined;
        var body_buf2: [128]u8 = undefined;
        const num_str = try std.fmt.bufPrint(&body_buf2, "{d}", .{remaining});
        const body = try std.fmt.bufPrint(&body_buf,
            " {{\"error\":\"circuit breaker open\",\"retry_after_seconds\":{s}}}",
            .{num_str});
        try sendJson(conn_fd, 503, body);
        return;
    }

    const header_end = std.mem.indexOf(u8, raw_request, "\r\n\r\n") orelse {
        try sendJson(conn_fd, 400, "{\"error\":\"missing body\"}");
        return;
    };
    const body_start = header_end + 4;
    const body_slice = std.mem.trim(u8, raw_request[body_start..], " \r\n\t");

    if (body_slice.len == 0) {
        try sendJson(conn_fd, 400, "{\"error\":\"empty body\"}");
        return;
    }

    if (body_slice.len > 1024 * 1024) {
        try sendJson(conn_fd, 413, "{\"error\":\"request too large\"}");
        return;
    }

    var parsed = std.json.parseFromSlice(ChatRequest, ctx.allocator, body_slice, .{
        .ignore_unknown_fields = true,
    }) catch {
        try sendJson(conn_fd, 400, "{\"error\":\"invalid JSON\"}");
        return;
    };
    defer parsed.deinit();

    const stream = parsed.value.stream orelse false;

    if (stream) {
        const sse_header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n";
        _ = c.write(conn_fd, sse_header.ptr, sse_header.len);

        if (ctx.loop) |loop| {
            const last_msg = if (parsed.value.messages.len > 0)
                parsed.value.messages[parsed.value.messages.len - 1].content
            else
                "";
            const result = loop.step(last_msg) catch {
                const err_data = "data: {{\"error\":\"loop error\"}}\n\n";
                _ = c.write(conn_fd, err_data.ptr, err_data.len);
                const done_data = "data: [DONE]\n\n";
                _ = c.write(conn_fd, done_data.ptr, done_data.len);
                return;
            };
            ctx.circuit_breaker.recordSuccess();

            const escaped = try escapeSSE(ctx.allocator, result.content);
            defer ctx.allocator.free(escaped);
            var sse_buf: [8192]u8 = undefined;
            const sse_str = std.fmt.bufPrint(&sse_buf,
                "data: {{\"content\":{s}}}\n\n", .{escaped}) catch {
                const done_data = "data: [DONE]\n\n";
                _ = c.write(conn_fd, done_data.ptr, done_data.len);
                return;
            };
            _ = c.write(conn_fd, sse_str.ptr, sse_str.len);
        } else {
            const hello = "data: {{\"content\":\"Hello from Zeepseek!\"}}\n\n";
            _ = c.write(conn_fd, hello.ptr, hello.len);
        }
        const done_data = "data: [DONE]\n\n";
        _ = c.write(conn_fd, done_data.ptr, done_data.len);
    } else {
        if (ctx.loop) |loop| {
            const last_msg = if (parsed.value.messages.len > 0)
                parsed.value.messages[parsed.value.messages.len - 1].content
            else
                "";
            const result = loop.step(last_msg) catch {
                ctx.circuit_breaker.recordFailure();
                try sendJson(conn_fd, 500, "{\"error\":\"execution failed\"}");
                return;
            };
            ctx.circuit_breaker.recordSuccess();
            var response_buf: [4096]u8 = undefined;
            const response_content = try std.fmt.bufPrint(&response_buf,
                " {{\"content\":{s},\"reasoning\":null,\"finish_reason\":\"{s}\"}}",
                .{ result.content, "stop" });
            try sendJson(conn_fd, 200, response_content);
        } else {
            try sendJson(conn_fd, 200, " {{\"content\":\"Hello from Zeepseek!\"}}");
        }
    }
}

fn escapeSSE(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayListAligned(u8, null) = .empty;
    try result.ensureTotalCapacityPrecise(allocator, input.len * 2);
    defer result.deinit(allocator);
    for (input) |ch| {
        switch (ch) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, ch),
        }
    }
    return try result.toOwnedSlice(allocator);
}
