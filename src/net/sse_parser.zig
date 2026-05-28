const std = @import("std");
const array_list = std.array_list;

pub const SSEParser = struct {
    buf: std.ArrayList(u8) = .{},
    pos: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) SSEParser {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *SSEParser) void {
        self.buf.deinit(self.alloc);
    }

    pub const Event = union(enum) {
        message: Message,
        retry: u32,
        comment: void,
        done: void,
        err: []const u8,
    };

    pub const Message = struct {
        id: ?[]const u8 = null,
        event: ?[]const u8 = null,
        data: []const u8 = "",
    };

    pub fn isThinkingChunk(data: []const u8) bool {
        return std.mem.indexOf(u8, data, "\"reasoning_content\"") != null;
    }

    pub fn extractThinkingContent(allocator: std.mem.Allocator, data: []const u8) !?[]const u8 {
        var start_idx: ?usize = null;
        var end_idx: ?usize = null;
        var i: usize = 0;

        while (i < data.len) : (i += 1) {
            if (i + 18 <= data.len and std.mem.eql(u8, data[i..i+18], "\"reasoning_content\"")) {
                i += 18;
                while (i < data.len and (data[i] == ' ' or data[i] == ':')) : (i += 1) {}
                if (i < data.len and data[i] == '"') {
                    i += 1;
                    start_idx = i;
                    while (i < data.len and data[i] != '"') : (i += 1) {
                        if (data[i] == '\\' and i + 1 < data.len) i += 1;
                    }
                    end_idx = i;
                    break;
                }
            }
        }

        if (start_idx == null or end_idx == null) return null;
        return try unescapeJsonString(allocator, data[start_idx.?..end_idx.?]);
    }

    fn unescapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            if (input[i] == '\\' and i + 1 < input.len) {
                i += 1;
                switch (input[i]) {
                    '"' => try result.append('"'),
                    '\\' => try result.append('\\'),
                    'n' => try result.append('\n'),
                    'r' => try result.append('\r'),
                    't' => try result.append('\t'),
                    else => {
                        try result.append('\\');
                        try result.append(input[i]);
                    },
                }
            } else {
                try result.append(input[i]);
            }
        }
        return result.toOwnedSlice();
    }

    pub fn extractContentAndThinking(
        allocator: std.mem.Allocator,
        json_data: []const u8,
    ) !struct { content: []const u8, reasoning: ?[]const u8 } {
        var content_result: ?[]const u8 = null;
        var reasoning_result: ?[]const u8 = null;
        var i: usize = 0;

        while (i < json_data.len) : (i += 1) {
            if (i + 9 <= json_data.len and std.mem.eql(u8, json_data[i..i+9], "\"content\":")) {
                i += 9;
                while (i < json_data.len and (json_data[i] == ' ' or json_data[i] == ':')) : (i += 1) {}
                if (i < json_data.len and json_data[i] == '"') {
                    i += 1;
                    const value_start = i;
                    while (i < json_data.len and json_data[i] != '"') : (i += 1) {
                        if (json_data[i] == '\\' and i + 1 < json_data.len) i += 1;
                    }
                    content_result = try unescapeJsonString(allocator, json_data[value_start..i]);
                }
            }

            if (i + 18 <= json_data.len and std.mem.eql(u8, json_data[i..i+18], "\"reasoning_content\":")) {
                i += 18;
                while (i < json_data.len and (json_data[i] == ' ' or json_data[i] == ':')) : (i += 1) {}
                if (i < json_data.len and json_data[i] == '"') {
                    i += 1;
                    const value_start = i;
                    while (i < json_data.len and json_data[i] != '"') : (i += 1) {
                        if (json_data[i] == '\\' and i + 1 < json_data.len) i += 1;
                    }
                    reasoning_result = try unescapeJsonString(allocator, json_data[value_start..i]);
                }
            }
        }

        return .{ .content = content_result orelse "", .reasoning = reasoning_result };
    }

    pub fn parse(self: *SSEParser, chunk: []const u8) ![]Event {
        var events = array_list.AlignedManaged(Event, null).init(self.alloc);
        var i: usize = 0;

        while (i < chunk.len) {
            if (chunk[i] == '\r' or chunk[i] == '\n') {
                i += 1;
                if (i < chunk.len and chunk[i] == '\n') i += 1;
                continue;
            }

            if (chunk[i] == ':') {
                while (i < chunk.len and chunk[i] != '\n') i += 1;
                continue;
            }

            const field_start = i;
            while (i < chunk.len and chunk[i] != ':' and chunk[i] != '\n') i += 1;

            const field = chunk[field_start..i];
            var value: []const u8 = "";

            if (i < chunk.len and chunk[i] == ':') {
                i += 1;
                if (i < chunk.len and chunk[i] == ' ') i += 1;
                const value_start = i;
                while (i < chunk.len and chunk[i] != '\n') i += 1;
                value = chunk[value_start..i];
            }

            if (i < chunk.len and chunk[i] == '\n') i += 1;

            if (field.len == 0) {
                if (self.buf.items.len > 0) {
                    try events.append(.{ .message = .{
                        .data = try self.alloc.dupe(u8, self.buf.items),
                    }});
                    self.buf.clearRetainingCapacity();
                }
                continue;
            }

            if (std.mem.eql(u8, field, "data")) {
                if (self.buf.items.len > 0) {
                    try self.buf.append(self.alloc, ' ');
                }
                try self.buf.appendSlice(self.alloc, value);
            } else if (std.mem.eql(u8, field, "event")) {
                try events.append(.{ .message = .{
                    .event = try self.alloc.dupe(u8, value),
                    .data = try self.alloc.dupe(u8, self.buf.items),
                }});
            } else if (std.mem.eql(u8, field, "id")) {
                try events.append(.{ .message = .{
                    .id = try self.alloc.dupe(u8, value),
                }});
            } else if (std.mem.eql(u8, field, "retry")) {
                const retry = std.fmt.parseInt(u32, value, 10) catch 0;
                try events.append(.{ .retry = retry });
            }
        }

        try events.append(.{ .done = {} });
        return events.toOwnedSlice();
    }
};

