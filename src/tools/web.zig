const std = @import("std");
const tools_mod = @import("mod.zig");
const ToolCall = tools_mod.ToolCall;
const ToolResult = tools_mod.ToolResult;
const sandbox_mod = @import("sandbox");
const Sandbox = sandbox_mod.Sandbox;

pub fn executeSearch(alloc: std.mem.Allocator, sandbox: ?*Sandbox, call: ToolCall) !ToolResult {
    _ = sandbox;
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to parse arguments" };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const query = map.get("query") orelse {
        return ToolResult{ .success = false, .output = "", .err_msg = "Missing query argument" };
    };
    const limit_str = map.get("limit") orelse "5";

    // Honest stub: no external search API is wired up. Report failure so the
    // model falls back to the shell tool (curl) instead of treating the note
    // as a real search result.
    _ = limit_str;
    return ToolResult{
        .success = false,
        .output = try std.fmt.allocPrint(alloc, "Web search is not implemented. Use the shell tool (curl/wget) instead. Query was: {s}", .{query}),
        .err_msg = "Web search not implemented",
    };
}

pub fn executeScrape(alloc: std.mem.Allocator, sandbox: ?*Sandbox, call: ToolCall) !ToolResult {
    _ = sandbox;
    var map = tools_mod.parseArgs(alloc, call.arguments) catch {
        return ToolResult{ .success = false, .output = "", .err_msg = "Failed to parse arguments" };
    };
    defer tools_mod.freeArgs(alloc, &map);

    const url = map.get("url") orelse {
        return ToolResult{ .success = false, .output = "", .err_msg = "Missing url argument" };
    };

    _ = url;
    return ToolResult{
        .success = false,
        .output = try std.fmt.allocPrint(alloc, "Web scraping is not implemented. Use the shell tool (curl/wget) instead.", .{}),
        .err_msg = "Web scraping not implemented",
    };
}
