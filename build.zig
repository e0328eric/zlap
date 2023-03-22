const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = std.builtin.Version{
        .major = 0,
        .minor = 1,
        .patch = 3,
    };

    const lib = b.addStaticLibrary(.{
        .name = "zlap",
        .root_source_file = .{ .path = "src/zlap.zig" },
        .target = target,
        .optimize = optimize,
        .version = version,
    });
    lib.install();

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/zlap.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const zlap_mod = b.addModule("zlap", .{
        .source_file = .{ .path = "src/zlap.zig" },
    });

    const example_exe = b.addExecutable(.{
        .name = "zlap-example",
        .root_source_file = .{ .path = "example/main.zig" },
        .target = target,
        .optimize = optimize,
        .version = version,
    });
    example_exe.addModule("zlap", zlap_mod);
    example_exe.install();

    const example_run = example_exe.run();
    example_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        example_run.addArgs(args);
    }

    const example_run_step = b.step("run-example", "Run the example");
    example_run_step.dependOn(&example_run.step);
}
