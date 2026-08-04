const std = @import("std");
const sandbox_mod = @import("../utils/sandbox.zig");
const c = @import("c");
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
    // Synchronous popen pipeline (same path as runShell, verified in-app).
    // std.process.spawn(io) + blocking std.c.read on io-managed pipes
    // stalls inside the zigzag runtime.
    var cmd = std.ArrayList(u8).empty;
    defer cmd.deinit(alloc);
    try cmd.appendSlice(alloc, "cd ");
    try cmd.appendSlice(alloc, cwd);
    try cmd.appendSlice(alloc, " && ");
    for (argv, 0..) |arg, i| {
        if (i > 0) try cmd.append(alloc, ' ');
        try cmd.append(alloc, '\'');
        try cmd.appendSlice(alloc, arg);
        try cmd.append(alloc, '\'');
    }
    const cmd_z = try alloc.dupeSentinel(u8, cmd.items, 0);
    defer alloc.free(cmd_z);
    const fp = c.popen(cmd_z.ptr, "r") orelse return error.SpawnFailed;
    defer _ = c.pclose(fp);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    return .{ .output = try out.toOwnedSlice(alloc), .success = true };
}

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

test "runArgv executes a command and captures output" {
    const alloc = std.testing.allocator;
    const result = try runArgv(alloc, "/tmp", &.{ "sh", "-c", "echo hello" });
    defer alloc.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expectEqualSlices(u8, "hello\n", result.output);
}

test "runArgv reports non-zero exit as failure" {
    const alloc = std.testing.allocator;
    const result = try runArgv(alloc, "/tmp", &.{ "sh", "-c", "exit 3" });
    defer alloc.free(result.output);
    try std.testing.expect(!result.success);
}

test "runArgv merges stderr into output" {
    const alloc = std.testing.allocator;
    const result = try runArgv(alloc, "/tmp", &.{ "sh", "-c", "echo out; echo oops >&2" });
    defer alloc.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "oops") != null);
}

test "runShell without sandbox runs /bin/sh -c" {
    const alloc = std.testing.allocator;
    const result = try runShell(alloc, null, "/tmp", "echo shell-ok");
    defer alloc.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expectEqualSlices(u8, "shell-ok\n", result.output);
}

test "runShell output is capped" {
    const alloc = std.testing.allocator;
    const result = try runShell(alloc, null, "/tmp", "yes x | head -c 200000");
    defer alloc.free(result.output);
    try std.testing.expect(result.output.len < 200000);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "truncated") != null);
}
