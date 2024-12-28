const std = @import("std");
const xml = @import("xml");
const Allocator = std.mem.Allocator;

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
    datas: std.ArrayListUnmanaged(u32),
    strings: std.ArrayListUnmanaged(u8),

    pub fn deinit(ps: *PuzzleSet, gpa: Allocator) void {
        ps.puzzles.deinit(gpa);
        ps.datas.deinit(gpa);
        ps.strings.deinit(gpa);
        ps.* = undefined;
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
        const p: Parse = try .init(gpa, &ps, reader, diag);
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

    pub fn dataSizeOf(comptime T: type) usize {
        return @divExact(@bitSizeOf(T), 32);
    }

    pub fn data(ps: PuzzleSet, comptime T: type, index: DataIndex) T {
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

    pub fn dataSliceLen(ps: PuzzleSet, index: DataIndex) u32 {
        return ps.datas.items[@intFromEnum(index)];
    }

    pub fn dataSliceElem(ps: PuzzleSet, comptime T: type, index: DataIndex, i: usize) T {
        return ps.data(T, @enumFromInt(@intFromEnum(index) + 1 + i * dataSizeOf(T)));
    }

    pub fn fromData(comptime T: type, value: u32) T {
        if (@typeInfo(T) == .@"enum") {
            return @enumFromInt(value);
        } else {
            return @bitCast(value);
        }
    }

    pub fn addData(ps: *PuzzleSet, gpa: Allocator, comptime T: type, value: T) !DataIndex {
        try ps.datas.ensureUnusedCapacity(gpa, dataSizeOf(T));
        return ps.addDataAssumeCapacity(T, value);
    }

    pub fn addDataAssumeCapacity(ps: *PuzzleSet, comptime T: type, value: T) DataIndex {
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

    pub fn addDataSlice(ps: *PuzzleSet, gpa: Allocator, comptime T: type, slice: []const T) !DataIndex {
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

    pub fn toData(value: anytype) u32 {
        if (@typeInfo(@TypeOf(value)) == .@"enum") {
            return @intFromEnum(value);
        } else {
            return @bitCast(value);
        }
    }

    pub fn string(ps: PuzzleSet, s: StringIndex) [:0]const u8 {
        const ptr: [*:0]const u8 = @ptrCast(ps.strings.items[@intFromEnum(s)..].ptr);
        return std.mem.span(ptr);
    }

    pub fn addString(ps: *PuzzleSet, gpa: Allocator, s: []const u8) !StringIndex {
        const index: StringIndex = @enumFromInt(ps.strings.items.len);
        try ps.strings.ensureUnusedCapacity(gpa, s.len + 1);
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

    pub const Type = enum {
        rows,
        columns,
    };
};

pub const Solution = struct {
    id: StringIndex,
    image: DataIndex,
    notes: DataIndex,

    pub const Type = enum {
        goal,
        solution,
        saved,
    };
};

pub const DataIndex = enum(u32) {
    empty_slice = 0,
    _,
};

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
    defer ps.deinit(gpa);

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
    defer ps.deinit(gpa);
    try std.testing.expectEqual(0, diag.errors.items.len);

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(gpa);
    try ps.render(gpa, output.writer(gpa));
    try std.testing.expectEqualStrings(expected_output, output.items);
}
