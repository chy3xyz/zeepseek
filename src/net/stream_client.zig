const std = @import("std");
const http = std.http;

const RateLimiter = @import("http_client.zig").RateLimiter;
const CircuitBreaker = @import("http_client.zig").CircuitBreaker;
const CacheConfig = @import("http_client.zig").CacheConfig;

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

pub const CtxItem = struct { role: []const u8, content: []const u8 };

pub const ThinkingConfig = struct {
    enabled: bool = true,
    render_inline: bool = true,
};

pub const DeepSeekStreamClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    rate_limiter: ?*RateLimiter = null,
    circuit_breaker: ?*CircuitBreaker = null,
    http_client: http.Client,
    endpoint: []const u8 = "https://api.deepseek.com/chat/completions",
    last_http_status: u16 = 0,
    last_http_body: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        rate_limiter: ?*RateLimiter,
        circuit_breaker: ?*CircuitBreaker,
    ) DeepSeekStreamClient {
        return .{
            .allocator = allocator,
            .io = io,
            .rate_limiter = rate_limiter,
            .circuit_breaker = circuit_breaker,
            .http_client = http.Client{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *DeepSeekStreamClient) void {
        if (self.last_http_body) |b| self.allocator.free(b);
        self.http_client.deinit();
    }

    pub const StreamEvent = struct {
        content: []const u8,
        done: bool = false,
    };

    pub fn streamMessage(
        self: *DeepSeekStreamClient,
        api_key: []const u8,
        prompt: []const u8,
        context: []const CtxItem,
        model: []const u8,
        cache_decision: anytype,
        system_prompt: []const u8,
        reasoning_effort: ?[]const u8,
    ) !StreamIterator {
        if (self.circuit_breaker) |cb| {
            if (cb.isOpen()) return error.CircuitOpen;
        }

        if (self.rate_limiter) |rl| {
            try rl.wait();
        }

        const completions_uri = if (std.mem.endsWith(u8, self.endpoint, "/v1"))
            std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.endpoint}) catch return error.AllocationFailed
        else
            std.fmt.allocPrint(self.allocator, "{s}/v1/chat/completions", .{self.endpoint}) catch return error.AllocationFailed;
        defer self.allocator.free(completions_uri);
        const uri = std.Uri.parse(completions_uri) catch return error.InvalidUri;

        const body = try self.buildRequestBody(prompt, context, model, cache_decision, system_prompt, reasoning_effort);

        const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key});
        defer self.allocator.free(auth_value);

        const headers = [_]http.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "text/event-stream" },
        };

        // Load system CA certificates on first HTTPS request. Zig's http.Client
        // starts with an empty bundle, so TLS handshake would fail otherwise.
        if (!@import("builtin").target.cpu.arch.isWasm()) {
            if (self.http_client.ca_bundle.bytes.items.len == 0) {
                var bundle = std.crypto.Certificate.Bundle.empty;
                const now = std.Io.Timestamp.now(self.io, .real);
                try bundle.rescan(self.allocator, self.io, now);
                self.http_client.ca_bundle = bundle;
            }
        }

        var request = try self.http_client.request(.POST, uri, .{
            .extra_headers = &headers,
        });

        try request.sendBodyComplete(body);
        errdefer request.deinit();

        var redirect_buf: [8192]u8 = undefined;
        var response = try request.receiveHead(&redirect_buf);

        const status = @intFromEnum(response.head.status);
        if (status < 200 or status >= 300) {
            if (self.circuit_breaker) |cb| {
                cb.recordFailure();
            }

            // Capture the response body so the UI can show *why* the request failed.
            var err_reader_buf: [4096]u8 = undefined;
            const err_reader = response.reader(&err_reader_buf);
            const err_body = err_reader.allocRemaining(self.allocator, .limited(4096)) catch null;
            if (self.last_http_body) |old| self.allocator.free(old);
            self.last_http_body = err_body;
            self.last_http_status = @intCast(status);

            return error.HttpError;
        }

        if (self.circuit_breaker) |cb| {
            cb.recordSuccess();
        }

        const transfer_buffer = try self.allocator.alloc(u8, 8192);
        const body_reader = response.reader(transfer_buffer);

        return StreamIterator{
            .allocator = self.allocator,
            .reader = body_reader,
            .buffer = try std.ArrayList(u8).initCapacity(self.allocator, 4096),
            .line_accumulator = try std.ArrayList(u8).initCapacity(self.allocator, 4096),
            .transfer_buffer = transfer_buffer,
            .tool_call_json = .empty,
        };
    }

    fn buildRequestBody(
        self: *DeepSeekStreamClient,
        prompt: []const u8,
        context: []const CtxItem,
        model: []const u8,
        cache_decision: anytype,
        system_prompt: []const u8,
        reasoning_effort: ?[]const u8,
    ) ![]u8 {
        var body = try std.ArrayList(u8).initCapacity(self.allocator, 2048);
        errdefer body.deinit(self.allocator);

        try body.appendSlice(self.allocator, "{\"model\":\"");
        try body.appendSlice(self.allocator, model);
        try body.appendSlice(self.allocator, "\",\"stream\":true,\"messages\":[");

        if (system_prompt.len > 0) {
            const cache_tag = switch (cache_decision) {
                .hit => "(cache)",
                .miss => "",
                .none => "",
            };
            try body.appendSlice(self.allocator, "{\"role\":\"system\",\"content\":\"");
            try escapeJsonString(self.allocator, system_prompt, &body);
            if (cache_tag.len > 0) {
                try body.appendSlice(self.allocator, " ");
                try body.appendSlice(self.allocator, cache_tag);
            }
            try body.appendSlice(self.allocator, "\"}");
        }

        for (context) |ctx| {
            if (body.items.len > 0 and body.items[body.items.len - 1] != '[') {
                try body.appendSlice(self.allocator, ",");
            }
            try body.appendSlice(self.allocator, "{\"role\":\"");
            try body.appendSlice(self.allocator, ctx.role);
            try body.appendSlice(self.allocator, "\",\"content\":\"");
            try escapeJsonString(self.allocator, ctx.content, &body);
            try body.appendSlice(self.allocator, "\"}");
        }

        if (body.items.len > 0 and body.items[body.items.len - 1] != '[') {
            try body.appendSlice(self.allocator, ",");
        }
        try body.appendSlice(self.allocator, "{\"role\":\"user\",\"content\":\"");
        try escapeJsonString(self.allocator, prompt, &body);
        try body.appendSlice(self.allocator, "\"}");

        try body.appendSlice(self.allocator, "],\"tools\":[");
        // Shell tool
        try body.appendSlice(self.allocator, "{\"type\":\"function\",\"function\":{\"name\":\"shell\",\"description\":\"Execute a shell command. Returns stdout/stderr.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Shell command to execute\"}},\"required\":[\"command\"]}}},");
        // File read
        try body.appendSlice(self.allocator, "{\"type\":\"function\",\"function\":{\"name\":\"file_read\",\"description\":\"Read contents of a file.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path\"}},\"required\":[\"path\"]}}},");
        // File write
        try body.appendSlice(self.allocator, "{\"type\":\"function\",\"function\":{\"name\":\"file_write\",\"description\":\"Write content to a file.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}}},");
        // File edit
        try body.appendSlice(self.allocator, "{\"type\":\"function\",\"function\":{\"name\":\"file_edit\",\"description\":\"Edit a file by replacing oldString with newString.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"oldString\":{\"type\":\"string\"},\"newString\":{\"type\":\"string\"}},\"required\":[\"path\",\"oldString\",\"newString\"]}}},");
        // Git status
        try body.appendSlice(self.allocator, "{\"type\":\"function\",\"function\":{\"name\":\"git_status\",\"description\":\"Show git repository status.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"repo\":{\"type\":\"string\"}},\"required\":[]}}},");
        // Git commit
        try body.appendSlice(self.allocator, "{\"type\":\"function\",\"function\":{\"name\":\"git_commit\",\"description\":\"Create a git commit.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"},\"all\":{\"type\":\"boolean\"}},\"required\":[\"message\"]}}},");
        // Web search
        try body.appendSlice(self.allocator, "{\"type\":\"function\",\"function\":{\"name\":\"web_search\",\"description\":\"Search the web.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}},\"required\":[\"query\"]}}},");
        // Web scrape
        try body.appendSlice(self.allocator, "{\"type\":\"function\",\"function\":{\"name\":\"web_scrape\",\"description\":\"Fetch and extract content from a URL.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}},\"required\":[\"url\"]}}}");
        try body.appendSlice(self.allocator, "],\"tool_choice\":\"auto\"");

        if (reasoning_effort) |effort| {
            try body.appendSlice(self.allocator, ",\"reasoning_effort\":\"");
            try body.appendSlice(self.allocator, effort);
            try body.appendSlice(self.allocator, "\"}");
        } else {
            try body.appendSlice(self.allocator, "}");
        }

        return body.toOwnedSlice(self.allocator);
    }
};

