const std = @import("std");
const ast = @import("../ast.zig");
const interface = @import("../../interface.zig");
const Context = interface.Context;

const Tree = ast.Tree;

pub const max_depth = 3;

/// Nodes that open a nested control-flow block. A plain `{ ... }` block is not
/// control flow: it does not make the code harder to follow.
fn isControlTag(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .if_simple,
        .@"if",
        .for_simple,
        .@"for",
        .while_simple,
        .while_cont,
        .@"while",
        .@"switch",
        .switch_comma,
        => true,
        else => false,
    };
}

fn isElseIf(tree: *const Tree, index: usize) bool {
    const tag = tree.tag(index);
    if (tag != .if_simple and tag != .@"if") return false;
    const tok = tree.ast.nodeMainToken(tree.nodeAt(index));
    return tok > 0 and tree.tokenTag(tok - 1) == .keyword_else;
}

/// `zig/block-depth`: control-flow nesting deeper than 3 is a warning in every
/// profile, because it is a readability ceiling rather than a defect.
pub fn blockDepth(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var controls: std.ArrayList(ast.Range) = .empty;
    defer controls.deinit(ctx.allocator);

    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        if (!isControlTag(tree.tag(i))) continue;
        if (isElseIf(tree, i)) continue;
        const b = tree.nodeBytes(i);
        try controls.append(ctx.allocator, .{ .start = b.start, .end = b.end, .index = i });
    }

    for (controls.items) |item| {
        const depth = nestingDepth(controls.items, item);
        if (depth <= max_depth) continue;

        try ctx.report(
            "zig/block-depth",
            tree.nodeSpan(item.index),
            "Control flow block nesting exceeds the maximum limit of 3",
            "Flatten the block with early returns or guard clauses",
        );
    }
}

/// Number of control-flow nodes enclosing `target`, including `target` itself.
fn nestingDepth(controls: []const ast.Range, target: ast.Range) usize {
    var depth: usize = 1;
    for (controls) |c| {
        if (c.index == target.index) continue;
        if (c.start > target.start or c.end < target.end) continue;
        depth += 1;
    }
    return depth;
}

test "nesting limit is small enough to read" {
    try std.testing.expectEqual(@as(usize, 3), max_depth);
}

test "control tags are control flow nodes, not plain blocks" {
    try std.testing.expect(isControlTag(.if_simple));
    try std.testing.expect(isControlTag(.@"if"));
    try std.testing.expect(isControlTag(.for_simple));
    try std.testing.expect(isControlTag(.@"for"));
    try std.testing.expect(isControlTag(.while_simple));
    try std.testing.expect(isControlTag(.while_cont));
    try std.testing.expect(isControlTag(.@"while"));
    try std.testing.expect(!isControlTag(.fn_decl));
    try std.testing.expect(!isControlTag(.block));
    try std.testing.expect(!isControlTag(.block_two));
}

test "blockDepth triggers at depth 4 and ignores else-if chains" {
    const src: [:0]const u8 =
        \\fn ok(a: bool, b: bool, c: bool, d: bool) void {
        \\    if (a) {
        \\        if (b) {
        \\            if (c) {}
        \\        }
        \\    }
        \\    if (a) {} else if (b) {} else if (c) {} else if (d) {}
        \\}
        \\fn deep(a: bool, b: bool, c: bool, d: bool) void {
        \\    if (a) {
        \\        if (b) {
        \\            if (c) {
        \\                if (d) {}
        \\            }
        \\        }
        \\    }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = try Tree.parse(arena.allocator(), src, .zig);
    defer tree.deinit();

    var diags = std.ArrayList(@import("../../../core/diagnostic.zig").Diagnostic).empty;
    var ctx = Context{
        .allocator = arena.allocator(),
        .file_path = "test.zig",
        .source = src,
        .diagnostics = &diags,
    };
    try blockDepth(&ctx, &tree);

    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqual(@as(usize, 13), diags.items[0].span.start_line);
}
