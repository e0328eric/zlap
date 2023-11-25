const std = @import("std");
const ascii = std.ascii;
const fmt = std.fmt;
const io = std.io;
const json = std.json;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const process = std.process;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const valid_types = [_][]const u8{
    "bool",
    "number",
    "string",
};

const valid_lst_types = [_][]const u8{
    "bools",
    "numbers",
    "strings",
};

fn strToType(comptime string: []const u8) type {
    if (comptime mem.eql(u8, string, "bool")) return bool;
    if (comptime mem.eql(u8, string, "number")) return i64;
    if (comptime mem.eql(u8, string, "string")) return []const u8;

    @compileError(
        "The string should be either `bool`, `number` or `string`. But got " ++ string ++ ".",
    );
}

fn strToTypeForList(comptime string: []const u8) type {
    if (comptime mem.eql(u8, string, "bools")) return bool;
    if (comptime mem.eql(u8, string, "numbers")) return i64;
    if (comptime mem.eql(u8, string, "strings")) return []const u8;

    @compileError(
        "The string should be either `bools`, `numbers` or `strings`. But got " ++ string ++ ".",
    );
}

const ONLY_SHORT_HASH_SUFFIX: u8 = '!';

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

pub const ZlapError = Allocator.Error || fmt.ParseIntError || error{
    ArgumentOverflowed,
    CannotFindFlag,
    CommandParseFailed,
    FlagValueNotFound,
    InternalError,
    InvalidFlagName,
    InvalidMultipleShortFlags,
    InvalidSubcommand,
    InvalidTypeStringFound,
    InvalidValue,
    JsonParseFailed,
    ShortFlagNameAlreadyExists,
    ShortFlagNameIsTooLong,
    SubcommandConflicted,
    UnknownDefaultValueString,
};

const ParsedCommandName = union(enum) {
    long: []const u8,
    short: []const u8,
    normal: []const u8,

    fn parseCommandName(string: []const u8) @This() {
        if (mem.startsWith(u8, string, "--")) return .{ .long = string[2..] };
        if (mem.startsWith(u8, string, "-")) return .{ .short = string[1..] };
        return .{ .normal = string };
    }
};

pub const Value = union(enum) {
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

    fn isPlural(self: @This()) bool {
        return switch (self) {
            .bools, .numbers, .strings => true,
            else => false,
        };
    }
};

pub const Arg = struct {
    meta: []const u8,
    desc: ?[]const u8,
    value: Value,

    fn deinit(self: @This()) void {
        self.value.deinit();
    }
};

pub const Flag = struct {
    long: ?[]const u8,
    short: ?u8,
    desc: ?[]const u8,
    value: Value,

    fn deinit(self: @This()) void {
        self.value.deinit();
    }
};

pub const Subcmd = struct {
    name: []const u8,
    desc: ?[]const u8,
    args: ArrayList(Arg),
    args_idx: usize,
    flags: StringHashMap(Flag),
    short_arg_map: [256]?[]const u8,

    fn deinit(self: *@This()) void {
        for (self.args.items) |arg| {
            arg.deinit();
        }

        var iter = self.flags.valueIterator();
        while (iter.next()) |flag| {
            flag.deinit();
        }

        self.args.deinit();
        self.flags.deinit();
    }
};

// Global Variables
var raw_args: [][:0]u8 = undefined;
var zlap_json: json.Parsed(ZlapJson) = undefined;

const subcmd_capacity: usize = 16;
const arguments_capacity: usize = 64;
const flags_capacity: usize = 256;
// END Global Variables

