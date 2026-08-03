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

    // Tool-safety guard module used by app.zig's tool execution path
    const dangerous_patterns_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/dangerous_patterns.zig"),
        .target = target,
        .optimize = optimize,
    });
    zz_mod.addImport("dangerous_patterns", dangerous_patterns_mod);

    // Unified tool execution + sandbox (used by app.zig's tool calls)
    const sandbox_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/sandbox.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sandbox_mod.addImport("c", c_mod);
    const tools_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tools_mod.addImport("sandbox", sandbox_mod);
    tools_mod.addImport("c", c_mod);
    zz_mod.addImport("tools", tools_mod);

    // Session format (shared by app.zig save/load)
    const session_format_mod = b.createModule(.{
        .root_source_file = b.path("src/storage/session_format.zig"),
        .target = target,
        .optimize = optimize,
    });
    zz_mod.addImport("session_format", session_format_mod);

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
    zz_run.addPassthruArgs();
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
