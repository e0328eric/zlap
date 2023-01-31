const std = @import("std");
const json = std.json;
const mem = std.mem;
const meta = std.meta;
const process = std.process;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const valid_types = [_][]const u8{
    "null",
    "bool",
    "number",
    "string",
};

const valid_lst_types = [_][]const u8{
    "bools",
    "numbers",
    "strings",
};

fn strToTypeForList(comptime string: []const u8) type {
    if (comptime mem.eql(u8, string, "bools")) return bool;
    if (comptime mem.eql(u8, string, "numbers")) return i64;
    if (comptime mem.eql(u8, string, "strings")) return []const u8;

    @compileError(
        "The string should be either `bools`, `numbers` or `strings`. But got " ++ string ++ ".",
    );
}

const ArgJson = struct {
    meta: []const u8,
    desc: ?[]const u8,
    type: []const u8,
    default: ?[]const u8,
};

const FlagJson = struct {
    long: ?[]const u8,
    short: ?[]const u8,
    desc: ?[]const u8,
    type: []const u8,
    default: ?[]const u8,
};

const SubcmdJson = struct {
    name: []const u8,
    desc: ?[]const u8,
    args: []const ArgJson,
    flags: []const FlagJson,
};

const ZlapJson = struct {
    name: []const u8,
    desc: ?[]const u8,
    args: []const ArgJson,
    flags: []const FlagJson,
    subcmds: []const SubcmdJson,
};

pub const ZlapError = Allocator.Error || json.ParseError(ZlapJson) || error{
    InvalidTypeStringFound,
};

pub const Value = union(enum) {
    null,
    bool: bool,
    number: i64,
    string: []const u8,
    bools: ArrayList(bool),
    numbers: ArrayList(i64),
    strings: ArrayList([]const u8),

    fn deinit(self: @This()) void {
        switch (self) {
            inline .bools, .numbers, .strings => |lst| lst.deinit(),
            else => {},
        }
    }
};

pub const Arg = struct {
    desc: ?[]const u8,
    value: Value,

    fn deinit(self: @This()) void {
        self.value.deinit();
    }
};

pub const Flag = struct {
    long: ?[]const u8,
    short: ?[]const u8,
    desc: ?[]const u8,
    value: Value,

    fn deinit(self: @This()) void {
        self.value.deinit();
    }
};

pub const Subcmd = struct {
    desc: ?[]const u8,
    args: ArrayList(Arg),
    flags: ArrayList(Flag),

    fn deinit(self: @This()) void {
        for (self.args.items) |arg| {
            arg.deinit();
        }
        for (self.flags.items) |flag| {
            flag.deinit();
        }

        self.args.deinit();
        self.flags.deinit();
    }
};

// Global Variables
var args: [][:0]u8 = undefined;
var zlap_json: ZlapJson = undefined;

const subcmd_capacity: usize = 16;
const arguments_capacity: usize = 64;
const flags_capacity: usize = 256;
// END Global Variables

pub const Zlap = struct {
    allocator: Allocator,
    program_name: []const u8,
    program_desc: ?[]const u8,
    main_args: ArrayList(Arg),
    main_flags: ArrayList(Flag),
    subcommands: StringHashMap(Subcmd),

    const Self = @This();

    pub fn init(allocator: Allocator, comptime command_json: []const u8) ZlapError!Self {
        var tok_stream = json.TokenStream.init(command_json);
        zlap_json = try json.parse(ZlapJson, &tok_stream, .{ .allocator = allocator });
        errdefer json.parseFree(ZlapJson, zlap_json, .{ .allocator = allocator });

        var zlap: Self = undefined;
        zlap.allocator = allocator;
        zlap.program_name = zlap_json.name;
        zlap.program_desc = zlap_json.desc;

        zlap.main_args = try ArrayList(Arg).initCapacity(allocator, arguments_capacity);
        errdefer zlap.main_args.deinit();
        zlap.main_flags = try ArrayList(Flag).initCapacity(allocator, flags_capacity);
        errdefer zlap.main_flags.deinit();
        zlap.subcommands = StringHashMap(Subcmd).init(allocator);
        errdefer zlap.subcommands.deinit();
        try zlap.subcommands.ensureTotalCapacity(subcmd_capacity);

        // Initialing inner values for zlap
        try zlap.initFields();

        // Parsing the command line argument
        args = try process.argsAlloc(allocator);
        errdefer process.argsFree(allocator, args);
        try zlap.parseArguments();

        return zlap;
    }

    pub fn deinit(self: *Self) void {
        for (self.main_args.items) |arg| {
            arg.deinit();
        }
        for (self.main_flags.items) |flag| {
            flag.deinit();
        }

        var iter = self.subcommands.valueIterator();
        while (iter.next()) |subcmd| {
            subcmd.deinit();
        }

        self.main_args.deinit();
        self.main_flags.deinit();
        self.subcommands.deinit();

        json.parseFree(ZlapJson, zlap_json, .{ .allocator = self.allocator });
        process.argsFree(self.allocator, args);
    }

    fn initFields(self: *Self) ZlapError!void {
        for (zlap_json.args) |arg_json| {
            try self.main_args.append(
                .{
                    .desc = arg_json.desc,
                    .value = try makeValue(self.allocator, arg_json),
                },
            );
        }
        for (zlap_json.flags) |flag_json| {
            try self.main_flags.append(
                .{
                    .long = flag_json.long,
                    .short = flag_json.short,
                    .desc = flag_json.desc,
                    .value = try makeValue(self.allocator, flag_json),
                },
            );
        }
    }

    fn parseArguments(self: *Self) ZlapError!void {
        _ = self;
    }
};

fn makeValue(allocator: Allocator, json_data: anytype) ZlapError!Value {
    inline for (valid_types) |@"type"| {
        if (mem.eql(u8, json_data.type, @"type")) {
            return @unionInit(Value, @"type", undefined);
        }
    }
    inline for (valid_lst_types) |@"type"| {
        if (mem.eql(u8, json_data.type, @"type")) {
            return @unionInit(
                Value,
                @"type",
                try ArrayList(strToTypeForList(@"type")).initCapacity(
                    allocator,
                    16,
                ),
            );
        }
    }
    return error.InvalidTypeStringFound;
}