test "sse parser basic" {
    var parser = SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    const chunk = "data:hello world\n\n";
    const events = try parser.parse(chunk);
    defer std.testing.allocator.free(events);

    try std.testing.expect(events.len > 0);
}

test "sse parser empty data" {
    var parser = SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    const chunk = "\n\n";
    const events = try parser.parse(chunk);
    defer std.testing.allocator.free(events);
}

test "is thinking chunk" {
    try std.testing.expect(SSEParser.isThinkingChunk("{\"reasoning_content\":\"thinking...\"}"));
    try std.testing.expect(!SSEParser.isThinkingChunk("{\"content\":\"hello\"}"));
}

test "extract thinking content" {
    const alloc = std.testing.allocator;
    const data = "{\"reasoning_content\":\"Let me think about this\"}";
    const result = try SSEParser.extractThinkingContent(alloc, data);
    defer if (result) |r| alloc.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, "Let me think about this", result.?);
}

test "extract content and thinking" {
    const alloc = std.testing.allocator;
    const data = "{\"delta\":{\"content\":\"Hello\",\"reasoning_content\":\"thinking...\"}}";
    const result = try SSEParser.extractContentAndThinking(alloc, data);
    defer {
        alloc.free(result.content);
        if (result.reasoning) |r| alloc.free(r);
    }
    try std.testing.expectEqualSlices(u8, "Hello", result.content);
    try std.testing.expect(result.reasoning != null);
}

test "extract content only" {
    const alloc = std.testing.allocator;
    const data = "{\"delta\":{\"content\":\"Hello\"}}";
    const result = try SSEParser.extractContentAndThinking(alloc, data);
    defer alloc.free(result.content);
    try std.testing.expectEqualSlices(u8, "Hello", result.content);
    try std.testing.expect(result.reasoning == null);
}
