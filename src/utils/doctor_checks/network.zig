//! /doctor `network` check.
//!
//! Live TCP reachability probe of the configured API endpoint.
//!
//! Parses `ctx.endpoint` (e.g. `https://api.example.com/v1/chat`), resolves
//! the host portion, opens a TCP socket, then closes it. We only verify that
//! the endpoint is routable from this machine — no HTTP round-trip is
//! performed. The probe honors `ctx.http_probe_timeout_ms` when the kernel
//! supports it (passed through as `IpAddress.ConnectOptions.timeout`).
//!
//! Robustness contract: `run` NEVER propagates an error. Any failure —
//! malformed endpoint, DNS resolution failure, TCP connect failure, or
//! allocation failure — is mapped to a `.fail` `CheckResult` with a hint
//! containing the underlying `@errorName`. The `runInner` happy path uses
//! comptime-known string fragments and a few `dupe` calls; the fallback
//! `failResult` mirrors the pattern used by the other doctor checks so
//! `/doctor` always renders something useful for this row.

const std = @import("std");
const builtin = @import("builtin");
const doctor = @import("../doctor.zig");

// ── Public entry point ────────────────────────────────────────────────

pub fn run(ctx: *const doctor.Ctx) !doctor.CheckResult {
    return runInner(ctx) catch |err| failResult(ctx, err);
}

// ── Happy path ────────────────────────────────────────────────────────

fn runInner(ctx: *const doctor.Ctx) !doctor.CheckResult {
    const a = ctx.allocator;
    const io = ctx.io;

    // 1. Parse the endpoint into scheme / host / port.
    const parsed = try parseEndpoint(ctx.endpoint);

    // 2. Resolve host → IpAddress (DNS lookup).
    const addr = std.Io.net.IpAddress.resolve(io, parsed.host, parsed.port) catch |err| {
        return failWith(a, parsed, @errorName(err));
    };

    // 3. Open a TCP stream to validate reachability. Honor the configured
    //    timeout when the implementation can express one, otherwise the
    //    connect will block at the OS default.
    const timeout: std.Io.Timeout = if (ctx.http_probe_timeout_ms == 0)
        .none
    else
        .{
            .duration = .{
                .raw = .{ .nanoseconds = @as(i96, @intCast(ctx.http_probe_timeout_ms)) * 1_000_000 },
                .clock = .awake,
            },
        };

    var stream = std.Io.net.IpAddress.connect(&addr, io, .{
        .mode = .stream,
        .protocol = .tcp,
        .timeout = timeout,
    }) catch |err| {
        return failWith(a, parsed, @errorName(err));
    };
    defer std.Io.net.Stream.close(&stream, io);

    // 4. Format the resolved IP for the success detail line.
    var ip_buf: [64]u8 = undefined;
    var ip_w: std.Io.Writer = .fixed(&ip_buf);
    std.Io.net.IpAddress.format(addr, &ip_w) catch {};

    const name = try a.dupe(u8, "network");
    const detail = try std.fmt.allocPrint(a, "reachable: {s}:{d} (resolved to {s})", .{
        parsed.host,
        parsed.port,
        ip_buf[0..ip_w.end],
    });

    return .{
        .name = name,
        .status = .pass,
        .detail = detail,
        .hint = null,
    };
}

// ── Endpoint parsing ──────────────────────────────────────────────────

const ParsedEndpoint = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
};

const ParseEndpointError = error{ InvalidEndpoint, InvalidPort };

