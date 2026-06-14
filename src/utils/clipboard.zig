//! Cross-platform clipboard writer.
//!
//! Provides a single entry point, `copyText`, that writes UTF-8 text to the
//! system clipboard by spawning the platform's standard external tool:
//! - macOS:   pbcopy
//! - Linux:   wl-copy (Wayland) or xclip (X11)
//! - Windows: clip (via cmd /c clip)

const std = @import("std");

pub const ClipboardError = error{
    ClipboardCommandNotFound,
    ClipboardCopyFailed,
};

/// Write `text` to the system clipboard using the platform's standard tool.
/// macOS: pbcopy
/// Linux Wayland: wl-copy
/// Linux X11: xclip -selection clipboard
/// Windows: clip (via cmd /c clip)
pub fn copyText(allocator: std.mem.Allocator, io: std.Io, text: []const u8) ClipboardError!void {
    const argv = clipboardArgv(allocator) orelse return error.ClipboardCommandNotFound;

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.ClipboardCopyFailed;

    if (child.stdin) |stdin| {
        std.Io.File.writeStreamingAll(stdin, io, text) catch return error.ClipboardCopyFailed;
        std.Io.File.close(stdin, io);
        child.stdin = null;
    }

    const term = std.process.Child.wait(&child, io) catch return error.ClipboardCopyFailed;
    if (!term.success()) return error.ClipboardCopyFailed;
}

/// Select the platform-appropriate clipboard command argv, or null if no
/// supported tool can be located.
fn clipboardArgv(allocator: std.mem.Allocator) ?[]const []const u8 {
    const target = @import("builtin").target;
    return switch (target.os.tag) {
        .macos => if (commandExists(allocator, "pbcopy")) &.{ "pbcopy" } else null,
        .linux => detectLinuxClipboardTool(allocator),
        .windows => if (commandExists(allocator, "cmd")) &.{ "cmd", "/c", "clip" } else null,
        else => null,
    };
}

/// At runtime, prefer wl-copy if WAYLAND_DISPLAY is set and the binary exists,
/// otherwise fall back to xclip. This avoids hard-coding the session type.
fn detectLinuxClipboardTool(allocator: std.mem.Allocator) ?[]const []const u8 {
    const has_wl_copy = commandExists(allocator, "wl-copy");
    const has_xclip = commandExists(allocator, "xclip");
    const wayland_display = std.c.getenv("WAYLAND_DISPLAY");
    if (wayland_display != null and has_wl_copy) {
        return &.{ "wl-copy" };
    }
    if (has_xclip) {
        return &.{ "xclip", "-selection", "clipboard" };
    }
    if (has_wl_copy) {
        return &.{ "wl-copy" };
    }
    return null;
}

fn commandExists(allocator: std.mem.Allocator, name: []const u8) bool {
    const path = std.c.getenv("PATH") orelse return false;
    const path_slice = std.mem.sliceTo(path, 0);

    var it = std.mem.splitScalar(u8, path_slice, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full_path = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
        defer allocator.free(full_path);

        // std.c.open requires a null-terminated path; append a NUL byte.
        const path_z = allocator.allocSentinel(u8, full_path.len, 0) catch continue;
        defer allocator.free(path_z);
        @memcpy(path_z, full_path);

        const fd = std.c.open(
            @ptrCast(path_z.ptr),
            .{ .ACCMODE = .RDONLY },
            @as(std.c.mode_t, 0),
        );
        if (fd >= 0) {
            _ = std.c.close(fd);
            return true;
        }
    }
    return false;
}

test "linux clipboard tool detection returns a known tool" {
    const target = @import("builtin").target;
    if (target.os.tag != .linux) return;

    const argv = detectLinuxClipboardTool(std.testing.allocator);
    try std.testing.expect(argv != null);
    try std.testing.expect(argv.?.len > 0);
    const first = argv.?[0];
    const is_known = std.mem.eql(u8, first, "wl-copy") or std.mem.eql(u8, first, "xclip");
    try std.testing.expect(is_known);
}

test "macos clipboard argv selects pbcopy" {
    const target = @import("builtin").target;
    if (target.os.tag != .macos) return;

    const argv = clipboardArgv(std.testing.allocator);
    try std.testing.expect(argv != null);
    try std.testing.expect(argv.?.len > 0);
    try std.testing.expectEqualStrings("pbcopy", argv.?[0]);
}
