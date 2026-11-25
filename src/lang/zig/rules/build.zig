const std = @import("std");
const ast = @import("../ast.zig");
const interface = @import("../../interface.zig");
const diagnostic = @import("../../../core/diagnostic.zig");
const Context = interface.Context;

const Tree = ast.Tree;
const build_zon = "build.zig.zon";

/// True when the file is a package manifest, which is the only file the
/// `zig/zon-*` rules apply to.
pub fn isManifest(path: []const u8) bool {
    return std.mem.endsWith(u8, path, build_zon);
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

fn parseZon(allocator: std.mem.Allocator, source: []const u8) ?Tree {
    const src_z = allocator.dupeSentinel(u8, source, 0) catch return null;
    var tree = Tree.parse(allocator, src_z, .zon) catch return null;
    if (tree.ast.errors.len > 0) {
        tree.deinit();
        return null;
    }
    return tree;
}

fn findZonField(tree: *const Tree, target_name: []const u8) ?std.zig.Ast.Node.Index {
    const decls = tree.ast.rootDecls();
    if (decls.len == 0) return null;
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const init = tree.ast.fullStructInit(&buf, decls[0]) orelse return null;
    for (init.ast.fields) |field_val| {
        const first = tree.ast.firstToken(field_val);
        if (first < 2) continue;
        const name_tok = first - 2;
        if (tree.tokenTag(name_tok) != .identifier) continue;
        if (std.mem.eql(u8, tree.tokenText(name_tok), target_name)) return field_val;
    }
    return null;
}

/// `zig/zon-fingerprint`: a manifest without `.fingerprint` breaks builds.
pub fn zonFingerprint(ctx: *Context) interface.CheckError!void {
    if (!isManifest(ctx.file_path)) return;
    var tree = parseZon(ctx.allocator, ctx.source) orelse return;
    defer tree.deinit();
    if (findZonField(&tree, "fingerprint") != null) return;

    try ctx.report(
        "zig/zon-fingerprint",
        wholeFileSpan(ctx.source),
        "build.zig.zon lacks a .fingerprint",
        "Add '.fingerprint = 0x...' so the package identity is stable",
    );
}

/// `zig/zon-name-literal`: `.name` must be an enum literal.
pub fn zonNameLiteral(ctx: *Context) interface.CheckError!void {
    if (!isManifest(ctx.file_path)) return;
    var tree = parseZon(ctx.allocator, ctx.source) orelse return;
    defer tree.deinit();

    const val = findZonField(&tree, "name") orelse return;
    if (tree.ast.nodeTag(val) != .string_literal) return;

    try ctx.report(
        "zig/zon-name-literal",
        tree.nodeSpan(@intFromEnum(val)),
        "build.zig.zon .name is a string literal",
        "Write the name as an enum literal, for example '.name = .codestyle'",
    );
}

/// `zig/zon-min-version`: a manifest states the compiler it needs.
pub fn zonMinVersion(ctx: *Context) interface.CheckError!void {
    if (!isManifest(ctx.file_path)) return;
    var tree = parseZon(ctx.allocator, ctx.source) orelse return;
    defer tree.deinit();
    if (findZonField(&tree, "minimum_zig_version") != null) return;

    try ctx.report(
        "zig/zon-min-version",
        wholeFileSpan(ctx.source),
        "build.zig.zon lacks .minimum_zig_version",
        "Add '.minimum_zig_version = \"0.17.0\"' so the required toolchain is explicit",
    );
}

/// `zig/zon-explicit-paths`: `.paths` never packages the repository root.
pub fn zonExplicitPaths(ctx: *Context) interface.CheckError!void {
    if (!isManifest(ctx.file_path)) return;
    var tree = parseZon(ctx.allocator, ctx.source) orelse return;
    defer tree.deinit();

    const paths_val = findZonField(&tree, "paths") orelse {
        try ctx.report(
            "zig/zon-explicit-paths",
            wholeFileSpan(ctx.source),
            "build.zig.zon has no .paths",
            "List the files and directories the package ships",
        );
        return;
    };

    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const arr = tree.ast.fullArrayInit(&buf, paths_val) orelse return;
    for (arr.ast.elements) |elem| {
        if (tree.ast.nodeTag(elem) != .string_literal) continue;
        const txt = std.mem.trim(u8, tree.ast.getNodeSource(elem), " \t\r\n");
        if (!std.mem.eql(u8, txt, "\"\"") and !std.mem.eql(u8, txt, "\".\"")) continue;

        try ctx.report(
            "zig/zon-explicit-paths",
            tree.nodeSpan(@intFromEnum(elem)),
            "build.zig.zon packages the whole repository",
            "List the shipped files explicitly instead of the repository root",
        );
        return;
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

test "zon AST rules ignore comments and catch multiline or spaceless root paths" {
    const src =
        \\// .fingerprint = 0x1, .minimum_zig_version = "0.17.0",
        \\.{
        \\    .name = "codestyle",
        \\    .paths = .{
        \\        "",
        \\    },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    var ctx = Context{
        .allocator = arena.allocator(),
        .file_path = "build.zig.zon",
        .source = src,
        .diagnostics = &diags,
    };
    try zonFingerprint(&ctx);
    try zonNameLiteral(&ctx);
    try zonMinVersion(&ctx);
    try zonExplicitPaths(&ctx);

    try std.testing.expectEqual(@as(usize, 4), diags.items.len);
}
