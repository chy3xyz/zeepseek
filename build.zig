const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/zeepseek_c.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_mod = translate_c.createModule();

    // ── ZigZag-based TUI (Elm Architecture) ──────────────────────────
    const zigzag_dep = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });

    const zz_mod = b.addModule("zeepseek", .{
        .root_source_file = b.path("src/ui/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zz_mod.addImport("c", c_mod);
    zz_mod.addImport("zigzag", zigzag_dep.module("zigzag"));

    // Expose net modules for streaming integration
    const http_client_file = b.createModule(.{
        .root_source_file = b.path("src/net/http_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    zz_mod.addImport("http_client", http_client_file);

    const stream_client_file = b.createModule(.{
        .root_source_file = b.path("src/net/stream_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    zz_mod.addImport("stream_client", stream_client_file);

    const zz_exe = b.addExecutable(.{
        .name = "zeepseek",
        .root_module = zz_mod,
    });
    b.installArtifact(zz_exe);

    const zz_run = b.addRunArtifact(zz_exe);
    zz_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        zz_run.addArgs(args);
    }
    const zz_step = b.step("run", "Run zeepseek TUI");
    zz_step.dependOn(&zz_run.step);

    // ── Tests (single test runner imports all modules) ─────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("c", c_mod);
    test_mod.addImport("zigzag", zigzag_dep.module("zigzag"));

    const test_build = b.addTest(.{ .root_module = test_mod });
    const test_run = b.addRunArtifact(test_build);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&test_run.step);
}
