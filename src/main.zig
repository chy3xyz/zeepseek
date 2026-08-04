//! Zeepseek entry point
//!
//! This file is the build root so all subdirectories (ui, dispatch, net,
//! cache, utils, storage, tools, etc.) share one module namespace.

const app = @import("ui/app.zig");
const git_worker = @import("utils/git_worker.zig");

pub fn main(init: std.process.Init) !void {
    // Git worker mode: standalone subprocess serving git commands over
    // stdio, spawned once at startup so the main process never forks
    // inside the zigzag runtime.
    var args_iter = init.minimal.args.iterate();
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--git-worker")) {
            return git_worker.main(init);
        }
    }
    try app.main(init, null);
}

const std = @import("std");
