const std = @import("std");
const xml = @import("xml");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const max_colors = @import("libpbn.zig").max_colors;
const Diagnostics = @import("libpbn.zig").Diagnostics;
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

ps: *PuzzleSet,
reader: *xml.Reader,
diag: *Diagnostics,

const Parse = @This();

pub fn init(ps: *PuzzleSet, reader: *xml.Reader, diag: *Diagnostics) Allocator.Error!Parse {
    // The puzzle set data is represented as the "root" puzzle, which will be
    // initialized later.
    try ps.puzzles.append(ps.gpa, undefined);
    // The empty string must reside at index 0.
    try ps.strings.append(ps.gpa, 0);

    return .{
        .ps = ps,
        .reader = reader,
        .diag = diag,
    };
}

pub fn parse(p: Parse) (error{InvalidPbn} || xml.Reader.ReadError)!void {
    var source: StringIndex = .empty;
    var title: StringIndex = .empty;
    var author: StringIndex = .empty;
    var author_id: StringIndex = .empty;
    var copyright: StringIndex = .empty;
    var notes: std.ArrayList(StringIndex) = .empty;
    defer notes.deinit(p.ps.gpa);

    try p.reader.skipProlog();
    if (!std.mem.eql(u8, p.reader.elementName(), "puzzleset")) {
        try p.diag.addError(.unrecognized_element, p.reader.location());
        try p.reader.skipDocument();
        return error.InvalidPbn;
    }
    try p.noAttributes();

    while (try p.readChild(enum {
        source,
        title,
        author,
        authorid,
        copyright,
        puzzle,
        note,
    })) |child| {
        switch (child) {
            .source => {
                try p.noAttributes();
                source = try p.addElementString();
            },
            .title => {
                try p.noAttributes();
                title = try p.addElementString();
            },
            .author => {
                try p.noAttributes();
                author = try p.addElementString();
            },
            .authorid => {
                try p.noAttributes();
                author_id = try p.addElementString();
            },
            .copyright => {
                try p.noAttributes();
                copyright = try p.addElementString();
            },
            .puzzle => {
                if (try p.readPuzzle()) |puzzle| {
                    try p.ps.puzzles.append(p.ps.gpa, puzzle);
                }
            },
            .note => {
                try p.noAttributes();
                try notes.append(p.ps.gpa, try p.addElementString());
            },
        }
    }

    p.ps.puzzles.items[0] = .{
        .source = source,
        .id = .empty,
        .title = title,
        .author = author,
        .author_id = author_id,
        .copyright = copyright,
        .description = .empty,
        .colors = .empty,
        .row_clues = .empty,
        .column_clues = .empty,
        .goals = .empty,
        .solved_solutions = .empty,
        .saved_solutions = .empty,
        .notes = .empty,
    };
}

