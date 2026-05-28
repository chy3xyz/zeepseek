const std = @import("std");

pub const SseEvent = struct {
    event: []const u8 = "",
    data: []const u8 = "",
    id: []const u8 = "",
    retry: ?u32 = null,

    pub fn deinit(self: *SseEvent) void {
        _ = self;
    }
};

pub const SseStream = struct {
    allocator: std.mem.Allocator,
    reader: std.Io.Reader,
    line_buffer: []u8,
    line_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, reader: std.Io.Reader) !SseStream {
        const line_buffer = try allocator.alloc(u8, 8192);
        return .{
            .allocator = allocator,
            .reader = reader,
            .line_buffer = line_buffer,
            .line_len = 0,
        };
    }

    pub fn deinit(self: *SseStream) void {
        self.allocator.free(self.line_buffer);
    }

    pub fn nextEvent(self: *SseStream) !?SseEvent {
        var event_type: []const u8 = "";
        var data: []const u8 = "";
        var event_id: []const u8 = "";
        var retry: ?u32 = null;

        while (true) {
            const line = try self.readLine() orelse return null;
            if (line.len == 0) {
                if (data.len > 0) {
                    const event = SseEvent{
                        .event = event_type,
                        .data = data,
                        .id = event_id,
                        .retry = retry,
                    };
                    return event;
                }
                continue;
            }

            if (line[0] == ':') continue;

            const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const field = line[0..colon_idx];
            var value = line[colon_idx + 1 ..];
            if (value.len > 0 and value[0] == ' ') {
                value = value[1..];
            }

            if (std.mem.eql(u8, field, "event")) {
                event_type = value;
            } else if (std.mem.eql(u8, field, "data")) {
                if (data.len > 0) {
                    data = std.mem.concat(self.allocator, u8, &.{ data, "\n", value }) catch value;
                } else {
                    data = value;
                }
            } else if (std.mem.eql(u8, field, "id")) {
                event_id = value;
            } else if (std.mem.eql(u8, field, "retry")) {
                retry = std.fmt.parseInt(u32, value, 10) catch null;
            }
        }
    }

    fn readLine(self: *SseStream) !?[]const u8 {
        var i: usize = 0;
        while (i < self.line_buffer.len - 1) {
            const byte = self.reader.readByte() catch |err| {
                if (err == error.EndOfStream) {
                    if (i == 0) return null;
                    const result = self.line_buffer[0..i];
                    self.line_len = i;
                    return result;
                }
                return err;
            };

            if (byte == '\r') {
                const next_byte = self.reader.readByte() catch |err| {
                    if (err == error.EndOfStream) {
                        const result = self.line_buffer[0..i];
                        self.line_len = i;
                        return result;
                    }
                    return err;
                };
                if (next_byte == '\n') {
                    const result = self.line_buffer[0..i];
                    self.line_len = i;
                    return result;
                }
                self.line_buffer[i] = byte;
                i += 1;
                self.line_buffer[i] = next_byte;
                i += 1;
            } else if (byte == '\n') {
                const result = self.line_buffer[0..i];
                self.line_len = i;
                return result;
            } else {
                self.line_buffer[i] = byte;
                i += 1;
            }
        }
        return error.StreamTooLong;
    }
};

test "sse event parsing" {
    const event = SseEvent{
        .event = "message",
        .data = "Hello, World!",
        .id = "1",
        .retry = null,
    };
    try std.testing.expectEqualSlices(u8, "message", event.event);
    try std.testing.expectEqualSlices(u8, "Hello, World!", event.data);
}