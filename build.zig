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

    const tmp_exe = b.addExecutable(.{
        .name = "libpbn-test",
        .root_source_file = b.path("src/libpbn.zig"),
        .target = target,
        .optimize = optimize,
    });
    tmp_exe.root_module.addImport("xml", xml.module("xml"));
    b.installArtifact(tmp_exe);

    const tmp_exe_run = b.addRunArtifact(tmp_exe);
    if (b.args) |args| tmp_exe_run.addArgs(args);
    b.step("run", "Run").dependOn(&tmp_exe_run.step);
}
