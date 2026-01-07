const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var zlap = try @import("zlap").Zlap(@embedFile("./command.zlap"), null).init(allocator, init.minimal.args);
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
    const foo_flag = subcmd.flags.get("foo") orelse @panic("not found");
    const c_flag = subcmd.flags.get("c!") orelse @panic("not found");
    const bar_flag = subcmd.flags.get("bar") orelse @panic("not found");
    const baz_flag = subcmd.flags.get("baz") orelse @panic("not found");

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
