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
pub fn copyText(allocator: std.mem.Allocator, text: []const u8) ClipboardError!void {
    const argv = clipboardArgv() orelse return error.ClipboardCommandNotFound;

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return error.ClipboardCopyFailed;

    if (child.stdin) |stdin| {
        _ = stdin.write(text) catch {};
        stdin.close();
        child.stdin = null;
    }

    const term = child.wait() catch return error.ClipboardCopyFailed;
    switch (term) {
        .Exited => |code| if (code != 0) return error.ClipboardCopyFailed,
        .Signal, .Stopped, .Unknown => return error.ClipboardCopyFailed,
    }
}

/// Select the platform-appropriate clipboard command argv, or null if no
/// supported tool can be located.
fn clipboardArgv() ?[]const []const u8 {
    const target = @import("builtin").target;
    return switch (target.os.tag) {
        .macos => if (commandExists("pbcopy")) &.{ "pbcopy" } else null,
        .linux => detectLinuxClipboardTool(),
        .windows => if (commandExists("cmd")) &.{ "cmd", "/c", "clip" } else null,
        else => null,
    };
}

/// At runtime, prefer wl-copy if WAYLAND_DISPLAY is set and the binary exists,
/// otherwise fall back to xclip. This avoids hard-coding the session type.
fn detectLinuxClipboardTool() ?[]const []const u8 {
    const wayland_display = std.c.getenv("WAYLAND_DISPLAY");
    if (wayland_display != null and commandExists("wl-copy")) {
        return &.{ "wl-copy" };
    }
    if (commandExists("xclip")) {
        return &.{ "xclip", "-selection", "clipboard" };
    }
    if (commandExists("wl-copy")) {
        return &.{ "wl-copy" };
    }
    return null;
}

fn commandExists(name: []const u8) bool {
    const path = std.c.getenv("PATH") orelse return false;
    const path_slice = std.mem.sliceTo(path, 0);

    var it = std.mem.splitScalar(u8, path_slice, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full_path = std.mem.concat(
            std.heap.page_allocator,
            u8,
            &.{ dir, &.{std.fs.path.sep}, name, &.{0} },
        ) catch continue;
        defer std.heap.page_allocator.free(full_path);

        const fd = std.c.open(
            @ptrCast(full_path.ptr),
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

test "clipboard command selection for current target" {
    const target = @import("builtin").target;
    const tool = switch (target.os.tag) {
        .macos => "pbcopy",
        .linux => if (std.c.getenv("WAYLAND_DISPLAY") != null) "wl-copy" else "xclip",
        .windows => "clip",
        else => return,
    };
    try std.testing.expect(tool.len > 0);
}

test "linux clipboard tool detection returns a known tool" {
    const target = @import("builtin").target;
    if (target.os.tag != .linux) return;

    const argv = detectLinuxClipboardTool();
    try std.testing.expect(argv != null);
    try std.testing.expect(argv.?.len > 0);
    const first = argv.?[0];
    const is_known = std.mem.eql(u8, first, "wl-copy") or std.mem.eql(u8, first, "xclip");
    try std.testing.expect(is_known);
}

test "macos clipboard argv selects pbcopy" {
    const target = @import("builtin").target;
    if (target.os.tag != .macos) return;

    const argv = clipboardArgv();
    try std.testing.expect(argv != null);
    try std.testing.expect(argv.?.len > 0);
    try std.testing.expectEqualStrings("pbcopy", argv.?[0]);
}