fn readPuzzle(p: Parse) !?Puzzle {
    var source: StringIndex = .empty;
    var id: StringIndex = .empty;
    var title: StringIndex = .empty;
    var author: StringIndex = .empty;
    var author_id: StringIndex = .empty;
    var copyright: StringIndex = .empty;
    var description: StringIndex = .empty;
    var colors: Color.List = .empty;
    defer colors.deinit(p.ps.gpa);
    var row_clues: ClueLine.List = .empty;
    defer row_clues.deinit(p.ps.gpa);
    var column_clues: ClueLine.List = .empty;
    defer column_clues.deinit(p.ps.gpa);
    var goals: Solution.List = .empty;
    defer goals.deinit(p.ps.gpa);
    var solved_solutions: Solution.List = .empty;
    defer solved_solutions.deinit(p.ps.gpa);
    var saved_solutions: Solution.List = .empty;
    defer saved_solutions.deinit(p.ps.gpa);
    var notes: Note.List = .empty;
    defer notes.deinit(p.ps.gpa);

    // To avoid managing many smaller (and more difficult to manage)
    // allocations, all the "complex" intermediate parsing state is owned by an
    // arena.
    var arena_state: std.heap.ArenaAllocator = .init(p.ps.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var default_color_name: []const u8 = "black";
    var background_color_name: []const u8 = "white";
    var parsed_clues: std.EnumArray(Clue.Type, [][]ParsedClue) = .initFill(&.{});
    var parsed_solutions: std.ArrayListUnmanaged(ParsedSolution) = .empty;

    var attrs = p.attributes(enum {
        type,
        defaultcolor,
        backgroundcolor,
    });
    while (try attrs.next()) |attr| {
        switch (attr.name) {
            .type => {
                if (!std.mem.eql(u8, try p.reader.attributeValue(attr.index), "grid")) {
                    try p.diag.addError(.puzzle_type_unsupported, p.reader.attributeLocation(attr.index));
                    return null;
                }
            },
            .defaultcolor => {
                default_color_name = try p.reader.attributeValueAlloc(arena, attr.index);
            },
            .backgroundcolor => {
                background_color_name = try p.reader.attributeValueAlloc(arena, attr.index);
            },
        }
    }

    const location = p.reader.location();
    while (try p.readChild(enum {
        source,
        id,
        title,
        author,
        authorid,
        copyright,
        description,
        color,
        clues,
        solution,
        note,
    })) |child| {
        switch (child) {
            .source => {
                try p.noAttributes();
                source = try p.addElementString();
            },
            .id => {
                try p.noAttributes();
                id = try p.addElementString();
            },
            .title => {
                try p.noAttributes();
                title = try p.addElementString();
            },
            .author => {
                try p.noAttributes();
                author = try p.addElementString();
            },
            .authorid => {
                try p.noAttributes();
                author_id = try p.addElementString();
            },
            .copyright => {
                try p.noAttributes();
                copyright = try p.addElementString();
            },
            .description => {
                try p.noAttributes();
                description = try p.addElementString();
            },
            .color => {
                try colors.append(p.ps.gpa, try p.readColor());
            },
            .clues => {
                try p.readClues(arena, &parsed_clues, default_color_name);
            },
            .solution => {
                if (try p.readSolution(arena)) |solution| {
                    try parsed_solutions.append(arena, solution);
                }
            },
            .note => {
                try p.noAttributes();
                try notes.append(p.ps.gpa, .{ .text = try p.addElementString() });
            },
        }
    }

    try p.addDefaultColors(&colors);
    assignColorChars(colors.items);
    p.sortColors(colors.items, background_color_name, default_color_name) catch |err| switch (err) {
        error.ColorUndefined => {
            try p.diag.addError(.puzzle_color_undefined, location);
            return null;
        },
    };
    if (colors.items.len > max_colors) {
        try p.diag.addError(.puzzle_too_many_colors, location);
        return null;
    }

    var colors_by_name: std.StringArrayHashMapUnmanaged(Color.Index) = .empty;
    var colors_by_char: std.AutoArrayHashMapUnmanaged(u8, Color.Index) = .empty;
    for (colors.items, 0..) |color, i| {
        if (i >= max_colors) break;
        const color_index: Color.Index = @enumFromInt(i);
        const color_name = p.ps.string(color.name);
        const by_name_gop = try colors_by_name.getOrPut(arena, color_name);
        if (by_name_gop.found_existing) {
            try p.diag.addError(.color_duplicate_name, location);
        } else {
            by_name_gop.key_ptr.* = try arena.dupe(u8, color_name);
            by_name_gop.value_ptr.* = color_index;
        }
        const by_char_gop = try colors_by_char.getOrPut(arena, color.desc.char);
        if (by_char_gop.found_existing) {
            try p.diag.addError(.color_duplicate_char, location);
        } else {
            by_char_gop.value_ptr.* = color_index;
        }
    }

    p.processClues(parsed_clues.get(.rows), &row_clues, colors_by_name) catch |err| switch (err) {
        error.ColorUndefined => {
            try p.diag.addError(.puzzle_color_undefined, location);
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    p.processClues(parsed_clues.get(.columns), &column_clues, colors_by_name) catch |err| switch (err) {
        error.ColorUndefined => {
            try p.diag.addError(.puzzle_color_undefined, location);
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    const clues_available = row_clues.items.len != 0 and column_clues.items.len != 0;
    const n_rows, const n_columns = dims: {
        if (clues_available) {
            break :dims .{ row_clues.items.len, column_clues.items.len };
        } else for (parsed_solutions.items) |parsed_solution| {
            if (parsed_solution.type == .goal) {
                break :dims .{ parsed_solution.image.len, parsed_solution.image[0].len };
            }
        } else {
            try p.diag.addError(.puzzle_missing_goal, location);
            return null;
        }
    };

    for (parsed_solutions.items) |parsed_solution| {
        if (p.processSolution(parsed_solution, n_rows, n_columns, colors_by_char)) |solution| {
            const solutions = switch (parsed_solution.type) {
                .goal => &goals,
                .solution => &solved_solutions,
                .saved => &saved_solutions,
            };
            try solutions.append(p.ps.gpa, solution);
        } else |err| switch (err) {
            error.ImageMismatchedDimensions => try p.diag.addError(.image_mismatched_dimensions, location),
            error.SolutionIndeterminateImage => try p.diag.addError(.solution_indeterminate_image, location),
            error.ColorUndefined => try p.diag.addError(.puzzle_color_undefined, location),
            error.OutOfMemory => return error.OutOfMemory,
        }
    }

    if (!clues_available) {
        // We already validated above that there is at least one goal available.
        try p.deriveClues(n_rows, &row_clues, n_columns, &column_clues, goals.items[0].image);
    }

    return .{
        .source = source,
        .id = id,
        .title = title,
        .author = author,
        .author_id = author_id,
        .copyright = copyright,
        .description = description,
        .colors = try p.ps.addDataSlice(Color, colors.items),
        .row_clues = try p.ps.addDataSlice(ClueLine, row_clues.items),
        .column_clues = try p.ps.addDataSlice(ClueLine, column_clues.items),
        .goals = try p.ps.addDataSlice(Solution, goals.items),
        .solved_solutions = try p.ps.addDataSlice(Solution, solved_solutions.items),
        .saved_solutions = try p.ps.addDataSlice(Solution, saved_solutions.items),
        .notes = try p.ps.addDataSlice(Note, notes.items),
    };
}

fn readColor(p: Parse) !Color {
    var name: StringIndex = .empty;
    var char: u8 = 0;

    var attrs = p.attributes(enum { name, char });
    while (try attrs.next()) |attr| {
        switch (attr.name) {
            .name => {
                name = try p.ps.addString(try p.reader.attributeValue(attr.index));
            },
            .char => {
                const value = try p.reader.attributeValue(attr.index);
                if (value.len == 1) {
                    char = value[0];
                } else {
                    try p.diag.addError(.color_invalid_char, p.reader.attributeLocation(attr.index));
                }
            },
        }
    }

    if (name == .empty) {
        try p.diag.addError(.color_missing_name, p.reader.location());
    }

    const location = p.reader.location();
    const value = try p.readElementTextAlloc(p.ps.gpa);
    defer p.ps.gpa.free(value);
    const rgb: Rgb = Rgb.parse(value) orelse invalid: {
        try p.diag.addError(.color_invalid_rgb, location);
        break :invalid .{ .r = 0, .g = 0, .b = 0 };
    };

    return .{
        .name = name,
        .desc = .{
            .char = char,
            .r = rgb.r,
            .g = rgb.g,
            .b = rgb.b,
        },
    };
}

fn addDefaultColors(p: Parse, colors: *std.ArrayListUnmanaged(Color)) !void {
    var found_black = false;
    var found_white = false;
    for (colors.items) |color| {
        const name = p.ps.string(color.name);
        if (std.mem.eql(u8, name, "black")) {
            found_black = true;
        } else if (std.mem.eql(u8, name, "white")) {
            found_white = true;
        }
    }
    if (!found_black) {
        try colors.append(p.ps.gpa, .{
            .name = try p.ps.addString("black"),
            .desc = .{
                .char = 'X',
                .r = 0,
                .g = 0,
                .b = 0,
            },
        });
    }
    if (!found_white) {
        try colors.append(p.ps.gpa, .{
            .name = try p.ps.addString("white"),
            .desc = .{
                .char = '.',
                .r = 255,
                .g = 255,
                .b = 255,
            },
        });
    }
}

/// Assigns characters to any colors missing them (up to a maximum of 32).
fn assignColorChars(colors: []Color) void {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    comptime assert(alphabet.len == max_colors);
    var assigned: std.StaticBitSet(alphabet.len) = .initFull();
    for (colors) |*color| {
        if (color.desc.char == 0) {
            // If we run out of available colors from our 32-character alphabet,
            // the puzzle will be deemed invalid regardless due to exceeding
            // the maximum color limit, so it doesn't matter.
            const available = assigned.toggleFirstSet() orelse return;
            color.desc.char = alphabet[available];
        }
    }
}

fn sortColors(
    p: Parse,
    colors: []Color,
    background_color: []const u8,
    default_color: []const u8,
) !void {
    var background_index: ?usize = null;
    var default_index: ?usize = null;
    for (colors, 0..) |color, i| {
        const name = p.ps.string(color.name);
        if (std.mem.eql(u8, name, background_color)) {
            background_index = i;
        } else if (std.mem.eql(u8, name, default_color)) {
            default_index = i;
        }
    }

    if (background_index) |index| {
        const new_index: usize = @intFromEnum(Color.Index.background);
        if (default_index == new_index) default_index = index;
        std.mem.swap(Color, &colors[index], &colors[new_index]);
    } else return error.ColorUndefined;

    if (default_index) |index| {
        const new_index: usize = @intFromEnum(Color.Index.default);
        std.mem.swap(Color, &colors[index], &colors[new_index]);
    } else return error.ColorUndefined;
}

const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    fn parse(s: []const u8) ?Rgb {
        return switch (s.len) {
            3 => .{
                .r = std.fmt.parseInt(u8, &.{ s[0], s[0] }, 16) catch return null,
                .g = std.fmt.parseInt(u8, &.{ s[1], s[1] }, 16) catch return null,
                .b = std.fmt.parseInt(u8, &.{ s[2], s[2] }, 16) catch return null,
            },
            6 => .{
                .r = std.fmt.parseInt(u8, s[0..2], 16) catch return null,
                .g = std.fmt.parseInt(u8, s[2..4], 16) catch return null,
                .b = std.fmt.parseInt(u8, s[4..6], 16) catch return null,
            },
            else => null,
        };
    }
};

fn readClues(
    p: Parse,
    arena: Allocator,
    clues: *std.EnumArray(Clue.Type, [][]ParsedClue),
    default_color_name: []const u8,
) !void {
    var lines: std.ArrayListUnmanaged([]ParsedClue) = .empty;

    var maybe_clues_type: ?Clue.Type = null;
    var attrs = p.attributes(enum { type });
    while (try attrs.next()) |attr| {
        switch (attr.name) {
            .type => maybe_clues_type = std.meta.stringToEnum(Clue.Type, try p.reader.attributeValue(attr.index)) orelse
                return p.diag.addError(.clues_invalid_type, p.reader.location()),
        }
    }
    const clues_type = maybe_clues_type orelse return p.diag.addError(.clues_missing_type, p.reader.location());
    if (clues.get(clues_type).len != 0) {
        return p.diag.addError(.clues_duplicate, p.reader.location());
    }

    while (try p.readChild(enum { line })) |child| {
        switch (child) {
            .line => try lines.append(arena, try p.readCluesLine(arena, default_color_name)),
        }
    }

    clues.set(clues_type, try lines.toOwnedSlice(arena));
}

fn readCluesLine(p: Parse, arena: Allocator, default_color_name: []const u8) ![]ParsedClue {
    var clues: std.ArrayListUnmanaged(ParsedClue) = .empty;

    try p.noAttributes();

    while (try p.readChild(enum { count })) |child| {
        switch (child) {
            .count => try clues.append(arena, try p.readClue(arena, default_color_name)),
        }
    }

    return try clues.toOwnedSlice(arena);
}

fn readClue(p: Parse, arena: Allocator, default_color_name: []const u8) !ParsedClue {
    var color_name = default_color_name;

    var attrs = p.attributes(enum { color });
    while (try attrs.next()) |attr| {
        switch (attr.name) {
            .color => color_name = try p.reader.attributeValueAlloc(arena, attr.index),
        }
    }

    const location = p.reader.location();
    const value = try p.readElementTextAlloc(arena);
    const count = std.fmt.parseInt(u27, value, 10) catch 0;
    if (count == 0) try p.diag.addError(.clue_invalid_count, location);

    return .{
        .color_name = color_name,
        .count = count,
    };
}

fn processClues(
    p: Parse,
    parsed_clues: []const []const ParsedClue,
    clues: *ClueLine.List,
    colors_by_name: std.StringArrayHashMapUnmanaged(Color.Index),
) !void {
    try clues.ensureTotalCapacityPrecise(p.ps.gpa, parsed_clues.len);
    for (parsed_clues) |parsed_line| {
        const line_base: u32 = @intCast(p.ps.clues.items.len);
        try p.ps.clues.ensureUnusedCapacity(p.ps.gpa, parsed_line.len);
        for (parsed_line) |parsed_clue| {
            _ = p.ps.clues.appendAssumeCapacity(.{
                .color = colors_by_name.get(parsed_clue.color_name) orelse return error.ColorUndefined,
                .count = parsed_clue.count,
            });
        }
        clues.appendAssumeCapacity(.{
            .clues = .{
                .base = line_base,
                .len = @intCast(parsed_line.len),
            },
        });
    }
}

const ParsedClue = struct {
    color_name: []const u8,
    count: u27,
};

fn readSolution(p: Parse, arena: Allocator) !?ParsedSolution {
    var @"type": Solution.Type = .goal;
    var id: StringIndex = .empty;
    var image: ?[][][]u8 = null;
    var notes: std.ArrayListUnmanaged(Note) = .empty;

    var attrs = p.attributes(enum { type, id });
    while (try attrs.next()) |attr| {
        switch (attr.name) {
            .type => @"type" = std.meta.stringToEnum(Solution.Type, try p.reader.attributeValue(attr.index)) orelse {
                try p.diag.addError(.solution_invalid_type, p.reader.attributeLocation(attr.index));
                return null;
            },
            .id => id = try p.ps.addString(try p.reader.attributeValue(attr.index)),
        }
    }

    const location = p.reader.location();
    while (try p.readChild(enum { image, note })) |child| {
        switch (child) {
            .image => {
                if (image == null) {
                    image = try p.readImage(arena);
                } else {
                    try p.diag.addError(.solution_duplicate_image, p.reader.location());
                    try p.reader.skipElement();
                }
            },
            .note => {
                try p.noAttributes();
                try notes.append(arena, .{ .text = try p.addElementString() });
            },
        }
    }

    return .{
        .id = id,
        .type = @"type",
        .image = image orelse {
            try p.diag.addError(.solution_missing_image, location);
            return null;
        },
        .notes = try notes.toOwnedSlice(arena),
    };
}

fn readImage(p: Parse, arena: Allocator) !?[][][]u8 {
    const location = p.reader.location();
    const raw = try p.readElementTextAlloc(arena);

    var rows: std.ArrayListUnmanaged([][]u8) = .empty;
    var after_last_row: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, after_last_row, '|')) |row_start| {
        if (std.mem.indexOfNone(u8, raw[after_last_row..row_start], &std.ascii.whitespace) != null) {
            try p.diag.addError(.image_invalid, location);
            return null;
        }
        const row_end = std.mem.indexOfScalarPos(u8, raw, row_start + 1, '|') orelse {
            try p.diag.addError(.image_invalid, location);
            return null;
        };
        after_last_row = row_end + 1;

        const row_raw = raw[row_start + 1 .. row_end];
        var columns: std.ArrayListUnmanaged([]u8) = .empty;
        var i: usize = 0;
        while (i < row_raw.len) : (i += 1) {
            switch (row_raw[i]) {
                ' ', '\t', '\r', '\n' => {},
                '\\', '/', ']' => {
                    try p.diag.addError(.image_invalid, location);
                    return null;
                },
                '[' => {
                    const group_end = std.mem.indexOfScalarPos(u8, row_raw, i + 1, ']') orelse {
                        try p.diag.addError(.image_invalid, location);
                        return null;
                    };
                    const group = row_raw[i + 1 .. group_end];
                    if (std.mem.indexOfAny(u8, group, " \t\r\n?\\/") != null) {
                        try p.diag.addError(.image_invalid, location);
                        return null;
                    }
                    try columns.append(arena, group);
                    i = group_end;
                },
                else => try columns.append(arena, row_raw[i..][0..1]),
            }
        }
        if (columns.items.len == 0) {
            try p.diag.addError(.image_invalid, location);
            return null;
        }
        try rows.append(arena, try columns.toOwnedSlice(arena));
    }
    if (rows.items.len == 0) {
        try p.diag.addError(.image_invalid, location);
        return null;
    }
    return try rows.toOwnedSlice(arena);
}

fn processSolution(
    p: Parse,
    solution: ParsedSolution,
    n_rows: usize,
    n_columns: usize,
    colors_by_char: std.AutoArrayHashMapUnmanaged(u8, Color.Index),
) !Solution {
    const image_index: Cell.Index = @enumFromInt(p.ps.images.items.len);
    try p.ps.images.ensureUnusedCapacity(p.ps.gpa, n_rows * n_columns);
    if (solution.image.len != n_rows) return error.ImageMismatchedDimensions;
    for (solution.image) |row| {
        if (row.len != n_columns) return error.ImageMismatchedDimensions;
        for (row) |cell| {
            p.ps.images.appendAssumeCapacity(try processCell(cell, solution.type, colors_by_char));
        }
    }

    return .{
        .id = solution.id,
        .image = image_index,
        .notes = try p.ps.addDataSlice(Note, solution.notes),
    };
}

fn processCell(
    cell: []const u8,
    solution_type: Solution.Type,
    colors_by_char: std.AutoArrayHashMapUnmanaged(u8, Color.Index),
) !Cell {
    if (solution_type != .saved and (cell.len != 1 or cell[0] == '?')) return error.SolutionIndeterminateImage;
    var bits: u32 = 0;
    for (cell) |c| {
        if (c == '?') {
            bits = @intCast((@as(u33, 1) << @intCast(colors_by_char.count())) - 1);
        } else {
            const color = colors_by_char.get(c) orelse return error.ColorUndefined;
            bits |= @as(u32, 1) << @intFromEnum(color);
        }
    }
    return @enumFromInt(bits);
}

fn deriveClues(
    p: Parse,
    n_rows: usize,
    row_clues: *ClueLine.List,
    n_columns: usize,
    column_clues: *ClueLine.List,
    image: Cell.Index,
) !void {
    // We have already validated that the image is a proper goal image, so that
    // each cell has exactly one bit set.
    var line: Clue.List = .empty;
    defer line.deinit(p.ps.gpa);

    try row_clues.ensureTotalCapacityPrecise(p.ps.gpa, n_rows);
    for (0..n_rows) |i| {
        line.clearRetainingCapacity();

        var run_color: Color.Index = .background;
        var run_len: usize = 0;
        for (0..n_columns) |j| {
            const color: Color.Index = @enumFromInt(@ctz(@intFromEnum(p.ps.images.items[@intFromEnum(image) + i * n_columns + j])));
            if (color == run_color) {
                run_len += 1;
            } else {
                if (run_color != .background) {
                    try line.append(p.ps.gpa, .{
                        .color = run_color,
                        .count = @intCast(run_len),
                    });
                }
                run_color = color;
                run_len = 1;
            }
        }
        if (run_color != .background) {
            try line.append(p.ps.gpa, .{
                .color = run_color,
                .count = @intCast(run_len),
            });
        }

        row_clues.appendAssumeCapacity(.{
            .clues = try p.ps.addDataSlice(Clue, line.items),
        });
    }

    try column_clues.ensureTotalCapacityPrecise(p.ps.gpa, n_columns);
    for (0..n_columns) |j| {
        line.clearRetainingCapacity();

        var run_color: Color.Index = .background;
        var run_len: usize = 0;
        for (0..n_rows) |i| {
            const color: Color.Index = @enumFromInt(@ctz(@intFromEnum(p.ps.images.items[@intFromEnum(image) + i * n_columns + j])));
            if (color == run_color) {
                run_len += 1;
            } else {
                if (run_color != .background) {
                    try line.append(p.ps.gpa, .{
                        .color = run_color,
                        .count = @intCast(run_len),
                    });
                }
                run_color = color;
                run_len = 1;
            }
        }
        if (run_color != .background) {
            try line.append(p.ps.gpa, .{
                .color = run_color,
                .count = @intCast(run_len),
            });
        }

        column_clues.appendAssumeCapacity(.{
            .clues = try p.ps.addDataSlice(Clue, line.items),
        });
    }
}

const ParsedSolution = struct {
    id: StringIndex,
    type: Solution.Type,
    image: []const []const []const u8,
    notes: []const Note,
};

fn readChild(p: Parse, comptime Child: type) !?Child {
    while (true) {
        switch (try p.reader.read()) {
            .element_start => {
                if (std.meta.stringToEnum(Child, p.reader.elementName())) |child| {
                    return child;
                } else {
                    try p.diag.addError(.unrecognized_element, p.reader.location());
                    try p.reader.skipElement();
                }
            },
            .element_end => return null,
            .comment => {},
            .text => {
                if (std.mem.indexOfNone(u8, p.reader.textRaw(), &std.ascii.whitespace)) |pos| {
                    var location = p.reader.location();
                    location.update(p.reader.textRaw()[0..pos]);
                    try p.diag.addError(.illegal_content, location);
                }
            },
            .pi,
            .cdata,
            .character_reference,
            .entity_reference,
            => try p.diag.addError(.illegal_content, p.reader.location()),
            .eof, .xml_declaration => unreachable,
        }
    }
}

fn noAttributes(p: Parse) !void {
    for (0..p.reader.attributeCount()) |i| {
        try p.diag.addError(.unrecognized_attribute, p.reader.attributeLocation(i));
    }
}

fn attributes(p: Parse, comptime Name: type) AttributeIterator(Name) {
    return .{
        .reader = p.reader,
        .index = 0,
        .diag = p.diag,
    };
}

fn Attribute(comptime Name: type) type {
    return struct {
        name: Name,
        index: usize,
    };
}

fn AttributeIterator(comptime Name: type) type {
    return struct {
        reader: *const xml.Reader,
        index: usize,
        diag: *Diagnostics,

        fn next(iter: *@This()) !?Attribute(Name) {
            while (iter.index < iter.reader.attributeCount()) {
                const index = iter.index;
                iter.index += 1;
                if (std.meta.stringToEnum(Name, iter.reader.attributeName(index))) |name| {
                    return .{
                        .name = name,
                        .index = index,
                    };
                } else {
                    try iter.diag.addError(.unrecognized_attribute, iter.reader.attributeLocation(index));
                }
            }
            return null;
        }
    };
}

fn addElementString(p: Parse) !StringIndex {
    const index: StringIndex = @enumFromInt(p.ps.strings.items.len);
    var aw: std.Io.Writer.Allocating = .fromArrayList(p.ps.gpa, &p.ps.strings);
    defer p.ps.strings = aw.toArrayList();
    p.readElementTextWrite(&aw.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
    aw.writer.writeByte(0) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return index;
}

fn readElementTextAlloc(p: Parse, allocator: Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    p.readElementTextWrite(&aw.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
    return try aw.toOwnedSlice();
}

fn readElementTextWrite(p: Parse, writer: *std.Io.Writer) !void {
    // This is a stricter version of the logic in xml.Reader.readElementTextWrite.
    const depth = p.reader.element_names.items.len;
    while (true) {
        switch (try p.reader.read()) {
            .xml_declaration, .eof => unreachable,
            .element_start, .pi => {
                try p.diag.addError(.illegal_content, p.reader.location());
            },
            .comment => {},
            .element_end => if (p.reader.element_names.items.len == depth) return,
            .text => try p.reader.textWrite(writer),
            .cdata => try p.reader.cdataWrite(writer),
            .character_reference => {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(p.reader.characterReferenceChar(), &buf) catch unreachable;
                try writer.writeAll(buf[0..len]);
            },
            .entity_reference => {
                const expanded = xml.predefined_entities.get(p.reader.entityReferenceName()) orelse unreachable;
                try writer.writeAll(expanded);
            },
        }
    }
}
