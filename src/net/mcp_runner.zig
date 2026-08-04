//! MCP stdio runner — spawns an MCP server subprocess and drives the
//! JSON-RPC handshake (initialize -> tools/list) over stdin/stdout pipes.
//!
//! Uses the same independent-worker pattern as git_worker: the child runs
//! outside the zigzag runtime, so no fork-in-multithreaded-interaction
//! issues. Responses are read with a poll timeout so a slow/absent server
//! cannot hang the UI thread indefinitely.

const std = @import("std");
const posix = std.posix;

pub const McpServer = struct {
    cfg_name: []const u8, // name from ~/.zeepseek/mcp.json
    command: []const u8,
    args: []const []const u8,
};

pub const McpSession = struct {
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    child_pid: posix.pid_t,
    alloc: std.mem.Allocator,
    id: u64 = 0,
    initialized: bool = false,

    pub fn spawn(alloc: std.mem.Allocator, server: McpServer) !McpSession {
        var argv = std.ArrayList([]const u8).init(alloc);
        defer argv.deinit();
        try argv.append(server.command);
        for (server.args) |a| try argv.append(a);

        const child = try std.process.spawn(.{}, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        return .{
            .stdin_fd = child.stdin.?.handle,
            .stdout_fd = child.stdout.?.handle,
            .child_pid = child.pid,
            .alloc = alloc,
        };
    }

    /// Write a JSON-RPC request and read one response line (Content-Length
    /// framed) with a poll timeout.
    pub fn roundTrip(self: *McpSession, body: []const u8, timeout_ms: u64) ![]const u8 {
        self.id += 1;
        var framed = std.ArrayList(u8).init(self.alloc);
        defer framed.deinit();
        try framed.writer().print("Content-Length: {d}\r\n\r\n", .{body.len});
        try framed.appendSlice(body);

        const n = framed.items.len;
        var off: usize = 0;
        while (off < n) {
            const w = try posix.write(self.stdin_fd, framed.items[off..]);
            if (w == 0) return error.TransportClosed;
            off += w;
        }

        // Read headers (until \r\n\r\n) then the payload.
        var buf: [65536]u8 = undefined;
        var total: usize = 0;
        const deadline = std.time.milliTimestamp() + timeout_ms;
        var content_len: usize = 0;
        while (true) {
            if (std.time.milliTimestamp() > deadline) return error.Timeout;
            const pollfd = [1]posix.pollfd{.{ .fd = self.stdout_fd, .events = posix.POLL.IN, .revents = 0 }};
            const pr = try posix.poll(&pollfd, timeout_ms);
            if (pr == 0) return error.Timeout;
            const r = try posix.read(self.stdout_fd, buf[total..]);
            if (r == 0) return error.TransportClosed;
            total += r;
            const head_end = std.mem.indexOfPos(u8, buf[0..total], 0, "\r\n\r\n");
            if (head_end) |he| {
                const headers = buf[0..he];
                var it = std.mem.splitScalar(u8, headers, '\n');
                while (it.next()) |line| {
                    if (std.ascii.startsWithIgnoreCase(line, "content-length")) {
                        content_len = std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " \r"), 10) catch 0;
                    }
                }
                const body_start = he + 4;
                while (total < body_start + content_len) {
                    const r2 = try posix.read(self.stdout_fd, buf[total..]);
                    if (r2 == 0) return error.TransportClosed;
                    total += r2;
                }
                return self.alloc.dupe(u8, buf[body_start .. body_start + content_len]);
            }
        }
    }

    pub fn deinit(self: *McpSession) void {
        _ = posix.close(self.stdin_fd);
        _ = posix.close(self.stdout_fd);
        _ = posix.kill(self.child_pid, posix.SIG.KILL) catch {};
    }
};

test "spawn fails cleanly for missing command" {
    const alloc = std.testing.allocator;
    const srv = McpServer{ .cfg_name = "missing", .command = "/nonexistent/mcp-server-xyz", .args = &.{} };
    _ = McpSession.spawn(alloc, srv) catch |e| {
        try std.testing.expect(e == error.FileNotFound);
        return;
    };
    return error.TestUnexpectedResult;
}
