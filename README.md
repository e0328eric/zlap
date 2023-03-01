# zlap
Command line argument parser for zig using JSON file.

# Features
- short flag support: `-a` for instance.
    - short flags can be merged as long as every flags except the last one does not takes values.
- long flag support: `--long` for instance.
- values of flags should be splitted with spaces:
  If the command line `--file foo.zig bar.zig` is given, then the parser parses `--file` takes
  two values `foo.zig` and `bar.zig`.

# Example
This library uses JSON file to define the command line parser spec.
Following code below is in the `example` folder:
```json
{
  "name": "zlap-example",
  "desc": "An example for zlap library",

  "args": [
    {
      "desc": "print this argument as a string",
      "meta": "PRINT",
      "type": "string",
      "default": null
    },
    {
      "desc": "print this argument as a number",
      "meta": "FOO",
      "type": "number",
      "default": null
    }
  ],
  "flags": [
    {
      "long": "conti",
      "short": "c",
      "desc": "Print this string (conti)",
      "type": "bool",
      "default": "false"
    }
  ],

  "subcmds": [
    {
      "name": "init",
      "desc": "An init",
      "args": [
        {
          "desc": "print this argument as a string",
          "meta": "PRINT",
          "type": "string",
          "default": null
        }
      ],
      "flags": [
        {
          "long": "conti",
          "short": "c",
          "desc": "Print this string (i)",
          "type": "bool",
          "default": "false"
        },
        {
          "long": "foo",
          "short": "f",
          "desc": "Print this string (foo)",
          "type": "strings",
          "default": null
        }
      ]
    },
    {
      "name": "run",
      "desc": "An run",
      "args": [
        {
          "desc": "print this argument as a string",
          "meta": "PRINT",
          "type": "string",
          "default": null
        }
      ],
      "flags": []
    }
  ]
}
```

Now, inline this file into the main code using `@embedFile`. Later, if zig will support some
concept like comptimeAllocator, we can parse JSON file at the compile-time.
So, I will leave the parameter of `command` of `Zlap.init` by comptime string.

Every memory is released by calling `Zlap.deinit`. Thus do not deallocate any memories related to
`Zlap` except itself.

```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const command = @embedFile("./command.json");

    var zlap = try @import("zlap").Zlap.init(allocator, command);
    defer zlap.deinit();

    if (zlap.is_help) {
        std.debug.print("{s}\n", .{zlap.help_msg});
        return;
    }

    if (!zlap.isSubcmdActive("init")) {
        std.debug.print("{s}\n", .{zlap.help_msg});
        return;
    }

    const subcmd = zlap.subcommands.get("init").?;
    const foo_flag = subcmd.flags.get("foo") orelse return;

    for (foo_flag.value.strings.items) |string| {
        std.debug.print("<{s}>\n", .{string});
    }
}
```

# Actual Usage of this Library
See [xilo-zig](https://github.com/e0328eric/xilo-zig): a simple replacement of `rm` command.
.
