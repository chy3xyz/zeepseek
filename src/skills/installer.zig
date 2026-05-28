const std = @import("std");
const builtin = @import("builtin");
const skill_mod = @import("skill.zig");
const Skill = skill_mod.Skill;
const SkillError = skill_mod.SkillError;
const manifest_mod = @import("manifest.zig");
const ManifestParser = manifest_mod.ManifestParser;

pub const Installer = struct {
    allocator: std.mem.Allocator,
    user_agent: []const u8,

    pub fn init(allocator: std.mem.Allocator) !Installer {
        return .{
            .allocator = allocator,
            .user_agent = try allocator.dupe(u8, "zeepseek/0.1.0"),
        };
    }

    pub fn deinit(self: *Installer) void {
        self.allocator.free(self.user_agent);
    }

    pub fn cloneFromGithub(self: *Installer, owner: []const u8, repo: []const u8, dest: []const u8) !void {
        _ = self;
        _ = owner;
        _ = repo;

        std.fs.makeDirAbsolute(dest) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        std.debug.print("[SKILL] GitHub clone not implemented, use local path: {s}\n", .{dest});
    }

    pub fn parseManifest(self: *Installer, path: []const u8) !Skill {
        var parser = ManifestParser.init(self.allocator);
        return parser.parseFile(path);
    }

    pub fn validate(_: *Installer, skill: *const Skill) void {
        if (skill.name.len == 0) return;
        if (skill.version.len == 0) return;

        for (skill.commands) |cmd| {
            if (cmd.name.len == 0) return;
            if (cmd.handler.len == 0) return;
        }
    }

    pub fn listGithubSkills(self: *Installer) ![]const []const u8 {
        var skills = std.ArrayList([]const u8).init(self.allocator);
        try skills.append(try self.allocator.dupe(u8, "design-review"));
        try skills.append(try self.allocator.dupe(u8, "investigate"));
        try skills.append(try self.allocator.dupe(u8, "health"));
        try skills.append(try self.allocator.dupe(u8, "qa"));
        return skills.toOwnedSlice();
    }

    pub fn getSkillsDir(self: *Installer) ![]const u8 {
        if (comptime builtin.os.tag == .windows) {
            return std.fs.getAppDataDir(self.allocator, "zeepseek");
        } else if (comptime builtin.os.tag == .macos) {
            const home = std.c.getenv("HOME") orelse return SkillError.SkillsDirNotFound;
            const home_slice = std.mem.sliceTo(home, 0);
            return try std.fs.path.join(self.allocator, &.{ home_slice, "Library", "Application Support", "zeepseek", "skills" });
        } else {
            const home = std.c.getenv("HOME") orelse return SkillError.SkillsDirNotFound;
            const home_slice = std.mem.sliceTo(home, 0);
            return try std.fs.path.join(self.allocator, &.{ home_slice, ".local", "share", "zeepseek", "skills" });
        }
    }

    pub fn getSkillPath(self: *Installer, name: []const u8) ![]const u8 {
        const skills_dir = try self.getSkillsDir();
        defer self.allocator.free(skills_dir);
        return try std.fs.path.join(self.allocator, &.{ skills_dir, name });
    }

    pub fn findManifest(self: *Installer, dir_path: []const u8) !?[]const u8 {
        const manifest_names = [_][]const u8{ "skill.yaml", "skill.yml", "skill.json" };
        for (manifest_names) |name| {
            const manifest_path = try std.fs.path.join(self.allocator, &.{ dir_path, name });
            if (std.fs.openFileAbsolute(manifest_path, .{})) |_| {
                return manifest_path;
            } else |_| {
                self.allocator.free(manifest_path);
            }
        }
        return null;
    }
};