pub const StreamChunk = union(enum) {
    content: []const u8,
    reasoning: []const u8,
};

pub const StreamIterator = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    buffer: std.ArrayList(u8),
    line_accumulator: std.ArrayList(u8),
    transfer_buffer: []u8,
    done: bool = false,
    content_buffer: []const u8 = &.{},
    reasoning_buffer: []const u8 = &.{},
    tool_call_json: std.ArrayList(u8),
    has_tool_calls: bool = false,

    pub fn nextChunk(self: *StreamIterator) !?StreamChunk {
        if (self.done and self.content_buffer.len == 0 and self.reasoning_buffer.len == 0) return null;
        if (self.reasoning_buffer.len > 0) {
            const chunk = self.reasoning_buffer;
            self.reasoning_buffer = &.{};
            return StreamChunk{ .reasoning = chunk };
        }
        if (self.content_buffer.len > 0) {
            const chunk = self.content_buffer;
            self.content_buffer = &.{};
            return StreamChunk{ .content = chunk };
        }

        while (true) {
            var read_buf: [4096]u8 = undefined;
            const n = self.reader.readSliceShort(&read_buf) catch |err| {
                if (err == error.EndOfStream) {
                    self.done = true;
                    return null;
                }
                return err;
            };
            if (n == 0) {
                self.done = true;
                return null;
            }
            try self.line_accumulator.appendSlice(self.allocator, read_buf[0..n]);

            if (std.mem.indexOfScalar(u8, self.line_accumulator.items, '\n')) |newline_idx| {
                const line = self.line_accumulator.items[0 .. newline_idx + 1];
                const remainder = self.line_accumulator.items[newline_idx + 1 ..];
                const remainder_copy = try self.allocator.dupe(u8, remainder);
                defer self.allocator.free(remainder_copy);
                self.line_accumulator.clearRetainingCapacity();
                if (remainder_copy.len > 0) {
                    try self.line_accumulator.appendSlice(self.allocator, remainder_copy);
                }
                const trimmed = std.mem.trim(u8, line, "\r\n");
                if (trimmed.len == 0) continue;
                if (trimmed[0] == ':') continue;
                if (!std.mem.startsWith(u8, trimmed, "data:")) continue;

                const data_value = std.mem.trim(u8, trimmed[5..], " ");
                if (data_value.len == 0) continue;
                if (std.mem.eql(u8, data_value, "[DONE]")) {
                    self.done = true;
                    return null;
                }

                const extracted = try self.extractContentAndReasoning(data_value);
                if (extracted.reasoning.len > 0) {
                    self.reasoning_buffer = extracted.reasoning;
                }
                if (extracted.content.len > 0) {
                    self.content_buffer = extracted.content;
                }
                if (self.reasoning_buffer.len > 0 or self.content_buffer.len > 0) {
                    return self.nextChunk();
                }
                continue;
            }
        }
    }

    fn unescapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            if (input[i] == '\\' and i + 1 < input.len) {
                i += 1;
                switch (input[i]) {
                    '"' => try result.append(allocator, '"'),
                    '\\' => try result.append(allocator, '\\'),
                    'n' => try result.append(allocator, '\n'),
                    'r' => try result.append(allocator, '\r'),
                    't' => try result.append(allocator, '\t'),
                    else => {
                        try result.append(allocator, '\\');
                        try result.append(allocator, input[i]);
                    },
                }
            } else {
                try result.append(allocator, input[i]);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    fn extractContentAndReasoning(self: *StreamIterator, json_data: []const u8) !struct { content: []const u8, reasoning: []const u8 } {
        var content_result: []const u8 = "";
        var reasoning_result: []const u8 = "";
        var i: usize = 0;

        // First, check for tool_calls anywhere in the JSON
        if (std.mem.indexOf(u8, json_data, "\"tool_calls\"") != null or
            std.mem.indexOf(u8, json_data, "\"tool_call\"") != null)
        {
            self.has_tool_calls = true;
            try self.tool_call_json.appendSlice(self.allocator, json_data);
            try self.tool_call_json.appendSlice(self.allocator, "\n");
        }

        while (i < json_data.len) : (i += 1) {
            if (i + 7 <= json_data.len and std.mem.eql(u8, json_data[i..i+7], "\"delta\"")) {
                i += 7;
                while (i < json_data.len and json_data[i] != '{') : (i += 1) {}
                if (i < json_data.len) {
                    const brace_count = try self.findMatchingBrace(json_data, i);
                    if (brace_count) |end| {
                        const delta_json = json_data[i..end];

                        var ci: usize = 0;
                        while (ci < delta_json.len) : (ci += 1) {
                            if (ci + 9 <= delta_json.len and std.mem.eql(u8, delta_json[ci..ci+9], "\"content\":")) {
                                ci += 9;
                                while (ci < delta_json.len and (delta_json[ci] == ' ' or delta_json[ci] == '"')) : (ci += 1) {}
                                if (ci < delta_json.len and delta_json[ci] == '"') {
                                    ci += 1;
                                    const value_start = ci;
                                    while (ci < delta_json.len and delta_json[ci] != '"') : (ci += 1) {
                                        if (delta_json[ci] == '\\' and ci + 1 < delta_json.len) ci += 1;
                                    }
                                    content_result = try unescapeJsonString(self.allocator, delta_json[value_start..ci]);
                                }
                            }

                            if (ci + 18 <= delta_json.len and std.mem.eql(u8, delta_json[ci..ci+18], "\"reasoning_content\":")) {
                                ci += 18;
                                while (ci < delta_json.len and (delta_json[ci] == ' ' or delta_json[ci] == '"')) : (ci += 1) {}
                                if (ci < delta_json.len and delta_json[ci] == '"') {
                                    ci += 1;
                                    const value_start = ci;
                                    while (ci < delta_json.len and delta_json[ci] != '"') : (ci += 1) {
                                        if (delta_json[ci] == '\\' and ci + 1 < delta_json.len) ci += 1;
                                    }
                                    reasoning_result = try unescapeJsonString(self.allocator, delta_json[value_start..ci]);
                                }
                            }
                        }
                    }
                }
            }
        }
        return .{ .content = content_result, .reasoning = reasoning_result };
    }

    fn findMatchingBrace(self: *StreamIterator, json_data: []const u8, start: usize) !?usize {
        _ = self;
        if (start >= json_data.len or json_data[start] != '{') return null;
        var count: i32 = 1;
        var i = start + 1;
        while (i < json_data.len and count > 0) : (i += 1) {
            switch (json_data[i]) {
                '{' => count += 1,
                '}' => count -= 1,
                '"' => {
                    i += 1;
                    while (i < json_data.len and json_data[i] != '"') : (i += 1) {
                        if (json_data[i] == '\\') i += 1;
                    }
                },
                else => {},
            }
        }
        if (count == 0) return i;
        return null;
    }

    pub fn deinit(self: *StreamIterator) void {
        if (self.content_buffer.len > 0) self.allocator.free(self.content_buffer);
        if (self.reasoning_buffer.len > 0) self.allocator.free(self.reasoning_buffer);
        self.allocator.free(self.transfer_buffer);
        self.buffer.deinit(self.allocator);
        self.line_accumulator.deinit(self.allocator);
        self.tool_call_json.deinit(self.allocator);
    }
};

