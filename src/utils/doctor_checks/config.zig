//! `/doctor` config check.
//!
//! Validates the user-configurable fields on `Ctx` without doing any
//! network I/O. Failures here point at misconfiguration (missing key,
//! wrong scheme, blank model) that would break every other check or
//! every API call downstream.

const std = @import("std");
const doctor = @import("../doctor.zig");

pub fn run(ctx: *const doctor.Ctx) !doctor.CheckResult {
    return runInner(ctx) catch |err| failResult(ctx.allocator, err);
}

fn runInner(ctx: *const doctor.Ctx) !doctor.CheckResult {
    const a = ctx.allocator;

    // 1. API key presence + length sanity.
    if (ctx.api_key.len == 0) {
        return .{
            .name = try a.dupe(u8, "config"),
            .status = .fail,
            .detail = try a.dupe(u8, "api_key is empty"),
            .hint = try a.dupe(u8, "run /apikey <key> in the TUI, or set DEEPSEEK_API_KEY"),
        };
    }
    if (ctx.api_key.len < 8) {
        return .{
            .name = try a.dupe(u8, "config"),
            .status = .warn,
            .detail = try a.dupe(u8, "api_key is suspiciously short"),
            .hint = try a.dupe(u8, "deepseek keys are typically sk-... and ≥ 32 chars"),
        };
    }

    // 2. Provider / model / endpoint must be present and well-formed.
    if (ctx.provider.len == 0) {
        return .{
            .name = try a.dupe(u8, "config"),
            .status = .fail,
            .detail = try a.dupe(u8, "provider is empty"),
            .hint = try a.dupe(u8, "pick a provider with /provider <name>"),
        };
    }
    if (ctx.model.len == 0) {
        return .{
            .name = try a.dupe(u8, "config"),
            .status = .fail,
            .detail = try a.dupe(u8, "model is empty"),
            .hint = try a.dupe(u8, "pick a model with /model <name>"),
        };
    }
    if (!std.mem.startsWith(u8, ctx.endpoint, "http://") and
        !std.mem.startsWith(u8, ctx.endpoint, "https://"))
    {
        return .{
            .name = try a.dupe(u8, "config"),
            .status = .fail,
            .detail = try a.dupe(u8, "endpoint does not start with http(s)://"),
            .hint = try a.dupe(u8, "check the provider's base URL"),
        };
    }

    if (ctx.data_dir.len == 0) {
        return .{
            .name = try a.dupe(u8, "config"),
            .status = .warn,
            .detail = try a.dupe(u8, "data_dir is empty"),
            .hint = try a.dupe(u8, "sessions and the KV store will be created in CWD"),
        };
    }

    // 3. All good — mask the key and report.
    const masked = maskKey(a, ctx.api_key) catch ctx.api_key;
    const detail = try std.fmt.allocPrint(
        a,
        "api_key={s} provider={s} model={s} endpoint={s}",
        .{ masked, ctx.provider, ctx.model, ctx.endpoint },
    );
    return .{
        .name = try a.dupe(u8, "config"),
        .status = .pass,
        .detail = detail,
    };
}

/// Show the first 3 chars + "***" + last 2 chars. Falls back to "sk-***"
/// for short keys.
fn maskKey(a: std.mem.Allocator, key: []const u8) ![]u8 {
    if (key.len <= 8) return a.dupe(u8, "sk-***");
    return std.fmt.allocPrint(a, "{s}***{s}", .{ key[0..3], key[key.len - 2 ..] });
}

fn failResult(a: std.mem.Allocator, err: anyerror) doctor.CheckResult {
    return .{
        .name = a.dupe(u8, "config") catch "config",
        .status = .fail,
        .detail = a.dupe(u8, "config check failed") catch "config check failed",
        .hint = a.dupe(u8, @errorName(err)) catch null,
    };
}

test "maskKey: short key returns sk-***" {
    try std.testing.expectEqualStrings("sk-***", try maskKey(std.testing.allocator, "short"));
}

test "maskKey: long key masks middle" {
    const out = try maskKey(std.testing.allocator, "sk-abcdefghijklmnop");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("sk-***op", out);
}
