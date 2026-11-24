const std = @import("std");
const interface = @import("../../interface.zig");
const diagnostic = @import("../../../core/diagnostic.zig");
const Context = interface.Context;

const build_zon = "build.zig.zon";

/// True when the file is a package manifest, which is the only file the
/// `zig/zon-*` rules apply to.
pub fn isManifest(path: []const u8) bool {
    return std.mem.endsWith(u8, path, build_zon);
}

/// First match of `needle` in `source`, as a byte range.
fn findRange(source: []const u8, needle: []const u8) ?struct { start: usize, end: usize } {
    const idx = std.mem.indexOf(u8, source, needle) orelse return null;
    return .{ .start = idx, .end = idx + needle.len };
}

fn lineOf(source: []const u8, offset: usize) usize {
    var line: usize = 1;
    for (source[0..offset]) |ch| {
        if (ch == '\n') line += 1;
    }
    return line;
}

fn columnOf(source: []const u8, offset: usize) usize {
    var col: usize = 1;
    var i = offset;
    while (i > 0 and source[i - 1] != '\n') : (i -= 1) {
        col += 1;
    }
    return col;
}

fn wholeFileSpan(source: []const u8) diagnostic.Span {
    return .{
        .start_byte = 0,
        .end_byte = source.len,
        .start_line = 1,
        .start_col = 1,
        .end_line = lineOf(source, source.len),
        .end_col = columnOf(source, source.len),
    };
}

fn rangeSpan(source: []const u8, range: anytype) diagnostic.Span {
    const line = lineOf(source, range.start);
    return .{
        .start_byte = range.start,
        .end_byte = range.end,
        .start_line = line,
        .start_col = columnOf(source, range.start),
        .end_line = line,
        .end_col = columnOf(source, range.start) + (range.end - range.start),
    };
}

/// `zig/zon-fingerprint`: a manifest without `.fingerprint` breaks 0.16.
pub fn zonFingerprint(ctx: *Context) interface.CheckError!void {
    if (!isManifest(ctx.file_path)) return;
    if (findRange(ctx.source, ".fingerprint") != null) return;

    try ctx.report(
        "zig/zon-fingerprint",
        wholeFileSpan(ctx.source),
        "build.zig.zon lacks a .fingerprint",
        "Add '.fingerprint = 0x...' so the package identity is stable",
    );
}

fn isTrimmable(c: u8) bool {
    return c == ' ' or c == '=' or c == '\t';
}

/// `zig/zon-name-literal`: `.name` is an enum literal in 0.16.
pub fn zonNameLiteral(ctx: *Context) interface.CheckError!void {
    if (!isManifest(ctx.file_path)) return;

    const name_idx = std.mem.indexOf(u8, ctx.source, ".name") orelse return;
    var i = name_idx + ".name".len;
    while (i < ctx.source.len and isTrimmable(ctx.source[i])) : (i += 1) {}
    if (i >= ctx.source.len) return;
    if (ctx.source[i] != '"') return;

    var end = i + 1;
    while (end < ctx.source.len and ctx.source[end] != '"') : (end += 1) {}
    if (end >= ctx.source.len) return;
    end += 1;

    try ctx.report(
        "zig/zon-name-literal",
        rangeSpan(ctx.source, .{ .start = i, .end = end }),
        "build.zig.zon .name is a string literal",
        "Write the name as an enum literal, for example '.name = .codestyle'",
    );
}

/// `zig/zon-min-version`: a manifest states the compiler it needs.
pub fn zonMinVersion(ctx: *Context) interface.CheckError!void {
    if (!isManifest(ctx.file_path)) return;
    if (findRange(ctx.source, ".minimum_zig_version") != null) return;

    try ctx.report(
        "zig/zon-min-version",
        wholeFileSpan(ctx.source),
        "build.zig.zon lacks .minimum_zig_version",
        "Add '.minimum_zig_version = \"0.16.0\"' so the required toolchain is explicit",
    );
}

/// `zig/zon-explicit-paths`: `.paths` never packages the repository root.
pub fn zonExplicitPaths(ctx: *Context) interface.CheckError!void {
    if (!isManifest(ctx.file_path)) return;

    const paths_idx = std.mem.indexOf(u8, ctx.source, ".paths") orelse {
        try ctx.report(
            "zig/zon-explicit-paths",
            wholeFileSpan(ctx.source),
            "build.zig.zon has no .paths",
            "List the files and directories the package ships",
        );
        return;
    };

    // `.{ "" }` and `.{ "." }` package everything.
    const bad = [_][]const u8{ ".{ \"\" }", ".{\".\"}", ".{ \"\" }", ".{ \".\" }" };
    for (bad) |pattern| {
        if (std.mem.indexOf(u8, ctx.source[paths_idx..], pattern)) |rel| {
            const start = paths_idx + rel;
            try ctx.report(
                "zig/zon-explicit-paths",
                rangeSpan(ctx.source, .{ .start = start, .end = start + pattern.len }),
                "build.zig.zon packages the whole repository",
                "List the shipped files explicitly instead of the repository root",
            );
            return;
        }
    }
}

test "manifest detection follows the file name" {
    try std.testing.expect(isManifest("build.zig.zon"));
    try std.testing.expect(!isManifest("src/main.zig"));
}

test "line and column helpers are one-based" {
    const src = "ab\ncd\n";
    try std.testing.expectEqual(@as(usize, 2), lineOf(src, 3));
    try std.testing.expectEqual(@as(usize, 1), columnOf(src, 3));
    try std.testing.expectEqual(@as(usize, 2), columnOf(src, 4));
}
