const std = @import("std");
const builtin = @import("builtin");

const MIN_ZIG = std.SemanticVersion.parse("0.15.0-dev.1519+dd4e25cf4") catch unreachable;

// NOTE: This code came from
// https://github.com/zigtools/zls/blob/master/build.zig.
const Build = blk: {
    const current_zig = builtin.zig_version;
    if (current_zig.order(MIN_ZIG) == .lt) {
        @compileError(std.fmt.comptimePrint(
            "Your Zig version v{} does not meet the minimum build requirement of v{}",
            .{ current_zig, MIN_ZIG },
        ));
    }
    break :blk std.Build;
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zlap_mod = b.addModule("zlap", .{
        .root_source_file = b.path("src/zlap.zig"),
        .target = target,
        .optimize = optimize,
    });

    const main_tests = b.addTest(.{
        .name = "zlap-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zlap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const example_exe = b.addExecutable(.{
        .name = "zlap-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example_exe.root_module.addImport("zlap", zlap_mod);
    b.installArtifact(example_exe);

    const example_run = b.addRunArtifact(example_exe);
    example_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        example_run.addArgs(args);
    }

    const example_run_step = b.step("run-example", "Run the example");
    example_run_step.dependOn(&example_run.step);
}
