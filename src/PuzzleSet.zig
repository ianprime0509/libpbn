const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const xml = @import("xml");

puzzles: Puzzle.List,
datas: std.ArrayListUnmanaged(u32),
strings: std.ArrayListUnmanaged(u8),

const PuzzleSet = @This();

pub const max_colors = 32;

pub fn deinit(ps: *PuzzleSet, gpa: Allocator) void {
    ps.puzzles.deinit(gpa);
    ps.datas.deinit(gpa);
    ps.strings.deinit(gpa);
    ps.* = undefined;
}

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

pub const ParseError = error{InvalidPbn} || Allocator.Error;

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
    errdefer puzzle_set.deinit(gpa);
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
    errdefer puzzle_set.deinit(gpa);
    if (diag.errors.items.len > 0) return error.InvalidPbn;
    return puzzle_set;
}

fn parseXml(gpa: Allocator, reader: *xml.Reader, diag: *Diagnostics) anyerror!PuzzleSet {
    var ps: PuzzleSet = .{
        .puzzles = .empty,
        .datas = .empty,
        .strings = .empty,
    };
    errdefer ps.deinit(gpa);
    // The puzzle set data is represented as the "root" puzzle, which will be
    // initialized later.
    try ps.puzzles.append(gpa, undefined);
    // The first element of data is used to represent an empty slice.
    try ps.datas.append(gpa, 0);
    // The empty string must reside at index 0.
    try ps.strings.append(gpa, 0);

    var source: StringIndex = .empty;
    var title: StringIndex = .empty;
    var author: StringIndex = .empty;
    var author_id: StringIndex = .empty;
    var copyright: StringIndex = .empty;
    var puzzles: std.ArrayListUnmanaged(Puzzle.Index) = .empty;
    defer puzzles.deinit(gpa);
    var notes: std.ArrayListUnmanaged(StringIndex) = .empty;
    defer notes.deinit(gpa);

    try reader.skipProlog();
    if (!std.mem.eql(u8, reader.elementName(), "puzzleset")) {
        try diag.addError(.unrecognized_element, reader.location());
        try reader.skipDocument();
        return error.InvalidPbn;
    }
    try noAttributes(reader, diag);

    while (try readChild(reader, diag, enum {
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
                try noAttributes(reader, diag);
                source = try ps.addElementString(gpa, reader, diag);
            },
            .title => {
                try noAttributes(reader, diag);
                title = try ps.addElementString(gpa, reader, diag);
            },
            .author => {
                try noAttributes(reader, diag);
                author = try ps.addElementString(gpa, reader, diag);
            },
            .authorid => {
                try noAttributes(reader, diag);
                author_id = try ps.addElementString(gpa, reader, diag);
            },
            .copyright => {
                try noAttributes(reader, diag);
                copyright = try ps.addElementString(gpa, reader, diag);
            },
            .puzzle => {
                try readPuzzle(gpa, &ps, reader, diag);
            },
            .note => {
                try noAttributes(reader, diag);
                try notes.append(gpa, try ps.addElementString(gpa, reader, diag));
            },
        }
    }

    ps.puzzles.set(0, .{
        .source = source,
        .id = .empty,
        .title = title,
        .author = author,
        .author_id = author_id,
        .copyright = copyright,
        .description = .empty,
        .colors = .empty_slice,
        .row_clues = .empty_slice,
        .column_clues = .empty_slice,
        .goals = .empty_slice,
        .solved_solutions = .empty_slice,
        .saved_solutions = .empty_slice,
        .notes = .empty_slice,
    });

    return ps;
}

