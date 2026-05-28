const std = @import("std");
const stream_client = @import("../net/stream_client.zig");
const CacheFirstLoop = @import("../dispatch/cache_first_loop.zig").CacheFirstLoop;
const SubAgentScheduler = @import("subagent.zig").SubAgentScheduler;
const SubAgent = @import("subagent.zig").SubAgent;
const SubAgentRole = @import("subagent.zig").SubAgentRole;
const nowTimestamp = @import("subagent.zig").nowTimestamp;
const SubAgentState = @import("subagent.zig").SubAgentState;
const AgentResult = @import("subagent.zig").AgentResult;
const MergedResult = @import("subagent.zig").MergedResult;
const Change = @import("subagent.zig").Change;
const Evidence = @import("subagent.zig").Evidence;
const Risk = @import("subagent.zig").Risk;
const Severity = @import("subagent.zig").Severity;
const Blocker = @import("subagent.zig").Blocker;

pub const PollResult = enum {
    pending,
    chunk,
    done,
    timed_out,
    poll_error,
};

pub const SubWorker = struct {
    id: u32,
    role: SubAgentRole,
    task: []const u8,
    state: SubAgentState = .pending,
    result: ?AgentResult = null,
    loop: ?*CacheFirstLoop = null,
    stream: ?stream_client.StreamIterator = null,
    current_chunk: []const u8 = "",
    started_at: i64 = 0,
    timeout_ms: ?u64 = null,
    last_checkpoint_at: i64 = 0,
    checkpoint_interval_ms: u32 = 60_000,
    accumulated_output: std.ArrayList(u8),

    pub fn init(id: u32, role: SubAgentRole, task: []const u8, timeout_ms: ?u64, checkpoint_interval_ms: u32) SubWorker {
        return .{
            .id = id,
            .role = role,
            .task = task,
            .timeout_ms = timeout_ms,
            .checkpoint_interval_ms = checkpoint_interval_ms,
            .accumulated_output = .empty,
        };
    }

    pub fn start(self: *SubWorker, loop: *CacheFirstLoop) !void {
        self.loop = loop;
        self.state = .running;
        self.started_at = nowTimestamp();
        self.last_checkpoint_at = self.started_at;
        self.stream = try loop.stepStream(self.task);
    }

    pub fn poll(self: *SubWorker) !PollResult {
        if (self.state != .running) return .pending;
        if (self.stream == null) return .done;

        const chunk = try self.stream.?.nextChunk();
        if (chunk) |c| {
            switch (c) {
                .content => |text| {
                    self.current_chunk = text;
                    self.accumulated_output.appendSlice(std.heap.page_allocator, text) catch {};
                    return .chunk;
                },
                .reasoning => |text| {
                    self.stream.?.allocator.free(text);
                    return self.poll();
                },
            }
        }

        return .done;
    }

    pub fn pollWithTimeout(self: *SubWorker, now: i64) !PollResult {
        if (self.state != .running) return .pending;

        if (self.timeout_ms) |timeout| {
            const elapsed_s = now - self.started_at;
            const elapsed_ms = @as(u64, @intCast(elapsed_s)) * 1000;
            if (elapsed_ms >= timeout) {
                self.state = .timed_out;
                self.finishWithPartial();
                return .timed_out;
            }
        }

        return self.poll();
    }

    pub fn shouldCheckpoint(self: *SubWorker, now: i64) bool {
        if (self.checkpoint_interval_ms == 0) return false;
        const elapsed = @as(u64, @intCast(now - self.last_checkpoint_at)) * 1000;
        return elapsed >= self.checkpoint_interval_ms;
    }

    pub fn markCheckpointDone(self: *SubWorker, now: i64) void {
        self.last_checkpoint_at = now;
    }

    fn finishWithPartial(self: *SubWorker) void {
        if (self.stream) |*s| {
            s.deinit();
            self.stream = null;
        }

        const output = self.accumulated_output.items;
        const parsed = parseContractOutput(output);
        const joined_summary = std.mem.join(std.heap.page_allocator, "\n", parsed.summary) catch "";

        self.result = .{
            .summary = joined_summary,
            .changes = parsed.changes,
            .evidence = parsed.evidence,
            .risks = parsed.risks,
            .blockers = parsed.blockers,
        };
    }

    pub fn finish(self: *SubWorker, result: AgentResult) void {
        self.state = .completed;
        self.result = result;
        if (self.stream) |*s| {
            s.deinit();
            self.stream = null;
        }
    }

    pub fn finishFromAccumulated(self: *SubWorker) void {
        const output = self.accumulated_output.items;
        const parsed = parseContractOutput(output);
        const joined_summary = std.mem.join(std.heap.page_allocator, "\n", parsed.summary) catch "";
        self.result = .{
            .summary = joined_summary,
            .changes = parsed.changes,
            .evidence = parsed.evidence,
            .risks = parsed.risks,
            .blockers = parsed.blockers,
        };
        self.state = .completed;
        if (self.stream) |*s| {
            s.deinit();
            self.stream = null;
        }
    }

    pub fn abort(self: *SubWorker) void {
        self.state = .cancelled;
        if (self.stream) |*s| {
            s.deinit();
            self.stream = null;
        }
    }

    pub fn canWriteFiles(self: SubWorker) bool {
        return self.role.canWriteFiles();
    }

    pub fn canUseShell(self: SubWorker) bool {
        return self.role.canUseShell();
    }

    pub fn deinit(self: *SubWorker) void {
        self.accumulated_output.deinit(std.heap.page_allocator);
    }
};

