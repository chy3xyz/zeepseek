//! Zeepseek `/doctor` self-check framework.
//!
//! Runs a battery of runtime health checks (build, config, network, storage,
//! sandbox) and produces a report the TUI can render. Each check is a
//! standalone module under `doctor_checks/` that implements
//! `pub fn run(ctx: *const Ctx) !CheckResult` against the interface defined
//! here, so checks can be added, replaced, and unit-tested independently.
//!
//! Robustness: `runAll` never panics. Every check is expected to catch its
//! own errors and return a `fail` result with a helpful detail/hint
//! instead of propagating. Any leaked error becomes a synthetic
//! `{ pass = false, hint = "<error name>" }` entry.

const std = @import("std");

pub const Status = enum { pass, warn, fail };

pub const CheckResult = struct {
    name: []const u8,
    status: Status,
    detail: []const u8,
    hint: ?[]const u8 = null,
};

/// Read-only context passed to every check. Fields are owned by the caller
/// (the App). Checks must not free them. They may allocate their own
/// `name` / `detail` / `hint` strings with `ctx.allocator`; the report
/// owns them afterwards and `Report.deinit` releases them.
pub const Ctx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api_key: []const u8,
    provider: []const u8,
    model: []const u8,
    endpoint: []const u8,
    data_dir: []const u8,
    /// If the streaming / HTTP layer is initialized, this is its allocator
    /// and io; checks can use it for live probes.
    http_probe_timeout_ms: u32 = 5000,
};

pub const Summary = struct { pass: usize, warn: usize, fail: usize };

pub const Report = struct {
    results: []CheckResult,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.results) |r| {
            allocator.free(r.name);
            allocator.free(r.detail);
            if (r.hint) |h| allocator.free(h);
        }
        allocator.free(self.results);
        self.* = .{ .results = &.{} };
    }

    /// Aggregate counts.
    pub fn summary(self: *const Report) Summary {
        var s: Summary = .{ .pass = 0, .warn = 0, .fail = 0 };
        for (self.results) |r| switch (r.status) {
            .pass => s.pass += 1,
            .warn => s.warn += 1,
            .fail => s.fail += 1,
        };
        return s;
    }

    /// Render a human-readable plain-text report.
    pub fn render(self: *const Report, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "Zeepseek /doctor\n");
        try out.appendSlice(allocator, "================\n\n");

        for (self.results) |r| {
            const tag: []const u8 = switch (r.status) {
                .pass => "[ PASS ]",
                .warn => "[ WARN ]",
                .fail => "[ FAIL ]",
            };
            try out.print(allocator, "{s} {s}\n", .{ tag, r.name });
            try out.print(allocator, "        {s}\n", .{r.detail});
            if (r.hint) |h| try out.print(allocator, "        hint: {s}\n", .{h});
            try out.append(allocator, '\n');
        }

        const s = self.summary();
        try out.print(allocator, "summary: {d} pass, {d} warn, {d} fail\n", .{ s.pass, s.warn, s.fail });
        return out.toOwnedSlice(allocator);
    }
};

/// Run every registered check, catching any error so a single broken check
/// can never prevent the rest of the report from being shown.
pub fn runAll(ctx: *const Ctx) Report {
    var results = std.ArrayList(CheckResult).empty;
    errdefer {
        for (results.items) |r| {
            ctx.allocator.free(r.name);
            ctx.allocator.free(r.detail);
            if (r.hint) |h| ctx.allocator.free(h);
        }
        results.deinit(ctx.allocator);
    }

    const modules = .{
        @import("doctor_checks/build.zig"),
        @import("doctor_checks/config.zig"),
        @import("doctor_checks/network.zig"),
        @import("doctor_checks/storage.zig"),
        @import("doctor_checks/sandbox.zig"),
    };

    inline for (modules) |mod| {
        const r = mod.run(ctx) catch |err| CheckResult{
            .name = ctx.allocator.dupe(u8, @typeName(mod)) catch "<check>",
            .status = .fail,
            .detail = ctx.allocator.dupe(u8, "check threw an error") catch "check threw an error",
            .hint = ctx.allocator.dupe(u8, @errorName(err)) catch null,
        };
        results.append(ctx.allocator, r) catch {
            // allocator failure while building the report itself: give up
            // on appending further results, the partial report is still
            // returned below.
            break;
        };
    }

    return .{
        .results = results.toOwnedSlice(ctx.allocator) catch &.{},
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

test "Report.summary counts statuses" {
    const r = Report{ .results = &.{
        .{ .name = "a", .status = .pass, .detail = "" },
        .{ .name = "b", .status = .pass, .detail = "" },
        .{ .name = "c", .status = .warn, .detail = "" },
        .{ .name = "d", .status = .fail, .detail = "" },
    } };
    const s = r.summary();
    try std.testing.expectEqual(@as(usize, 2), s.pass);
    try std.testing.expectEqual(@as(usize, 1), s.warn);
    try std.testing.expectEqual(@as(usize, 1), s.fail);
}

test "Report.render produces header, every check, and summary line" {
    const alloc = std.testing.allocator;
    const r = Report{ .results = &.{
        .{ .name = "ok", .status = .pass, .detail = "fine" },
        .{ .name = "oops", .status = .fail, .detail = "broken", .hint = "reboot" },
    } };
    const out = try r.render(alloc);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "Zeepseek /doctor") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[ PASS ] ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[ FAIL ] oops") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hint: reboot") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "summary: 1 pass, 0 warn, 1 fail") != null);
}