fn readPuzzle(gpa: Allocator, ps: *PuzzleSet, reader: *xml.Reader, diag: *Diagnostics) !void {
    var source: StringIndex = .empty;
    var id: StringIndex = .empty;
    var title: StringIndex = .empty;
    var author: StringIndex = .empty;
    var author_id: StringIndex = .empty;
    var copyright: StringIndex = .empty;
    var description: StringIndex = .empty;
    var colors: std.ArrayListUnmanaged(Color) = .empty;
    defer colors.deinit(gpa);
    var row_clues: std.ArrayListUnmanaged(DataIndex) = .empty;
    defer row_clues.deinit(gpa);
    var column_clues: std.ArrayListUnmanaged(DataIndex) = .empty;
    defer column_clues.deinit(gpa);
    var goals: std.ArrayListUnmanaged(Solution) = .empty;
    defer goals.deinit(gpa);
    var solved_solutions: std.ArrayListUnmanaged(Solution) = .empty;
    defer solved_solutions.deinit(gpa);
    var saved_solutions: std.ArrayListUnmanaged(Solution) = .empty;
    defer saved_solutions.deinit(gpa);
    var notes: std.ArrayListUnmanaged(StringIndex) = .empty;
    defer notes.deinit(gpa);

    // To avoid managing many smaller (and more difficult to manage)
    // allocations, all the "complex" intermediate parsing state is owned by an
    // arena.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var default_color_name: []const u8 = "black";
    var background_color_name: []const u8 = "white";
    var parsed_clues: std.EnumArray(ParsedClue.Type, [][]ParsedClue) = .initFill(&.{});
    var parsed_solutions: std.ArrayListUnmanaged(ParsedSolution) = .empty;

    var attrs = attributes(reader, diag, enum {
        type,
        defaultcolor,
        backgroundcolor,
    });
    while (try attrs.next()) |attr| {
        switch (attr.name) {
            .type => {
                if (!std.mem.eql(u8, try reader.attributeValue(attr.index), "grid")) {
                    try diag.addError(.puzzle_type_unsupported, reader.attributeLocation(attr.index));
                    return;
                }
            },
            .defaultcolor => {
                default_color_name = try reader.attributeValueAlloc(arena, attr.index);
            },
            .backgroundcolor => {
                background_color_name = try reader.attributeValueAlloc(arena, attr.index);
            },
        }
    }

    const location = reader.location();
    while (try readChild(reader, diag, enum {
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
                try noAttributes(reader, diag);
                source = try ps.addElementString(gpa, reader, diag);
            },
            .id => {
                try noAttributes(reader, diag);
                id = try ps.addElementString(gpa, reader, diag);
            },
            .title => {
                try noAttributes(reader, diag);
                title = try ps.addElementString(gpa, reader, diag);
            },
            .author => {
                try noAttributes(reader, diag);
                author = try ps.addElementString(gpa, reader, diag);
            },
            .authorid => {
                try noAttributes(reader, diag);
                author_id = try ps.addElementString(gpa, reader, diag);
            },
            .copyright => {
                try noAttributes(reader, diag);
                copyright = try ps.addElementString(gpa, reader, diag);
            },
            .description => {
                try noAttributes(reader, diag);
                description = try ps.addElementString(gpa, reader, diag);
            },
            .color => {
                try colors.append(gpa, try readColor(gpa, ps, reader, diag));
            },
            .clues => {
                try readClues(arena, reader, &parsed_clues, default_color_name, diag);
            },
            .solution => {
                if (try readSolution(gpa, arena, ps, reader, diag)) |solution| {
                    try parsed_solutions.append(arena, solution);
                }
            },
            .note => {
                try noAttributes(reader, diag);
                try notes.append(gpa, try ps.addElementString(gpa, reader, diag));
            },
        }
    }

    try addDefaultColors(gpa, ps, &colors);
    assignColorChars(colors.items);
    sortColors(ps, colors.items, background_color_name, default_color_name) catch |err| switch (err) {
        error.ColorUndefined => {
            try diag.addError(.puzzle_color_undefined, location);
            return;
        },
    };
    if (colors.items.len > max_colors) {
        try diag.addError(.puzzle_too_many_colors, location);
        return;
    }

    var colors_by_name: std.StringArrayHashMapUnmanaged(Color.Index) = .empty;
    var colors_by_char: std.AutoArrayHashMapUnmanaged(u8, Color.Index) = .empty;
    for (colors.items, 0..) |color, i| {
        if (i >= max_colors) break;
        const color_index: Color.Index = @enumFromInt(i);
        const color_name = ps.string(color.name);
        const by_name_gop = try colors_by_name.getOrPut(arena, color_name);
        if (by_name_gop.found_existing) {
            try diag.addError(.color_duplicate_name, location);
        } else {
            by_name_gop.key_ptr.* = try arena.dupe(u8, color_name);
            by_name_gop.value_ptr.* = color_index;
        }
        const by_char_gop = try colors_by_char.getOrPut(arena, color.desc.char);
        if (by_char_gop.found_existing) {
            try diag.addError(.color_duplicate_char, location);
        } else {
            by_char_gop.value_ptr.* = color_index;
        }
    }

    processClues(gpa, ps, parsed_clues.get(.rows), &row_clues, colors_by_name) catch |err| switch (err) {
        error.ColorUndefined => {
            try diag.addError(.puzzle_color_undefined, location);
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    processClues(gpa, ps, parsed_clues.get(.columns), &column_clues, colors_by_name) catch |err| switch (err) {
        error.ColorUndefined => {
            try diag.addError(.puzzle_color_undefined, location);
            return;
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
            try diag.addError(.puzzle_missing_goal, location);
            return;
        }
    };

    for (parsed_solutions.items) |parsed_solution| {
        if (processSolution(gpa, ps, parsed_solution, n_rows, n_columns, colors_by_char)) |solution| {
            const solutions = switch (parsed_solution.type) {
                .goal => &goals,
                .solution => &solved_solutions,
                .saved => &saved_solutions,
            };
            try solutions.append(gpa, solution);
        } else |err| switch (err) {
            error.ImageMismatchedDimensions => try diag.addError(.image_mismatched_dimensions, location),
            error.SolutionIndeterminateImage => try diag.addError(.solution_indeterminate_image, location),
            error.ColorUndefined => try diag.addError(.puzzle_color_undefined, location),
            error.OutOfMemory => return error.OutOfMemory,
        }
    }

    if (!clues_available) {
        // We already validated above that there is at least one goal available.
        try ps.deriveClues(gpa, n_rows, &row_clues, n_columns, &column_clues, goals.items[0].image);
    }

    try ps.puzzles.append(gpa, .{
        .source = source,
        .id = id,
        .title = title,
        .author = author,
        .author_id = author_id,
        .copyright = copyright,
        .description = description,
        .colors = try ps.addDataSlice(gpa, Color, colors.items),
        .row_clues = try ps.addDataSlice(gpa, DataIndex, row_clues.items),
        .column_clues = try ps.addDataSlice(gpa, DataIndex, column_clues.items),
        .goals = try ps.addDataSlice(gpa, Solution, goals.items),
        .solved_solutions = try ps.addDataSlice(gpa, Solution, solved_solutions.items),
        .saved_solutions = try ps.addDataSlice(gpa, Solution, saved_solutions.items),
        .notes = try ps.addDataSlice(gpa, StringIndex, notes.items),
    });
}

fn readColor(gpa: Allocator, ps: *PuzzleSet, reader: *xml.Reader, diag: *Diagnostics) !Color {
    var name: StringIndex = .empty;
    var char: u8 = 0;

    var attrs = attributes(reader, diag, enum { name, char });
    while (try attrs.next()) |attr| {
        switch (attr.name) {
            .name => {
                name = try ps.addString(gpa, try reader.attributeValue(attr.index));
            },
            .char => {
                const value = try reader.attributeValue(attr.index);
                if (value.len == 1) {
                    char = value[0];
                } else {
                    try diag.addError(.color_invalid_char, reader.attributeLocation(attr.index));
                }
            },
        }
    }

    if (name == .empty) {
        try diag.addError(.color_missing_name, reader.location());
    }

    const location = reader.location();
    const value = try readElementTextAlloc(gpa, reader, diag);
    defer gpa.free(value);
    const rgb: Rgb = Rgb.parse(value) orelse invalid: {
        try diag.addError(.color_invalid_rgb, location);
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

fn addDefaultColors(gpa: Allocator, ps: *PuzzleSet, colors: *std.ArrayListUnmanaged(Color)) !void {
    var found_black = false;
    var found_white = false;
    for (colors.items) |color| {
        const name = ps.string(color.name);
        if (std.mem.eql(u8, name, "black")) {
            found_black = true;
        } else if (std.mem.eql(u8, name, "white")) {
            found_white = true;
        }
    }
    if (!found_black) {
        try colors.append(gpa, .{
            .name = try ps.addString(gpa, "black"),
            .desc = .{
                .char = 'X',
                .r = 0,
                .g = 0,
                .b = 0,
            },
        });
    }
    if (!found_white) {
        try colors.append(gpa, .{
            .name = try ps.addString(gpa, "white"),
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
    ps: *PuzzleSet,
    colors: []Color,
    background_color: []const u8,
    default_color: []const u8,
) !void {
    var background_index: ?usize = null;
    var default_index: ?usize = null;
    for (colors, 0..) |color, i| {
        const name = ps.string(color.name);
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
    arena: Allocator,
    reader: *xml.Reader,
    clues: *std.EnumArray(ParsedClue.Type, [][]ParsedClue),
    default_color_name: []const u8,
    diag: *Diagnostics,
) !void {
    var lines: std.ArrayListUnmanaged([]ParsedClue) = .empty;

    var maybe_clues_type: ?ParsedClue.Type = null;
    var attrs = attributes(reader, diag, enum { type });
    while (try attrs.next()) |attr| {
        switch (attr.name) {
            .type => maybe_clues_type = std.meta.stringToEnum(ParsedClue.Type, try reader.attributeValue(attr.index)) orelse
                return diag.addError(.clues_invalid_type, reader.location()),
        }
    }
    const clues_type = maybe_clues_type orelse return diag.addError(.clues_missing_type, reader.location());
    if (clues.get(clues_type).len != 0) {
        return diag.addError(.clues_duplicate, reader.location());
    }

    while (try readChild(reader, diag, enum { line })) |child| {
        switch (child) {
            .line => try lines.append(arena, try readCluesLine(arena, reader, default_color_name, diag)),
        }
    }

    clues.set(clues_type, try lines.toOwnedSlice(arena));
}

fn readCluesLine(
    arena: Allocator,
    reader: *xml.Reader,
    default_color_name: []const u8,
    diag: *Diagnostics,
) ![]ParsedClue {
    var clues: std.ArrayListUnmanaged(ParsedClue) = .empty;

    try noAttributes(reader, diag);

    while (try readChild(reader, diag, enum { count })) |child| {
        switch (child) {
            .count => try clues.append(arena, try readClue(arena, reader, default_color_name, diag)),
        }
    }

    return try clues.toOwnedSlice(arena);
}

fn readClue(
    arena: Allocator,
    reader: *xml.Reader,
    default_color_name: []const u8,
    diag: *Diagnostics,
) !ParsedClue {
    var color_name = default_color_name;

    var attrs = attributes(reader, diag, enum { color });
    while (try attrs.next()) |attr| {
        switch (attr.name) {
            .color => color_name = try reader.attributeValueAlloc(arena, attr.index),
        }
    }

    const location = reader.location();
    const value = try readElementTextAlloc(arena, reader, diag);
    const count = std.fmt.parseInt(u27, value, 10) catch 0;
    if (count == 0) try diag.addError(.clue_invalid_count, location);

    return .{
        .color_name = color_name,
        .count = count,
    };
}

fn processClues(
    gpa: Allocator,
    ps: *PuzzleSet,
    parsed_clues: []const []const ParsedClue,
    clues: *std.ArrayListUnmanaged(DataIndex),
    colors_by_name: std.StringArrayHashMapUnmanaged(Color.Index),
) !void {
    try clues.ensureTotalCapacityPrecise(gpa, parsed_clues.len);
    for (parsed_clues) |parsed_line| {
        const line: DataIndex = @enumFromInt(ps.datas.items.len);
        try ps.datas.ensureUnusedCapacity(gpa, dataSizeOf(Clue) * parsed_line.len + 1);
        ps.datas.appendAssumeCapacity(@intCast(parsed_line.len));
        for (parsed_line) |parsed_clue| {
            _ = ps.addDataAssumeCapacity(Clue, .{
                .color = colors_by_name.get(parsed_clue.color_name) orelse return error.ColorUndefined,
                .count = parsed_clue.count,
            });
        }
        clues.appendAssumeCapacity(line);
    }
}

const ParsedClue = struct {
    color_name: []const u8,
    count: u27,

    const Type = enum {
        rows,
        columns,
    };
};

fn readSolution(
    gpa: Allocator,
    arena: Allocator,
    ps: *PuzzleSet,
    reader: *xml.Reader,
    diag: *Diagnostics,
) !?ParsedSolution {
    var @"type": ParsedSolution.Type = .goal;
    var id: StringIndex = .empty;
    var image: ?[][][]u8 = null;
    var notes: std.ArrayListUnmanaged(StringIndex) = .empty;

    var attrs = attributes(reader, diag, enum { type, id });
    while (try attrs.next()) |attr| {
        switch (attr.name) {
            .type => @"type" = std.meta.stringToEnum(ParsedSolution.Type, try reader.attributeValue(attr.index)) orelse {
                try diag.addError(.solution_invalid_type, reader.attributeLocation(attr.index));
                return null;
            },
            .id => id = try ps.addString(gpa, try reader.attributeValue(attr.index)),
        }
    }

    const location = reader.location();
    while (try readChild(reader, diag, enum { image, note })) |child| {
        switch (child) {
            .image => {
                if (image == null) {
                    image = try readImage(arena, reader, diag);
                } else {
                    try diag.addError(.solution_duplicate_image, reader.location());
                    try reader.skipElement();
                }
            },
            .note => {
                try noAttributes(reader, diag);
                try notes.append(arena, try ps.addElementString(gpa, reader, diag));
            },
        }
    }

    return .{
        .id = id,
        .type = @"type",
        .image = image orelse {
            try diag.addError(.solution_missing_image, location);
            return null;
        },
        .notes = try notes.toOwnedSlice(arena),
    };
}

fn readImage(arena: Allocator, reader: *xml.Reader, diag: *Diagnostics) !?[][][]u8 {
    const location = reader.location();
    const raw = try readElementTextAlloc(arena, reader, diag);

    var rows: std.ArrayListUnmanaged([][]u8) = .empty;
    var after_last_row: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, after_last_row, '|')) |row_start| {
        if (std.mem.indexOfNone(u8, raw[after_last_row..row_start], &std.ascii.whitespace) != null) {
            try diag.addError(.image_invalid, location);
            return null;
        }
        const row_end = std.mem.indexOfScalarPos(u8, raw, row_start + 1, '|') orelse {
            try diag.addError(.image_invalid, location);
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
                    try diag.addError(.image_invalid, location);
                    return null;
                },
                '[' => {
                    const group_end = std.mem.indexOfScalarPos(u8, row_raw, i + 1, ']') orelse {
                        try diag.addError(.image_invalid, location);
                        return null;
                    };
                    const group = row_raw[i + 1 .. group_end];
                    if (std.mem.indexOfAny(u8, group, " \t\r\n?\\/") != null) {
                        try diag.addError(.image_invalid, location);
                        return null;
                    }
                    try columns.append(arena, group);
                    i = group_end;
                },
                else => try columns.append(arena, row_raw[i..][0..1]),
            }
        }
        if (columns.items.len == 0) {
            try diag.addError(.image_invalid, location);
            return null;
        }
        try rows.append(arena, try columns.toOwnedSlice(arena));
    }
    if (rows.items.len == 0) {
        try diag.addError(.image_invalid, location);
        return null;
    }
    return try rows.toOwnedSlice(arena);
}

fn processSolution(
    gpa: Allocator,
    ps: *PuzzleSet,
    solution: ParsedSolution,
    n_rows: usize,
    n_columns: usize,
    colors_by_char: std.AutoArrayHashMapUnmanaged(u8, Color.Index),
) !Solution {
    const image_index: DataIndex = @enumFromInt(ps.datas.items.len);
    try ps.datas.ensureUnusedCapacity(gpa, n_rows * n_columns);
    if (solution.image.len != n_rows) return error.ImageMismatchedDimensions;
    for (solution.image) |row| {
        if (row.len != n_columns) return error.ImageMismatchedDimensions;
        for (row) |cell| {
            const colors = try processCell(cell, solution.type, colors_by_char);
            ps.datas.appendAssumeCapacity(colors);
        }
    }

    return .{
        .id = solution.id,
        .image = image_index,
        .notes = try ps.addDataSlice(gpa, StringIndex, solution.notes),
    };
}

fn processCell(
    cell: []const u8,
    solution_type: ParsedSolution.Type,
    colors_by_char: std.AutoArrayHashMapUnmanaged(u8, Color.Index),
) !u32 {
    if (solution_type != .saved and (cell.len != 1 or cell[0] == '?')) return error.SolutionIndeterminateImage;
    var colors: u32 = 0;
    for (cell) |c| {
        if (c == '?') {
            colors = @intCast((@as(u33, 1) << @intCast(colors_by_char.count())) - 1);
        } else {
            const color = colors_by_char.get(c) orelse return error.ColorUndefined;
            colors |= @as(u32, 1) << @intFromEnum(color);
        }
    }
    return colors;
}

fn deriveClues(
    ps: *PuzzleSet,
    gpa: Allocator,
    n_rows: usize,
    row_clues: *std.ArrayListUnmanaged(DataIndex),
    n_columns: usize,
    column_clues: *std.ArrayListUnmanaged(DataIndex),
    image: DataIndex,
) !void {
    // We have already validated that the image is a proper goal image, so that
    // each cell has exactly one bit set.
    var clues: std.ArrayListUnmanaged(Clue) = .empty;
    defer clues.deinit(gpa);

    try row_clues.ensureTotalCapacityPrecise(gpa, n_rows);
    for (0..n_rows) |i| {
        clues.clearRetainingCapacity();

        var run_color: Color.Index = .background;
        var run_len: usize = 0;
        for (0..n_columns) |j| {
            const color: Color.Index = @enumFromInt(@ctz(ps.datas.items[@intFromEnum(image) + i * n_columns + j]));
            if (color == run_color) {
                run_len += 1;
            } else {
                if (run_color != .background) {
                    try clues.append(gpa, .{
                        .color = run_color,
                        .count = @intCast(run_len),
                    });
                }
                run_color = color;
                run_len = 1;
            }
        }
        if (run_color != .background) {
            try clues.append(gpa, .{
                .color = run_color,
                .count = @intCast(run_len),
            });
        }

        row_clues.appendAssumeCapacity(try ps.addDataSlice(gpa, Clue, clues.items));
    }

    try column_clues.ensureTotalCapacityPrecise(gpa, n_columns);
    for (0..n_columns) |j| {
        clues.clearRetainingCapacity();

        var run_color: Color.Index = .background;
        var run_len: usize = 0;
        for (0..n_rows) |i| {
            const color: Color.Index = @enumFromInt(@ctz(ps.datas.items[@intFromEnum(image) + i * n_columns + j]));
            if (color == run_color) {
                run_len += 1;
            } else {
                if (run_color != .background) {
                    try clues.append(gpa, .{
                        .color = run_color,
                        .count = @intCast(run_len),
                    });
                }
                run_color = color;
                run_len = 1;
            }
        }
        if (run_color != .background) {
            try clues.append(gpa, .{
                .color = run_color,
                .count = @intCast(run_len),
            });
        }

        column_clues.appendAssumeCapacity(try ps.addDataSlice(gpa, Clue, clues.items));
    }
}

const ParsedSolution = struct {
    id: StringIndex,
    type: Type,
    image: []const []const []const u8,
    notes: []const StringIndex,

    const Type = enum {
        goal,
        solution,
        saved,
    };
};

fn readChild(reader: *xml.Reader, diag: *Diagnostics, comptime Child: type) !?Child {
    while (true) {
        switch (try reader.read()) {
            .element_start => {
                if (std.meta.stringToEnum(Child, reader.elementName())) |child| {
                    return child;
                } else {
                    try diag.addError(.unrecognized_element, reader.location());
                    try reader.skipElement();
                }
            },
            .element_end => return null,
            .comment => {},
            .text => {
                if (std.mem.indexOfNone(u8, reader.textRaw(), &std.ascii.whitespace)) |pos| {
                    var location = reader.location();
                    location.update(reader.textRaw()[0..pos]);
                    try diag.addError(.illegal_content, location);
                }
            },
            .pi,
            .cdata,
            .character_reference,
            .entity_reference,
            => try diag.addError(.illegal_content, reader.location()),
            .eof, .xml_declaration => unreachable,
        }
    }
}

fn noAttributes(reader: *const xml.Reader, diag: *Diagnostics) !void {
    for (0..reader.attributeCount()) |i| {
        try diag.addError(.unrecognized_attribute, reader.attributeLocation(i));
    }
}

fn attributes(reader: *const xml.Reader, diag: *Diagnostics, comptime Name: type) AttributeIterator(Name) {
    return .{
        .reader = reader,
        .index = 0,
        .diag = diag,
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
    const puzzles = ps.puzzles.slice();

    try writer.xmlDeclaration("UTF-8", true);
    try writer.elementStart("puzzleset");
    try ps.renderStringElement(writer, "source", puzzles.items(.source)[0]);
    try ps.renderStringElement(writer, "title", puzzles.items(.title)[0]);
    try ps.renderStringElement(writer, "author", puzzles.items(.author)[0]);
    try ps.renderStringElement(writer, "authorid", puzzles.items(.author_id)[0]);
    try ps.renderStringElement(writer, "copyright", puzzles.items(.copyright)[0]);
    for (1..ps.puzzles.len) |i| {
        try ps.renderPuzzle(writer, puzzles, @enumFromInt(i));
    }
    try ps.renderNotes(writer, puzzles.items(.notes)[0]);
    try writer.elementEnd();
    try writer.sink.write("\n");
}

fn renderPuzzle(ps: PuzzleSet, writer: *xml.Writer, puzzles: Puzzle.List.Slice, puzzle: Puzzle.Index) !void {
    const colors = puzzles.items(.colors)[@intFromEnum(puzzle)];
    const row_clues = puzzles.items(.row_clues)[@intFromEnum(puzzle)];
    const n_rows = ps.dataSliceLen(row_clues);
    const column_clues = puzzles.items(.column_clues)[@intFromEnum(puzzle)];
    const n_columns = ps.dataSliceLen(column_clues);

    try writer.elementStart("puzzle");
    const default_color = ps.dataSliceElem(Color, colors, @intFromEnum(Color.Index.default));
    const default_color_name = ps.string(default_color.name);
    if (!std.mem.eql(u8, default_color_name, "black")) {
        try writer.attribute("defaultcolor", default_color_name);
    }
    const background_color = ps.dataSliceElem(Color, colors, @intFromEnum(Color.Index.background));
    const background_color_name = ps.string(background_color.name);
    if (!std.mem.eql(u8, background_color_name, "white")) {
        try writer.attribute("backgroundcolor", background_color_name);
    }
    try ps.renderStringElement(writer, "source", puzzles.items(.source)[@intFromEnum(puzzle)]);
    try ps.renderStringElement(writer, "id", puzzles.items(.id)[@intFromEnum(puzzle)]);
    try ps.renderStringElement(writer, "title", puzzles.items(.title)[@intFromEnum(puzzle)]);
    try ps.renderStringElement(writer, "author", puzzles.items(.author)[@intFromEnum(puzzle)]);
    try ps.renderStringElement(writer, "authorid", puzzles.items(.author_id)[@intFromEnum(puzzle)]);
    try ps.renderStringElement(writer, "copyright", puzzles.items(.copyright)[@intFromEnum(puzzle)]);
    try ps.renderStringElement(writer, "description", puzzles.items(.description)[@intFromEnum(puzzle)]);
    try ps.renderColors(writer, colors);
    try ps.renderClues(writer, row_clues, .rows, colors);
    try ps.renderClues(writer, column_clues, .columns, colors);
    try ps.renderSolutions(writer, puzzles.items(.goals)[@intFromEnum(puzzle)], .goal, n_rows, n_columns, colors);
    try ps.renderSolutions(writer, puzzles.items(.solved_solutions)[@intFromEnum(puzzle)], .solution, n_rows, n_columns, colors);
    try ps.renderSolutions(writer, puzzles.items(.saved_solutions)[@intFromEnum(puzzle)], .saved, n_rows, n_columns, colors);
    try ps.renderNotes(writer, puzzles.items(.notes)[@intFromEnum(puzzle)]);
    try writer.elementEnd();
}

fn renderColors(ps: PuzzleSet, writer: *xml.Writer, colors: DataIndex) !void {
    for (0..ps.dataSliceLen(colors)) |i| {
        const color = ps.dataSliceElem(Color, colors, i);
        try writer.elementStart("color");
        try writer.attribute("name", ps.string(color.name));
        try writer.attribute("char", &.{color.desc.char});
        var buf: [6]u8 = undefined;
        const rgb = std.fmt.bufPrint(&buf, "{X:0>2}{X:0>2}{X:0>2}", .{ color.desc.r, color.desc.g, color.desc.b }) catch unreachable;
        try writer.text(rgb);
        try writer.elementEnd();
    }
}

fn renderClues(
    ps: PuzzleSet,
    writer: *xml.Writer,
    clues: DataIndex,
    clues_type: ParsedClue.Type,
    colors: DataIndex,
) !void {
    try writer.elementStart("clues");
    try writer.attribute("type", @tagName(clues_type));
    for (0..ps.dataSliceLen(clues)) |i| {
        const line = ps.dataSliceElem(DataIndex, clues, i);
        try writer.elementStart("line");
        for (0..ps.dataSliceLen(line)) |j| {
            const clue = ps.dataSliceElem(Clue, line, j);
            try writer.elementStart("count");
            if (clue.color != .default) {
                const color = ps.dataSliceElem(Color, colors, @intFromEnum(clue.color));
                try writer.attribute("color", ps.string(color.name));
            }
            var buf: [32]u8 = undefined;
            const count = std.fmt.bufPrint(&buf, "{}", .{clue.count}) catch unreachable;
            try writer.text(count);
            try writer.elementEnd();
        }
        try writer.elementEnd();
    }
    try writer.elementEnd();
}

fn renderSolutions(
    ps: PuzzleSet,
    writer: *xml.Writer,
    solutions: DataIndex,
    solutions_type: ParsedSolution.Type,
    n_rows: usize,
    n_columns: usize,
    colors: DataIndex,
) !void {
    for (0..ps.dataSliceLen(solutions)) |i| {
        const solution = ps.dataSliceElem(Solution, solutions, i);
        try writer.elementStart("solution");
        if (solutions_type != .goal) try writer.attribute("type", @tagName(solutions_type));
        const id = ps.string(solution.id);
        if (id.len != 0) try writer.attribute("id", id);
        try ps.renderImage(writer, solution.image, n_rows, n_columns, colors);
        try ps.renderNotes(writer, solution.notes);
        try writer.elementEnd();
    }
}

fn renderImage(
    ps: PuzzleSet,
    writer: *xml.Writer,
    image: DataIndex,
    n_rows: usize,
    n_columns: usize,
    colors: DataIndex,
) !void {
    try writer.elementStart("image");
    for (0..n_rows) |i| {
        try writer.text("\n|");
        for (ps.datas.items[@intFromEnum(image) + i * n_columns ..][0..n_columns]) |cell| {
            var color_set: std.bit_set.IntegerBitSet(32) = .{ .mask = cell };
            const n_set = color_set.count();
            if (n_set == ps.dataSliceLen(colors)) {
                try writer.text("?");
                continue;
            }
            if (n_set != 1) try writer.text("[");
            var color_iter = color_set.iterator(.{});
            while (color_iter.next()) |color_index| {
                const color = ps.dataSliceElem(Color, colors, color_index);
                try writer.text(&.{color.desc.char});
            }
            if (n_set != 1) try writer.text("]");
        }
        try writer.text("|");
    }
    try writer.text("\n");
    try writer.elementEnd();
}

fn renderNotes(ps: PuzzleSet, writer: *xml.Writer, notes: DataIndex) !void {
    const n = ps.dataSliceLen(notes);
    if (n == 0) return;
    try writer.elementStart("notes");
    for (0..n) |i| {
        try ps.renderStringElement(writer, "note", ps.dataSliceElem(StringIndex, notes, i));
    }
    try writer.elementEnd();
}

pub const Puzzle = struct {
    source: StringIndex,
    id: StringIndex,
    title: StringIndex,
    author: StringIndex,
    author_id: StringIndex,
    copyright: StringIndex,
    description: StringIndex,
    colors: DataIndex,
    row_clues: DataIndex,
    column_clues: DataIndex,
    goals: DataIndex,
    solved_solutions: DataIndex,
    saved_solutions: DataIndex,
    notes: DataIndex,

    pub const Index = enum(u32) {
        root = 0,
        _,
    };

    pub const List = std.MultiArrayList(Puzzle);
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
};

pub const Clue = packed struct(u32) {
    color: Color.Index,
    count: u27,
};

pub const Solution = struct {
    id: StringIndex,
    image: DataIndex,
    notes: DataIndex,
};

pub const DataIndex = enum(u32) {
    empty_slice = 0,
    _,
};

pub const StringIndex = enum(u32) {
    empty = 0,
    _,
};

fn dataSizeOf(comptime T: type) usize {
    return @divExact(@bitSizeOf(T), 32);
}

fn data(ps: PuzzleSet, comptime T: type, index: DataIndex) T {
    if (@bitSizeOf(T) == 32) {
        return fromData(T, ps.datas.items[@intFromEnum(index)]);
    } else {
        var value: T = undefined;
        inline for (@typeInfo(T).@"struct".fields, @intFromEnum(index)..) |field, i| {
            @field(value, field.name) = fromData(field.type, ps.datas.items[i]);
        }
        return value;
    }
}

fn dataSliceLen(ps: PuzzleSet, index: DataIndex) u32 {
    return ps.datas.items[@intFromEnum(index)];
}

fn dataSliceElem(ps: PuzzleSet, comptime T: type, index: DataIndex, i: usize) T {
    return ps.data(T, @enumFromInt(@intFromEnum(index) + 1 + i * dataSizeOf(T)));
}

fn fromData(comptime T: type, value: u32) T {
    if (@typeInfo(T) == .@"enum") {
        return @enumFromInt(value);
    } else {
        return @bitCast(value);
    }
}

fn addData(ps: *PuzzleSet, gpa: Allocator, comptime T: type, value: T) !DataIndex {
    try ps.datas.ensureUnusedCapacity(gpa, dataSizeOf(T));
    return ps.addDataAssumeCapacity(T, value);
}

fn addDataAssumeCapacity(ps: *PuzzleSet, comptime T: type, value: T) DataIndex {
    const index: DataIndex = @enumFromInt(ps.datas.items.len);
    if (@bitSizeOf(T) == 32) {
        ps.datas.appendAssumeCapacity(toData(value));
    } else {
        inline for (@typeInfo(T).@"struct".fields) |field| {
            ps.datas.appendAssumeCapacity(toData(@field(value, field.name)));
        }
    }
    return index;
}

fn addDataSlice(ps: *PuzzleSet, gpa: Allocator, comptime T: type, slice: []const T) !DataIndex {
    try ps.datas.ensureUnusedCapacity(gpa, dataSizeOf(T) * slice.len + 1);
    const index: DataIndex = @enumFromInt(ps.datas.items.len);
    ps.datas.appendAssumeCapacity(@intCast(slice.len));
    if (@bitSizeOf(T) == 32) {
        ps.datas.appendSliceAssumeCapacity(@ptrCast(slice));
    } else {
        for (slice) |value| {
            inline for (@typeInfo(T).@"struct".fields) |field| {
                ps.datas.appendAssumeCapacity(toData(@field(value, field.name)));
            }
        }
    }
    return index;
}

fn toData(value: anytype) u32 {
    if (@typeInfo(@TypeOf(value)) == .@"enum") {
        return @intFromEnum(value);
    } else {
        return @bitCast(value);
    }
}

fn string(ps: PuzzleSet, s: StringIndex) [:0]const u8 {
    const ptr: [*:0]const u8 = @ptrCast(ps.strings.items[@intFromEnum(s)..].ptr);
    return std.mem.span(ptr);
}

fn addString(ps: *PuzzleSet, gpa: Allocator, s: []const u8) !StringIndex {
    const index: StringIndex = @enumFromInt(ps.strings.items.len);
    try ps.strings.ensureUnusedCapacity(gpa, s.len + 1);
    ps.strings.appendSliceAssumeCapacity(s);
    ps.strings.appendAssumeCapacity(0);
    return index;
}

fn addElementString(ps: *PuzzleSet, gpa: Allocator, reader: *xml.Reader, diag: *Diagnostics) !StringIndex {
    const index: StringIndex = @enumFromInt(ps.strings.items.len);
    var writer = ps.strings.writer(gpa);
    try readElementTextWrite(reader, writer.any(), diag);
    try ps.strings.append(gpa, 0);
    return index;
}

fn readElementTextAlloc(gpa: Allocator, reader: *xml.Reader, diag: *Diagnostics) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    var writer = buf.writer(gpa);
    try readElementTextWrite(reader, writer.any(), diag);
    return try buf.toOwnedSlice(gpa);
}

fn readElementTextWrite(reader: *xml.Reader, writer: std.io.AnyWriter, diag: *Diagnostics) !void {
    // This is a stricter version of the logic in xml.Reader.readElementTextWrite.
    const depth = reader.element_names.items.len;
    while (true) {
        switch (try reader.read()) {
            .xml_declaration, .eof => unreachable,
            .element_start, .pi => {
                try diag.addError(.illegal_content, reader.location());
            },
            .comment => {},
            .element_end => if (reader.element_names.items.len == depth) return,
            .text => try reader.textWrite(writer),
            .cdata => try reader.cdataWrite(writer),
            .character_reference => {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(reader.characterReferenceChar(), &buf) catch unreachable;
                try writer.writeAll(buf[0..len]);
            },
            .entity_reference => {
                const expanded = xml.predefined_entities.get(reader.entityReferenceName()) orelse unreachable;
                try writer.writeAll(expanded);
            },
        }
    }
}

fn renderStringElement(ps: *const PuzzleSet, writer: *xml.Writer, name: []const u8, text: StringIndex) !void {
    const s = ps.string(text);
    if (s.len == 0) return;
    try writer.elementStart(name);
    try writer.text(s);
    try writer.elementEnd();
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
    defer ps.deinit(gpa);
    try std.testing.expectEqual(0, diag.errors.items.len);

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(gpa);
    try ps.render(gpa, output.writer(gpa));
    try std.testing.expectEqualStrings(expected_output, output.items);
}
