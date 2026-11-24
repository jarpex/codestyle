const std = @import("std");
const interface = @import("../interface.zig");
const Context = interface.Context;
const diagnostic = @import("../../core/diagnostic.zig");
const text_rules = @import("../../core/text_rules.zig");

const POSIX_DEFINE = "#define _POSIX_C_SOURCE 200809L";

const posix_triggers = [_][]const u8{
    "_POSIX_C_SOURCE",
    "<unistd.h>",
    "<fcntl.h>",
    "<poll.h>",
    "<sys/socket.h>",
    "<sys/stat.h>",
    "<sys/wait.h>",
    "<pthread.h>",
};

fn hasPosixTrigger(source: []const u8) bool {
    for (posix_triggers) |trigger| {
        if (std.mem.indexOf(u8, source, trigger) != null) {
            return true;
        }
    }
    return false;
}

pub fn run(ctx: *Context) interface.CheckError!void {
    const source = ctx.source;
    if (source.len == 0) return;

    if (hasPosixTrigger(source)) {
        var first_line_end: usize = 0;
        while (first_line_end < source.len and
            source[first_line_end] != '\n') : (first_line_end += 1)
        {}
        var first_line = source[0..first_line_end];
        if (first_line.len > 0 and first_line[first_line.len - 1] == '\r') {
            first_line = first_line[0 .. first_line.len - 1];
        }

        if (!std.mem.eql(u8, first_line, POSIX_DEFINE)) {
            try ctx.report(
                "c/posix-source-first-line",
                .{
                    .start_byte = 0,
                    .end_byte = first_line_end,
                    .start_line = 1,
                    .start_col = 1,
                    .end_line = 1,
                    .end_col = @max(1, first_line.len + 1),
                },
                "POSIX feature test macro must be defined on the first line",
                "Add '#define _POSIX_C_SOURCE 200809L' at line 1 before any includes",
            );
        }
    }

    try text_rules.run(ctx, .{
        .indent = .tabs,
        .max_line_len = 80,
        .line_len_message = "Line exceeds 80 columns",
    });
}

test "c/posix-source-first-line success" {
    const valid_src =
        "#define _POSIX_C_SOURCE 200809L\n" ++
        "#include <unistd.h>\n" ++
        "int main(void) { return 0; }\n";
    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    var ctx = Context{
        .allocator = std.testing.allocator,
        .file_path = "test.c",
        .source = valid_src,
        .diagnostics = &diags,
    };
    try run(&ctx);
    defer diags.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "c/posix-source-first-line failure" {
    const invalid_src =
        "#include <unistd.h>\n" ++
        "#define _POSIX_C_SOURCE 200809L\n" ++
        "int main(void) { return 0; }\n";
    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    var ctx = Context{
        .allocator = std.testing.allocator,
        .file_path = "test.c",
        .source = invalid_src,
        .diagnostics = &diags,
    };
    try run(&ctx);
    defer diags.deinit(std.testing.allocator);
    try std.testing.expect(diags.items.len > 0);
    try std.testing.expectEqualStrings("c/posix-source-first-line", diags.items[0].rule_id);
    try std.testing.expectEqual(@as(usize, 1), diags.items[0].span.start_line);
}

test "style/indent requires tabs and skips comment continuations" {
    const src =
        "int main(void) {\n" ++
        "    int x = 1;\n" ++
        "\tint y = 2;\n" ++
        "\t/*\n" ++
        "\t* comment continuation\n" ++
        "\t*/\n" ++
        "\t* another continuation\n" ++
        "\t int z = 3;\n" ++
        "}\n";
    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    var ctx = Context{
        .allocator = std.testing.allocator,
        .file_path = "test.c",
        .source = src,
        .diagnostics = &diags,
    };
    try run(&ctx);
    defer diags.deinit(std.testing.allocator);

    // Line 2 (4 spaces) and Line 8 (tab + space) fail.
    // Lines 5 and 7 (comment continuation with "\t* ") pass.
    var indent_errors: usize = 0;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "style/indent")) {
            indent_errors += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), indent_errors);
}

test "style/line-length failure over 80 columns with tabs" {
    // 20 tabs = 80 cols. One more character 'x' makes it 81 cols.
    const long_line = "\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\tx\n";
    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    var ctx = Context{
        .allocator = std.testing.allocator,
        .file_path = "test.c",
        .source = long_line,
        .diagnostics = &diags,
    };
    try run(&ctx);
    defer diags.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("style/line-length", diags.items[0].rule_id);
    try std.testing.expectEqual(@as(usize, 81), diags.items[0].span.start_col);
}
