//! Pure ANSI layout helpers (no App state) — split out of app.zig.

const std = @import("std");
const zz = @import("zigzag");
const theme = @import("theme.zig");
const R = theme.Pal.R;

pub fn padToCol(out: *std.ArrayList(u8), a: std.mem.Allocator, target: u16, used: usize) void {
    if (used < target) {
        var p = used;
        while (p < target) : (p += 1) { out.appendSlice(a, " ") catch {}; }
    }
}

pub fn enforceWidth(a: std.mem.Allocator, text: []const u8, target: u16) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try result.appendSlice(a, "\n");
        first = false;
        const line_w = zz.layout.measure.width(line);
        if (line_w > target) {
            const trunc = try zz.layout.measure.truncate(a, line, target);
            defer a.free(trunc);
            try result.appendSlice(a, trunc);
        } else {
            try result.appendSlice(a, line);
            var p = line_w;
            while (p < target) : (p += 1) { try result.appendSlice(a, " "); }
        }
    }
    return result.toOwnedSlice(a);
}

/// Return the last `target_h` lines of `text`, shifted up by `scroll_offset`
/// lines from the bottom. Pads with blank lines at the bottom so the result
/// always contains exactly `target_h` lines. This keeps the footer fixed.
pub fn clipFromBottom(a: std.mem.Allocator, text: []const u8, target_h: u16, scroll_offset: u16) ![]const u8 {
    if (target_h == 0) return try a.dupe(u8, "");
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    var list = std.ArrayList([]const u8).empty;
    defer list.deinit(a);
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| try list.append(a, line);

    const total = list.items.len;
    const th = @min(total, @as(usize, target_h));
    const max_offset = if (total > target_h) total - target_h else 0;
    const offset = @min(scroll_offset, max_offset);
    const end = total - offset;
    const start = if (end > th) end - th else 0;

    var result = std.ArrayList(u8).empty;
    defer result.deinit(a);
    for (start..end) |i| {
        if (i > start) try result.appendSlice(a, "\n");
        try result.appendSlice(a, list.items[i]);
    }
    var visible: usize = end - start;
    while (visible < target_h) : (visible += 1) {
        try result.appendSlice(a, "\n");
    }
    return result.toOwnedSlice(a);
}

/// Return the first `max_width` display columns of `str`, preserving any
/// ANSI escape sequences that appear before the cut-off point. Wide chars
/// are not split. No ellipsis is added.
pub fn ansiClip(a: std.mem.Allocator, str: []const u8, max_width: usize) ![]const u8 {
    if (max_width == 0) return try a.dupe(u8, "");
    var result = std.ArrayList(u8).empty;
    defer result.deinit(a);
    var w: usize = 0;
    var i: usize = 0;
    while (i < str.len and w < max_width) {
        const c = str[i];
        if (c == 0x1b) {
            const start = i;
            i += 1;
            if (i < str.len and str[i] == '[') {
                i += 1;
                while (i < str.len and !((str[i] >= 'A' and str[i] <= 'Z') or (str[i] >= 'a' and str[i] <= 'z'))) {
                    i += 1;
                }
                if (i < str.len) i += 1;
            } else if (i < str.len) {
                i += 1;
            }
            try result.appendSlice(a, str[start..i]);
            continue;
        }
        const byte_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (i + byte_len > str.len) {
            try result.appendSlice(a, str[i..]);
            break;
        }
        const cp = std.unicode.utf8Decode(str[i..][0..byte_len]) catch {
            try result.appendSlice(a, str[i..i + 1]);
            w += 1;
            i += 1;
            continue;
        };
        const cw = zz.unicode.charWidth(cp);
        if (w + cw > max_width) break;
        try result.appendSlice(a, str[i..i + byte_len]);
        w += cw;
        i += byte_len;
    }
    return result.toOwnedSlice(a);
}

/// ANSI-aware overlay: places `content` onto `base` at (x, y), preserving
/// escape sequences in both layers. Unlike zz.place.overlay, this does not
/// corrupt ANSI codes by indexing into their byte sequences.
pub fn ansiOverlay(a: std.mem.Allocator, base: []const u8, content: []const u8, x: usize, y: usize) ![]const u8 {
    const base_w = zz.layout.measure.maxLineWidth(base);
    const base_h = zz.layout.measure.height(base);
    const content_w = zz.layout.measure.maxLineWidth(content);
    const content_h = zz.layout.measure.height(content);

    var base_lines = std.ArrayList([]const u8).empty;
    defer base_lines.deinit(a);
    var base_iter = std.mem.splitScalar(u8, base, '\n');
    while (base_iter.next()) |line| try base_lines.append(a, line);

    var content_lines = std.ArrayList([]const u8).empty;
    defer content_lines.deinit(a);
    var content_iter = std.mem.splitScalar(u8, content, '\n');
    while (content_iter.next()) |line| try content_lines.append(a, line);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(a);

    var row: usize = 0;
    while (row < base_h) : (row += 1) {
        if (row > 0) try result.appendSlice(a, "\n");
        const base_line = if (row < base_lines.items.len) base_lines.items[row] else "";
        if (row < y or row >= y + content_h or content_lines.items.len == 0) {
            try result.appendSlice(a, base_line);
            continue;
        }
        const content_row = row - y;
        const content_line = if (content_row < content_lines.items.len) content_lines.items[content_row] else "";
        const content_line_w = zz.layout.measure.width(content_line);
        var overlay_w = if (content_line_w > content_w) content_line_w else content_w;
        const max_overlay_w = if (x < base_w) base_w - x else 0;
        if (overlay_w > max_overlay_w) overlay_w = max_overlay_w;

        // Prefix: base columns [0, x)
        const prefix = try ansiClip(a, base_line, x);
        defer a.free(prefix);
        // Suffix: base columns [x + overlay_w, base_w)
        const up_to_overlay_end = try ansiClip(a, base_line, x + overlay_w);
        defer a.free(up_to_overlay_end);
        const suffix = base_line[up_to_overlay_end.len..];

        // Pad content to the overlay width
        const padded_content = if (overlay_w > 0)
            try zz.layout.measure.padRight(a, content_line, overlay_w)
        else
            try a.dupe(u8, "");
        defer a.free(padded_content);

        try result.appendSlice(a, prefix);
        try result.appendSlice(a, R); // reset before overlay
        try result.appendSlice(a, padded_content);
        try result.appendSlice(a, R); // reset after overlay
        try result.appendSlice(a, suffix);

        // Ensure the output line visually matches base_w
        const out_w = zz.layout.measure.width(prefix) + overlay_w + zz.layout.measure.width(suffix);
        if (out_w < base_w) {
            var p = out_w;
            while (p < base_w) : (p += 1) try result.appendSlice(a, " ");
        }
    }

    return result.toOwnedSlice(a);
}

pub fn appendIntFn(out: *std.ArrayList(u8), a: std.mem.Allocator, val: anytype) void {
    if (std.fmt.allocPrint(a, "{d}", .{val})) |s| {
        out.appendSlice(a, s) catch {};
    } else |_| {}
}

pub fn appendFmtFn(out: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (std.fmt.allocPrint(a, fmt, args)) |s| {
        out.appendSlice(a, s) catch {};
    } else |_| {}
}

pub fn ansiVisibleLen(text: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and text[i] != 'm') : (i += 1) {}
            i += 1;
        } else {
            len += 1;
            i += 1;
        }
    }
}
