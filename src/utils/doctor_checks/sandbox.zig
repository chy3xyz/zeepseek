//! /doctor `sandbox` check.
//!
//! Reports which sandbox backend Zeepseek would activate on the current
//! platform. This is purely informational — no sandboxed process is spawned
//! and no syscall that requires privileges is issued. The backend is
//! determined by `builtin.target.os.tag`, mirroring `Policy.host()` in
//! `src/utils/sandbox.zig`:
//!
//! | OS       | Backend     |
//! |----------|-------------|
//! | macOS    | `seatbelt`  |
//! | Linux    | `landlock`  |
//! | Windows  | `job_object`|
//! | other    | `none`      |
//!
//! `Status` is `.pass` for a real backend and `.warn` for `none` so the user
//! notices that no OS-level isolation is configured.

const std = @import("std");
const builtin = @import("builtin");
const doctor = @import("../doctor.zig");

// ── Platform / backend resolution (compile-time) ──────────────────────
//
// Resolving the backend at comptime keeps `run` allocation-light: the only
// runtime work is the two `dupe` calls. The string map intentionally
// duplicates the logic in `src/utils/sandbox.zig::Policy.host` so the
// doctor check remains independent and stable even if that file evolves.

const Backend = enum { seatbelt, landlock, job_object, none };

const resolved = struct {
    const os_tag = builtin.target.os.tag;

    const backend: Backend = switch (os_tag) {
        .macos => .seatbelt,
        .linux => .landlock,
        .windows => .job_object,
        else => .none,
    };

    const platform_label: []const u8 = switch (os_tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => @tagName(os_tag),
    };

    const backend_label: []const u8 = switch (backend) {
        .seatbelt => "seatbelt",
        .landlock => "landlock",
        .job_object => "job_object",
        .none => "none",
    };

    /// `true` when a real OS-level sandbox backend is available.
    const is_real: bool = backend != .none;
};

// ── Public entry point ────────────────────────────────────────────────

pub fn run(ctx: *const doctor.Ctx) !doctor.CheckResult {
    // Per the doctor framework's robustness contract, `run` must NEVER
    // propagate an error. The happy path uses comptime-resolved strings and
    // exactly two runtime allocations; the `catch` arm downgrades any
    // allocation failure to a `fail` result with the error name as a hint,
    // so `/doctor` always renders something for this check.
    return runInner(ctx) catch |err| failResult(ctx, err);
}

fn runInner(ctx: *const doctor.Ctx) !doctor.CheckResult {
    const a = ctx.allocator;

    const detail_src = std.fmt.comptimePrint("{s} → {s}", .{
        resolved.platform_label,
        resolved.backend_label,
    });

    const name = try a.dupe(u8, "sandbox");
    const detail = try a.dupe(u8, detail_src);
    const hint: ?[]const u8 = if (resolved.is_real)
        null
    else
        try a.dupe(u8, "no sandbox backend is configured for this platform; subagent and shell tools will fall back to command-level restrictions");

    return .{
        .name = name,
        .status = if (resolved.is_real) .pass else .warn,
        .detail = detail,
        .hint = hint,
    };
}

/// Build a `.fail` CheckResult when `runInner` cannot allocate. Mirrors the
/// fallback pattern used by `doctor.runAll` so a synthetic result is always
/// renderable; if the dupe itself fails we fall back to static strings (the
/// same pragmatic compromise used throughout the doctor framework).
fn failResult(ctx: *const doctor.Ctx, err: anyerror) doctor.CheckResult {
    const a = ctx.allocator;
    return .{
        .name = a.dupe(u8, "sandbox") catch "sandbox",
        .status = .fail,
        .detail = a.dupe(u8, "sandbox check failed") catch "sandbox check failed",
        .hint = a.dupe(u8, @errorName(err)) catch null,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

test "run returns pass on a platform with a real backend" {
    if (resolved.backend == .none) return error.SkipZigTest;

    const ctx: doctor.Ctx = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .api_key = "",
        .provider = "",
        .model = "",
        .endpoint = "",
        .data_dir = "",
    };

    const result = try run(&ctx);
    defer std.testing.allocator.free(result.name);
    defer std.testing.allocator.free(result.detail);
    if (result.hint) |h| defer std.testing.allocator.free(h);

    try std.testing.expectEqualStrings("sandbox", result.name);
    try std.testing.expect(result.status == .pass);
    try std.testing.expect(result.hint == null);
    try std.testing.expect(std.mem.indexOf(u8, result.detail, resolved.platform_label) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.detail, resolved.backend_label) != null);
}

test "run returns warn with hint on platforms without a backend" {
    if (resolved.backend != .none) return error.SkipZigTest;

    const ctx: doctor.Ctx = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .api_key = "",
        .provider = "",
        .model = "",
        .endpoint = "",
        .data_dir = "",
    };

    const result = try run(&ctx);
    defer std.testing.allocator.free(result.name);
    defer std.testing.allocator.free(result.detail);
    if (result.hint) |h| defer std.testing.allocator.free(h);

    try std.testing.expectEqualStrings("sandbox", result.name);
    try std.testing.expect(result.status == .warn);
    try std.testing.expect(result.hint != null);
    try std.testing.expectEqualStrings("none", resolved.backend_label);
}
