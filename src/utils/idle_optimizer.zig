const std = @import("std");
const reasonix_mod = @import("../cache/reasonix.zig");
const mmap_store_mod = @import("../storage/mmap_store.zig");
const store_mod = @import("../storage/store.zig");

pub const IdleOptimizerError = error{
    ThreadSpawnFailed,
};

pub const Options = struct {
    check_interval_ms: u64 = 30_000,
    idle_threshold_ms: u64 = 5_000,
    enable_wal_checkpoint: bool = true,
    enable_cache_cleanup: bool = true,
    enable_cold_flush: bool = true,
    enable_defragment: bool = true,
    defragment_threshold: f32 = 0.3,

    pub fn validate(self: Options) !void {
        if (self.idle_threshold_ms > self.check_interval_ms) {
            return error.IdleThresholdExceedsInterval;
        }
    }
};

comptime {
    const opts = Options{};
    if (opts.idle_threshold_ms > opts.check_interval_ms) {
        @compileError("idle_threshold_ms must be <= check_interval_ms");
    }
}

pub const IdleOptimizer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool),
    last_activity: i64,
    options: Options,

    reasonix: ?*reasonix_mod.Reasonix = null,
    store: ?*store_mod.Store = null,
    mmap_store: ?*mmap_store_mod.MmapStore = null,

    pub fn init(allocator: std.mem.Allocator, options: Options) IdleOptimizer {
        return .{
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
            .last_activity = 0,
            .options = options,
            .reasonix = null,
            .store = null,
            .mmap_store = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    pub fn setReasonix(self: *Self, reasonix: *reasonix_mod.Reasonix) void {
        self.reasonix = reasonix;
    }

    pub fn setStore(self: *Self, store: *store_mod.Store) void {
        self.store = store;
    }

    pub fn setMmapStore(self: *Self, mmap_store: *mmap_store_mod.MmapStore) void {
        self.mmap_store = mmap_store;
    }

    pub fn start(self: *Self) !void {
        if (self.running.load(.seq_cst)) return;
        self.last_activity = nowMs();
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        if (!self.running.load(.seq_cst)) return;
        self.running.store(false, .seq_cst);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn nowMs() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }

    pub fn notifyActivity(self: *Self) void {
        @atomicStore(i64, &self.last_activity, nowMs(), .seq_cst);
    }

    fn isIdle(self: *Self) bool {
        const now = nowMs();
        const last = @atomicLoad(i64, &self.last_activity, .seq_cst);
        const idle_threshold = @as(i64, @intCast(self.options.idle_threshold_ms));
        return (now - last) > idle_threshold;
    }

    fn sleepMs(ms: u64) void {
        const ts = std.c.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        };
        _ = std.c.nanosleep(&ts, null);
    }

    fn sleepInterval(ctx: *Self, ms: u64) void {
        const chunk_ms: u64 = 100;
        var remaining = ms;
        while (remaining > 0 and ctx.running.load(.seq_cst)) {
            const step = @min(remaining, chunk_ms);
            sleepMs(step);
            remaining -= step;
        }
    }

    fn runLoop(ctx: *Self) void {
        while (ctx.running.load(.seq_cst)) {
            sleepInterval(ctx, ctx.options.check_interval_ms);
            if (!ctx.running.load(.seq_cst)) break;
            if (ctx.isIdle()) {
                ctx.optimize();
            }
        }
    }

    fn optimize(self: *Self) void {
        if (self.options.enable_cache_cleanup) {
            self.cleanupExpired();
        }

        if (self.options.enable_cold_flush) {
            self.flushColdTier();
        }

        if (self.options.enable_wal_checkpoint) {
            self.walCheckpoint();
        }

        if (self.options.enable_defragment) {
            self.defragment();
        }
    }

    fn cleanupExpired(self: *Self) void {
        if (self.reasonix) |r| {
            r.cleanupExpired();
        }
    }

    fn flushColdTier(self: *Self) void {
        if (self.mmap_store) |s| {
            s.flushColdTier() catch {};
        }
    }

    fn walCheckpoint(self: *Self) void {
        if (self.store) |s| {
            s.checkpoint() catch {};
        }
    }

    fn defragment(self: *Self) void {
        if (self.mmap_store) |s| {
            s.defragmentIfNeeded(self.options.defragment_threshold);
        }
    }
};

test "idle optimizer init and deinit" {
    var optimizer = IdleOptimizer.init(std.testing.allocator, .{});
    defer optimizer.deinit();
    try std.testing.expect(!optimizer.running.load(.seq_cst));
}

test "idle optimizer start and stop" {
    var optimizer = IdleOptimizer.init(std.testing.allocator, .{
        .check_interval_ms = 100,
        .idle_threshold_ms = 50,
    });
    defer optimizer.deinit();

    try optimizer.start();
    defer optimizer.stop();

    try std.testing.expect(optimizer.running.load(.seq_cst));
    optimizer.stop();
    try std.testing.expect(!optimizer.running.load(.seq_cst));
}

test "idle optimizer notify activity updates state" {
    var optimizer = IdleOptimizer.init(std.testing.allocator, .{});
    defer optimizer.deinit();

    optimizer.notifyActivity();
    try std.testing.expect(optimizer.last_activity > 0);
}
