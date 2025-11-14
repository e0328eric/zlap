# zlap
Command line argument parser for zig

# Features
- short flag support: `-a` for instance.
    - short flags can be merged as long as every flags except the last one does not takes values.
- long flag support: `--long` for instance.
- values of flags should be splitted with spaces:
  If the command line `--file foo.zig bar.zig` is given, then the parser parses `--file` takes
  two values `foo.zig` and `bar.zig`.

# How to use this?
To include this package, run the below command
```console
$ zig fetch --save https://github.com/e0328eric/zlap/archive/refs/tags/v0.6.1.tar.gz
```

## Example
This library uses personal spec to define the command line parser.
Following code below is in the `example` folder:
```
#@zlap-example | An example for zlap library {
    *PRINT   : string  | print this argument as a string;
    *FOO     : number  | print this argument as a number;
    -conti,c := @false | print this string [conti];
}

#init | An init {
    *PRINT: string |;
    *INPUT: numbers | the description;
    -,c   := @false | print this string (c);
    -foo,f :strings | print this string (foo);
    -bar, := @true | print this string (bar);
    -baz,B := 123 | print this string (baz);
}

#run | An run {
    *PRINT: string | print this argument as a string;
}
```

Now, inline this file into the main code using `@embedFile`. Later, if zig will support some
concept like comptimeAllocator, we can parse that file at the compile-time.
So, I will leave the parameter of `command` of `Zlap.init` by comptime string.

Every memory is released by calling `Zlap.deinit`. Thus do not deallocate any memories related to
`Zlap` except itself.

```zig
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
```

# Note
Before version 0.5.0, it uses JSON file to write a command line spec.
However, after version 0.5.0, it uses custom one.

# Actual Usage of this Library
- [tavol](https://github.com/e0328eric/tavol): Simple AES-encryption/decryption for files.
- [xilo-zig](https://github.com/e0328eric/xilo-zig): a simple replacement of `rm` command.
