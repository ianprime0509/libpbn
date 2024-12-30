const std = @import("std");
const xml = @import("xml");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Parse = @import("Parse.zig");
const Render = @import("Render.zig");

pub const max_colors = 32;

pub const ParseError = error{InvalidPbn} || Allocator.Error;

pub const Diagnostics = struct {
    errors: std.ArrayListUnmanaged(Error),
    gpa: Allocator,

    pub const Error = struct {
        type: Type,
        location: xml.Location,

        pub const Type = union(enum) {
            xml: xml.Reader.ErrorCode,
            illegal_content,
            unrecognized_element,
            unrecognized_attribute,
            puzzle_type_unsupported,
            puzzle_too_many_colors,
            puzzle_color_undefined,
            puzzle_missing_clues,
            puzzle_missing_goal,
            color_missing_name,
            color_invalid_char,
            color_invalid_rgb,
            color_duplicate_name,
            color_duplicate_char,
            clues_invalid_type,
            clues_missing_type,
            clues_duplicate,
            clue_invalid_count,
            solution_invalid_type,
            solution_missing_image,
            solution_duplicate_image,
            solution_indeterminate_image,
            image_invalid,
            image_mismatched_dimensions,
        };
    };

    pub fn init(gpa: Allocator) Diagnostics {
        return .{
            .errors = .empty,
            .gpa = gpa,
        };
    }

    pub fn deinit(diag: *Diagnostics) void {
        diag.errors.deinit(diag.gpa);
        diag.* = undefined;
    }

    pub fn addError(diag: *Diagnostics, err: Error.Type, location: xml.Location) Allocator.Error!void {
        try diag.errors.append(diag.gpa, .{ .type = err, .location = location });
    }

    pub fn fatal(diag: *Diagnostics, err: Error.Type, location: xml.Location) ParseError {
        try diag.addError(err, location);
        return error.InvalidPbn;
    }
};

