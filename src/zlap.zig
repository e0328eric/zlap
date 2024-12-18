const std = @import("std");
const ascii = std.ascii;
const fmt = std.fmt;
const io = std.io;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const process = std.process;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Type = std.builtin.Type;

const SUBCMD_CAPACITY: usize = 16;
const ARGUMENTS_CAPACITY: usize = 64;
const FLAGS_CAPACITY: usize = 256;
const ONLY_SHORT_HASH_SUFFIX: u8 = '!';

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
        "The string should be either `bool`, `number` or `string`. But got " ++
            string ++ ".",
    );
}

fn strToTypeForList(comptime string: []const u8) type {
    if (comptime mem.eql(u8, string, "bools")) return bool;
    if (comptime mem.eql(u8, string, "numbers")) return i64;
    if (comptime mem.eql(u8, string, "strings")) return []const u8;

    @compileError(
        "The string should be either `bools`, `numbers` or `strings`. But got " ++
            string ++ ".",
    );
}

const ArgZlap = struct {
    meta: []const u8 = "",
    desc: []const u8 = "",
    type: []const u8 = "",
    default: []const u8 = "",
};

const FlagZlap = struct {
    long: []const u8 = "",
    short: []const u8 = "",
    desc: []const u8 = "",
    type: []const u8 = "",
    default: []const u8 = "",
};

const ZlapMetadata = struct {
    subcmd_num: comptime_int = 0,
    arg_num: comptime_int = 0,
    flag_num: comptime_int = 0,
};

fn zlapGetMetadata(cmd_text: []const u8) ZlapMetadata {
    comptime {
        @setEvalBranchQuota(20000);
        var zlap_metadata = ZlapMetadata{};
        var arg_num_tmp = 0;
        var flag_num_tmp = 0;
        var stmt = mem.tokenizeAny(u8, cmd_text, ";\n\r}");
        var line_num: usize = 0;

        while (stmt.next()) |raw_line| : (line_num += 1) {
            const line = mem.trim(u8, raw_line, " \t");
            if (line.len == 0) continue;

            switch (line[0]) {
                '{' => {
                    if (zlap_metadata.subcmd_num > 0) {
                        zlap_metadata.arg_num |= arg_num_tmp;
                        zlap_metadata.flag_num |= flag_num_tmp;
                        zlap_metadata.arg_num <<= 8;
                        zlap_metadata.flag_num <<= 8;
                    }
                    zlap_metadata.subcmd_num += 1;
                    arg_num_tmp = 0;
                    flag_num_tmp = 0;
                },
                '#' => if (mem.eql(u8, line[1..], "arg")) {
                    arg_num_tmp += 1;
                } else if (mem.eql(u8, line[1..], "flag")) {
                    flag_num_tmp += 1;
                } else continue,
                else => continue,
            }
        } else {
            zlap_metadata.arg_num |= arg_num_tmp;
            zlap_metadata.flag_num |= flag_num_tmp;
        }

        return zlap_metadata;
    }
}

fn getArgNum(
    comptime metadata: ZlapMetadata,
    comptime idx: comptime_int,
) comptime_int {
    comptime std.debug.assert(metadata.subcmd_num >= 1);
    return metadata.arg_num >> (metadata.subcmd_num - idx - 1) * 8 & 0xFF;
}

fn getFlagNum(
    comptime metadata: ZlapMetadata,
    comptime idx: comptime_int,
) comptime_int {
    comptime std.debug.assert(metadata.subcmd_num >= 1);
    return metadata.flag_num >> (metadata.subcmd_num - idx - 1) * 8 & 0xFF;
}

