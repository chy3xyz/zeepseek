//! Pure ANSI layout helpers (no App state) — split out of app.zig.

const std = @import("std");

pub fn padToCol(out: *std.ArrayList(u8), a: std.mem.Allocator, target: u16, used: usize) void {
    if (used < target) {
        var p = used;
        while (p < target) : (p += 1) { out.appendSlice(a, " ") catch {}; }
    }
}