pub const Zlap = struct {
    allocator: Allocator,
    program_name: []const u8,
    program_desc: ?[]const u8,
    main_args: ArrayList(Arg),
    main_args_idx: usize,
    main_flags: StringHashMap(Flag),
    short_arg_map: [256]?[]const u8,
    subcommands: StringHashMap(Subcmd),
    active_subcmd: ?*Subcmd,
    is_help: bool,
    help_msg: []const u8,

    const Self = @This();

    pub fn init(allocator: Allocator, comptime command_json: []const u8) !Self {
        zlap_json = json.parseFromSlice(ZlapJson, allocator, command_json, .{}) catch {
            return error.JsonParseFailed;
        };
        errdefer zlap_json.deinit();

        var zlap: Self = undefined;
        zlap.allocator = allocator;
        zlap.program_name = zlap_json.value.name;
        zlap.program_desc = zlap_json.value.desc;
        zlap.main_args_idx = 0;
        zlap.short_arg_map = [_]?[]const u8{null} ** 256;
        zlap.active_subcmd = null;
        zlap.is_help = false;

        zlap.main_args = try ArrayList(Arg).initCapacity(allocator, arguments_capacity);
        errdefer {
            for (zlap.main_args.items) |arg| {
                arg.deinit();
            }
            zlap.main_args.deinit();
        }

        zlap.main_flags = StringHashMap(Flag).init(allocator);
        errdefer {
            var iter = zlap.main_flags.valueIterator();
            while (iter.next()) |flag| {
                flag.deinit();
            }
            zlap.main_flags.deinit();
        }
        try zlap.main_flags.ensureTotalCapacity(flags_capacity);

        zlap.subcommands = StringHashMap(Subcmd).init(allocator);
        errdefer {
            var iter = zlap.subcommands.valueIterator();
            while (iter.next()) |subcmd| {
                subcmd.deinit();
            }
            zlap.subcommands.deinit();
        }
        try zlap.subcommands.ensureTotalCapacity(subcmd_capacity);

        // Initialing inner values for zlap
        try zlap.initFields();

        // Parsing the command line argument
        raw_args = try process.argsAlloc(allocator);
        errdefer process.argsFree(allocator, raw_args);
        try zlap.parseCommandlineArguments();

        zlap.help_msg = try zlap.makeHelpMessage();
        errdefer zlap.freeHelpMessage(zlap.help_msg);

        return zlap;
    }

    pub fn deinit(self: *Self) void {
        for (self.main_args.items) |arg| {
            arg.deinit();
        }

        var flag_iter = self.main_flags.valueIterator();
        while (flag_iter.next()) |flag| {
            flag.deinit();
        }

        var subcmd_iter = self.subcommands.valueIterator();
        while (subcmd_iter.next()) |subcmd| {
            subcmd.deinit();
        }

        self.main_args.deinit();
        self.main_flags.deinit();
        self.subcommands.deinit();
        self.freeHelpMessage(self.help_msg);

        zlap_json.deinit();
        process.argsFree(self.allocator, raw_args);
    }

    pub fn isSubcmdActive(self: *const Self, name: ?[]const u8) bool {
        if (name == null and self.active_subcmd == null) return true;
        if (self.active_subcmd == null) return false;

        return mem.eql(u8, self.active_subcmd.?.name, name.?);
    }

    fn initFields(self: *Self) ZlapError!void {
        for (zlap_json.value.args) |arg_json| {
            const value = try makeValue(self.allocator, arg_json);
            errdefer value.deinit();

            try self.main_args.append(
                .{
                    .meta = arg_json.meta,
                    .desc = arg_json.desc,
                    .value = value,
                },
            );
        }

        try self.main_flags.put(
            "help",
            .{
                .long = "help",
                .short = 'h',
                .desc = "Print this help message",
                .value = .{ .bool = false },
            },
        );
        self.short_arg_map[@intCast('h')] = "help";

        var short_name_for_hash = [2]u8{ 0, ONLY_SHORT_HASH_SUFFIX };
        for (zlap_json.value.flags) |flag_json| {
            const value = try makeValue(self.allocator, flag_json);
            errdefer value.deinit();

            if (flag_json.short == null and flag_json.long == null) {
                return error.InvalidFlagName;
            }

            const short_name = if (flag_json.short) |short| short: {
                if (short.len > 1) return error.ShortFlagNameIsTooLong;
                break :short short[0];
            } else null;

            try self.main_flags.put(
                makeHashName(flag_json.long, &short_name_for_hash, short_name),
                .{
                    .long = flag_json.long,
                    .short = short_name,
                    .desc = flag_json.desc,
                    .value = value,
                },
            );

            if (short_name) |sn| {
                const long_name_ptr = &self.short_arg_map[@as(usize, @intCast(sn))];
                if (long_name_ptr.* != null and long_name_ptr.*.?.len > 0) {
                    return error.ShortFlagNameAlreadyExists;
                }
                long_name_ptr.* = flag_json.long;
            }
        }
        for (zlap_json.value.subcmds) |subcmd_json| {
            if (self.subcommands.get(subcmd_json.name) != null) return error.SubcommandConflicted;

            var args = try ArrayList(Arg).initCapacity(self.allocator, arguments_capacity);
            errdefer {
                for (args.items) |arg| {
                    arg.deinit();
                }
                args.deinit();
            }
            var flags = StringHashMap(Flag).init(self.allocator);
            errdefer {
                var iter = flags.valueIterator();
                while (iter.next()) |flag| {
                    flag.deinit();
                }
                flags.deinit();
            }
            try flags.ensureTotalCapacity(flags_capacity);
            var short_arg_map = [_]?[]const u8{null} ** 256;

            for (subcmd_json.args) |arg_json| {
                const value = try makeValue(self.allocator, arg_json);
                errdefer value.deinit();

                try args.append(
                    .{
                        .meta = arg_json.meta,
                        .desc = arg_json.desc,
                        .value = value,
                    },
                );
            }

            try flags.put(
                "help",
                .{
                    .long = "help",
                    .short = 'h',
                    .desc = "Print this help message",
                    .value = .{ .bool = false },
                },
            );
            short_arg_map[@as(usize, @intCast('h'))] = "help";

            for (subcmd_json.flags) |flag_json| {
                const value = try makeValue(self.allocator, flag_json);
                errdefer value.deinit();

                if (flag_json.short == null and flag_json.long == null) {
                    return error.InvalidFlagName;
                }

                const short_name = if (flag_json.short) |short| short: {
                    if (short.len > 1) return error.ShortFlagNameIsTooLong;
                    break :short short[0];
                } else null;

                try flags.put(
                    makeHashName(flag_json.long, &short_name_for_hash, short_name),
                    .{
                        .long = flag_json.long,
                        .short = short_name,
                        .desc = flag_json.desc,
                        .value = value,
                    },
                );

                if (short_name) |sn| {
                    const long_name_ptr = &short_arg_map[@as(usize, @intCast(sn))];
                    if (long_name_ptr.* != null and long_name_ptr.*.?.len > 0) {
                        return error.ShortFlagNameAlreadyExists;
                    }
                    long_name_ptr.* = flag_json.long;
                }
            }

            try self.subcommands.put(subcmd_json.name, .{
                .name = subcmd_json.name,
                .desc = subcmd_json.desc,
                .args = args,
                .args_idx = 0,
                .flags = flags,
                .short_arg_map = short_arg_map,
            });
        }
    }

    fn parseCommandlineArguments(self: *Self) ZlapError!void {
        var idx: usize = 1;
        while (idx < raw_args.len) : (idx += 1) {
            const parsed_command = ParsedCommandName.parseCommandName(raw_args[idx]);
            switch (parsed_command) {
                .long => |name| try self.parseLongFlag(null, &idx, name),
                .short => |name| try self.parseShortFlag(null, &idx, name),
                .normal => |name| try self.parseNormalCommand(idx == 1, null, &idx, name),
            }
        }
    }

    fn parseNormalCommand(
        self: *Self,
        is_subcommand: bool,
        maybe_subcmd: ?*Subcmd,
        idx: *usize,
        subcmd_name: []const u8,
    ) ZlapError!void {
        if (is_subcommand) {
            if (self.subcommands.count() == 0) return self.parseNormalCommand(
                false,
                null,
                idx,
                subcmd_name,
            );

            self.active_subcmd =
                self.subcommands.getPtr(subcmd_name) orelse return error.InvalidSubcommand;
            idx.* += 1;

            while (idx.* < raw_args.len) : (idx.* += 1) {
                const parsed_flag = ParsedCommandName.parseCommandName(raw_args[idx.*]);
                switch (parsed_flag) {
                    .long => |name| try self.parseLongFlag(self.active_subcmd, idx, name),
                    .short => |name| try self.parseShortFlag(self.active_subcmd, idx, name),
                    .normal => |name| try self.parseNormalCommand(idx.* == 0, self.active_subcmd, idx, name),
                }
            }
        } else {
            idx.* -|= 1;
            if (maybe_subcmd) |subcmd| {
                if (subcmd.args_idx >= subcmd.args.items.len) return error.ArgumentOverflowed;
                try parseValue(false, idx, &subcmd.args.items[subcmd.args_idx], null, null);
                subcmd.args_idx += 1;
            } else {
                if (self.main_args_idx >= self.main_args.items.len) return error.ArgumentOverflowed;
                try parseValue(false, idx, &self.main_args.items[self.main_args_idx], null, null);
                self.main_args_idx += 1;
            }
        }
    }

    fn parseLongFlag(
        self: *Self,
        maybe_subcmd: ?*Subcmd,
        idx: *usize,
        name: []const u8,
    ) ZlapError!void {
        const flag_ptr: *Flag =
            if (maybe_subcmd) |subcmd|
            subcmd.flags.getPtr(name) orelse return error.CannotFindFlag
        else blk: {
            if (name.len == 0) return;
            break :blk self.main_flags.getPtr(name) orelse return error.CannotFindFlag;
        };

        self.is_help = self.is_help or mem.eql(u8, flag_ptr.long.?, "help");
        try parseValue(false, idx, flag_ptr, null, null);
    }

    fn parseShortFlag(
        self: *Self,
        maybe_subcmd: ?*Subcmd,
        idx: *usize,
        name: []const u8,
    ) ZlapError!void {
        var name_idx: usize = 0;
        var flag_ptrs = try ArrayList(*Flag).initCapacity(self.allocator, name.len);
        defer flag_ptrs.deinit();

        var short_name_for_hash = [2]u8{ 0, ONLY_SHORT_HASH_SUFFIX };
        if (maybe_subcmd) |subcmd| {
            while (name_idx < name.len) : (name_idx += 1) {
                self.is_help = self.is_help or name[name_idx] == 'h';
                // zig fmt: off
                try flag_ptrs.append(subcmd.flags.getPtr(makeHashName(
                        subcmd.short_arg_map[name[name_idx]], &short_name_for_hash, name[name_idx]))
                    orelse return error.CannotFindFlag);
                // zig fmt: on
            }
        } else {
            while (name_idx < name.len) : (name_idx += 1) {
                self.is_help = self.is_help or name[name_idx] == 'h';
                // zig fmt: off
                try flag_ptrs.append(self.main_flags.getPtr(makeHashName(
                        self.short_arg_map[name[name_idx]], &short_name_for_hash, name[name_idx]))
                    orelse return error.CannotFindFlag);
                // zig fmt: on
            }
        }

        for (flag_ptrs.items, 0..) |flag_ptr, i| {
            try parseValue(true, idx, flag_ptr, flag_ptrs.items.len, i);
        }
    }

    fn parseValue(
        comptime multiple_short: bool,
        idx: *usize,
        ptr: anytype,
        flag_ptrs_len: ?usize,
        flag_ptrs_idx: ?usize,
    ) ZlapError!void {
        var flag_name: ParsedCommandName = undefined;

        if (multiple_short) {
            if (flag_ptrs_idx.? + 1 < flag_ptrs_len.? and ptr.value != .bool)
                return error.InvalidMultipleShortFlags;
        }

        if (ptr.value != .bool) {
            idx.* += 1;
        }

        switch (ptr.value) {
            .bool => |*val| val.* = !val.*,
            .number => |*val| {
                flag_name = ParsedCommandName.parseCommandName(raw_args[idx.*]);
                if (flag_name != .normal) return error.FlagValueNotFound;
                val.* = try fmt.parseInt(i64, flag_name.normal, 0);
            },
            .string => |*val| {
                flag_name = ParsedCommandName.parseCommandName(raw_args[idx.*]);
                if (flag_name != .normal) return error.FlagValueNotFound;
                val.* = flag_name.normal;
            },
            .bools => |*val| {
                while (blk: {
                    if (idx.* >= raw_args.len) break :blk false;
                    flag_name = ParsedCommandName.parseCommandName(raw_args[idx.*]);
                    break :blk flag_name == .normal;
                }) : (idx.* += 1) {
                    try val.*.append(try isTruthy(flag_name.normal));
                }
                idx.* -|= 1;
            },
            .numbers => |*val| {
                while (blk: {
                    if (idx.* >= raw_args.len) break :blk false;
                    flag_name = ParsedCommandName.parseCommandName(raw_args[idx.*]);
                    break :blk flag_name == .normal;
                }) : (idx.* += 1) {
                    try val.*.append(try fmt.parseInt(i64, flag_name.normal, 0));
                }
                idx.* -|= 1;
            },
            .strings => |*val| {
                while (blk: {
                    if (idx.* >= raw_args.len) break :blk false;
                    flag_name = ParsedCommandName.parseCommandName(raw_args[idx.*]);
                    break :blk flag_name == .normal;
                }) : (idx.* += 1) {
                    try val.*.append(flag_name.normal);
                }
                idx.* -|= 1;
            },
        }
    }

    fn makeHelpMessage(self: *const Self) ZlapError![]const u8 {
        var is_main_help = false;
        var msg = try ArrayList(u8).initCapacity(self.allocator, 400);
        errdefer msg.deinit();

        var writer = msg.writer();
        try writer.print("{s}\n\n", .{self.program_desc orelse ""});

        var args: *const ArrayList(Arg) = undefined;
        var flags: *const StringHashMap(Flag) = undefined;

        if (self.active_subcmd) |subcmd| {
            try writer.print("Usage: {s} {s} [flags]", .{ self.program_name, subcmd.name });

            args = &subcmd.args;
            flags = &subcmd.flags;
        } else {
            is_main_help = true;
            if (self.subcommands.count() > 0) {
                try writer.print("Usage: {s} [subcommands] [flags]", .{self.program_name});
            } else {
                try writer.print("Usage: {s} [flags]", .{self.program_name});
            }

            args = &self.main_args;
            flags = &self.main_flags;
        }

        var padding: usize = 0;
        for (args.items) |arg| {
            padding = @max(padding, arg.meta.len);
            try writer.print(" {s}", .{arg.meta});
            if (arg.value.isPlural()) {
                try writer.print("...", .{});
            }
        } else {
            try writer.print("\n\n", .{});
        }

        var flags_iter = flags.valueIterator();
        while (flags_iter.next()) |flag| {
            const flag_long_len = @max((flag.long orelse "").len, 4);
            padding = @max(padding, flag_long_len);
        }

        if (is_main_help and self.subcommands.count() > 0) {
            var subcmd_iter = self.subcommands.valueIterator();
            while (subcmd_iter.next()) |subcmd| {
                const subcmd_len = @max(subcmd.name.len, 4);
                padding = @max(padding, subcmd_len);
            }
        }

        try writer.print("Arguments:\n", .{});
        for (args.items) |arg| {
            try writer.print("    {s}", .{arg.meta});
            if (arg.value.isPlural()) {
                try writer.print("...", .{});
                try writer.writeByteNTimes(' ', padding - arg.meta.len + 7);
            } else {
                try writer.writeByteNTimes(' ', padding - arg.meta.len + 10);
            }
            if (arg.desc) |desc| try writer.print("{s}", .{desc});
            try writer.writeByte('\n');
        } else {
            try writer.print("\n\n", .{});
        }

        try writer.print("Options:\n", .{});

        flags_iter = flags.valueIterator();
        while (flags_iter.next()) |flag| {
            try writer.print("    ", .{});
            if (flag.short) |short| {
                try writer.print("-{c},", .{short});
            } else {
                try writer.print(" " ** 3, .{});
            }
            if (flag.long) |long| {
                try writer.print(" --{s}", .{long});
                if (flag.value.isPlural()) {
                    try writer.print("...", .{});
                    try writer.writeByteNTimes(' ', padding - (flag.long orelse "").len + 1);
                } else {
                    try writer.writeByteNTimes(' ', padding - (flag.long orelse "").len + 4);
                }
            } else {
                try writer.writeByteNTimes(' ', padding + 7);
            }
            if (flag.desc) |desc| try writer.print("{s}", .{desc});
            try writer.writeByte('\n');
        }

        if (is_main_help and self.subcommands.count() > 0) {
            try writer.print("\nSubcommands:\n", .{});
            var subcmd_iter = self.subcommands.valueIterator();
            while (subcmd_iter.next()) |subcmd| {
                try writer.print("    {s}", .{subcmd.name});
                try writer.writeByteNTimes(' ', padding - subcmd.name.len + 2);
                try writer.print("        {?s}\n", .{subcmd.desc});
            }
        }

        return msg.toOwnedSlice();
    }

    fn freeHelpMessage(self: *const Self, msg: []const u8) void {
        self.allocator.free(msg);
    }
};

