const std = @import("std");
const storage_mod = @import("../storage/store.zig");
const Store = storage_mod.Store;

pub const RLMError = error{
    ProcessSpawnFailed,
    ProcessNotRunning,
    QueryFailed,
    SessionNotFound,
    SessionAlreadyExists,
    MaxTurnsExceeded,
    SaveFailed,
    RestoreFailed,
    JsonParseError,
};

pub const RLMConfig = struct {
    python_path: []const u8 = "python3",
    working_dir: ?[]const u8 = null,
    max_turns: u32 = 100,
};

pub const RLMQuery = struct {
    id: []const u8,
    prompt: []const u8,
    timestamp: i64,
};

pub const RLMResponse = struct {
    query_id: []const u8,
    response: []const u8,
    execution_time_ms: u64,
    token_count: u32,
    cache_cost_saved: f64,
    timestamp: i64,
};

pub const RLMSession = struct {
    id: []const u8,
    config: RLMConfig,
    child_pid: ?std.process.Child = null,
    stdin_fd: ?std.posix.fd_t = null,
    stdout_buf: std.ArrayList(u8) = .empty,
    history: std.ArrayList(RLMQuery) = .empty,
    responses: std.ArrayList(RLMResponse) = .empty,
    turns_used: u32 = 0,
    created_at: i64,
    last_activity: i64,
    running: bool = false,
    io: std.Io,

    fn getTimeSecs() i64 {
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        return @as(i64, @intCast(tv.sec));
    }

    fn getTimeMs() i64 {
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        return @as(i64, @intCast(tv.sec)) * 1000 + @divTrunc(@as(i64, @intCast(tv.usec)), 1000);
    }

    fn getTimeUs() i64 {
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        return @as(i64, @intCast(tv.sec)) * 1_000_000 + @as(i64, @intCast(tv.usec));
    }

    pub fn init(alloc: std.mem.Allocator, io: std.Io, id: []const u8, config: RLMConfig) !RLMSession {
        const now = getTimeSecs();
        return RLMSession{
            .id = try alloc.dupe(u8, id),
            .config = config,
            .created_at = now,
            .last_activity = now,
            .io = io,
        };
    }

    pub fn deinit(self: *RLMSession, alloc: std.mem.Allocator) void {
        self.stop();
        for (self.history.items) |q| {
            alloc.free(q.id);
            alloc.free(q.prompt);
        }
        self.history.deinit(alloc);
        for (self.responses.items) |r| {
            alloc.free(r.query_id);
            alloc.free(r.response);
        }
        self.responses.deinit(alloc);
        self.stdout_buf.deinit(alloc);
        alloc.free(self.id);
    }

    pub fn start(self: *RLMSession) !void {
        if (self.running) return;

        self.child_pid = std.process.spawn(self.io, .{
            .argv = &.{ self.config.python_path, "-u", "-c", RLM_SERVER_SCRIPT },
            .cwd = if (self.config.working_dir) |d| .{ .path = d } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch return error.ProcessSpawnFailed;

        self.stdin_fd = self.child_pid.?.stdin.?.handle;
        self.running = true;
    }

    pub fn stop(self: *RLMSession) void {
        if (!self.running) return;
        if (self.child_pid) |child| {
            _ = std.c.close(child.stdin.?.handle);
            _ = std.c.close(child.stdout.?.handle);
            _ = std.c.close(child.stderr.?.handle);
            self.child_pid = null;
        }
        self.stdin_fd = null;
        self.running = false;
    }

    fn sendRequest(self: *RLMSession, alloc: std.mem.Allocator, method: []const u8, params: ?[]const []const u8, request_id: []const u8) ![]const u8 {
        if (self.stdin_fd == null) return error.ProcessNotRunning;

        var req_str: []const u8 = undefined;
        if (params) |p| {
            if (p.len >= 1) {
                req_str = try std.fmt.allocPrint(alloc,
                    "{{\"id\":\"{s}\",\"method\":\"{s}\",\"params\":{{\"prompt\":\"{s}\"}}}}",
                    .{ request_id, method, p[0] });
            } else {
                req_str = try std.fmt.allocPrint(alloc,
                    "{{\"id\":\"{s}\",\"method\":\"{s}\"}}",
                    .{ request_id, method });
            }
        } else {
            req_str = try std.fmt.allocPrint(alloc,
                "{{\"id\":\"{s}\",\"method\":\"{s}\"}}",
                .{ request_id, method });
        }
        defer alloc.free(req_str);

        _ = std.c.write(self.stdin_fd.?, req_str.ptr, req_str.len);
        _ = std.c.write(self.stdin_fd.?, "\n".ptr, 1);

        var resp_buf: [8192]u8 = undefined;
        const n_read = std.c.read(self.child_pid.?.stdout.?.handle, &resp_buf, resp_buf.len);
        if (n_read <= 0) return error.QueryFailed;
        const n: usize = @intCast(n_read);

        const resp_str = try alloc.dupe(u8, resp_buf[0..n]);
        if (std.mem.indexOf(u8, resp_str, "\"error\"") != null) return error.QueryFailed;

        if (std.mem.indexOf(u8, resp_str, "\"result\":")) |result_idx| {
            const result_start = result_idx + 9;
            const segment = resp_str[result_start..];
            const end = std.mem.indexOfScalar(u8, segment, '}') orelse segment.len;
            return try alloc.dupe(u8, segment[1..end - 1]);
        }

        return resp_str;
    }

    pub fn query(self: *RLMSession, alloc: std.mem.Allocator, prompt: []const u8) !RLMResponse {
        if (self.turns_used >= self.config.max_turns) return error.MaxTurnsExceeded;
        if (!self.running) try self.start();

        const start_time = getTimeUs();
        const query_id = try std.fmt.allocPrint(alloc, "{d}", .{getTimeMs()});

        const q_item = RLMQuery{
            .id = try alloc.dupe(u8, query_id),
            .prompt = try alloc.dupe(u8, prompt),
            .timestamp = getTimeSecs(),
        };
        try self.history.append(alloc, q_item);

        const result = self.sendRequest(alloc, "query", &[_][]const u8{prompt}, query_id) catch {
            const end_time = getTimeUs();
            const exec_time = @divTrunc(end_time - start_time, 1000);
            return RLMResponse{
                .query_id = query_id,
                .response = try alloc.dupe(u8, "[error: query failed]"),
                .execution_time_ms = @intCast(exec_time),
                .token_count = 0,
                .cache_cost_saved = 0.0,
                .timestamp = getTimeSecs(),
            };
        };

        const end_time = getTimeUs();
        const exec_time = @divTrunc(end_time - start_time, 1000);
        const token_count = @as(u32, @intCast(result.len / 4));
        const cache_saved = @as(f64, @floatFromInt(result.len)) * 0.001;

        const resp = RLMResponse{
            .query_id = query_id,
            .response = result,
            .execution_time_ms = @intCast(exec_time),
            .token_count = token_count,
            .cache_cost_saved = cache_saved,
            .timestamp = getTimeSecs(),
        };
        try self.responses.append(alloc, resp);
        self.turns_used += 1;
        self.last_activity = getTimeSecs();

        return resp;
    }

    pub fn getHistory(self: *const RLMSession) []const RLMResponse {
        return self.responses.items;
    }

    pub fn reset(self: *RLMSession, alloc: std.mem.Allocator) !void {
        for (self.history.items) |q| {
            alloc.free(q.id);
            alloc.free(q.prompt);
        }
        self.history.clearRetainingCapacity();
        for (self.responses.items) |r| {
            alloc.free(r.query_id);
            alloc.free(r.response);
        }
        self.responses.clearRetainingCapacity();
        self.turns_used = 0;
        self.last_activity = getTimeSecs();

        if (self.running) {
            _ = self.sendRequest(alloc, "reset", null, "reset") catch {};
        }
    }

    pub fn saveState(self: *RLMSession, store: *Store) !void {
        const alloc = store.allocator;
        const state_key = try std.fmt.allocPrint(alloc, "rlm:session:{s}:state", .{self.id});
        defer alloc.free(state_key);

        var state_map = std.StringArrayHashMap([]const u8).init(alloc);
        defer state_map.deinit();
        try state_map.put("session_id", self.id);
        try state_map.put("turns_used", try std.fmt.allocPrint(alloc, "{d}", .{self.turns_used}));
        try state_map.put("max_turns", try std.fmt.allocPrint(alloc, "{d}", .{self.config.max_turns}));
        try state_map.put("created_at", try std.fmt.allocPrint(alloc, "{d}", .{self.created_at}));
        try state_map.put("last_activity", try std.fmt.allocPrint(alloc, "{d}", .{self.last_activity}));

        var buf: [2048]u8 = undefined;
        const json_str = try std.json.stringify(state_map, .{}, &buf);
        try store.put(state_key, json_str);

        const hist_key = try std.fmt.allocPrint(alloc, "rlm:session:{s}:history", .{self.id});
        defer alloc.free(hist_key);
        var hist_list: [256]u8 = undefined;
        const hist_str = try std.json.stringify(self.history.items, .{}, &hist_list);
        try store.put(hist_key, hist_str);
    }

    pub fn restoreState(self: *RLMSession, store: *Store) !void {
        const alloc = store.allocator;
        const state_key = try std.fmt.allocPrint(alloc, "rlm:session:{s}:state", .{self.id});
        defer alloc.free(state_key);

        const json_data = store.get(state_key) orelse return error.RestoreFailed;

        const parsed = std.json.parseFromSlice(std.StringArrayHashMap([]const u8), alloc, json_data, .{}) catch return error.JsonParseError;
        defer parsed.deinit();

        if (parsed.value.get("turns_used")) |v| {
            self.turns_used = std.fmt.parseInt(u32, v, 10) catch 0;
        }
        if (parsed.value.get("max_turns")) |v| {
            self.config.max_turns = std.fmt.parseInt(u32, v, 10) catch 100;
        }
        if (parsed.value.get("created_at")) |v| {
            self.created_at = std.fmt.parseInt(i64, v, 10) catch self.created_at;
        }
        if (parsed.value.get("last_activity")) |v| {
            self.last_activity = std.fmt.parseInt(i64, v, 10) catch self.last_activity;
        }
    }
};

pub const RLMManager = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(*RLMSession),
    config: RLMConfig,
    io: std.Io,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, config: RLMConfig) !RLMManager {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        return RLMManager{
            .arena = arena,
            .allocator = arena.allocator(),
            .sessions = std.StringHashMap(*RLMSession).init(arena.allocator()),
            .config = config,
            .io = io,
        };
    }

    pub fn deinit(self: *RLMManager) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit();
        self.arena.deinit();
    }

    pub fn createSession(self: *RLMManager, id: []const u8) !*RLMSession {
        if (self.sessions.contains(id)) return error.SessionAlreadyExists;
        const session = try self.allocator.create(RLMSession);
        session.* = try RLMSession.init(self.allocator, self.io, id, self.config);
        try self.sessions.put(try self.allocator.dupe(u8, id), session);
        return session;
    }

    pub fn getSession(self: *RLMManager, id: []const u8) ?*RLMSession {
        return self.sessions.get(id);
    }

    pub fn deleteSession(self: *RLMManager, id: []const u8) void {
        if (self.sessions.get(id)) |session| {
            session.deinit(self.allocator);
            _ = self.sessions.remove(id);
            self.allocator.destroy(session);
        }
    }

    pub fn listSessions(self: *RLMManager) []const []const u8 {
        var result = std.ArrayList([]const u8).empty;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            result.append(self.allocator, entry.key_ptr.*) catch {};
        }
        return result.toOwnedSlice(self.allocator) catch &.{};
    }

    pub fn queryBatch(self: *RLMManager, session_id: []const u8, prompts: []const []const u8) ![]RLMResponse {
        const session = self.getSession(session_id) orelse return error.SessionNotFound;
        var results = std.ArrayList(RLMResponse).empty;
        const alloc = self.allocator;
        for (prompts) |prompt| {
            const resp = try session.query(alloc, prompt);
            try results.append(alloc, resp);
        }
        return results.toOwnedSlice(alloc) catch &.{};
    }
};

