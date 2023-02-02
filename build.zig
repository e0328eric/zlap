const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const strip = b.option(bool, "strip", "Omit debug information") orelse false;

    const lib = b.addStaticLibrary("zlap", "src/zlap.zig");
    lib.setBuildMode(mode);
    lib.install();

    const main_tests = b.addTest("src/zlap.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const zlap = std.build.Pkg{
        .name = "zlap",
        .source = .{ .path = "src/zlap.zig" },
    };

    const example_exe = b.addExecutable("zlap-example", "example/main.zig");
    example_exe.strip = strip;
    example_exe.setTarget(target);
    example_exe.setBuildMode(mode);
    example_exe.addPackage(zlap);
    example_exe.install();

    const example_run = example_exe.run();
    example_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        example_run.addArgs(args);
    }

    const example_run_step = b.step("run-example", "Run the example");
    example_run_step.dependOn(&example_run.step);
}
