const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // 1. Tree-sitter runtime core
    mod.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    mod.addIncludePath(b.path("vendor/tree-sitter/lib/src"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/lib/src/lib.c"),
        .flags = &.{ "-std=c99", "-Wno-everything" },
    });

    // 2. Tree-sitter C grammar
    mod.addIncludePath(b.path("vendor/tree-sitter-c/src"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter-c/src/parser.c"),
        .flags = &.{ "-std=c99", "-Wno-everything" },
    });

    const exe = b.addExecutable(.{
        .name = "codestyle",
        .root_module = mod,
    });
    b.installArtifact(exe);

    // Run step: zig build run -- [args]
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Unit and integration test target
    const unit_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.has_side_effects = true;
    const test_step = b.step("test", "Run all unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);

    const runner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/runner_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    runner_tests.root_module.addImport("codestyle", mod);
    runner_tests.root_module.link_libc = true;

    const run_runner_tests = b.addRunArtifact(runner_tests);
    run_runner_tests.has_side_effects = true;
    test_step.dependOn(&run_runner_tests.step);
}