const ParsedContract = struct {
    summary: []const []const u8,
    changes: []const []const u8,
    evidence: []const []const u8,
    risks: []const []const u8,
    blockers: []const []const u8,
};

fn parseContractOutput(output: []const u8) ParsedContract {
    var summary: std.ArrayList([]const u8) = .empty;
    var changes: std.ArrayList([]const u8) = .empty;
    var evidence: std.ArrayList([]const u8) = .empty;
    var risks: std.ArrayList([]const u8) = .empty;
    var blockers: std.ArrayList([]const u8) = .empty;
    const alloc = std.heap.page_allocator;

    var section: enum { none, summary, changes, evidence, risks, blockers } = .none;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.ascii.startsWithIgnoreCase(trimmed, "SUMMARY:")) {
            section = .summary;
            const content = trimmed[8..];
            if (content.len > 0) summary.append(alloc, content) catch {};
        } else if (std.ascii.startsWithIgnoreCase(trimmed, "CHANGES:")) {
            section = .changes;
        } else if (std.ascii.startsWithIgnoreCase(trimmed, "EVIDENCE:")) {
            section = .evidence;
        } else if (std.ascii.startsWithIgnoreCase(trimmed, "RISKS:")) {
            section = .risks;
        } else if (std.ascii.startsWithIgnoreCase(trimmed, "BLOCKERS:")) {
            section = .blockers;
        } else if (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') {
            const content = std.mem.trim(u8, trimmed[1..], " \t");
            if (content.len == 0) continue;
            switch (section) {
                .changes => changes.append(alloc, content) catch {},
                .evidence => evidence.append(alloc, content) catch {},
                .risks => risks.append(alloc, content) catch {},
                .blockers => blockers.append(alloc, content) catch {},
                else => {},
            }
        }
    }

    return .{
        .summary = summary.toOwnedSlice(alloc) catch &.{},
        .changes = changes.toOwnedSlice(alloc) catch &.{},
        .evidence = evidence.toOwnedSlice(alloc) catch &.{},
        .risks = risks.toOwnedSlice(alloc) catch &.{},
        .blockers = blockers.toOwnedSlice(alloc) catch &.{},
    };
}

