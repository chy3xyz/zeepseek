//! Streaming flow helpers — split out of app.zig.

const std = @import("std");
const App = @import("app.zig").App;
const tools_run = @import("tools_run.zig");

pub fn pollStream(app: *App) void {
    const ss = app.stream_state orelse return;

    // Drain content
    if (ss.drainContent(app.alloc)) |content| {
        defer app.alloc.free(content);
        app.onStreamContent(content);
    }

    // Drain reasoning
    if (ss.drainReasoning(app.alloc)) |reasoning| {
        defer app.alloc.free(reasoning);
        app.onStreamReasoning(reasoning);
    }

    // Check done
    if (ss.isDone()) {
        // Check for tool calls BEFORE marking done
        const has_tc = ss.has_tool_calls.load(.acquire);
        const tc_json = if (has_tc) ss.drainToolCallJson(app.alloc) else null;

        if (ss.error_msg) |msg| {
            app.onStreamError(msg);
            if (msg.len > 0) app.alloc.free(msg);
            ss.error_msg = null;
        } else if (tc_json != null) {
            // Handle tool calls — don't mark stream done yet
            tools_run.handleToolCalls(app, tc_json.?);
            app.alloc.free(tc_json.?);
            // Cleanup stream state but keep streaming_idx alive
            if (app.stream_thread) |t| {
                t.join();
                app.stream_thread = null;
            }
            ss.deinit();
            app.alloc.destroy(ss);
            app.stream_state = null;
            return;
        } else {
            app.onStreamDone();
        }
        // Cleanup
        if (app.stream_thread) |t| {
            t.join();
            app.stream_thread = null;
        }
        ss.deinit();
        app.alloc.destroy(ss);
        app.stream_state = null;
    }
}


/// Process the next queued tool call. Pauses at the first call that
/// requires user approval (pending_tool) and resumes on Enter/Esc.
/// Execute one tool through the unified tools/ pipeline with extra guards.
/// Returns a caller-owned string (empty slice on failure).

pub fn isSensitivePath(path: []const u8) bool {
const sensitive_dirs = [_][]const u8{ ".ssh", ".aws", ".gnupg", ".kube", ".config" };
const sensitive_files = [_][]const u8{ "id_rsa", "id_ed25519", "authorized_keys", "known_hosts", "shadow", "sudoers", "apikey" };
const sensitive_prefixes = [_][]const u8{ "/etc/", "/proc/", "/sys/", "/dev/", "/boot/", "/private/" };

var it = std.mem.splitScalar(u8, path, '/');
while (it.next()) |seg| {
    if (seg.len == 0) continue;
    for (sensitive_dirs) |d| {
        if (std.mem.eql(u8, seg, d)) return true;
    }
    for (sensitive_files) |f| {
        if (std.mem.eql(u8, seg, f)) return true;
    }
}
for (sensitive_prefixes) |p| {
    if (std.mem.startsWith(u8, path, p)) return true;
}
return false;
}

pub fn extractJsonString(_: *App, json: []const u8, key: []const u8) ?[]const u8 {
    // Simple JSON string extractor: finds "key":"value"
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    if (std.mem.indexOf(u8, json, search)) |start| {
        const val_start = start + search.len;
        if (std.mem.indexOfScalarPos(u8, json, val_start, '"')) |end| {
            return json[val_start..end];
        }
    }
    return null;
}