fn ZlapSubcmd(
    comptime subcmd_text: []const u8,
    comptime metadata: ZlapMetadata,
    comptime idx: comptime_int,
) type {
    comptime {
        std.debug.assert(subcmd_text[subcmd_text.len - 1] == '}');

        @setEvalBranchQuota(20000);
        const args_num = getArgNum(metadata, idx);
        const flags_num = getFlagNum(metadata, idx);
        var stmt = mem.tokenizeAny(u8, subcmd_text, ";\n\r");
        var type_to_read: enum { none, args, flags } = .none;
        var args: [args_num]ArgZlap = @splat(ArgZlap{});
        var flags: [flags_num]FlagZlap = @splat(FlagZlap{});
        var args_idx = -1;
        var flags_idx = -1;
        var name: []const u8 = "";
        var desc: []const u8 = "";
        var is_main: bool = false;

        while (stmt.next()) |raw_line| {
            const line = mem.trim(u8, raw_line, " \t");
            if (line.len == 0) continue;

            switch (line[0]) {
                '#' => if (mem.eql(u8, line[1..], "arg")) {
                    type_to_read = .args;
                    args_idx += 1;
                    continue;
                } else if (mem.eql(u8, line[1..], "flag")) {
                    type_to_read = .flags;
                    flags_idx += 1;
                    continue;
                } else if (mem.eql(u8, line[1..], "main")) {
                    is_main = true;
                    continue;
                } else {
                    var dict = mem.tokenizeScalar(u8, line[1..], ':');
                    const key = dict.next() orelse "";
                    const value = mem.trim(u8, dict.next() orelse "", " \t");
                    if (mem.eql(u8, key, "name")) {
                        name = value;
                    } else if (mem.eql(u8, key, "desc")) {
                        desc = value;
                    } else {
                        @compileError(fmt.comptimePrint(
                            "only `#name`, `#desc`, `#arg` and `#flag` are allowed, but got {s}",
                            .{line},
                        ));
                    }
                },
                '}' => break, // NOTE: END OF THE SUBCOMMAND
                else => {
                    var dict = mem.tokenizeScalar(u8, line, ':');
                    const key = dict.next() orelse "";
                    const value = mem.trim(u8, dict.next() orelse "", " \t");
                    switch (type_to_read) {
                        .args => @field(args[args_idx], key) = value,
                        .flags => @field(flags[flags_idx], key) = value,
                        .none => @compileError("either `#arg` or `#flag` is used before"),
                    }
                },
            }
        }

        const subcmd_type: Type = .{ .@"struct" = Type.Struct{
            .layout = .auto,
            .is_tuple = false,
            .decls = &.{},
            .fields = &.{
                Type.StructField{
                    .name = "is_main",
                    .type = bool,
                    .is_comptime = true,
                    .alignment = @alignOf(bool),
                    .default_value = @ptrCast(&is_main),
                },
                Type.StructField{
                    .name = "name",
                    .type = []const u8,
                    .is_comptime = true,
                    .alignment = @alignOf([]const u8),
                    .default_value = @ptrCast(&name),
                },
                Type.StructField{
                    .name = "desc",
                    .type = []const u8,
                    .is_comptime = true,
                    .alignment = @alignOf([]const u8),
                    .default_value = @ptrCast(&desc),
                },
                Type.StructField{
                    .name = "args",
                    .type = [args_num]ArgZlap,
                    .is_comptime = true,
                    .alignment = @alignOf([args_num]ArgZlap),
                    .default_value = @ptrCast(&args),
                },
                Type.StructField{
                    .name = "flags",
                    .type = [flags_num]FlagZlap,
                    .is_comptime = true,
                    .alignment = @alignOf([flags_num]FlagZlap),
                    .default_value = @ptrCast(&flags),
                },
            },
        } };

        return @Type(subcmd_type);
    }
}