pub const WorkerPool = struct {
    workers: std.ArrayList(SubWorker),
    max_concurrent: u32,
    allocator: std.mem.Allocator,
    active_count: u32 = 0,
    default_timeout_ms: ?u64 = null,
    checkpoint_interval_ms: u32 = 60_000,

    pub fn init(allocator: std.mem.Allocator, max_concurrent: u32, default_timeout_ms: ?u64) WorkerPool {
        return .{
            .workers = .empty,
            .max_concurrent = max_concurrent,
            .allocator = allocator,
            .default_timeout_ms = default_timeout_ms,
        };
    }

    pub fn deinit(self: *WorkerPool) void {
        for (self.workers.items) |*w| {
            if (w.state == .running) {
                w.abort();
            }
            w.deinit();
        }
        self.workers.deinit(self.allocator);
    }

    pub fn spawn(self: *WorkerPool, role: SubAgentRole, task: []const u8, loop: *CacheFirstLoop) !u32 {
        if (self.active_count >= self.max_concurrent) {
            return error.TooManyWorkers;
        }

        const id = @as(u32, @intCast(self.workers.items.len));
        try self.workers.append(self.allocator, SubWorker.init(id, role, task, self.default_timeout_ms, self.checkpoint_interval_ms));
        errdefer self.workers.pop();
        const worker = &self.workers.items[self.workers.items.len - 1];

        try worker.start(loop);
        self.active_count += 1;

        return id;
    }

    pub fn pollAll(self: *WorkerPool) !void {
        const now = nowTimestamp();
        for (self.workers.items) |*w| {
            if (w.state == .running) {
                const result = try w.pollWithTimeout(now);
                if (result == .done) {
                    w.finishFromAccumulated();
                    self.active_count -= 1;
                } else if (result == .timed_out) {
                    self.active_count -= 1;
                }
            }
        }
    }

    pub fn complete(self: *WorkerPool, id: u32, result: AgentResult) void {
        if (id < self.workers.items.len) {
            self.workers.items[id].finish(result);
            if (self.workers.items[id].state == .running) {
                self.active_count -= 1;
            }
        }
    }

    pub fn abort(self: *WorkerPool, id: u32) void {
        if (id < self.workers.items.len) {
            self.workers.items[id].abort();
            if (self.workers.items[id].state == .running) {
                self.active_count -= 1;
            }
        }
    }

    pub fn abortAll(self: *WorkerPool) void {
        for (self.workers.items) |*w| {
            if (w.state == .running) {
                w.abort();
            }
        }
        self.active_count = 0;
    }

    pub fn get(self: *WorkerPool, id: u32) ?*SubWorker {
        if (id < self.workers.items.len) {
            return &self.workers.items[id];
        }
        return null;
    }

    pub fn listActive(self: *WorkerPool) []const SubWorker {
        return self.workers.items;
    }

    pub fn getRunning(self: *WorkerPool) []const SubWorker {
        var result: std.ArrayList(SubWorker) = .empty;
        for (self.workers.items) |w| {
            if (w.state == .running) {
                result.append(self.allocator, w) catch {};
            }
        }
        return result.toOwnedSlice(self.allocator) catch &.{};
    }
};

test "worker pool" {
    const alloc = std.testing.allocator;
    var pool = WorkerPool.init(alloc, 5, null);
    defer pool.deinit();

    try std.testing.expectEqual(@as(u32, 0), pool.active_count);
    try std.testing.expectEqual(@as(u32, 5), pool.max_concurrent);
}

test "contract output parsing" {
    const test_output =
        \\SUMMARY: This is a test summary.
        \\CHANGES:
        \\- src/main.zig: added foo
        \\- src/lib.zig: modified bar
        \\EVIDENCE:
        \\- src/main.zig:10: function foo
        \\RISKS:
        \\- high: potential issue
        \\BLOCKERS:
        \\- needs auth -> auth.zig
    ;

    const parsed = parseContractOutput(test_output);
    defer {
        std.heap.page_allocator.free(parsed.summary);
        std.heap.page_allocator.free(parsed.changes);
        std.heap.page_allocator.free(parsed.evidence);
        std.heap.page_allocator.free(parsed.risks);
        std.heap.page_allocator.free(parsed.blockers);
    }

    try std.testing.expectEqual(@as(usize, 1), parsed.summary.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.changes.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.evidence.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.risks.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.blockers.len);
}
