const std = @import("std");
const zlap = @import("zlap");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const command = @embedFile("./command.json");

    var foo = try zlap.Zlap.init(allocator, command);
    defer foo.deinit();

    std.debug.print("<arg>\n", .{});
    for (foo.main_args.items) |arg| {
        std.debug.print("{{ desc: {s}, value: {any} }}\n", .{ arg.desc orelse "", arg.value });
    }

    std.debug.print("\n<flag>\n", .{});
    for (foo.main_flags.items) |flag| {
        std.debug.print("{{ long: {?s}, short: {?}, desc: {?s}, value: {any} }}\n", .{
            flag.long,
            flag.short,
            flag.desc,
            flag.value,
        });
    }

    std.debug.print("\n<Subcommand>\n", .{});
    var iter = foo.subcommands.iterator();
    while (iter.next()) |entry| {
        std.debug.print("[{s}]\n", .{entry.key_ptr.*});

        std.debug.print("\t[arg]\n", .{});
        for (entry.value_ptr.*.args.items) |arg| {
            std.debug.print("{{ desc: {s}, value: {any} }}\n", .{ arg.desc orelse "", arg.value });
        }

        std.debug.print("\t[flag]\n", .{});
        for (entry.value_ptr.*.flags.items) |flag| {
            std.debug.print("{{ long: {?s}, short: {?}, desc: {?s}, value: {any} }}\n", .{
                flag.long,
                flag.short,
                flag.desc,
                flag.value,
            });
        }
    }
}
