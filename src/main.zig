//! Zeepseek entry point
//!
//! This file is the build root so all subdirectories (ui, dispatch, net,
//! cache, utils, storage, tools, etc.) share one module namespace.

const app = @import("ui/app.zig");

pub fn main(init: std.process.Init) !void {
    try app.main(init);
}

const std = @import("std");
