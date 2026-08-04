//! Standalone git worker process.
//!
//! Spawned once at app startup (--git-worker) so the main process never
//! forks inside the zigzag runtime (popen/spawn from the UI/stream threads
//! stalls). This process is single-threaded with no zigzag runtime, so
//! popen is safe here.
//!
//! Protocol:
//!   request (stdin):  "cwd\x1farg1\x1farg2...\n"
//!   response (stdout): "ok\x1f<len>\n<output>"  or  "err\x1f<len>\n<message>"

const std = @import("std");
const c = @import("c");
const builtin = @import("builtin");

const MAX_LINE: usize = 8192;

pub fn main(init: std.process.Init) !void {
    _ = init;
    var line_buf: [MAX_LINE]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        // Read one byte at a time until newline (command lines are short).
        var byte: [1]u8 = undefined;
        const n = std.c.read(0, &byte, 1);
        if (n <= 0) break;
        if (byte[0] == '\n') {
            if (line_len > 0) {
                handleCommand(line_buf[0..line_len]);
                line_len = 0;
            }
        } else if (line_len < MAX_LINE) {
            line_buf[line_len] = byte[0];
            line_len += 1;
        }
    }
}

fn handleCommand(cmd_line: []const u8) void {
    // Split on \x1f: first field = cwd, rest = git argv.
    var fields = std.mem.splitScalar(u8, cmd_line, 0x1f);
    const cwd = fields.next() orelse return;
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(std.heap.page_allocator);
    while (fields.next()) |f| {
        if (f.len > 0) args.append(std.heap.page_allocator, f) catch return;
    }
    // Build "cd <cwd> && git <args>" via popen (single-threaded here).
    var cmd = std.ArrayList(u8).empty;
    defer cmd.deinit(std.heap.page_allocator);
    cmd.appendSlice(std.heap.page_allocator, "cd ") catch return;
    cmd.appendSlice(std.heap.page_allocator, cwd) catch return;
    cmd.appendSlice(std.heap.page_allocator, " && git") catch return;
    for (args.items) |arg| {
        cmd.append(std.heap.page_allocator, ' ') catch return;
        cmd.append(std.heap.page_allocator, '\'') catch return;
        cmd.appendSlice(std.heap.page_allocator, arg) catch return;
        cmd.append(std.heap.page_allocator, '\'') catch return;
    }
    const cmd_z = std.heap.page_allocator.dupeSentinel(u8, cmd.items, 0) catch return;
    defer std.heap.page_allocator.free(cmd_z);

    const fp = c.popen(cmd_z.ptr, "r") orelse {
        writeResponse("err", "failed to spawn git");
        return;
    };
    defer _ = c.pclose(fp);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.heap.page_allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const r = c.fread(&buf, 1, buf.len, fp);
        if (r == 0) break;
        out.appendSlice(std.heap.page_allocator, buf[0..r]) catch break;
    }
    writeResponse("ok", out.items);
}

fn writeResponse(status: []const u8, payload: []const u8) void {
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s}\x1f{d}\n", .{ status, payload.len }) catch return;
    _ = std.c.write(1, header.ptr, header.len);
    if (payload.len > 0) {
        _ = std.c.write(1, payload.ptr, payload.len);
    }
}

/// Client side: spawns the worker once and communicates over pipes.
/// runGit() blocks on the worker's response (~10ms for git status) but
/// never forks — safe from any thread inside the zigzag runtime.
extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

pub const Client = struct {
    stdin_fd: std.posix.fd_t,
    stdout_fd: std.posix.fd_t,

    pub fn spawn(io: std.Io) !Client {
        var exe_buf: [4096]u8 = undefined;
        var sz: u32 = @intCast(exe_buf.len);
        if (builtin.os.tag == .macos) {
            _ = _NSGetExecutablePath(&exe_buf, &sz);
        }
        const exe = exe_buf[0..@intCast(sz)];
        const child = try std.process.spawn(io, .{
            .argv = &.{ exe, "--git-worker" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        return .{
            .stdin_fd = child.stdin.?.handle,
            .stdout_fd = child.stdout.?.handle,
        };
    }

    /// Runs `git <args>` in `cwd`; returns an owned output string (caller
    /// frees) or null on failure.
    pub fn runGit(self: *Client, alloc: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ?[]const u8 {
        var cmd = std.ArrayList(u8).empty;
        defer cmd.deinit(alloc);
        cmd.appendSlice(alloc, cwd) catch return null;
        for (args) |a| {
            cmd.append(alloc, 0x1f) catch return null;
            cmd.appendSlice(alloc, a) catch return null;
        }
        cmd.append(alloc, '\n') catch return null;

        var off: usize = 0;
        while (off < cmd.items.len) {
            const n = std.c.write(self.stdin_fd, cmd.items.ptr + off, cmd.items.len - off);
            if (n <= 0) return null;
            off += @intCast(n);
        }

        // Header: "status\x1f<len>\n" (byte at a time; short).
        var header: [64]u8 = undefined;
        var hlen: usize = 0;
        while (hlen < header.len) : (hlen += 1) {
            const n = std.c.read(self.stdout_fd, header[hlen..][0..1].ptr, 1);
            if (n <= 0) return null;
            if (header[hlen] == '\n') break;
        }
        const header_line = header[0..hlen];
        var fields = std.mem.splitScalar(u8, header_line, 0x1f);
        _ = fields.next() orelse return null; // status
        const len_str = fields.next() orelse return null;
        const payload_len = std.fmt.parseInt(usize, len_str, 10) catch return null;
        if (payload_len == 0) return alloc.dupe(u8, "") catch null;

        const out = alloc.alloc(u8, payload_len) catch return null;
        var got: usize = 0;
        while (got < payload_len) {
            const n = std.c.read(self.stdout_fd, out.ptr + got, payload_len - got);
            if (n <= 0) {
                alloc.free(out);
                return null;
            }
            got += @intCast(n);
        }
        return out;
    }
};
