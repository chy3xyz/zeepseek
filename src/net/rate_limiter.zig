const std = @import("std");

pub const RateLimitConfig = struct {
    max_requests: u32 = 100,
    window_ms: u32 = 60000,
    burst_size: u32 = 10,
};

pub const PerKeyLimit = struct {
    max_requests: u32,
    window_ms: u32,
    burst_size: u32,

    pub fn default() PerKeyLimit {
        return .{
            .max_requests = 100,
            .window_ms = 60000,
            .burst_size = 10,
        };
    }
};

const ClientBucket = struct {
    tokens: f64,
    last_update_ms: i64,
};

pub const RateLimiter = struct {
    config: RateLimitConfig,
    key_limits: std.StringHashMap(PerKeyLimit),
    clients: std.StringHashMap(ClientBucket),
    allocator: std.mem.Allocator,
    last_cleanup_ms: i64,

    pub fn init(allocator: std.mem.Allocator, config: RateLimitConfig) RateLimiter {
        return .{
            .config = config,
            .key_limits = std.StringHashMap(PerKeyLimit).init(allocator),
            .clients = std.StringHashMap(ClientBucket).init(allocator),
            .allocator = allocator,
            .last_cleanup_ms = 0,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.clients.deinit();

        var key_it = self.key_limits.iterator();
        while (key_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.key_limits.deinit();
    }

    pub fn setKeyLimit(self: *RateLimiter, key: []const u8, limit: PerKeyLimit) !void {
        const existing = self.key_limits.get(key);
        if (existing) |_| {
            self.key_limits.put(key, limit) catch return;
        } else {
            const duped_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(duped_key);
            try self.key_limits.put(duped_key, limit);
        }
    }

    fn getEffectiveLimit(self: *RateLimiter, key: []const u8) PerKeyLimit {
        if (self.key_limits.get(key)) |custom| {
            return custom;
        }
        return PerKeyLimit{
            .max_requests = self.config.max_requests,
            .window_ms = self.config.window_ms,
            .burst_size = self.config.burst_size,
        };
    }

    fn nowMs() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }

    pub fn check(self: *RateLimiter, identifier: []const u8) bool {
        self.maybeCleanup();

        const now = nowMs();
        const effective_limit = self.getEffectiveLimit(identifier);
        const bucket = self.getOrCreateBucket(identifier, now, effective_limit);

        if (bucket.tokens >= 1.0) {
            const new_bucket = ClientBucket{
                .tokens = bucket.tokens - 1.0,
                .last_update_ms = now,
            };
            if (self.clients.get(identifier)) |_| {
                self.clients.put(identifier, new_bucket) catch return true;
            } else {
                const key = self.allocator.dupe(u8, identifier) catch return true;
                self.clients.put(key, new_bucket) catch {
                    self.allocator.free(key);
                    return true;
                };
            }
            return true;
        }

        if (self.clients.get(identifier)) |_| {
            self.clients.put(identifier, bucket) catch {};
        } else {
            const key = self.allocator.dupe(u8, identifier) catch return false;
            self.clients.put(key, bucket) catch {
                self.allocator.free(key);
                return false;
            };
        }
        return false;
    }

    fn maybeCleanup(self: *RateLimiter) void {
        const now = nowMs();
        if (now - self.last_cleanup_ms < 60 * 1000) return;
        self.last_cleanup_ms = now;

        const max_idle_ms = 5 * 60 * 1000;
        var to_remove: std.ArrayList([]const u8) = .empty;
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.last_update_ms > max_idle_ms) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |key| {
            if (self.clients.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
            }
        }
        to_remove.deinit(self.allocator);
    }

    fn getOrCreateBucket(self: *RateLimiter, identifier: []const u8, now: i64, limit: PerKeyLimit) ClientBucket {
        if (self.clients.get(identifier)) |existing| {
            const elapsed = @as(f64, @floatFromInt(now - existing.last_update_ms));
            const tokens_to_add = elapsed * @as(f64, @floatFromInt(limit.max_requests)) / @as(f64, @floatFromInt(limit.window_ms));
            const new_tokens = @min(@as(f64, @floatFromInt(limit.burst_size)), existing.tokens + tokens_to_add);
            return ClientBucket{ .tokens = new_tokens, .last_update_ms = now };
        }
        return ClientBucket{
            .tokens = @as(f64, @floatFromInt(limit.burst_size)),
            .last_update_ms = now,
        };
    }

    pub fn remaining(self: *RateLimiter, identifier: []const u8) u32 {
        const effective_limit = self.getEffectiveLimit(identifier);
        if (self.clients.get(identifier)) |bucket| {
            return @as(u32, @intFromFloat(@max(0, bucket.tokens)));
        }
        return effective_limit.burst_size;
    }

    pub fn recordUsage(self: *RateLimiter, identifier: []const u8) void {
        _ = self;
        _ = identifier;
    }
};

test "RateLimiter basic functionality" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, .{
        .max_requests = 10,
        .window_ms = 1000,
        .burst_size = 5,
    });
    defer limiter.deinit();

    const ip = "192.168.1.1";
    var allowed: u32 = 0;
    for (0..5) |_| {
        if (limiter.check(ip)) allowed += 1;
    }
    try std.testing.expectEqual(@as(u32, 5), allowed);
    try std.testing.expect(!limiter.check(ip));
}

test "RateLimiter different identifiers independent" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, .{
        .max_requests = 10,
        .window_ms = 1000,
        .burst_size = 2,
    });
    defer limiter.deinit();

    _ = limiter.check("192.168.1.1");
    _ = limiter.check("192.168.1.1");
    try std.testing.expect(limiter.check("192.168.1.2"));
    try std.testing.expect(limiter.check("192.168.1.2"));
}

test "RateLimiter per-key custom limits" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, .{
        .max_requests = 10,
        .window_ms = 1000,
        .burst_size = 2,
    });
    defer limiter.deinit();

    try limiter.setKeyLimit("premium-key", .{
        .max_requests = 100,
        .window_ms = 1000,
        .burst_size = 50,
    });

    var premium_allowed: u32 = 0;
    for (0..50) |_| {
        if (limiter.check("premium-key")) premium_allowed += 1;
    }
    try std.testing.expectEqual(@as(u32, 50), premium_allowed);

    var regular_allowed: u32 = 0;
    for (0..3) |_| {
        if (limiter.check("regular-key")) regular_allowed += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), regular_allowed);
}

test "RateLimiter deinit after use" {
    var limiter = RateLimiter.init(std.testing.allocator, .{ .max_requests = 10, .window_ms = 1000 });
    _ = limiter.check("tmp-key");
    limiter.deinit();
}

test "RateLimiter multiple keys independent" {
    var limiter = RateLimiter.init(std.testing.allocator, .{ .max_requests = 5, .window_ms = 1000 });
    defer limiter.deinit();
    for (0..5) |_| { try std.testing.expect(limiter.check("key-a")); }
    for (0..5) |_| { try std.testing.expect(limiter.check("key-b")); }
}