pub const PuzzleSet = struct {
    puzzles: Puzzle.List,
    colors: Color.List,
    clue_lines: ClueLine.List,
    clues: Clue.List,
    solutions: Solution.List,
    images: Cell.List,
    notes: Note.List,
    strings: std.ArrayListUnmanaged(u8),
    gpa: Allocator,

    pub fn deinit(ps: *PuzzleSet) void {
        ps.puzzles.deinit(ps.gpa);
        ps.colors.deinit(ps.gpa);
        ps.clue_lines.deinit(ps.gpa);
        ps.clues.deinit(ps.gpa);
        ps.solutions.deinit(ps.gpa);
        ps.images.deinit(ps.gpa);
        ps.notes.deinit(ps.gpa);
        ps.strings.deinit(ps.gpa);
        ps.* = undefined;
    }

    pub fn source(ps: PuzzleSet, puzzle: Puzzle.Index) ?[:0]const u8 {
        return ps.optionalString(ps.puzzles.items[@intFromEnum(puzzle)].source) orelse
            ps.optionalString(ps.puzzles.items[0].source);
    }

    pub fn id(ps: PuzzleSet, puzzle: Puzzle.Index) ?[:0]const u8 {
        return ps.optionalString(ps.puzzles.items[@intFromEnum(puzzle)].id);
    }

    pub fn title(ps: PuzzleSet, puzzle: Puzzle.Index) ?[:0]const u8 {
        return ps.optionalString(ps.puzzles.items[@intFromEnum(puzzle)].title);
    }

    pub fn author(ps: PuzzleSet, puzzle: Puzzle.Index) ?[:0]const u8 {
        return ps.optionalString(ps.puzzles.items[@intFromEnum(puzzle)].author) orelse
            ps.optionalString(ps.puzzles.items[0].author);
    }

    pub fn authorId(ps: PuzzleSet, puzzle: Puzzle.Index) ?[:0]const u8 {
        return ps.optionalString(ps.puzzles.items[@intFromEnum(puzzle)].author_id) orelse
            ps.optionalString(ps.puzzles.items[0].author_id);
    }

    pub fn copyright(ps: PuzzleSet, puzzle: Puzzle.Index) ?[:0]const u8 {
        return ps.optionalString(ps.puzzles.items[@intFromEnum(puzzle)].copyright) orelse
            ps.optionalString(ps.puzzles.items[0].copyright);
    }

    pub fn description(ps: PuzzleSet, puzzle: Puzzle.Index) ?[:0]const u8 {
        return ps.optionalString(ps.puzzles.items[@intFromEnum(puzzle)].description);
    }

    pub fn colorCount(ps: PuzzleSet, puzzle: Puzzle.Index) usize {
        return ps.puzzles.items[@intFromEnum(puzzle)].colors.len;
    }

    pub fn colorMask(ps: PuzzleSet, puzzle: Puzzle.Index) Cell {
        return @enumFromInt((@as(u32, 1) << @intCast(ps.colorCount(puzzle))) - 1);
    }

    pub fn color(ps: PuzzleSet, puzzle: Puzzle.Index, index: Color.Index) Color {
        return ps.data(ps.puzzles.items[@intFromEnum(puzzle)].colors, index);
    }

    pub fn rowCount(ps: PuzzleSet, puzzle: Puzzle.Index) usize {
        return ps.puzzles.items[@intFromEnum(puzzle)].row_clues.len;
    }

    pub fn rowClueCount(ps: PuzzleSet, puzzle: Puzzle.Index, row: ClueLine.Index) usize {
        const line = ps.data(ps.puzzles.items[@intFromEnum(puzzle)].row_clues, row);
        return line.clues.len;
    }

    pub fn rowClue(ps: PuzzleSet, puzzle: Puzzle.Index, row: ClueLine.Index, n: Clue.Index) Clue {
        const line = ps.data(ps.puzzles.items[@intFromEnum(puzzle)].row_clues, row);
        return ps.data(line.clues, n);
    }

    pub fn columnCount(ps: PuzzleSet, puzzle: Puzzle.Index) usize {
        return ps.puzzles.items[@intFromEnum(puzzle)].column_clues.len;
    }

    pub fn columnClueCount(ps: PuzzleSet, puzzle: Puzzle.Index, column: ClueLine.Index) usize {
        const line = ps.data(ps.puzzles.items[@intFromEnum(puzzle)].column_clues, column);
        return line.clues.len;
    }

    pub fn columnClue(ps: PuzzleSet, puzzle: Puzzle.Index, column: ClueLine.Index, n: Clue.Index) Clue {
        const line = ps.data(ps.puzzles.items[@intFromEnum(puzzle)].column_clues, column);
        return ps.data(line.clues, n);
    }

    pub fn getOrAddSavedSolution(ps: *PuzzleSet, puzzle: Puzzle.Index) Allocator.Error!Solution.Index {
        const p = &ps.puzzles.items[@intFromEnum(puzzle)];
        if (p.saved_solutions.len == 0) {
            const n_rows = p.row_clues.len;
            const n_columns = p.column_clues.len;
            const image_index: Cell.Index = @enumFromInt(ps.images.items.len);
            @memset(try ps.images.addManyAsSlice(ps.gpa, n_rows * n_columns), ps.colorMask(puzzle));

            const new_solutions_base: u32 = @intCast(ps.solutions.items.len);
            try ps.solutions.append(ps.gpa, .{
                .id = .empty,
                .image = image_index,
                .notes = .empty,
            });
            p.saved_solutions = .{ .base = new_solutions_base, .len = 1 };
        }
        return @enumFromInt(0);
    }

    pub fn savedSolutionImage(ps: PuzzleSet, puzzle: Puzzle.Index, solution: Solution.Index) Image {
        const p = &ps.puzzles.items[@intFromEnum(puzzle)];
        return .{
            .puzzle = puzzle,
            .index = ps.data(p.saved_solutions, solution).image,
            .rows = p.row_clues.len,
            .columns = p.column_clues.len,
        };
    }

    pub fn imageGet(ps: PuzzleSet, image: Image, row: usize, column: usize) Cell {
        return ps.images.items[@intFromEnum(image.cellIndex(row, column))];
    }

    pub fn imageSet(ps: *PuzzleSet, image: Image, row: usize, column: usize, cell: Cell) void {
        ps.images.items[@intFromEnum(image.cellIndex(row, column))] = @enumFromInt(@intFromEnum(cell) & @intFromEnum(ps.colorMask(image.puzzle)));
    }

    pub fn imageClear(ps: *PuzzleSet, image: Image) void {
        @memset(ps.images.items[@intFromEnum(image.index)..][0 .. image.rows * image.columns], ps.colorMask(image.puzzle));
    }

    pub fn parse(gpa: Allocator, pbn_xml: []const u8, diag: *Diagnostics) ParseError!PuzzleSet {
        var doc: xml.StaticDocument = .init(pbn_xml);
        var reader = doc.reader(gpa, .{
            // The PBN format does not use namespaces.
            .namespace_aware = false,
        });
        defer reader.deinit();
        var puzzle_set = parseXml(gpa, reader.raw(), diag) catch |err| switch (err) {
            error.MalformedXml => return diag.fatal(.{ .xml = reader.errorCode() }, reader.errorLocation()),
            else => |other| return @as(ParseError, @errorCast(other)),
        };
        errdefer puzzle_set.deinit();
        if (diag.errors.items.len > 0) return error.InvalidPbn;
        return puzzle_set;
    }

    pub fn parseReader(gpa: Allocator, pbn_xml: anytype, diag: *Diagnostics) (ParseError || @TypeOf(pbn_xml).Error)!PuzzleSet {
        var doc = xml.streamingDocument(gpa, pbn_xml);
        defer doc.deinit();
        var reader = doc.reader(gpa, .{
            // The PBN format does not use namespaces.
            .namespace_aware = false,
        });
        defer reader.deinit();
        var puzzle_set = parseXml(gpa, reader.raw(), diag) catch |err| switch (err) {
            error.MalformedXml => return diag.fatal(.{ .xml = reader.errorCode() }, reader.errorLocation()),
            else => |other| return @as(ParseError || @TypeOf(pbn_xml).Error, @errorCast(other)),
        };
        errdefer puzzle_set.deinit();
        if (diag.errors.items.len > 0) return error.InvalidPbn;
        return puzzle_set;
    }

    fn parseXml(gpa: Allocator, reader: *xml.Reader, diag: *Diagnostics) anyerror!PuzzleSet {
        var ps: PuzzleSet = .{
            .puzzles = .empty,
            .colors = .empty,
            .clue_lines = .empty,
            .clues = .empty,
            .solutions = .empty,
            .images = .empty,
            .notes = .empty,
            .strings = .empty,
            .gpa = gpa,
        };
        errdefer ps.deinit();
        const p: Parse = try .init(&ps, reader, diag);
        try p.parse();
        return ps;
    }

    pub fn render(ps: PuzzleSet, gpa: Allocator, writer: anytype) (Allocator.Error || @TypeOf(writer).Error)!void {
        var output = xml.streamingOutput(writer);
        var xml_writer = output.writer(gpa, .{
            .indent = "  ",
            .namespace_aware = false,
        });
        defer xml_writer.deinit();
        return @errorCast(ps.renderXml(xml_writer.raw()));
    }

    fn renderXml(ps: PuzzleSet, writer: *xml.Writer) anyerror!void {
        const r: Render = .init(ps, writer);
        try r.render();
    }

    pub fn data(ps: PuzzleSet, slice: anytype, index: @TypeOf(slice).Index) @TypeOf(slice).Data {
        return ps.dataSlice(slice)[@intFromEnum(index)];
    }

    pub fn dataSlice(ps: PuzzleSet, slice: anytype) []@TypeOf(slice).Data {
        const list = switch (@TypeOf(slice).Data) {
            Color => ps.colors,
            ClueLine => ps.clue_lines,
            Clue => ps.clues,
            Solution => ps.solutions,
            Cell => ps.images,
            Note => ps.notes,
            else => comptime unreachable, // invalid data slice type
        };
        return list.items[slice.base..][0..slice.len];
    }

    pub fn addDataSlice(ps: *PuzzleSet, comptime T: type, items: []const T) Allocator.Error!DataSlice(T) {
        const list = switch (T) {
            Color => &ps.colors,
            ClueLine => &ps.clue_lines,
            Clue => &ps.clues,
            Solution => &ps.solutions,
            Cell => &ps.images,
            Note => &ps.notes,
            else => comptime unreachable, // invalid data slice type
        };
        const base: u32 = @intCast(list.items.len);
        try list.appendSlice(ps.gpa, items);
        return .{ .base = base, .len = @intCast(items.len) };
    }

    pub fn string(ps: PuzzleSet, s: StringIndex) [:0]const u8 {
        const ptr: [*:0]const u8 = @ptrCast(ps.strings.items[@intFromEnum(s)..].ptr);
        return std.mem.span(ptr);
    }

    pub fn optionalString(ps: PuzzleSet, s: StringIndex) ?[:0]const u8 {
        const value = ps.string(s);
        return if (value.len != 0) value else null;
    }

    pub fn addString(ps: *PuzzleSet, s: []const u8) !StringIndex {
        const index: StringIndex = @enumFromInt(ps.strings.items.len);
        try ps.strings.ensureUnusedCapacity(ps.gpa, s.len + 1);
        ps.strings.appendSliceAssumeCapacity(s);
        ps.strings.appendAssumeCapacity(0);
        return index;
    }
};

