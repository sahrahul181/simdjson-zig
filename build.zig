const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core simdjson module
    const simdjson_mod = b.addModule("simdjson", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });

    // Benchmark CLI executable
    const bench_exe = b.addExecutable(.{
        .name = "simdjson_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .imports = &.{
                .{ .name = "simdjson", .module = simdjson_mod },
            },
        }),
    });
    b.installArtifact(bench_exe);

    // Benchmark run steps
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_bench.addArgs(args);
    }

    const run_step = b.step("run", "Run the benchmark suite");
    run_step.dependOn(&run_bench.step);

    const bench_step = b.step("bench", "Run the benchmark suite");
    bench_step.dependOn(&run_bench.step);

    // Unit & integration test suite
    const unit_tests = b.addTest(.{
        .root_module = simdjson_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.has_side_effects = true;
    if (b.args) |args| {
        run_unit_tests.addArgs(args);
    }

    const test_step = b.step("test", "Run all unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);
}
