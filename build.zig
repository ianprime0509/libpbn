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

    const test_step = b.step("test", "Run all tests");

    const libpbn_test = b.addTest(.{ .root_module = libpbn });
    const libpbn_test_run = b.addRunArtifact(libpbn_test);
    test_step.dependOn(&libpbn_test_run.step);

    const libpbn_exe = b.addExecutable(.{
        .name = "libpbn-test",
        .root_module = libpbn,
    });
    b.installArtifact(libpbn_exe);

    const libpbn_exe_run = b.addRunArtifact(libpbn_exe);
    if (b.args) |args| libpbn_exe_run.addArgs(args);
    b.step("run", "Run").dependOn(&libpbn_exe_run.step);

    const docs_step = b.step("docs", "Build the documentation");
    const libpbn_docs = b.addObject(.{
        .name = "libpbn",
        .root_module = libpbn,
    });
    const libpbn_docs_copy = b.addInstallDirectory(.{
        .source_dir = libpbn_docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&libpbn_docs_copy.step);
}
