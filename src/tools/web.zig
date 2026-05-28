const std = @import("std");
const tools_mod = @import("mod.zig");
const ToolCall = tools_mod.ToolCall;
const ToolResult = tools_mod.ToolResult;
const sandbox_mod = @import("../utils/sandbox.zig");
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

    const output = try std.fmt.allocPrint(alloc,
        "Web search for: {s}\nResults limit: {s}\n\n[Note: Web search requires an external search API key. Configure DDG_API_KEY or SEARCH_API_KEY in your environment.]",
        .{ query, limit_str }
    );

    return ToolResult{ .success = true, .output = output };
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

    const output = try std.fmt.allocPrint(alloc,
        "URL: {s}\n\n[Note: Web scraping requires network access. Use the shell tool with curl/wget as a workaround.]",
        .{url}
    );

    return ToolResult{ .success = true, .output = output };
}
