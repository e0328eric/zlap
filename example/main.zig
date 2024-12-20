const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var zlap = try @import("zlap").Zlap(@embedFile("./command.zlap")).init(allocator);
    defer zlap.deinit();

    if (zlap.is_help) {
        std.debug.print("{s}\n", .{zlap.help_msg});
        return;
    }

    if (!zlap.isSubcmdActive("init")) {
        std.debug.print("Other subcommand was found. Quitting...\n", .{});
        return;
    }

    const subcmd = zlap.subcommands.get("init").?;
    const foo_flag = subcmd.flags.get("foo") orelse return;
    const c_flag = subcmd.flags.get("c!") orelse return;
    const bar_flag = subcmd.flags.get("bar") orelse return;
    const baz_flag = subcmd.flags.get("baz") orelse return;

    std.debug.print("|{s}|\n", .{subcmd.args.get("PRINT").?.value.string});

    for (foo_flag.value.strings.items) |string| {
        std.debug.print("<{s}>\n", .{string});
    }

    if (c_flag.value.bool) {
        std.debug.print("flag -c sets to true\n", .{});
    }

    if (!bar_flag.value.bool) {
        std.debug.print("flag --bar sets to false\n", .{});
    }

    std.debug.print("flag --baz sets to {}\n", .{baz_flag.value.number});
}
