const std = @import("std");
const interface = @import("../lang/interface.zig");
const Context = interface.Context;

/// Shared line-oriented style rules. Both frontends run these, so a rule id
/// means one thing across languages: `options` carries the per-language limits.
pub const IndentStyle = enum {
    tabs,
    spaces4,
};

pub const Options = struct {
    indent: IndentStyle = .spaces4,
    max_line_len: usize = 100,
    /// Message text is fixed, not formatted, so a rule id keeps one wording.
    line_len_message: []const u8 = "Line exceeds 100 columns",
};

const TAB_WIDTH: usize = 4;

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// A block comment continuation or closing line aligns its `*` with spaces
/// after the leading tabs (e.g. ` * text`, ` *`, or ` */`). Indentation rules
/// skip those lines so a comment body keeps its shape.
fn isCommentContinuation(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and isBlank(line[i])) : (i += 1) {}
    if (i >= line.len or line[i] != '*') return false;
    if (i + 1 == line.len) return true;
    return line[i + 1] == ' ' or line[i + 1] == '\t' or line[i + 1] == '/';
}

fn checkIndent(
    ctx: *Context,
    line: []const u8,
    line_no: usize,
    offset: usize,
    style: IndentStyle,
) interface.CheckError!void {
    if (line.len == 0) return;

    var i: usize = 0;
    var has_tab = false;
    var has_space = false;
    while (i < line.len and isBlank(line[i])) : (i += 1) {
        if (line[i] == '\t') has_tab = true else has_space = true;
    }
    if (i == line.len) return;
    if (isCommentContinuation(line)) return;

    const bad = switch (style) {
        .tabs => has_space,
        .spaces4 => has_tab,
    };
    if (!bad) return;

    try ctx.report(
        "style/indent",
        .{
            .start_byte = offset,
            .end_byte = offset + i,
            .start_line = line_no,
            .start_col = 1,
            .end_line = line_no,
            .end_col = i + 1,
        },
        switch (style) {
            .tabs => "Spaces used for indentation instead of tabs",
            .spaces4 => "Tabs used for indentation instead of 4 spaces",
        },
        switch (style) {
            .tabs => "Indent using exactly 1 tab (\\t) per logical level",
            .spaces4 => "Indent using exactly 4 spaces per logical indentation level",
        },
    );
}

fn checkLineLength(
    ctx: *Context,
    line: []const u8,
    line_no: usize,
    offset: usize,
    options: Options,
) interface.CheckError!void {
    var width: usize = 0;
    var limit_col: ?usize = null;
    for (line) |ch| {
        width += if (ch == '\t') TAB_WIDTH - (width % TAB_WIDTH) else 1;
        if (width > options.max_line_len and limit_col == null) limit_col = width;
    }

    const start_col = limit_col orelse return;
    try ctx.report(
        "style/line-length",
        .{
            .start_byte = offset,
            .end_byte = offset + line.len,
            .start_line = line_no,
            .start_col = start_col,
            .end_line = line_no,
            .end_col = width + 1,
        },
        options.line_len_message,
        "Break the line before binary operators or after commas",
    );
}

fn checkTrailingWhitespace(
    ctx: *Context,
    line: []const u8,
    line_no: usize,
    offset: usize,
) interface.CheckError!void {
    if (line.len == 0) return;
    if (!isBlank(line[line.len - 1])) return;

    var start = line.len - 1;
    while (start > 0 and isBlank(line[start - 1])) : (start -= 1) {}

    try ctx.report(
        "style/trailing-whitespace",
        .{
            .start_byte = offset + start,
            .end_byte = offset + line.len,
            .start_line = line_no,
            .start_col = start + 1,
            .end_line = line_no,
            .end_col = line.len + 1,
        },
        "Line contains trailing whitespace before newline",
        "Remove trailing whitespace characters from line end",
    );
}

pub fn run(ctx: *Context, options: Options) interface.CheckError!void {
    var lines = std.mem.splitScalar(u8, ctx.source, '\n');
    var line_no: usize = 1;
    var offset: usize = 0;

    while (lines.next()) |raw_line| : (line_no += 1) {
        const line_len = raw_line.len;
        defer offset += line_len + 1;

        if (line_len > 0 and raw_line[line_len - 1] == '\r') {
            try ctx.report(
                "style/line-endings",
                .{
                    .start_byte = offset + line_len - 1,
                    .end_byte = offset + line_len,
                    .start_line = line_no,
                    .start_col = line_len,
                    .end_line = line_no,
                    .end_col = line_len + 1,
                },
                "CRLF line endings detected",
                "Convert CRLF line terminators to standard LF (\\n)",
            );
        }

        const line = if (line_len > 0 and raw_line[line_len - 1] == '\r')
            raw_line[0 .. line_len - 1]
        else
            raw_line;

        try checkTrailingWhitespace(ctx, line, line_no, offset);
        try checkLineLength(ctx, line, line_no, offset, options);
        try checkIndent(ctx, line, line_no, offset, options.indent);
    }
}
