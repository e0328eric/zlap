const std = @import("std");
const builtin = @import("builtin");

const min_zig_string = "0.13.0-dev.211+6a65561e3";

// NOTE: This code came from
// https://github.com/zigtools/zls/blob/master/build.zig.
const Build = blk: {
    const current_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(min_zig_string) catch unreachable;
    if (current_zig.order(min_zig) == .lt) {
        @compileError(std.fmt.comptimePrint(
            "Your Zig version v{} does not meet the minimum build requirement of v{}",
            .{ current_zig, min_zig },
        ));
    }
    break :blk std.Build;
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = std.SemanticVersion{
        .major = 0,
        .minor = 3,
        .patch = 7,
    };

    const lib = b.addStaticLibrary(.{
        .name = "zlap",
        .root_source_file = b.path("src/zlap.zig"),
        .target = target,
        .optimize = optimize,
        .version = version,
    });
    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/zlap.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const zlap_mod = b.addModule("zlap", .{
        .root_source_file = b.path("src/zlap.zig"),
    });

    const example_exe = b.addExecutable(.{
        .name = "zlap-example",
        .root_source_file = b.path("example/main.zig"),
        .target = target,
        .optimize = optimize,
        .version = version,
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
