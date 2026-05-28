const std = @import("std");
const keyspace = @import("keyspace.zig");

pub const MockStore = struct {
    data: std.StringHashMap([]const u8),
    ttls: std.StringHashMap(u64),
    arena: std.heap.ArenaAllocator,

    pub fn init(alloc: std.mem.Allocator) MockStore {
        return .{
            .data = std.StringHashMap([]const u8).init(alloc),
            .ttls = std.StringHashMap(u64).init(alloc),
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *MockStore) void {
        self.data.deinit();
        self.ttls.deinit();
        self.arena.deinit();
    }

    pub fn get(self: *MockStore, key: []const u8) ?[]const u8 {
        if (self.ttls.get(key)) |expires| {
            var tv: std.c.timeval = undefined;
            _ = std.c.gettimeofday(&tv, null);
            const now: i64 = @intCast(tv.tv_sec);
            if (now > expires and expires != 0) {
                self.delete(key);
                return null;
            }
        }
        return self.data.get(key);
    }

    pub fn put(self: *MockStore, key: []const u8, value: []const u8, ttl_seconds: ?u64) void {
        const alloc = self.arena.allocator();
        const key_copy = alloc.dupe(u8, key) catch return;
        const value_copy = alloc.dupe(u8, value) catch return;
        self.data.put(key_copy, value_copy) catch return;
        if (ttl_seconds) |ttl| {
            var tv: std.c.timeval = undefined;
            _ = std.c.gettimeofday(&tv, null);
            const now: i64 = @intCast(tv.tv_sec);
            const expires: i64 = now + @as(i64, @intCast(ttl));
            self.ttls.put(key_copy, expires) catch return;
        }
    }

    pub fn delete(self: *MockStore, key: []const u8) void {
        _ = self.data.remove(key);
        _ = self.ttls.remove(key);
    }

    pub fn list(self: *MockStore, prefix: []const u8) []const []const u8 {
        _ = prefix;
        return &.{};
    }
};

pub const Keyspace = keyspace.Keyspace;
pub const makeKey = keyspace.makeKey;
pub const makeKeyBounded = keyspace.makeKeyBounded;
