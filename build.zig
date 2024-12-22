const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xml = b.dependency("xml", .{
        .target = target,
        .optimize = optimize,
    });

    const libpbn = b.addModule("libpbn", .{
        .root_source_file = b.path("src/libpbn.zig"),
        .target = target,
        .optimize = optimize,
    });
    libpbn.addImport("xml", xml.module("xml"));

    const step_test = b.step("test", "Run all tests");

    const libpbn_test = b.addTest(.{ .root_module = libpbn });
    const libpbn_test_run = b.addRunArtifact(libpbn_test);
    step_test.dependOn(&libpbn_test_run.step);

    const libpbn_exe = b.addExecutable(.{
        .name = "libpbn-test",
        .root_module = libpbn,
    });
    b.installArtifact(libpbn_exe);

    const libpbn_exe_run = b.addRunArtifact(libpbn_exe);
    if (b.args) |args| libpbn_exe_run.addArgs(args);
    b.step("run", "Run").dependOn(&libpbn_exe_run.step);
}