pub const Puzzle = struct {
    source: StringIndex,
    id: StringIndex,
    title: StringIndex,
    author: StringIndex,
    author_id: StringIndex,
    copyright: StringIndex,
    description: StringIndex,
    colors: DataSlice(Color),
    row_clues: DataSlice(ClueLine),
    column_clues: DataSlice(ClueLine),
    goals: DataSlice(Solution),
    solved_solutions: DataSlice(Solution),
    saved_solutions: DataSlice(Solution),
    notes: DataSlice(Note),

    pub const Index = enum(u32) {
        root = 0,
        _,
    };

    pub const List = std.ArrayListUnmanaged(Puzzle);
};

pub const Color = struct {
    name: StringIndex,
    desc: packed struct(u32) {
        char: u8,
        r: u8,
        g: u8,
        b: u8,
    },

    pub const Index = enum(u5) {
        background = 0,
        default = 1,
        _,
    };

    pub const List = std.ArrayListUnmanaged(Color);

    pub fn rgb(color: Color) struct { u8, u8, u8 } {
        return .{ color.desc.r, color.desc.g, color.desc.b };
    }

    pub fn rgbFloat(color: Color) struct { f32, f32, f32 } {
        return .{
            @as(f32, @floatFromInt(color.desc.r)) / 255.0,
            @as(f32, @floatFromInt(color.desc.g)) / 255.0,
            @as(f32, @floatFromInt(color.desc.b)) / 255.0,
        };
    }
};

