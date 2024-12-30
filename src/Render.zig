const std = @import("std");
const xml = @import("xml");

const PuzzleSet = @import("libpbn.zig").PuzzleSet;
const Puzzle = @import("libpbn.zig").Puzzle;
const Color = @import("libpbn.zig").Color;
const Clue = @import("libpbn.zig").Clue;
const ClueLine = @import("libpbn.zig").ClueLine;
const Solution = @import("libpbn.zig").Solution;
const Cell = @import("libpbn.zig").Cell;
const Note = @import("libpbn.zig").Note;
const DataSlice = @import("libpbn.zig").DataSlice;
const StringIndex = @import("libpbn.zig").StringIndex;

ps: PuzzleSet,
writer: *xml.Writer,

const Render = @This();

pub fn init(ps: PuzzleSet, writer: *xml.Writer) Render {
    return .{
        .ps = ps,
        .writer = writer,
    };
}

pub fn render(r: Render) anyerror!void {
    try r.writer.xmlDeclaration("UTF-8", true);
    try r.writer.elementStart("puzzleset");
    try r.renderStringElement("source", r.ps.puzzles.items[0].source);
    try r.renderStringElement("title", r.ps.puzzles.items[0].title);
    try r.renderStringElement("author", r.ps.puzzles.items[0].author);
    try r.renderStringElement("authorid", r.ps.puzzles.items[0].author_id);
    try r.renderStringElement("copyright", r.ps.puzzles.items[0].copyright);
    for (1..r.ps.puzzles.items.len) |i| {
        try r.renderPuzzle(@enumFromInt(i));
    }
    try r.renderNotes(r.ps.puzzles.items[0].notes);
    try r.writer.elementEnd();
    try r.writer.sink.write("\n");
}

fn renderPuzzle(r: Render, puzzle: Puzzle.Index) !void {
    const colors = r.ps.puzzles.items[@intFromEnum(puzzle)].colors;
    const row_clues = r.ps.puzzles.items[@intFromEnum(puzzle)].row_clues;
    const n_rows = row_clues.len;
    const column_clues = r.ps.puzzles.items[@intFromEnum(puzzle)].column_clues;
    const n_columns = column_clues.len;

    try r.writer.elementStart("puzzle");
    const default_color = r.ps.color(puzzle, .default);
    const default_color_name = r.ps.string(default_color.name);
    if (!std.mem.eql(u8, default_color_name, "black")) {
        try r.writer.attribute("defaultcolor", default_color_name);
    }
    const background_color = r.ps.color(puzzle, .background);
    const background_color_name = r.ps.string(background_color.name);
    if (!std.mem.eql(u8, background_color_name, "white")) {
        try r.writer.attribute("backgroundcolor", background_color_name);
    }
    try r.renderStringElement("source", r.ps.puzzles.items[@intFromEnum(puzzle)].source);
    try r.renderStringElement("id", r.ps.puzzles.items[@intFromEnum(puzzle)].id);
    try r.renderStringElement("title", r.ps.puzzles.items[@intFromEnum(puzzle)].title);
    try r.renderStringElement("author", r.ps.puzzles.items[@intFromEnum(puzzle)].author);
    try r.renderStringElement("authorid", r.ps.puzzles.items[@intFromEnum(puzzle)].author_id);
    try r.renderStringElement("copyright", r.ps.puzzles.items[@intFromEnum(puzzle)].copyright);
    try r.renderStringElement("description", r.ps.puzzles.items[@intFromEnum(puzzle)].description);
    try r.renderColors(colors);
    try r.renderClues(row_clues, .rows, colors);
    try r.renderClues(column_clues, .columns, colors);
    try r.renderSolutions(r.ps.puzzles.items[@intFromEnum(puzzle)].goals, .goal, n_rows, n_columns, colors);
    try r.renderSolutions(r.ps.puzzles.items[@intFromEnum(puzzle)].solved_solutions, .solution, n_rows, n_columns, colors);
    try r.renderSolutions(r.ps.puzzles.items[@intFromEnum(puzzle)].saved_solutions, .saved, n_rows, n_columns, colors);
    try r.renderNotes(r.ps.puzzles.items[@intFromEnum(puzzle)].notes);
    try r.writer.elementEnd();
}