/// Parses `<scheme>://<host[:port]>/<rest...>` into its constituent parts.
/// The host may not contain a `/` (only the first `/` after `://` is treated
/// as the path separator). Port defaults to 443 for `https` and 80 for
/// `http`; any other scheme is rejected.
fn parseEndpoint(endpoint: []const u8) ParseEndpointError!ParsedEndpoint {
    // Strip "scheme://"
    const sep_idx = std.mem.indexOf(u8, endpoint, "://") orelse
        return error.InvalidEndpoint;
    if (sep_idx == 0) return error.InvalidEndpoint;
    const scheme = endpoint[0..sep_idx];
    const rest = endpoint[sep_idx + 3 ..];

    // Take everything up to the next "/" as host[:port].
    const path_idx = std.mem.indexOfScalar(u8, rest, '/');
    const host_port = if (path_idx) |i| rest[0..i] else rest;
    if (host_port.len == 0) return error.InvalidEndpoint;

    // Split host and explicit port (if any).
    const colon_idx = std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host: []const u8 = if (colon_idx) |i| host_port[0..i] else host_port;
    if (host.len == 0) return error.InvalidEndpoint;

    const port: u16 = if (colon_idx) |i|
        std.fmt.parseInt(u16, host_port[i + 1 ..], 10) catch return error.InvalidPort
    else if (std.mem.eql(u8, scheme, "https"))
        443
    else if (std.mem.eql(u8, scheme, "http"))
        80
    else
        return error.InvalidEndpoint;

    return .{ .scheme = scheme, .host = host, .port = port };
}

// ── Failure paths ─────────────────────────────────────────────────────

/// Build a `.fail` result that includes the parsed host:port in the
/// detail line and the underlying error name in the hint. Allocates
/// with `a`; if any allocation fails, the caller (which has already
/// caught an error) will run through `failResult` instead.
fn failWith(
    a: std.mem.Allocator,
    parsed: ParsedEndpoint,
    err_name: []const u8,
) !doctor.CheckResult {
    const name = try a.dupe(u8, "network");
    errdefer a.free(name);
    const detail = try std.fmt.allocPrint(a, "cannot reach {s}:{d}", .{
        parsed.host,
        parsed.port,
    });
    errdefer a.free(detail);
    const hint = try a.dupe(u8, err_name);
    return .{
        .name = name,
        .status = .fail,
        .detail = detail,
        .hint = hint,
    };
}

/// Last-resort fallback when `runInner` cannot even allocate. Mirrors the
/// synthetic-result pattern used by `doctor.runAll` so the framework still
/// renders a meaningful row. If the dupe itself fails, fall back to string
/// literals (the same pragmatic compromise used throughout the framework).
fn failResult(ctx: *const doctor.Ctx, err: anyerror) doctor.CheckResult {
    const a = ctx.allocator;
    return .{
        .name = a.dupe(u8, "network") catch "network",
        .status = .fail,
        .detail = a.dupe(u8, "network probe failed") catch "network probe failed",
        .hint = a.dupe(u8, @errorName(err)) catch null,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

test "parseEndpoint: https default port" {
    const p = try parseEndpoint("https://api.example.com/v1/chat");
    try std.testing.expectEqualStrings("https", p.scheme);
    try std.testing.expectEqualStrings("api.example.com", p.host);
    try std.testing.expectEqual(@as(u16, 443), p.port);
}

test "parseEndpoint: http default port" {
    const p = try parseEndpoint("http://localhost:8080/path");
    try std.testing.expectEqualStrings("http", p.scheme);
    try std.testing.expectEqualStrings("localhost", p.host);
    try std.testing.expectEqual(@as(u16, 8080), p.port);
}

test "parseEndpoint: explicit https port" {
    const p = try parseEndpoint("https://api.example.com:8443/x");
    try std.testing.expectEqualStrings("api.example.com", p.host);
    try std.testing.expectEqual(@as(u16, 8443), p.port);
}

test "parseEndpoint: no trailing path" {
    const p = try parseEndpoint("https://api.example.com");
    try std.testing.expectEqualStrings("api.example.com", p.host);
    try std.testing.expectEqual(@as(u16, 443), p.port);
}

test "parseEndpoint: rejects unknown scheme" {
    try std.testing.expectError(error.InvalidEndpoint, parseEndpoint("ftp://example.com/"));
}

test "parseEndpoint: rejects missing scheme" {
    try std.testing.expectError(error.InvalidEndpoint, parseEndpoint("api.example.com"));
}

test "parseEndpoint: rejects empty host" {
    try std.testing.expectError(error.InvalidEndpoint, parseEndpoint("https:///path"));
}

test "parseEndpoint: rejects invalid port" {
    try std.testing.expectError(error.InvalidPort, parseEndpoint("http://h:abc/"));
}
