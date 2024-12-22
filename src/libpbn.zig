const std = @import("std");

pub const PuzzleSet = @import("PuzzleSet.zig");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 2) return error.InvalidArgs; // usage: libpbn puzzle.pbn

    const xml = try std.fs.cwd().readFileAlloc(gpa, args[1], 4 * 1024 * 1024);
    defer gpa.free(xml);
    var diag: PuzzleSet.Diagnostics = .init(gpa);
    defer diag.deinit();
    var ps = try PuzzleSet.parse(gpa, xml, &diag);
    defer ps.deinit(gpa);

    var stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    try ps.render(gpa, stdout_buf.writer());
    try stdout_buf.flush();
}
