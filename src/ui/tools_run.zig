//! Tool-execution helpers (MCP routing, tool dispatch) — split out of app.zig.

const std = @import("std");
const App = @import("app.zig").App;
const tools_mod = @import("../tools/mod.zig");
const mcp_client_mod = @import("../net/mcp_client.zig");
const dangerous_patterns = @import("dangerous_patterns");
const git_worker_mod = @import("../utils/git_worker.zig");
const extractJsonString = @import("app.zig").extractJsonString;
const isSensitivePath = App.isSensitivePath;

fn isBuiltinToolName(name: []const u8) bool {
    const builtin = [_][]const u8{ "shell", "file_read", "file_write", "file_edit", "git_status", "git_commit", "web_search", "web_scrape" };
    for (builtin) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

/// Forward a tool call to the connected MCP server via tools/call.
pub fn callMcpTool(app: *App, name: []const u8, arguments: []const u8) []const u8 {
    const sess = &(app.mcp_session orelse return toolErr(app, "Error: no MCP session", .{}));
    const req = mcp_client_mod.buildToolsCall(app.alloc, 1, name, arguments) catch return toolErr(app, "Error: MCP call build failed", .{});
    defer app.alloc.free(req);
    const resp = sess.roundTrip(req, 8000) catch |e| return toolErr(app, "Error: MCP call: {s}", .{@errorName(e)});
    defer app.alloc.free(resp);
    return app.alloc.dupe(u8, resp) catch "";
}

pub fn runTool(app: *App, call: tools_mod.ToolCall, cwd: []const u8) []const u8 {
    // MCP tool forwarding: names outside the built-in set are routed to
    // the connected MCP server's tools/call.
    if (app.mcp_session != null and !isBuiltinToolName(call.name)) {
        return callMcpTool(app, call.name, call.arguments);
    }
    // Extra guards on top of the sandbox: dangerous shell commands and
    // sensitive paths are refused before anything executes.
    if (std.mem.eql(u8, call.name, "shell")) {
        if (app.extractJsonString(call.arguments, "command")) |cmd| {
            if (app.run_mode != .yolo) {
            if (dangerous_patterns.checkDangerousCommand(cmd)) |p| {
                return toolErr(app, "Error: blocked dangerous command ({s}). Prefer a direct command (e.g. 'ls' instead of 'sh -c \"ls\"')", .{p.description});
            }
            // Execute through the worker process (pipe I/O, 30s timeout,
            // kill on hang) so a long-running command can never freeze
            // the UI indefinitely.
            if (app.git_worker) |*gw| {
                if (gw.runShell(app.alloc, cwd, cmd)) |out| {
                    return out;
                }
                return toolErr(app, "Error: shell execution failed or timed out", .{});
            }
        }
    }
    }
    if (std.mem.eql(u8, call.name, "file_read") or
        std.mem.eql(u8, call.name, "file_write") or
        std.mem.eql(u8, call.name, "file_edit"))
    {
        if (app.extractJsonString(call.arguments, "path")) |path| {
            if (isSensitivePath(path)) {
                return toolErr(app, "Error: blocked sensitive path", .{});
            }
        }
    }

    // Recovery guardrail (Reasonix borrow): consecutive tool failures
    // stop the tool to avoid a retry loop.
    const res = tools_mod.executeTool(app.alloc, app.sandbox, cwd, call) catch {
        app.tool_fail_streak += 1;
        if (app.tool_fail_streak >= 3) {
            app.tool_fail_streak = 0;
            app.setNotification("Tool failed 3x in a row — stopped (use /clear to reset)");
        }
        return toolErr(app, "Error: tool execution failed", .{});
    };
    // ToolResult.output is allocator-owned when non-empty, static "" on error.
    app.tool_fail_streak = 0;
    if (res.output.len > 0) {
        const owned = app.alloc.dupe(u8, res.output) catch "";
        app.alloc.free(res.output);
        return owned;
    }
    return toolErr(app, "Error: {s}", .{res.err_msg orelse "tool failed"});
}

/// Allocate an error/status string owned by the caller (freed by
/// handleToolCalls). Returns an empty slice on allocation failure —
/// callers must not free empty results.
pub fn toolErr(app: *App, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(app.alloc, fmt, args) catch "";
}
