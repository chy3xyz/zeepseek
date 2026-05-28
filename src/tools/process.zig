const std = @import("std");
const sandbox_mod = @import("../utils/sandbox.zig");
const Sandbox = sandbox_mod.Sandbox;

pub const RunResult = struct {
    output: []const u8,
    success: bool,
};

/// Run a command without shell interpolation of cwd. argv is passed directly to the process.
pub fn runArgv(
    alloc: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) !RunResult {
    var threaded = std.Io.Threaded.init(alloc, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    const io = threaded.io();

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var stdout = std.ArrayList(u8).empty;
    defer stdout.deinit(alloc);
    var stderr = std.ArrayList(u8).empty;
    defer stderr.deinit(alloc);

    if (child.stdout) |out| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n_read = std.c.read(out.handle, &buf, buf.len);
            if (n_read <= 0) break;
            try stdout.appendSlice(alloc, buf[0..@intCast(n_read)]);
        }
        out.close(io);
    }
    if (child.stderr) |err_pipe| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n_read = std.c.read(err_pipe.handle, &buf, buf.len);
            if (n_read <= 0) break;
            try stderr.appendSlice(alloc, buf[0..@intCast(n_read)]);
        }
        err_pipe.close(io);
    }

    const term = child.wait(io) catch {
        return RunResult{ .output = try alloc.dupe(u8, "process wait failed"), .success = false };
    };
    const exit_ok = term == .exited and term.exited == 0;

    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(alloc);
    try combined.appendSlice(alloc, stdout.items);
    if (stderr.items.len > 0) {
        if (stdout.items.len > 0) try combined.appendSlice(alloc, "\n");
        try combined.appendSlice(alloc, stderr.items);
    }

    const max_output_len = 32 * 1024;
    const final_output = if (combined.items.len > max_output_len)
        try std.fmt.allocPrint(alloc, "{s}\n\n... ({d} chars truncated)", .{
            combined.items[0..max_output_len],
            combined.items.len - max_output_len,
        })
    else
        try alloc.dupe(u8, combined.items);

    return RunResult{ .output = final_output, .success = exit_ok };
}

/// Run a shell command in cwd via /bin/sh -c. cwd is not interpolated into the command string.
pub fn runShell(
    alloc: std.mem.Allocator,
    sandbox: ?*Sandbox,
    cwd: []const u8,
    cmd: []const u8,
) !RunResult {
    if (sandbox) |sb| {
        if (!sb.allowShell(cmd)) {
            return RunResult{
                .output = try alloc.dupe(u8, "[sandbox violation] command blocked"),
                .success = false,
            };
        }
    }

    const argv = &[_][]const u8{ "/bin/sh", "-c", cmd };
    return runArgv(alloc, cwd, argv);
}

/// Run git with explicit argv (no shell).
pub fn runGit(
    alloc: std.mem.Allocator,
    repo: []const u8,
    args: []const []const u8,
) !RunResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "git");
    try argv.appendSlice(alloc, args);
    return runArgv(alloc, repo, argv.items);
}