fn ZlapZlap(comptime cmd_text: []const u8) type {
    comptime {
        @setEvalBranchQuota(50000);

        const metadata = zlapGetMetadata(cmd_text);
        var iter = mem.tokenizeScalar(u8, cmd_text, '{');
        var zlap_type: Type = .{ .@"struct" = Type.Struct{
            .layout = .auto,
            .is_tuple = false,
            .decls = &.{},
            .fields = &.{},
        } };

        var idx = 0;
        var double_main = 0;

        while (iter.next()) |subcmd_str| : (idx += 1) {
            const subcmd_part = mem.trim(u8, subcmd_str, " \t\n\r");
            const subcmd = ZlapSubcmd(subcmd_part, metadata, idx){};
            if (subcmd.is_main) {
                if (double_main > 1) @compileError("two `#main` subcommands found");

                double_main += 1;
                zlap_type.@"struct".fields = zlap_type.@"struct".fields ++
                    .{Type.StructField{
                    .name = "program_name",
                    .type = []const u8,
                    .is_comptime = true,
                    .alignment = @alignOf([]const u8),
                    .default_value = @ptrCast(&subcmd.name),
                }};
                zlap_type.@"struct".fields = zlap_type.@"struct".fields ++
                    .{Type.StructField{
                    .name = "program_desc",
                    .type = []const u8,
                    .is_comptime = true,
                    .alignment = @alignOf([]const u8),
                    .default_value = @ptrCast(&subcmd.desc),
                }};
                zlap_type.@"struct".fields = zlap_type.@"struct".fields ++
                    .{Type.StructField{
                    .name = "main",
                    .type = @TypeOf(subcmd),
                    .is_comptime = true,
                    .alignment = @alignOf(@TypeOf(subcmd)),
                    .default_value = @ptrCast(&subcmd),
                }};
            } else {
                var name: [subcmd.name.len + 1:0]u8 = @splat(0);
                @memcpy(name[0..subcmd.name.len], subcmd.name);
                zlap_type.@"struct".fields = zlap_type.@"struct".fields ++
                    .{Type.StructField{
                    .name = &name,
                    .type = @TypeOf(subcmd),
                    .is_comptime = true,
                    .alignment = @alignOf(@TypeOf(subcmd)),
                    .default_value = @ptrCast(&subcmd),
                }};
            }
        }

        if (double_main == 0) @compileError("no `#main` subcommand found");

        return @Type(zlap_type);
    }
}

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
    args: StringHashMap(*const Arg),
    flags: StringHashMap(Flag),
    args_raw: ArrayList(Arg),
    args_idx: usize,
    short_arg_map: [256]?[]const u8,

    fn deinit(self: *@This()) void {
        self.args.deinit();

        for (self.args_raw.items) |arg| {
            arg.deinit();
        }

        var iter = self.flags.valueIterator();
        while (iter.next()) |flag| {
            flag.deinit();
        }

        self.args_raw.deinit();
        self.flags.deinit();
    }
};

// Global Variables
var raw_argv: [][:0]u8 = undefined;
// END Global Variables