const RLM_SERVER_SCRIPT =
    \\#!/usr/bin/env python3
    \\"""RLM Server - persistent REPL for Zeepseek"""
    \\
    \\import json
    \\import sys
    \\import signal
    \\import os
    \\
    \\class RLM:
    \\    def __init__(self):
    \\        self.messages = []
    \\        self.max_turns = 100
    \\        
    \\    def add_message(self, role, content):
    \\        self.messages.append({"role": role, "content": content})
    \\        if len(self.messages) > self.max_turns * 2:
    \\            old = self.messages[:-20]
    \\            summary = self._summarize(old)
    \\            self.messages = [{"role": "system", "content": f"Summary: {summary}"}] + self.messages[-20:]
    \\    
    \\    def query(self, prompt):
    \\        self.add_message("user", prompt)
    \\        response = self._call_api(self.messages)
    \\        self.add_message("assistant", response)
    \\        return response
    \\    
    \\    def _call_api(self, messages):
    \\        try:
    \\            import requests
    \\            api_key = os.environ.get("DEEPSEEK_API_KEY", "")
    \\            resp = requests.post(
    \\                "https://api.deepseek.com/v1/chat/completions",
    \\                headers={"Authorization": f"Bearer {api_key}"},
    \\                json={"model": "deepseek-chat", "messages": messages, "stream": False},
    \\                timeout=60
    \\            )
    \\            resp.raise_for_status()
    \\            return resp.json()["choices"][0]["message"]["content"]
    \\        except ImportError:
    \\            return "[error: requests library not installed]"
    \\        except Exception as e:
    \\            return f"[error: {e}]"
    \\    
    \\    def _summarize(self, messages):
    \\        return "[summarized conversation]"
    \\    
    \\    def reset(self):
    \\        self.messages = []
    \\    
    \\    def state_dict(self):
    \\        return {"messages": self.messages, "max_turns": self.max_turns}
    \\
    \\def main():
    \\    rlm = RLM()
    \\    
    \\    def signal_handler(sig, frame):
    \\        state = rlm.state_dict()
    \\        print(json.dumps({"type": "state", "data": state}), flush=True)
    \\        sys.exit(0)
    \\    
    \\    signal.signal(signal.SIGINT, signal_handler)
    \\    signal.signal(signal.SIGTERM, signal_handler)
    \\    
    \\    for line in sys.stdin:
    \\        line = line.strip()
    \\        if not line:
    \\            continue
    \\        try:
    \\            req = json.loads(line)
    \\            method = req.get("method")
    \\            params = req.get("params", {})
    \\            req_id = req.get("id", "")
    \\            
    \\            if method == "query":
    \\                prompt = params.get("prompt", "") if isinstance(params, dict) else params
    \\                result = rlm.query(prompt)
    \\            elif method == "reset":
    \\                rlm.reset()
    \\                result = "OK"
    \\            elif method == "get_history":
    \\                result = rlm.get_history()
    \\            elif method == "get_state":
    \\                result = rlm.state_dict()
    \\            else:
    \\                result = {"error": f"Unknown method: {method}"}
    \\            
    \\            print(json.dumps({"id": req_id, "result": result}), flush=True)
    \\        except Exception as e:
    \\            print(json.dumps({"id": None, "error": str(e)}), flush=True)
    \\
    \\if __name__ == "__main__":
    \\    main()
;

test "rlm session init" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    var session = try RLMSession.init(alloc, io, "test-session", .{});
    defer session.deinit(alloc);
    try std.testing.expectEqualStrings("test-session", session.id);
    try std.testing.expectEqual(@as(u32, 0), session.turns_used);
}

test "rlm manager create and get session" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    var manager = try RLMManager.init(alloc, io, .{});
    defer manager.deinit();

    const session = try manager.createSession("session-1");
    try std.testing.expect(session != null);
    try std.testing.expect(manager.getSession("session-1") != null);
    try std.testing.expect(manager.getSession("nonexistent") == null);
}

test "rlm manager list sessions" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    var manager = try RLMManager.init(alloc, io, .{});
    defer manager.deinit();

    _ = try manager.createSession("s1");
    _ = try manager.createSession("s2");
    _ = try manager.createSession("s3");

    const sessions = manager.listSessions();
    try std.testing.expectEqual(@as(usize, 3), sessions.len);
}

test "rlm session reset" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    var session = try RLMSession.init(alloc, io, "test", .{});
    defer session.deinit(alloc);

    try session.reset(alloc);
    try std.testing.expectEqual(@as(u32, 0), session.turns_used);
}
