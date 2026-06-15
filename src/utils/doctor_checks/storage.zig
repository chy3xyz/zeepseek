//! `/doctor` storage check.
//!
//! Verifies that the configured data directory exists and is writable by
//! creating and removing a small probe file. Failure here means new
//! sessions and the KV cache cannot be persisted, which will silently
//! degrade the user experience.

const std = @import("std");
const doctor = @import("../doctor.zig");

const PROBE_NAME = ".zeepseek-doctor.tmp";

pub fn run(ctx: *const doctor.Ctx) !doctor.CheckResult {
    return runInner(ctx) catch |err| failResult(ctx, err);
}

fn runInner(ctx: *const doctor.Ctx) !doctor.CheckResult {
    const a = ctx.allocator;
    const io = ctx.io;

    if (ctx.data_dir.len == 0) {
        return .{
            .name = try a.dupe(u8, "storage"),
            .status = .fail,
            .detail = try a.dupe(u8, "data_dir is empty"),
            .hint = try a.dupe(u8, "configure a writable data directory"),
        };
    }

    // Try to open the directory.
    const dir = std.Io.Dir.openDirAbsolute(io, ctx.data_dir, .{}) catch |err| {
        const detail = try std.fmt.allocPrint(a, "cannot open {s}", .{ctx.data_dir});
        const hint_name = @errorName(err);
        return .{
            .name = try a.dupe(u8, "storage"),
            .status = .fail,
            .detail = detail,
            .hint = try a.dupe(u8, hint_name),
        };
    };
    defer std.Io.Dir.close(dir, io);

    // Create + write + sync a probe file, then delete it. This exercises
    // every permission bit the real store needs.
    const probe_path = try std.fs.path.join(a, &.{ ctx.data_dir, PROBE_NAME });
    defer a.free(probe_path);

    const file = std.Io.Dir.createFile(dir, io, PROBE_NAME, .{}) catch |err| {
        const detail = try std.fmt.allocPrint(a, "cannot create probe file in {s}", .{ctx.data_dir});
        return .{
            .name = try a.dupe(u8, "storage"),
            .status = .fail,
            .detail = detail,
            .hint = try a.dupe(u8, @errorName(err)),
        };
    };
    defer std.Io.File.close(file, io);

    std.Io.File.writeStreamingAll(file, io, "doctor") catch |err| {
        return .{
            .name = try a.dupe(u8, "storage"),
            .status = .fail,
            .detail = try a.dupe(u8, "cannot write to probe file"),
            .hint = try a.dupe(u8, @errorName(err)),
        };
    };

    std.Io.Dir.deleteFile(dir, io, PROBE_NAME) catch {
        // best effort; not fatal for the report
    };

    return .{
        .name = try a.dupe(u8, "storage"),
        .status = .pass,
        .detail = try std.fmt.allocPrint(a, "writable: {s}", .{ctx.data_dir}),
    };
}

fn failResult(ctx: *const doctor.Ctx, err: anyerror) doctor.CheckResult {
    const a = ctx.allocator;
    return .{
        .name = a.dupe(u8, "storage") catch "storage",
        .status = .fail,
        .detail = a.dupe(u8, "storage check failed") catch "storage check failed",
        .hint = a.dupe(u8, @errorName(err)) catch null,
    };
}