pub const ClueLine = struct {
    clues: DataSlice(Clue),

    pub const Index = enum(u32) { _ };

    pub const List = std.ArrayListUnmanaged(ClueLine);
};

pub const Clue = packed struct(u32) {
    color: Color.Index,
    count: u27,

    pub const Type = enum {
        rows,
        columns,
    };

    pub const Index = enum(u32) { _ };

    pub const List = std.ArrayListUnmanaged(Clue);
};

pub const Solution = struct {
    id: StringIndex,
    image: Cell.Index,
    notes: DataSlice(Note),

    pub const Type = enum {
        goal,
        solution,
        saved,
    };

    pub const Index = enum(u32) { _ };

    pub const List = std.ArrayListUnmanaged(Solution);
};

pub const Image = struct {
    puzzle: Puzzle.Index,
    index: Cell.Index,
    rows: usize,
    columns: usize,

    pub fn cellIndex(image: Image, row: usize, column: usize) Cell.Index {
        assert(row < image.rows and column < image.columns);
        return @enumFromInt(@intFromEnum(image.index) + image.columns * row + column);
    }
};

pub const Cell = enum(u32) {
    _,

    pub const Index = enum(u32) { _ };

    pub const List = std.ArrayListUnmanaged(Cell);

    pub fn only(color: Color.Index) Cell {
        return @enumFromInt(@as(u32, 1) << @intFromEnum(color));
    }
};

pub const Note = struct {
    text: StringIndex,

    pub const Index = enum(u32) { _ };

    pub const List = std.ArrayListUnmanaged(Note);
};

pub fn DataSlice(comptime T: type) type {
    return struct {
        base: u32,
        len: u32,

        pub const Index = T.Index;
        pub const Data = T;

        pub const empty: @This() = .{ .base = undefined, .len = 0 };
    };
}

pub const StringIndex = enum(u32) {
    empty = 0,
    _,
};

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 2) return error.InvalidArgs; // usage: libpbn puzzle.pbn

    const raw = try std.fs.cwd().readFileAlloc(gpa, args[1], 4 * 1024 * 1024);
    defer gpa.free(raw);
    var diag: Diagnostics = .init(gpa);
    defer diag.deinit();
    var ps = try PuzzleSet.parse(gpa, raw, &diag);
    defer ps.deinit();

    var stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    try ps.render(gpa, stdout_buf.writer());
    try stdout_buf.flush();
}