fn makeValue(allocator: Allocator, json_data: anytype) ZlapError!Value {
    // zig fmt: off
    if (!@hasField(@TypeOf(json_data), "default")) {
        @compileError("The type " ++ @typeName(@TypeOf(json_data))
            ++ " does not have `default` field.");
    }
    // zig fmt: on

    inline for (valid_types) |@"type"| {
        if (mem.eql(u8, json_data.type, @"type")) {
            return @unionInit(
                Value,
                @"type",
                if (json_data.default) |default_val|
                    try parseDefaultValue(strToType(@"type"), default_val)
                else blk: {
                    break :blk switch (strToType(@"type")) {
                        bool => false,
                        i64 => 0,
                        []const u8 => "",
                        else => unreachable,
                    };
                },
            );
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

fn parseDefaultValue(comptime T: type, string: []const u8) ZlapError!T {
    switch (T) {
        bool => {
            // zig fmt: off
            if (mem.eql(u8, string, "true")) return true
            else if (mem.eql(u8, string, "false")) return false
            else return error.UnknownDefaultValueString;
            // zig fmt: on
        },
        i64 => return fmt.parseInt(i64, string, 10),
        []const u8 => return string,
        else => @compileError("parseDefaultValue function does not support for a type " ++ @typeName(T)),
    }
}

fn isTruthy(string: []const u8) ZlapError!bool {
    var buf: [1024]u8 = undefined;
    const lower_string = ascii.lowerString(&buf, string);

    if (mem.eql(u8, lower_string, "true")) return true;
    if (lower_string.len == 1 and lower_string[0] == 't') return true;
    if (mem.eql(u8, lower_string, "false")) return false;
    if (lower_string.len == 1 and lower_string[0] == 'f') return false;

    return error.InvalidValue;
}

fn makeHashName(long_name: ?[]const u8, short_name_buf: []u8, short_name: ?u8) []const u8 {
    return if (long_name) |long| long else blk: {
        short_name_buf[0] = short_name.?;
        break :blk short_name_buf;
    };
}
