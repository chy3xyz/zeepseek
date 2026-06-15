//! `/doctor` build check.
//!
//! Reports the compile-time build environment: zig version, target
//! OS/arch, optimization mode, and (if available) the current git
//! commit. Always informational — never a health gate.

const std = @import("std");
const builtin = @import("builtin");
const doctor = @import("../doctor.zig");

// ── Public entry point ─────────────────────────────────────────────────

pub fn run(ctx: *const doctor.Ctx) !doctor.CheckResult {
    return buildResult(ctx) catch |err| failResult(ctx.allocator, err);
}

// ── Failure path ───────────────────────────────────────────────────────

fn failResult(alloc: std.mem.Allocator, err: anyerror) doctor.CheckResult {
    // Best-effort allocations: if even the fallback allocations fail, use
    // string literals so the framework can still report *something*.
    const name = alloc.dupe(u8, "build/env") catch "build/env";
    const detail = alloc.dupe(u8, "could not format build info") catch "could not format build info";
    const hint = alloc.dupe(u8, @errorName(err)) catch null;
    return .{
        .name = name,
        .status = .fail,
        .detail = detail,
        .hint = hint,
    };
}

// ── Success path ───────────────────────────────────────────────────────

fn buildResult(ctx: *const doctor.Ctx) !doctor.CheckResult {
    const alloc = ctx.allocator;
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);

    // "zig X.Y.Z[-pre]"
    const v = builtin.zig_version;
    try buf.print(alloc, "zig {d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    if (v.pre) |pre| try buf.print(alloc, "-{s}", .{pre});

    // " on os/arch"
    try buf.print(alloc, " on {s}/{s}", .{
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.cpu.arch),
    });

    // " (Mode)"
    try buf.print(alloc, " ({s})", .{modeLabel(builtin.mode)});

    // Optional " git:<sha>" — never fails the check.
    appendGitSuffix(ctx, &buf);

    const detail = try buf.toOwnedSlice(alloc);
    errdefer alloc.free(detail);

    const name = try alloc.dupe(u8, "build/env");
    errdefer alloc.free(name);

    return .{
        .name = name,
        .status = .pass,
        .detail = detail,
        .hint = null,
    };
}

fn modeLabel(mode: std.builtin.OptimizeMode) []const u8 {
    return switch (mode) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    };
}

// ── Git suffix (best-effort) ───────────────────────────────────────────

/// Try to read the short SHA from `.git/HEAD` and the resolved ref.
/// On any failure (no `.git`, no ref, truncated content, I/O error)
/// the function silently returns without appending anything.
fn appendGitSuffix(ctx: *const doctor.Ctx, buf: *std.ArrayList(u8)) void {
    const alloc = ctx.allocator;
    const io = ctx.io;

    const cwd = std.Io.Dir.cwd();

    // 1. Read `.git/HEAD`
    var head_buf: [256]u8 = undefined;
    const head_file = cwd.openFile(io, ".git/HEAD", .{}) catch return;
    defer std.Io.File.close(head_file, io);
    const head_len = std.Io.File.readPositionalAll(head_file, io, &head_buf, 0) catch return;
    var head = std.mem.trim(u8, head_buf[0..head_len], " \t\r\n");
    if (head.len == 0) return;

    const sha: []const u8 = sha: {
        const ref_prefix = "ref: refs/heads/";
        if (std.mem.startsWith(u8, head, ref_prefix)) {
            // Symbolic ref — resolve to `.git/refs/heads/<branch>`.
            const ref = head[ref_prefix.len..];
            const ref_path = std.fs.path.join(alloc, &.{ ".git", ref }) catch return;
            defer alloc.free(ref_path);

            var sha_buf: [64]u8 = undefined;
            const sha_file = cwd.openFile(io, ref_path, .{}) catch return;
            defer std.Io.File.close(sha_file, io);
            const sha_len = std.Io.File.readPositionalAll(sha_file, io, &sha_buf, 0) catch return;
            break :sha std.mem.trim(u8, sha_buf[0..sha_len], " \t\r\n");
        }
        // Detached HEAD — the file already contains the SHA.
        break :sha head;
    };

    if (sha.len < 7) return;
    const short = sha[0..@min(sha.len, 12)];
    buf.print(alloc, " git:{s}", .{short}) catch return;
}
