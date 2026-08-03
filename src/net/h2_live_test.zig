const std = @import("std");
const h2c = @import("h2_client.zig");

test "h2 example live" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();

    const key_ptr = std.c.getenv("DEEPSEEK_API_KEY") orelse return error.SkipZigTest;
    const key = std.mem.sliceTo(key_ptr, 0);
    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{key});
    defer alloc.free(auth);
    const headers = [_]struct { []const u8, []const u8 }{
        .{ "authorization", auth },
        .{ "content-type", "application/json" },
        .{ "accept", "text/event-stream" },
    };
    const body = "{\"model\":\"deepseek-chat\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":true}";

    var client = h2c.H2Client.init(alloc, threaded.io());
    client.read_timeout_ms = 8000;
    var resp = client.request("localhost", 8443, "/", &headers, body) catch |e| {
        std.debug.print("H2 ERROR: {s}\n", .{@errorName(e)});
        return;
    };
    defer resp.deinit();
    std.debug.print("H2 STATUS: {d} BODY: {d} bytes\n", .{ resp.status, resp.body.items.len });
    if (resp.body.items.len > 0) {
        std.debug.print("H2 BODY: {s}\n", .{resp.body.items[0..@min(resp.body.items.len, 200)]});
    }
}

test "h2 deepseek live" {
    const alloc = std.testing.allocator;
    const key_env = std.c.getenv("DEEPSEEK_API_KEY") orelse return;
    const key = try alloc.dupe(u8, std.mem.span(key_env));
    defer alloc.free(key);
    var io = std.Io.Threaded.init(alloc, .{});
    var client = h2c.H2Client.init(alloc, io.io());
    const body = "{\"model\":\"deepseek-chat\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":true}";
    var headers: [2]struct { []const u8, []const u8 } = .{
        .{ "authorization", std.fmt.allocPrint(alloc, "Bearer {s}", .{key}) catch return },
        .{ "content-type", "application/json" },
    };
    defer alloc.free(headers[0][1]);
    var resp = client.request("api.deepseek.com", 443, "/chat/completions", &headers, body) catch |e| {
        std.debug.print("DEEPSEEK ERR: {s}\n", .{@errorName(e)});
        return;
    };
    defer resp.deinit();
    std.debug.print("DEEPSEEK STATUS: {d} BODY: {d} bytes\n", .{ resp.status, resp.body.items.len });
    const idx = std.mem.indexOf(u8, resp.body.items, "Hello") orelse std.mem.indexOf(u8, resp.body.items, "hello");
    std.debug.print("DEEPSEEK has hello: {any}\n", .{idx != null});
}
