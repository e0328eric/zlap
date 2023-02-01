const std = @import("std");
const ascii = std.ascii;
const fmt = std.fmt;
const io = std.io;
const json = std.json;
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
    ArgumentOverflowed,
    CannotFindFlag,
    CommandParseFailed,
    FlagValueNotFound,
    InternalError,
    InvalidMultipleShortFlags,
    InvalidSubcommand,
    InvalidTypeStringFound,
    InvalidValue,
    ShortFlagNameIsTooLong,
    SubcommandConflicted,
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
};

const FlagName = union(enum) {
    long: []const u8,
    short: []const u8,
    normal: []const u8,

    fn parseFlagName(string: []const u8) FlagName {
        if (mem.startsWith(u8, string, "--")) return .{ .long = string[2..] };
        if (mem.startsWith(u8, string, "-")) return .{ .short = string[1..] };
        return .{ .normal = string };
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
    desc: ?[]const u8,
    args: ArrayList(Arg),
    args_idx: usize,
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
var raw_args: [][:0]u8 = undefined;
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
    main_args_idx: usize,
    main_flags: ArrayList(Flag),
    subcommands: StringHashMap(Subcmd),
    active_subcmd_name: ?[]const u8,
    is_help_flag_actived: bool,
    help_msg: []const u8,

    const Self = @This();

    pub fn init(allocator: Allocator, comptime command_json: []const u8) ZlapError!Self {
        var tok_stream = json.TokenStream.init(command_json);
        zlap_json = try json.parse(ZlapJson, &tok_stream, .{ .allocator = allocator });
        errdefer json.parseFree(ZlapJson, zlap_json, .{ .allocator = allocator });

        var zlap: Self = undefined;
        zlap.allocator = allocator;
        zlap.program_name = zlap_json.name;
        zlap.program_desc = zlap_json.desc;
        zlap.main_args_idx = 0;
        zlap.active_subcmd_name = null;
        zlap.is_help_flag_actived = false;

        zlap.main_args = try ArrayList(Arg).initCapacity(allocator, arguments_capacity);
        errdefer {
            for (zlap.main_args.items) |arg| {
                arg.deinit();
            }
            zlap.main_args.deinit();
        }
        zlap.main_flags = try ArrayList(Flag).initCapacity(allocator, flags_capacity);
        errdefer {
            for (zlap.main_flags.items) |flag| {
                flag.deinit();
            }
            zlap.main_flags.deinit();
        }
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
        self.freeHelpMessage(self.help_msg);

        json.parseFree(ZlapJson, zlap_json, .{ .allocator = self.allocator });
        process.argsFree(self.allocator, raw_args);
    }

    fn initFields(self: *Self) ZlapError!void {
        for (zlap_json.args) |arg_json| {
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

        try self.main_flags.append(
            .{
                .long = "help",
                .short = 'h',
                .desc = "Print this help message",
                .value = .{ .bool = false },
            },
        );
        for (zlap_json.flags) |flag_json| {
            const value = try makeValue(self.allocator, flag_json);
            errdefer value.deinit();

            const short_name = if (flag_json.short) |short| short: {
                if (short.len > 1) return error.ShortFlagNameIsTooLong;
                break :short short[0];
            } else null;
            try self.main_flags.append(
                .{
                    .long = flag_json.long,
                    .short = short_name,
                    .desc = flag_json.desc,
                    .value = value,
                },
            );
        }
        for (zlap_json.subcmds) |subcmd_json| {
            if (self.subcommands.get(subcmd_json.name) != null) return error.SubcommandConflicted;

            var args = try ArrayList(Arg).initCapacity(self.allocator, arguments_capacity);
            errdefer args.deinit();
            var flags = try ArrayList(Flag).initCapacity(self.allocator, flags_capacity);
            errdefer flags.deinit();

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

            try flags.append(
                .{
                    .long = "help",
                    .short = 'h',
                    .desc = "Print this help message",
                    .value = .{ .bool = false },
                },
            );
            for (subcmd_json.flags) |flag_json| {
                const value = try makeValue(self.allocator, flag_json);
                errdefer value.deinit();

                const short_name = if (flag_json.short) |short| short: {
                    if (short.len > 1) return error.ShortFlagNameIsTooLong;
                    break :short short[0];
                } else null;
                try flags.append(
                    .{
                        .long = flag_json.long,
                        .short = short_name,
                        .desc = flag_json.desc,
                        .value = value,
                    },
                );
            }

            try self.subcommands.put(subcmd_json.name, .{
                .desc = subcmd_json.desc,
                .args = args,
                .args_idx = 0,
                .flags = flags,
            });
        }
    }

    fn parseCommandlineArguments(self: *Self) ZlapError!void {
        var idx: usize = 1;
        while (idx < raw_args.len) : (idx += 1) {
            const parsed_flag = FlagName.parseFlagName(raw_args[idx]);
            switch (parsed_flag) {
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

            self.active_subcmd_name = subcmd_name;
            const subcmd =
                self.subcommands.getPtr(subcmd_name) orelse return error.InvalidSubcommand;
            idx.* += 1;

            while (idx.* < raw_args.len) : (idx.* += 1) {
                const parsed_flag = FlagName.parseFlagName(raw_args[idx.*]);
                switch (parsed_flag) {
                    .long => |name| try self.parseLongFlag(subcmd, idx, name),
                    .short => |name| try self.parseShortFlag(subcmd, idx, name),
                    .normal => |name| try self.parseNormalCommand(idx.* == 0, subcmd, idx, name),
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
        var flag_ptr: *Flag = undefined;

        if (maybe_subcmd) |subcmd| {
            for (subcmd.flags.items) |*flag| {
                if (flag.long != null and mem.eql(u8, flag.long.?, name)) {
                    flag_ptr = flag;
                    break;
                }
            } else {
                return error.CannotFindFlag;
            }
        } else {
            if (name.len == 0) return;
            for (self.main_flags.items) |*flag| {
                if (flag.long != null and mem.eql(u8, flag.long.?, name)) {
                    flag_ptr = flag;
                    break;
                }
            } else {
                return error.CannotFindFlag;
            }
        }

        self.is_help_flag_actived = mem.eql(u8, flag_ptr.long.?, "help");
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

        if (maybe_subcmd) |subcmd| {
            for (subcmd.flags.items) |*flag| {
                if (flag.short != null and flag.short.? == name[name_idx]) {
                    try flag_ptrs.append(flag);
                    self.is_help_flag_actived = name[name_idx] == 'h';
                    name_idx += 1;
                }
                if (name_idx >= name.len) break;
            } else {
                return error.CannotFindFlag;
            }
        } else {
            for (self.main_flags.items) |*flag| {
                if (flag.short != null and flag.short.? == name[name_idx]) {
                    try flag_ptrs.append(flag);
                    self.is_help_flag_actived = name[name_idx] == 'h';
                    name_idx += 1;
                }
                if (name_idx >= name.len) break;
            } else {
                return error.CannotFindFlag;
            }
        }

        for (flag_ptrs.items) |flag_ptr, i| {
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
        var flag_name: FlagName = undefined;

        if (multiple_short) {
            if (flag_ptrs_idx.? + 1 < flag_ptrs_len.? and ptr.value != .bool)
                return error.InvalidMultipleShortFlags;
        }

        if (ptr.value != .bool) {
            idx.* += 1;
        }

        switch (ptr.value) {
            .bool => |*val| val.* = true,
            .number => |*val| {
                flag_name = FlagName.parseFlagName(raw_args[idx.*]);
                if (flag_name != .normal) return error.FlagValueNotFound;
                val.* = try fmt.parseInt(i64, flag_name.normal, 0);
            },
            .string => |*val| {
                flag_name = FlagName.parseFlagName(raw_args[idx.*]);
                if (flag_name != .normal) return error.FlagValueNotFound;
                val.* = flag_name.normal;
            },
            .bools => |*val| {
                while (blk: {
                    if (idx.* >= raw_args.len) break :blk false;
                    flag_name = FlagName.parseFlagName(raw_args[idx.*]);
                    break :blk flag_name == .normal;
                }) : (idx.* += 1) {
                    try val.*.append(try isTruthy(flag_name.normal));
                }
                idx.* -|= 1;
            },
            .numbers => |*val| {
                while (blk: {
                    if (idx.* >= raw_args.len) break :blk false;
                    flag_name = FlagName.parseFlagName(raw_args[idx.*]);
                    break :blk flag_name == .normal;
                }) : (idx.* += 1) {
                    try val.*.append(try fmt.parseInt(i64, flag_name.normal, 0));
                }
                idx.* -|= 1;
            },
            .strings => |*val| {
                while (blk: {
                    if (idx.* >= raw_args.len) break :blk false;
                    flag_name = FlagName.parseFlagName(raw_args[idx.*]);
                    break :blk flag_name == .normal;
                }) : (idx.* += 1) {
                    try val.*.append(flag_name.normal);
                }
                idx.* -|= 1;
            },
        }
    }

    fn makeHelpMessage(self: Self) ZlapError![]const u8 {
        var msg = try ArrayList(u8).initCapacity(self.allocator, 400);
        errdefer msg.deinit();

        var writer = msg.writer();
        try writer.print("{s}\n\n", .{self.program_desc orelse ""});

        var args: *const ArrayList(Arg) = undefined;
        var flags: *const ArrayList(Flag) = undefined;

        if (self.active_subcmd_name) |subcmd_name| {
            const subcmd = self.subcommands.get(subcmd_name) orelse return error.InternalError;
            try writer.print("Usage: {s} {s} [flags]", .{ self.program_name, subcmd_name });

            args = &subcmd.args;
            flags = &subcmd.flags;
        } else {
            try writer.print("Usage: {s} [flags]", .{self.program_name});

            args = &self.main_args;
            flags = &self.main_flags;
        }

        for (args.items) |arg| {
            try writer.print(" {s}", .{arg.meta});
        } else {
            try writer.print("\n\n", .{});
        }

        try writer.print("Options:\n", .{});
        var max_len_flag_name: usize = 0;
        for (flags.items) |flag| {
            max_len_flag_name = @max(max_len_flag_name, (flag.long orelse "").len);
        }
        for (flags.items) |flag| {
            try writer.print("    -{?c}, --{?s}", .{ flag.short, flag.long });
            var i = max_len_flag_name - (flag.long orelse "").len + 8;
            while (i > 0) : (i -= 1) {
                try writer.print(" ", .{});
            }
            try writer.print("{?s}\n", .{flag.desc});
        }

        return msg.toOwnedSlice();
    }

    fn freeHelpMessage(self: Self, msg: []const u8) void {
        self.allocator.free(msg);
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

fn isTruthy(string: []const u8) ZlapError!bool {
    var buf: [1024]u8 = undefined;
    const lower_string = ascii.lowerString(&buf, string);

    if (mem.eql(u8, lower_string, "true")) return true;
    if (lower_string.len == 1 and lower_string[0] == 't') return true;
    if (mem.eql(u8, lower_string, "false")) return false;
    if (lower_string.len == 1 and lower_string[0] == 'f') return false;

    return error.InvalidValue;
}
