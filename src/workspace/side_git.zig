const std = @import("std");

/// SideGit: lightweight workspace snapshot system using git.
/// Automatically initializes a hidden git repo in the workspace if needed,
/// creates snapshots before/after tool operations, and supports rollback.
pub const SideGit = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    workspace_path: []const u8,
    enabled: bool = false,
    snapshot_count: usize = 0,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, workspace_path: []const u8) !SideGit {
        var sg = SideGit{
            .io = io,
            .alloc = alloc,
            .workspace_path = try alloc.dupe(u8, workspace_path),
            .enabled = false,
            .snapshot_count = 0,
        };

        // Check if git is available
        if (!try sg.gitAvailable()) {
            std.debug.print("[SideGit] git not found in PATH\n", .{});
            return sg;
        }

        // Check if workspace already has a git repo by trying to run git status
        if (try sg.hasGitRepo()) {
            sg.enabled = true;
            sg.snapshot_count = try sg.countCommits();
            // git available; repo setup is silent to avoid corrupting the TUI alt screen
            return sg;
        }

        // Try to init side-git repo
        sg.enabled = try sg.initRepo();
        if (sg.enabled) {
            // initialized new repo silently
        }

        return sg;
    }

    pub fn deinit(self: *SideGit) void {
        self.alloc.free(self.workspace_path);
    }

    fn runShell(self: *SideGit, cmd: []const u8) !void {
        const argv = &[_][]const u8{ "/bin/sh", "-c", cmd };
        var child = try std.process.spawn(self.io, .{ .argv = argv });
        _ = try child.wait(self.io);
    }

    fn runShellCapture(self: *SideGit, cmd: []const u8, buf: []u8) ![]const u8 {
        const tmp_path = "/tmp/zeepseek_sidegit_out";
        const full_cmd = try std.fmt.allocPrint(self.alloc, "{s} > {s} 2>/dev/null", .{ cmd, tmp_path });
        defer self.alloc.free(full_cmd);

        const argv = &[_][]const u8{ "/bin/sh", "-c", full_cmd };
        var child = try std.process.spawn(self.io, .{ .argv = argv });
        const term = try child.wait(self.io);
        if (term != .exited or term.exited != 0) return error.CommandFailed;

        const f = std.Io.Dir.openFileAbsolute(self.io, tmp_path, .{ .mode = .read_only }) catch return error.CommandFailed;
        defer std.Io.File.close(f, self.io);
        const n = try std.Io.File.readPositionalAll(f, self.io, buf, 0);
        return std.mem.trim(u8, buf[0..n], " \n\r\t");
    }

    fn gitAvailable(self: *SideGit) !bool {
        const argv = &[_][]const u8{"git", "--version"};
        var child = std.process.spawn(self.io, .{ .argv = argv }) catch return false;
        const term = child.wait(self.io) catch return false;
        return term == .exited and term.exited == 0;
    }

    fn hasGitRepo(self: *SideGit) !bool {
        const cmd = try std.fmt.allocPrint(self.alloc, "cd \"{s}\" && git rev-parse --git-dir", .{self.workspace_path});
        defer self.alloc.free(cmd);
        var buf: [256]u8 = undefined;
        _ = self.runShellCapture(cmd, &buf) catch return false;
        return true;
    }

    fn initRepo(self: *SideGit) !bool {
        const cmd = try std.fmt.allocPrint(self.alloc,
            "cd '{s}' && git init && git config user.name 'zeepseek' && git config user.email 'zeepseek@local' && git add -A && git commit -m 'side-git init' --allow-empty",
            .{self.workspace_path});
        defer self.alloc.free(cmd);
        self.runShell(cmd) catch return false;
        self.snapshot_count = 1;
        return true;
    }

    fn countCommits(self: *SideGit) !usize {
        const cmd = try std.fmt.allocPrint(self.alloc, "cd '{s}' && git rev-list --count HEAD", .{self.workspace_path});
        defer self.alloc.free(cmd);
        var buf: [32]u8 = undefined;
        const out = self.runShellCapture(cmd, &buf) catch return 0;
        return std.fmt.parseInt(usize, out, 10) catch 0;
    }

    /// Create a snapshot of the current workspace state.
    pub fn snapshot(self: *SideGit, message: []const u8) !void {
        if (!self.enabled) return;

        const cmd = try std.fmt.allocPrint(self.alloc,
            "cd '{s}' && git add -A && git commit -m '{s}' --allow-empty",
            .{ self.workspace_path, message });
        defer self.alloc.free(cmd);
        try self.runShell(cmd);
        self.snapshot_count += 1;
    }

    /// Rollback to the previous snapshot (soft reset, keeping changes in working tree).
    pub fn rollbackSoft(self: *SideGit) !void {
        if (!self.enabled or self.snapshot_count <= 1) return error.NoSnapshotToRollback;

        const cmd = try std.fmt.allocPrint(self.alloc, "cd '{s}' && git reset --soft HEAD~1", .{self.workspace_path});
        defer self.alloc.free(cmd);
        try self.runShell(cmd);
        self.snapshot_count -= 1;
    }

    /// Rollback to the previous snapshot (hard reset, discarding all changes).
    pub fn rollbackHard(self: *SideGit) !void {
        if (!self.enabled or self.snapshot_count <= 1) return error.NoSnapshotToRollback;

        const cmd = try std.fmt.allocPrint(self.alloc, "cd '{s}' && git reset --hard HEAD~1", .{self.workspace_path});
        defer self.alloc.free(cmd);
        try self.runShell(cmd);
        self.snapshot_count -= 1;
    }

    pub const Status = struct {
        enabled: bool,
        snapshot_count: usize,
        head_message: ?[]u8,
    };

    pub fn getStatus(self: *SideGit) !Status {
        var result = Status{
            .enabled = self.enabled,
            .snapshot_count = self.snapshot_count,
            .head_message = null,
        };

        if (!self.enabled) return result;

        const cmd = try std.fmt.allocPrint(self.alloc, "cd '{s}' && git log -1 --pretty=%s", .{self.workspace_path});
        defer self.alloc.free(cmd);
        var buf: [256]u8 = undefined;
        const out = self.runShellCapture(cmd, &buf) catch return result;
        if (out.len > 0) {
            result.head_message = try self.alloc.dupe(u8, out);
        }

        return result;
    }
};

pub const SideGitError = error{
    NoSnapshotToRollback,
    CommandFailed,
};