fn renderColors(r: Render, colors: DataSlice(Color)) !void {
    for (0..colors.len) |i| {
        const color = r.ps.data(colors, @enumFromInt(i));
        try r.writer.elementStart("color");
        try r.writer.attribute("name", r.ps.string(color.name));
        try r.writer.attribute("char", &.{color.desc.char});
        var buf: [6]u8 = undefined;
        const rgb = std.fmt.bufPrint(&buf, "{X:0>2}{X:0>2}{X:0>2}", .{ color.desc.r, color.desc.g, color.desc.b }) catch unreachable;
        try r.writer.text(rgb);
        try r.writer.elementEnd();
    }
}

fn renderClues(
    r: Render,
    clues: DataSlice(ClueLine),
    clues_type: Clue.Type,
    colors: DataSlice(Color),
) !void {
    try r.writer.elementStart("clues");
    try r.writer.attribute("type", @tagName(clues_type));
    for (0..clues.len) |i| {
        const line = r.ps.data(clues, @enumFromInt(i));
        try r.writer.elementStart("line");
        for (0..line.clues.len) |j| {
            const clue = r.ps.data(line.clues, @enumFromInt(j));
            try r.writer.elementStart("count");
            if (clue.color != .default) {
                const color = r.ps.data(colors, clue.color);
                try r.writer.attribute("color", r.ps.string(color.name));
            }
            var buf: [32]u8 = undefined;
            const count = std.fmt.bufPrint(&buf, "{}", .{clue.count}) catch unreachable;
            try r.writer.text(count);
            try r.writer.elementEnd();
        }
        try r.writer.elementEnd();
    }
    try r.writer.elementEnd();
}

fn renderSolutions(
    r: Render,
    solutions: DataSlice(Solution),
    solutions_type: Solution.Type,
    n_rows: usize,
    n_columns: usize,
    colors: DataSlice(Color),
) !void {
    for (0..solutions.len) |i| {
        const solution = r.ps.data(solutions, @enumFromInt(i));
        try r.writer.elementStart("solution");
        if (solutions_type != .goal) try r.writer.attribute("type", @tagName(solutions_type));
        const id = r.ps.string(solution.id);
        if (id.len != 0) try r.writer.attribute("id", id);
        try r.renderImage(solution.image, n_rows, n_columns, colors);
        try r.renderNotes(solution.notes);
        try r.writer.elementEnd();
    }
}

fn renderImage(
    r: Render,
    image: Cell.Index,
    n_rows: usize,
    n_columns: usize,
    colors: DataSlice(Color),
) !void {
    try r.writer.elementStart("image");
    for (0..n_rows) |i| {
        try r.writer.text("\n|");
        for (r.ps.images.items[@intFromEnum(image) + i * n_columns ..][0..n_columns]) |cell| {
            var color_set: std.bit_set.IntegerBitSet(32) = .{ .mask = @intFromEnum(cell) };
            const n_set = color_set.count();
            if (n_set == colors.len) {
                try r.writer.text("?");
                continue;
            }
            if (n_set != 1) try r.writer.text("[");
            var color_iter = color_set.iterator(.{});
            while (color_iter.next()) |color_index| {
                const color = r.ps.data(colors, @enumFromInt(color_index));
                try r.writer.text(&.{color.desc.char});
            }
            if (n_set != 1) try r.writer.text("]");
        }
        try r.writer.text("|");
    }
    try r.writer.text("\n");
    try r.writer.elementEnd();
}

fn renderNotes(r: Render, notes: DataSlice(Note)) !void {
    if (notes.len == 0) return;
    try r.writer.elementStart("notes");
    for (0..notes.len) |i| {
        try r.renderStringElement("note", r.ps.data(notes, @enumFromInt(i)).text);
    }
    try r.writer.elementEnd();
}

fn renderStringElement(r: Render, name: []const u8, text: StringIndex) !void {
    const s = r.ps.string(text);
    if (s.len == 0) return;
    try r.writer.elementStart(name);
    try r.writer.text(s);
    try r.writer.elementEnd();
}
