const std = @import("std");
const xml = @import("xml");

const PuzzleSet = @import("libpbn.zig").PuzzleSet;
const Puzzle = @import("libpbn.zig").Puzzle;
const Color = @import("libpbn.zig").Color;
const Clue = @import("libpbn.zig").Clue;
const Solution = @import("libpbn.zig").Solution;
const DataIndex = @import("libpbn.zig").DataIndex;
const StringIndex = @import("libpbn.zig").StringIndex;

ps: PuzzleSet,
puzzles: Puzzle.List.Slice,
writer: *xml.Writer,

const Render = @This();

pub fn init(ps: PuzzleSet, writer: *xml.Writer) Render {
    return .{
        .ps = ps,
        .puzzles = ps.puzzles.slice(),
        .writer = writer,
    };
}

pub fn render(r: Render) anyerror!void {
    try r.writer.xmlDeclaration("UTF-8", true);
    try r.writer.elementStart("puzzleset");
    try r.renderStringElement("source", r.puzzles.items(.source)[0]);
    try r.renderStringElement("title", r.puzzles.items(.title)[0]);
    try r.renderStringElement("author", r.puzzles.items(.author)[0]);
    try r.renderStringElement("authorid", r.puzzles.items(.author_id)[0]);
    try r.renderStringElement("copyright", r.puzzles.items(.copyright)[0]);
    for (1..r.ps.puzzles.len) |i| {
        try r.renderPuzzle(@enumFromInt(i));
    }
    try r.renderNotes(r.puzzles.items(.notes)[0]);
    try r.writer.elementEnd();
    try r.writer.sink.write("\n");
}

fn renderPuzzle(r: Render, puzzle: Puzzle.Index) !void {
    const colors = r.puzzles.items(.colors)[@intFromEnum(puzzle)];
    const row_clues = r.puzzles.items(.row_clues)[@intFromEnum(puzzle)];
    const n_rows = r.ps.dataSliceLen(row_clues);
    const column_clues = r.puzzles.items(.column_clues)[@intFromEnum(puzzle)];
    const n_columns = r.ps.dataSliceLen(column_clues);

    try r.writer.elementStart("puzzle");
    const default_color = r.ps.dataSliceElem(Color, colors, @intFromEnum(Color.Index.default));
    const default_color_name = r.ps.string(default_color.name);
    if (!std.mem.eql(u8, default_color_name, "black")) {
        try r.writer.attribute("defaultcolor", default_color_name);
    }
    const background_color = r.ps.dataSliceElem(Color, colors, @intFromEnum(Color.Index.background));
    const background_color_name = r.ps.string(background_color.name);
    if (!std.mem.eql(u8, background_color_name, "white")) {
        try r.writer.attribute("backgroundcolor", background_color_name);
    }
    try r.renderStringElement("source", r.puzzles.items(.source)[@intFromEnum(puzzle)]);
    try r.renderStringElement("id", r.puzzles.items(.id)[@intFromEnum(puzzle)]);
    try r.renderStringElement("title", r.puzzles.items(.title)[@intFromEnum(puzzle)]);
    try r.renderStringElement("author", r.puzzles.items(.author)[@intFromEnum(puzzle)]);
    try r.renderStringElement("authorid", r.puzzles.items(.author_id)[@intFromEnum(puzzle)]);
    try r.renderStringElement("copyright", r.puzzles.items(.copyright)[@intFromEnum(puzzle)]);
    try r.renderStringElement("description", r.puzzles.items(.description)[@intFromEnum(puzzle)]);
    try r.renderColors(colors);
    try r.renderClues(row_clues, .rows, colors);
    try r.renderClues(column_clues, .columns, colors);
    try r.renderSolutions(r.puzzles.items(.goals)[@intFromEnum(puzzle)], .goal, n_rows, n_columns, colors);
    try r.renderSolutions(r.puzzles.items(.solved_solutions)[@intFromEnum(puzzle)], .solution, n_rows, n_columns, colors);
    try r.renderSolutions(r.puzzles.items(.saved_solutions)[@intFromEnum(puzzle)], .saved, n_rows, n_columns, colors);
    try r.renderNotes(r.puzzles.items(.notes)[@intFromEnum(puzzle)]);
    try r.writer.elementEnd();
}

fn renderColors(r: Render, colors: DataIndex) !void {
    for (0..r.ps.dataSliceLen(colors)) |i| {
        const color = r.ps.dataSliceElem(Color, colors, i);
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
    clues: DataIndex,
    clues_type: Clue.Type,
    colors: DataIndex,
) !void {
    try r.writer.elementStart("clues");
    try r.writer.attribute("type", @tagName(clues_type));
    for (0..r.ps.dataSliceLen(clues)) |i| {
        const line = r.ps.dataSliceElem(DataIndex, clues, i);
        try r.writer.elementStart("line");
        for (0..r.ps.dataSliceLen(line)) |j| {
            const clue = r.ps.dataSliceElem(Clue, line, j);
            try r.writer.elementStart("count");
            if (clue.color != .default) {
                const color = r.ps.dataSliceElem(Color, colors, @intFromEnum(clue.color));
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
    solutions: DataIndex,
    solutions_type: Solution.Type,
    n_rows: usize,
    n_columns: usize,
    colors: DataIndex,
) !void {
    for (0..r.ps.dataSliceLen(solutions)) |i| {
        const solution = r.ps.dataSliceElem(Solution, solutions, i);
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
    image: DataIndex,
    n_rows: usize,
    n_columns: usize,
    colors: DataIndex,
) !void {
    try r.writer.elementStart("image");
    for (0..n_rows) |i| {
        try r.writer.text("\n|");
        for (r.ps.datas.items[@intFromEnum(image) + i * n_columns ..][0..n_columns]) |cell| {
            var color_set: std.bit_set.IntegerBitSet(32) = .{ .mask = cell };
            const n_set = color_set.count();
            if (n_set == r.ps.dataSliceLen(colors)) {
                try r.writer.text("?");
                continue;
            }
            if (n_set != 1) try r.writer.text("[");
            var color_iter = color_set.iterator(.{});
            while (color_iter.next()) |color_index| {
                const color = r.ps.dataSliceElem(Color, colors, color_index);
                try r.writer.text(&.{color.desc.char});
            }
            if (n_set != 1) try r.writer.text("]");
        }
        try r.writer.text("|");
    }
    try r.writer.text("\n");
    try r.writer.elementEnd();
}

fn renderNotes(r: Render, notes: DataIndex) !void {
    const n = r.ps.dataSliceLen(notes);
    if (n == 0) return;
    try r.writer.elementStart("notes");
    for (0..n) |i| {
        try r.renderStringElement("note", r.ps.dataSliceElem(StringIndex, notes, i));
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
