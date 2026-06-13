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

    // ── ZigZag dependency ─────────────────────────────────────────────
    const zigzag_dep = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });

    // ── Single root module at src/ level ──────────────────────────────
    // This lets all subdirectories (ui, dispatch, net, cache, utils,
    // storage, tools, skills, etc.) cross-import via relative paths.
    const root_mod = b.addModule("zeepseek", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addImport("c", c_mod);
    root_mod.addImport("zigzag", zigzag_dep.module("zigzag"));

    const exe = b.addExecutable(.{
        .name = "zeepseek",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    const run_step = b.step("run", "Run zeepseek TUI");
    run_step.dependOn(&run.step);

    // ── Tests ─────────────────────────────────────────────────────────
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