pub const ToolCallRepairPipeline = struct {
    allocator: std.mem.Allocator,
    seen_signatures: std.StringHashMap(void),
    accumulators: std.AutoHashMap(usize, []u8),
    max_accumulators: usize = 8,
    last_seen_names: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) ToolCallRepairPipeline {
        return .{
            .allocator = allocator,
            .seen_signatures = std.StringHashMap(void).init(allocator),
            .accumulators = std.AutoHashMap(usize, []u8).init(allocator),
            .last_seen_names = .empty,
        };
    }

    pub fn deinit(self: *ToolCallRepairPipeline) void {
        var sig_iter = self.seen_signatures.keyIterator();
        while (sig_iter.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.seen_signatures.deinit();
        var acc_iter = self.accumulators.iterator();
        while (acc_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.accumulators.deinit();
        for (self.last_seen_names.items) |name| {
            self.allocator.free(name);
        }
        self.last_seen_names.deinit(self.allocator);
    }

    pub const ToolCallResult = struct {
        calls: []ToolCallExtracted,
        content_delta: []const u8,
        done: bool,
    };

    pub const ToolCallExtracted = struct {
        index: usize,
        name: []const u8,
        arguments: []const u8,
        signature: []const u8,
    };

    pub fn processChunk(
        self: *ToolCallRepairPipeline,
        json_data: []const u8,
    ) !ToolCallResult {
        var content_buf: []const u8 = "";
        var extracted_calls: std.ArrayList(ToolCallExtracted) = .empty;
        var i: usize = 0;

        while (i < json_data.len) : (i += 1) {
            if (i + 5 <= json_data.len and std.mem.eql(u8, json_data[i..i+5], "\"tool")) {
                const tc_result = try self.parseToolCallsFromDelta(json_data, &i);
                if (tc_result) |calls| {
                    for (calls) |call| {
                        try extracted_calls.append(self.allocator, call);
                    }
                }
            } else if (i + 9 <= json_data.len and std.mem.eql(u8, json_data[i..i+9], "\"content\":")) {
                i += 9;
                while (i < json_data.len and (json_data[i] == ' ' or json_data[i] == '"')) : (i += 1) {}
                if (i < json_data.len and json_data[i] == '"') {
                    i += 1;
                    const value_start = i;
                    while (i < json_data.len and json_data[i] != '"') : (i += 1) {
                        if (json_data[i] == '\\' and i + 1 < json_data.len) i += 1;
                    }
                    content_buf = json_data[value_start..i];
                }
            } else if (i + 18 <= json_data.len and std.mem.eql(u8, json_data[i..i+18], "\"reasoning_content\":")) {
                i += 18;
                while (i < json_data.len and (json_data[i] == ' ' or json_data[i] == '"')) : (i += 1) {}
                if (i < json_data.len and json_data[i] == '"') {
                    i += 1;
                    while (i < json_data.len and json_data[i] != '"') : (i += 1) {
                        if (json_data[i] == '\\' and i + 1 < json_data.len) i += 1;
                    }
                }
            }
        }

        return .{
            .calls = try extracted_calls.toOwnedSlice(self.allocator),
            .content_delta = content_buf,
            .done = extracted_calls.items.len > 0,
        };
    }

    fn parseToolCallsFromDelta(
        self: *ToolCallRepairPipeline,
        json_data: []const u8,
        inout_i: *usize,
    ) !?[]ToolCallExtracted {
        var calls: std.ArrayList(ToolCallExtracted) = .empty;
        var i = inout_i.*;


        if (std.mem.startsWith(u8, json_data[i..], "\"tool_calls\":")) {
            i += 13;
            while (i < json_data.len and json_data[i] == ' ') : (i += 1) {}

            if (i < json_data.len and json_data[i] == '[') {
                i += 1;
                while (i < json_data.len and json_data[i] == ' ') : (i += 1) {}

                while (i < json_data.len and json_data[i] != ']') {
                    while (i < json_data.len and json_data[i] == ' ') : (i += 1) {}
                    if (i >= json_data.len or json_data[i] == ']') break;

                    if (json_data[i] == '{') {
                        const obj_end = findMatchingBrace(json_data, i);
                        const obj_data = if (obj_end) |end|
                            json_data[i..end + 1]
                        else
                            json_data[i..];
                        if (try self.extractSingleToolCall(obj_data)) |e| try calls.append(self.allocator, e);
                        if (obj_end == null) break;
                        i = obj_end.? + 1;
                    } else {
                        i += 1;
                    }
                    while (i < json_data.len and (json_data[i] == ' ' or json_data[i] == ',')) : (i += 1) {}
                }
                if (i < json_data.len and json_data[i] == ']') i += 1;
            }
        } else if (std.mem.startsWith(u8, json_data[i..], "\"tool_call\":")) {
            i += 12;
            while (i < json_data.len and json_data[i] == ' ') : (i += 1) {}
            if (i < json_data.len and json_data[i] == '{') {
                const obj_end = findMatchingBrace(json_data, i);
                const obj_data = if (obj_end) |end|
                    json_data[i..end + 1]
                else
                    json_data[i..];
                if (try self.extractSingleToolCall(obj_data)) |e| try calls.append(self.allocator, e);
                if (obj_end == null) {
                    inout_i.* = json_data.len;
                } else {
                    inout_i.* = obj_end.? + 1;
                }
                if (calls.items.len > 0) return try calls.toOwnedSlice(self.allocator);
                return null;
            }
        }

        inout_i.* = i;
        if (calls.items.len > 0) return try calls.toOwnedSlice(self.allocator);
        return null;
    }

    fn findMatchingBrace(json_data: []const u8, start: usize) ?usize {
        if (start >= json_data.len or json_data[start] != '{') return null;
        var count: i32 = 1;
        var i = start + 1;
        while (i < json_data.len and count > 0) : (i += 1) {
            switch (json_data[i]) {
                '{' => count += 1,
                '}' => {
                    count -= 1;
                    if (count == 0) return i;
                },
                '"' => {
                    i += 1;
                    while (i < json_data.len and json_data[i] != '"') : (i += 1) {
                        if (json_data[i] == '\\' and i + 1 < json_data.len) i += 1;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    const ToolCallJson = struct {
        index: usize = 0,
        function: struct {
            name: []const u8 = "",
            arguments: []const u8 = "",
        } = .{},
    };

    fn extractSingleToolCall(self: *ToolCallRepairPipeline, obj_data: []const u8) !?ToolCallExtracted {
        const parsed = std.json.parseFromSlice(ToolCallJson, self.allocator, obj_data, .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        if (parsed.value.function.name.len == 0) return null;
        return ToolCallExtracted{
            .index = parsed.value.index,
            .name = try self.allocator.dupe(u8, parsed.value.function.name),
            .arguments = try self.allocator.dupe(u8, parsed.value.function.arguments),
            .signature = try self.allocator.dupe(u8, ""),
        };
    }

    pub fn suppressRepeats(self: *ToolCallRepairPipeline, calls: []const ToolCallExtracted) ![]ToolCallExtracted {
        var kept: std.ArrayList(ToolCallExtracted) = .empty;
        for (calls) |call| {
            const sig = try std.fmt.allocPrint(self.allocator, "{d}:{s}", .{ call.index, call.name });
            defer self.allocator.free(sig);
            const gop = try self.seen_signatures.getOrPut(sig);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, sig);
                gop.value_ptr.* = {};
                try kept.append(self.allocator, call);
            }
        }
        return kept.toOwnedSlice(self.allocator);
    }

    pub fn balanceJson(self: *ToolCallRepairPipeline, text: []const u8) ![]const u8 {
        var open_braces: i32 = 0;
        var open_brackets: i32 = 0;
        var in_string: bool = false;
        var escaped: bool = false;

        for (text) |c| {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') {
                in_string = !in_string;
                continue;
            }
            if (in_string) continue;

            switch (c) {
                '{' => open_braces += 1,
                '}' => open_braces -= 1,
                '[' => open_brackets += 1,
                ']' => open_brackets -= 1,
                else => {},
            }
        }

        var balanced = std.ArrayList(u8).empty;
        defer balanced.deinit(self.allocator);
        try balanced.appendSlice(self.allocator, text);

        if (in_string) {
            try balanced.append(self.allocator, '"');
        }
        while (open_brackets > 0) {
            try balanced.append(self.allocator, ']');
            open_brackets -= 1;
        }
        while (open_braces > 0) {
            try balanced.append(self.allocator, '}');
            open_braces -= 1;
        }

        return balanced.toOwnedSlice(self.allocator);
    }

    pub fn repairAndParse(self: *ToolCallRepairPipeline, raw_json: []const u8) !?ToolCallExtracted {
        const balanced = try self.balanceJson(raw_json);
        defer self.allocator.free(balanced);

        const repaired = try self.repairJsonFragment(balanced);
        defer self.allocator.free(repaired);

        return try self.extractSingleToolCall(repaired);
    }

    fn repairJsonFragment(self: *ToolCallRepairPipeline, text: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and i + 1 < text.len) {
                try result.append(self.allocator, text[i]);
                try result.append(self.allocator, text[i + 1]);
                i += 1;
                continue;
            }
            if (text[i] == '"') {
                try result.append(self.allocator, text[i]);
                i += 1;
                while (i < text.len) : (i += 1) {
                    if (text[i] == '\\') {
                        try result.append(self.allocator, text[i]);
                        if (i + 1 < text.len) {
                            try result.append(self.allocator, text[i + 1]);
                            i += 1;
                        }
                    } else if (text[i] == '"') {
                        try result.append(self.allocator, text[i]);
                        break;
                    } else {
                        try result.append(self.allocator, text[i]);
                    }
                }
            } else {
                try result.append(self.allocator, text[i]);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }
};

test "tool call repair pipeline init and deinit" {
    var pipeline = ToolCallRepairPipeline.init(std.testing.allocator);
    defer pipeline.deinit();
    try std.testing.expect(pipeline.seen_signatures.count() == 0);
}

test "tool call repair pipeline basic parse" {
    var pipeline = ToolCallRepairPipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    const json = "{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]}";
    const result = try pipeline.processChunk(json);
    defer std.testing.allocator.free(result.calls);

    try std.testing.expect(result.calls.len == 1);
    try std.testing.expectEqualSlices(u8, "bash", result.calls[0].name);
    try std.testing.expectEqualSlices(u8, "{\"command\":\"ls\"}", result.calls[0].arguments);
    try std.testing.expectEqual(@as(usize, 0), result.calls[0].index);
}

test "tool call repair pipeline suppress repeats" {
    var pipeline = ToolCallRepairPipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    const json1 = "{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}";
    const json2 = "{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}";
    const json3 = "{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"ls\",\"arguments\":\"{}\"}}]}";

    const result1 = try pipeline.processChunk(json1);
    defer std.testing.allocator.free(result1.calls);
    const result2 = try pipeline.processChunk(json2);
    defer std.testing.allocator.free(result2.calls);
    const result3 = try pipeline.processChunk(json3);
    defer std.testing.allocator.free(result3.calls);

    try std.testing.expectEqual(@as(usize, 1), result1.calls.len);
    try std.testing.expectEqual(@as(usize, 1), result2.calls.len);
    try std.testing.expectEqual(@as(usize, 1), result3.calls.len);

    const filtered = try pipeline.suppressRepeats(&[_]ToolCallRepairPipeline.ToolCallExtracted{ result1.calls[0], result2.calls[0], result3.calls[0] });
    defer std.testing.allocator.free(filtered);
    try std.testing.expectEqual(@as(usize, 2), filtered.len);
}

test "tool call repair pipeline balance json" {
    var pipeline = ToolCallRepairPipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    const unbalanced = "{[";
    const balanced = try pipeline.balanceJson(unbalanced);
    defer pipeline.allocator.free(balanced);
    try std.testing.expectEqualSlices(u8, "{[]}", balanced);
}

test "tool call repair pipeline extract single call" {
    var pipeline = ToolCallRepairPipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    const obj = "{\"index\":2,\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}";
    const extracted = try pipeline.extractSingleToolCall(obj);
    try std.testing.expect(extracted != null);
    try std.testing.expectEqual(@as(usize, 2), extracted.?.index);
    try std.testing.expectEqualSlices(u8, "read_file", extracted.?.name);
    try std.testing.expectEqualSlices(u8, "{\"path\":\"a.txt\"}", extracted.?.arguments);
}

test "tool call repair pipeline repair and parse" {
    var pipeline = ToolCallRepairPipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    const truncated = "{\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command";
    const result = try pipeline.repairAndParse(truncated);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, "bash", result.?.name);
}

pub const StreamIteratorOld = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    buffer: std.ArrayList(u8),
    transfer_buffer: []u8,
    done: bool = false,
    content_buffer: []const u8 = &.{},

    pub fn nextChunk(self: *StreamIterator) !?[]const u8 {
        if (self.done and self.content_buffer.len == 0) return null;
        if (self.content_buffer.len > 0) {
            const chunk = self.content_buffer;
            self.content_buffer = &.{};
            return chunk;
        }

        var line_buf: [8192]u8 = undefined;
        var line_len: usize = 0;

        while (true) {
            const n = self.reader.readSliceShort(line_buf[line_len..]) catch |err| {
                if (err == error.EndOfStream) {
                    self.done = true;
                    return null;
                }
                return err;
            };
            if (n == 0) {
                self.done = true;
                return null;
            }
            line_len += n;

            if (line_buf[line_len - 1] == '\n') break;

            if (line_len >= line_buf.len) break;
        }

        const line = line_buf[0..line_len];
        const trimmed = std.mem.trim(u8, line, "\r\n");
        if (trimmed.len == 0) return null;

        if (trimmed[0] == ':') return null;

        if (!std.mem.startsWith(u8, trimmed, "data:")) return null;
        const data_value = std.mem.trim(u8, trimmed[5..], " ");
        if (data_value.len == 0) return null;
        if (std.mem.eql(u8, data_value, "[DONE]")) {
            self.done = true;
            return null;
        }

        const content = try self.extractContent(data_value);
        if (content.len > 0) {
            self.content_buffer = content;
            return self.nextChunk();
        }
        return null;
    }

    fn extractContent(self: *StreamIterator, json_data: []const u8) ![]const u8 {
        var start_idx: ?usize = null;
        var end_idx: ?usize = null;

        var i: usize = 0;
        while (i < json_data.len) : (i += 1) {
            if (i + 7 <= json_data.len and std.mem.eql(u8, json_data[i..i+7], "\"delta\"")) {
                i += 7;
                while (i < json_data.len and json_data[i] != '{') : (i += 1) {}
                if (i < json_data.len) {
                    const brace_count = try self.findMatchingBrace(json_data, i);
                    if (brace_count) |end| {
                        const delta_json = json_data[i..end];
                        start_idx = std.mem.indexOf(u8, delta_json, "\"content\":");
                        if (start_idx) |_| {
                            const content_start = i + 9 + start_idx.?;
                            var j = content_start;
                            while (j < delta_json.len and (delta_json[j] == ' ' or delta_json[j] == '"')) : (j += 1) {}
                            const value_start = j;
                            if (j < delta_json.len and delta_json[j] == '"') {
                                j += 1;
                                while (j < delta_json.len and delta_json[j] != '"') : (j += 1) {}
                                end_idx = j;
                                return self.allocator.dupe(u8, delta_json[value_start..j]);
                            }
                        }
                    }
                }
            }
        }
        return "";
    }

    fn findMatchingBrace(self: *StreamIterator, json_data: []const u8, start: usize) !?usize {
        _ = self;
        if (start >= json_data.len or json_data[start] != '{') return null;
        var count: i32 = 1;
        var i = start + 1;
        while (i < json_data.len and count > 0) : (i += 1) {
            switch (json_data[i]) {
                '{' => count += 1,
                '}' => count -= 1,
                '"' => {
                    i += 1;
                    while (i < json_data.len and json_data[i] != '"') : (i += 1) {
                        if (json_data[i] == '\\') i += 1;
                    }
                },
                else => {},
            }
        }
        if (count == 0) return i;
        return null;
    }

    pub fn deinit(self: *StreamIterator) void {
        self.allocator.free(self.transfer_buffer);
        self.buffer.deinit(self.allocator);
    }
};