test "parse and render - simple puzzle" {
    try testParseAndRender(
        \\<puzzleset>
        \\  <title>Test puzzle set</title>
        \\  <author>Ian Johnson</author>
        \\  <copyright>Public domain</copyright>
        \\  <puzzle>
        \\    <title>Test puzzle</title>
        \\    <clues type="rows">
        \\      <line><count>1</count></line>
        \\      <line><count color="black">2</count></line>
        \\    </clues>
        \\    <clues type="columns">
        \\      <line><count>2</count></line>
        \\      <line><count>1</count></line>
        \\    </clues>
        \\    <solution type="goal">
        \\      <image>| X . | | [X] X |</image>
        \\    </solution>
        \\    <solution type="saved">
        \\      <image>| [X.]? | | XX |</image>
        \\    </solution>
        \\  </puzzle>
        \\</puzzleset>
    ,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<puzzleset>
        \\  <title>Test puzzle set</title>
        \\  <author>Ian Johnson</author>
        \\  <copyright>Public domain</copyright>
        \\  <puzzle>
        \\    <title>Test puzzle</title>
        \\    <color name="white" char=".">FFFFFF</color>
        \\    <color name="black" char="X">000000</color>
        \\    <clues type="rows">
        \\      <line>
        \\        <count>1</count>
        \\      </line>
        \\      <line>
        \\        <count>2</count>
        \\      </line>
        \\    </clues>
        \\    <clues type="columns">
        \\      <line>
        \\        <count>2</count>
        \\      </line>
        \\      <line>
        \\        <count>1</count>
        \\      </line>
        \\    </clues>
        \\    <solution>
        \\      <image>
        \\|X.|
        \\|XX|
        \\</image>
        \\    </solution>
        \\    <solution type="saved">
        \\      <image>
        \\|??|
        \\|XX|
        \\</image>
        \\    </solution>
        \\  </puzzle>
        \\</puzzleset>
        \\
    );
}

test "parse and render - simple puzzle with no explicit clues" {
    try testParseAndRender(
        \\<puzzleset>
        \\  <title>Test puzzle set</title>
        \\  <author>Ian Johnson</author>
        \\  <copyright>Public domain</copyright>
        \\  <puzzle>
        \\    <title>Test puzzle</title>
        \\    <solution type="goal">
        \\      <image>| X . | | [X] X |</image>
        \\    </solution>
        \\    <solution type="saved">
        \\      <image>| [X.]? | | XX |</image>
        \\    </solution>
        \\  </puzzle>
        \\</puzzleset>
    ,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<puzzleset>
        \\  <title>Test puzzle set</title>
        \\  <author>Ian Johnson</author>
        \\  <copyright>Public domain</copyright>
        \\  <puzzle>
        \\    <title>Test puzzle</title>
        \\    <color name="white" char=".">FFFFFF</color>
        \\    <color name="black" char="X">000000</color>
        \\    <clues type="rows">
        \\      <line>
        \\        <count>1</count>
        \\      </line>
        \\      <line>
        \\        <count>2</count>
        \\      </line>
        \\    </clues>
        \\    <clues type="columns">
        \\      <line>
        \\        <count>2</count>
        \\      </line>
        \\      <line>
        \\        <count>1</count>
        \\      </line>
        \\    </clues>
        \\    <solution>
        \\      <image>
        \\|X.|
        \\|XX|
        \\</image>
        \\    </solution>
        \\    <solution type="saved">
        \\      <image>
        \\|??|
        \\|XX|
        \\</image>
        \\    </solution>
        \\  </puzzle>
        \\</puzzleset>
        \\
    );
}

fn testParseAndRender(input: []const u8, expected_output: []const u8) !void {
    const gpa = std.testing.allocator;

    var diag: Diagnostics = .init(gpa);
    defer diag.deinit();
    var ps = PuzzleSet.parse(gpa, input, &diag) catch |err| switch (err) {
        error.InvalidPbn => {
            for (diag.errors.items) |e| {
                std.debug.print("unexpected error: {}\n", .{e});
            }
            return error.InvalidPbn;
        },
        else => |other| return other,
    };
    defer ps.deinit();
    try std.testing.expectEqual(0, diag.errors.items.len);

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(gpa);
    try ps.render(gpa, output.writer(gpa));
    try std.testing.expectEqualStrings(expected_output, output.items);
}
