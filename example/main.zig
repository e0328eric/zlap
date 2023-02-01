const std = @import("std");
const zlap = @import("zlap");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const command = @embedFile("./command.json");

    var foo = try zlap.Zlap.init(allocator, command);
    defer foo.deinit();

    std.debug.print("{s}\n", .{foo.help_msg});
}