pub fn Zlap(comptime cmd_text: []const u8) type {
    return struct {
        allocator: Allocator,
        program_name: []const u8,
        program_desc: ?[]const u8,
        main_args: StringHashMap(*const Arg),
        main_flags: StringHashMap(Flag),
        main_args_raw: ArrayList(Arg),
        main_args_idx: usize,
        short_arg_map: [256]?[]const u8,
        subcommands: StringHashMap(Subcmd),
        active_subcmd: ?*Subcmd,
        is_help: bool,
        help_msg: []const u8,

        const Self = @This();
        const zlap_zlap = ZlapZlap(cmd_text){};

        pub fn init(allocator: Allocator) !Self {
            var zlap: Self = undefined;
            zlap.allocator = allocator;
            zlap.program_name = zlap_zlap.main.name;
            zlap.program_desc = zlap_zlap.main.desc;
            zlap.main_args_idx = 0;
            zlap.short_arg_map = [_]?[]const u8{null} ** 256;
            zlap.active_subcmd = null;
            zlap.is_help = false;

            zlap.main_args_raw = try ArrayList(Arg).initCapacity(allocator, ARGUMENTS_CAPACITY);
            errdefer {
                for (zlap.main_args_raw.items) |arg| {
                    arg.deinit();
                }
                zlap.main_args_raw.deinit();
            }

            zlap.main_flags = StringHashMap(Flag).init(allocator);
            errdefer {
                var iter = zlap.main_flags.valueIterator();
                while (iter.next()) |flag| {
                    flag.deinit();
                }
                zlap.main_flags.deinit();
            }
            try zlap.main_flags.ensureTotalCapacity(FLAGS_CAPACITY);

            zlap.subcommands = StringHashMap(Subcmd).init(allocator);
            errdefer {
                var iter = zlap.subcommands.valueIterator();
                while (iter.next()) |subcmd| {
                    subcmd.deinit();
                }
                zlap.subcommands.deinit();
            }
            try zlap.subcommands.ensureTotalCapacity(SUBCMD_CAPACITY);

            // Initialing inner values for zlap
            try zlap.initFields();

            // Parsing the command line argument
            raw_argv = try process.argsAlloc(allocator);
            errdefer process.argsFree(allocator, raw_argv);
            try zlap.parseCommandlineArguments();

            zlap.help_msg = try zlap.makeHelpMessage();
            errdefer zlap.freeHelpMessage(zlap.help_msg);

            zlap.main_args = StringHashMap(*const Arg).init(allocator);
            errdefer zlap.main_args.deinit();

            for (zlap.main_args_raw.items) |*arg| {
                try zlap.main_args.put(arg.meta, arg);
            }

            return zlap;
        }

        pub fn deinit(self: *Self) void {
            self.main_args.deinit();

            for (self.main_args_raw.items) |arg| {
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

            self.main_args_raw.deinit();
            self.main_flags.deinit();
            self.subcommands.deinit();
            self.freeHelpMessage(self.help_msg);

            process.argsFree(self.allocator, raw_argv);
        }

        pub fn isSubcmdActive(self: *const Self, name: ?[]const u8) bool {
            if (name == null and self.active_subcmd == null) return true;
            if (self.active_subcmd == null) return false;

            return mem.eql(u8, self.active_subcmd.?.name, name.?);
        }

        fn initFields(self: *Self) ZlapError!void {
            for (zlap_zlap.main.args) |arg_zlap| {
                const value = try makeValue(self.allocator, arg_zlap);
                errdefer value.deinit();

                try self.main_args_raw.append(
                    .{
                        .meta = arg_zlap.meta,
                        .desc = arg_zlap.desc,
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
            for (zlap_zlap.main.flags) |flag_zlap| {
                const value = try makeValue(self.allocator, flag_zlap);
                errdefer value.deinit();

                if (flag_zlap.short.len == 0 and flag_zlap.long.len == 0) {
                    return error.InvalidFlagName;
                }

                const short_name = if (flag_zlap.short.len > 0) short: {
                    if (flag_zlap.short.len > 1) return error.ShortFlagNameIsTooLong;
                    break :short flag_zlap.short[0];
                } else null;

                try self.main_flags.put(
                    makeHashName(flag_zlap.long, &short_name_for_hash, short_name),
                    .{
                        .long = flag_zlap.long,
                        .short = short_name,
                        .desc = flag_zlap.desc,
                        .value = value,
                    },
                );

                if (short_name) |sn| {
                    const long_name_ptr = &self.short_arg_map[@as(usize, @intCast(sn))];
                    if (long_name_ptr.* != null and long_name_ptr.*.?.len > 0) {
                        return error.ShortFlagNameAlreadyExists;
                    }
                    long_name_ptr.* = flag_zlap.long;
                }
            }

            const zlap_zlap_fields_arr = @typeInfo(@TypeOf(zlap_zlap)).@"struct".fields;
            inline for (zlap_zlap_fields_arr) |zlap_zlap_field| {
                if (comptime mem.eql(u8, zlap_zlap_field.name, "main")) continue;

                const subcmd_zlap = @field(zlap_zlap, zlap_zlap_field.name);
                if (@TypeOf(subcmd_zlap) == []const u8) continue;

                if (self.subcommands.get(zlap_zlap_field.name) != null)
                    return error.SubcommandConflicted;

                var args_raw = try ArrayList(Arg).initCapacity(
                    self.allocator,
                    ARGUMENTS_CAPACITY,
                );
                errdefer {
                    for (args_raw.items) |arg| {
                        arg.deinit();
                    }
                    args_raw.deinit();
                }
                var flags = StringHashMap(Flag).init(self.allocator);
                errdefer {
                    var iter = flags.valueIterator();
                    while (iter.next()) |flag| {
                        flag.deinit();
                    }
                    flags.deinit();
                }
                try flags.ensureTotalCapacity(FLAGS_CAPACITY);
                var short_arg_map = [_]?[]const u8{null} ** 256;

                for (subcmd_zlap.args) |arg_zlap| {
                    const value = try makeValue(self.allocator, arg_zlap);
                    errdefer value.deinit();

                    try args_raw.append(
                        .{
                            .meta = arg_zlap.meta,
                            .desc = arg_zlap.desc,
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

                for (subcmd_zlap.flags) |flag_zlap| {
                    const value = try makeValue(self.allocator, flag_zlap);
                    errdefer value.deinit();

                    if (flag_zlap.short.len == 0 and flag_zlap.long.len == 0) {
                        return error.InvalidFlagName;
                    }

                    const short_name = if (flag_zlap.short.len > 0) short: {
                        if (flag_zlap.short.len > 1) return error.ShortFlagNameIsTooLong;
                        break :short flag_zlap.short[0];
                    } else null;

                    try flags.put(
                        makeHashName(flag_zlap.long, &short_name_for_hash, short_name),
                        .{
                            .long = flag_zlap.long,
                            .short = short_name,
                            .desc = flag_zlap.desc,
                            .value = value,
                        },
                    );

                    if (short_name) |sn| {
                        const long_name_ptr = &short_arg_map[@as(usize, @intCast(sn))];
                        if (long_name_ptr.* != null and long_name_ptr.*.?.len > 0) {
                            return error.ShortFlagNameAlreadyExists;
                        }
                        long_name_ptr.* = flag_zlap.long;
                    }
                }

                var args = StringHashMap(*const Arg).init(self.allocator);
                errdefer args.deinit();

                for (args_raw.items) |*arg| {
                    try args.put(arg.meta, arg);
                }

                try self.subcommands.put(subcmd_zlap.name, .{
                    .name = subcmd_zlap.name,
                    .desc = subcmd_zlap.desc,
                    .args = args,
                    .flags = flags,
                    .args_raw = args_raw,
                    .args_idx = 0,
                    .short_arg_map = short_arg_map,
                });
            }
        }

        fn parseCommandlineArguments(self: *Self) ZlapError!void {
            var idx: usize = 1;
            while (idx < raw_argv.len) : (idx += 1) {
                const parsed_command = ParsedCommandName.parseCommandName(raw_argv[idx]);
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

                while (idx.* < raw_argv.len) : (idx.* += 1) {
                    const parsed_flag = ParsedCommandName.parseCommandName(raw_argv[idx.*]);
                    switch (parsed_flag) {
                        .long => |name| try self.parseLongFlag(self.active_subcmd, idx, name),
                        .short => |name| try self.parseShortFlag(self.active_subcmd, idx, name),
                        .normal => |name| try self.parseNormalCommand(
                            idx.* == 0,
                            self.active_subcmd,
                            idx,
                            name,
                        ),
                    }
                }
            } else {
                idx.* -|= 1;
                if (maybe_subcmd) |subcmd| {
                    if (subcmd.args_idx >= subcmd.args_raw.items.len)
                        return error.ArgumentOverflowed;
                    try parseValue(
                        false,
                        idx,
                        &subcmd.args_raw.items[subcmd.args_idx],
                        null,
                        null,
                    );
                    subcmd.args_idx += 1;
                } else {
                    if (self.main_args_idx >= self.main_args_raw.items.len)
                        return error.ArgumentOverflowed;
                    try parseValue(
                        false,
                        idx,
                        &self.main_args_raw.items[self.main_args_idx],
                        null,
                        null,
                    );
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
                    try flag_ptrs.append(subcmd.flags.getPtr(makeHashName(
                        subcmd.short_arg_map[name[name_idx]],
                        &short_name_for_hash,
                        name[name_idx],
                    )) orelse return error.CannotFindFlag);
                }
            } else {
                while (name_idx < name.len) : (name_idx += 1) {
                    self.is_help = self.is_help or name[name_idx] == 'h';
                    try flag_ptrs.append(self.main_flags.getPtr(makeHashName(
                        self.short_arg_map[name[name_idx]],
                        &short_name_for_hash,
                        name[name_idx],
                    )) orelse return error.CannotFindFlag);
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
                    flag_name = ParsedCommandName.parseCommandName(raw_argv[idx.*]);
                    if (flag_name != .normal) return error.FlagValueNotFound;
                    val.* = try fmt.parseInt(i64, flag_name.normal, 0);
                },
                .string => |*val| {
                    flag_name = ParsedCommandName.parseCommandName(raw_argv[idx.*]);
                    if (flag_name != .normal) return error.FlagValueNotFound;
                    val.* = flag_name.normal;
                },
                .bools => |*val| {
                    while (blk: {
                        if (idx.* >= raw_argv.len) break :blk false;
                        flag_name = ParsedCommandName.parseCommandName(raw_argv[idx.*]);
                        break :blk flag_name == .normal;
                    }) : (idx.* += 1) {
                        try val.*.append(try isTruthy(flag_name.normal));
                    }
                    idx.* -|= 1;
                },
                .numbers => |*val| {
                    while (blk: {
                        if (idx.* >= raw_argv.len) break :blk false;
                        flag_name = ParsedCommandName.parseCommandName(raw_argv[idx.*]);
                        break :blk flag_name == .normal;
                    }) : (idx.* += 1) {
                        try val.*.append(try fmt.parseInt(i64, flag_name.normal, 0));
                    }
                    idx.* -|= 1;
                },
                .strings => |*val| {
                    while (blk: {
                        if (idx.* >= raw_argv.len) break :blk false;
                        flag_name = ParsedCommandName.parseCommandName(raw_argv[idx.*]);
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
                try writer.print("Usage: {s} {s} [flags]", .{
                    self.program_name,
                    subcmd.name,
                });

                args = &subcmd.args_raw;
                flags = &subcmd.flags;
            } else {
                is_main_help = true;
                if (self.subcommands.count() > 0) {
                    try writer.print("Usage: {s} [subcommands] [flags]", .{
                        self.program_name,
                    });
                } else {
                    try writer.print("Usage: {s} [flags]", .{self.program_name});
                }

                args = &self.main_args_raw;
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
                    if (long.len > 0)
                        try writer.print(" --{s}", .{long})
                    else
                        try writer.print("   ", .{});
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
}

fn makeValue(allocator: Allocator, zlap_data: anytype) ZlapError!Value {
    if (!@hasField(@TypeOf(zlap_data), "default")) {
        @compileError("The type " ++ @typeName(@TypeOf(zlap_data)) ++
            " does not have `default` field.");
    }

    inline for (valid_types) |@"type"| {
        if (mem.eql(u8, zlap_data.type, @"type")) {
            return @unionInit(
                Value,
                @"type",
                if (zlap_data.default.len > 0)
                    try parseDefaultValue(strToType(@"type"), zlap_data.default)
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
        if (mem.eql(u8, zlap_data.type, @"type")) {
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

    std.debug.print("|{any}|\n", .{zlap_data});

    return error.InvalidTypeStringFound;
}

fn parseDefaultValue(comptime T: type, string: []const u8) ZlapError!T {
    switch (T) {
        bool => {
            if (mem.eql(u8, string, "true"))
                return true
            else if (mem.eql(u8, string, "false"))
                return false
            else
                return error.UnknownDefaultValueString;
        },
        i64 => return fmt.parseInt(i64, string, 10),
        []const u8 => return string,
        else => @compileError("parseDefaultValue function does not support for a type " ++
            @typeName(T)),
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
    return if (long_name != null and long_name.?.len > 0) long_name.? else blk: {
        short_name_buf[0] = short_name.?;
        break :blk short_name_buf;
    };
}
