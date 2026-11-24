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
        .if_simple => true,
        .for_simple => true,
        .while_simple => true,
        .@"switch" => true,
        .switch_comma => true,
        else => false,
    };
}

/// `zig/block-depth`: control-flow nesting deeper than 3 is a warning in every
/// profile, because it is a readability ceiling rather than a defect.
pub fn blockDepth(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        if (!isControlTag(tree.tag(i))) continue;

        const depth = nestingDepth(tree, i);
        if (depth <= max_depth) continue;

        try ctx.report(
            "zig/block-depth",
            tree.nodeSpan(i),
            "Control flow block nesting exceeds the maximum limit of 3",
            "Flatten the block with early returns or guard clauses",
        );
    }
}

/// Number of control-flow nodes that enclose `index`.
fn nestingDepth(tree: *const Tree, index: usize) usize {
    const target = tree.nodeBytes(index);
    var depth: usize = 0;

    var j: usize = 0;
    while (j < tree.nodeCount()) : (j += 1) {
        if (j == index) continue;
        if (!isControlTag(tree.tag(j))) continue;

        const b = tree.nodeBytes(j);
        if (b.start > target.start or b.end < target.end) continue;
        depth += 1;
    }
    return depth;
}

test "nesting limit is small enough to read" {
    try std.testing.expectEqual(@as(usize, 3), max_depth);
}

test "control tags are control flow nodes, not plain blocks" {
    try std.testing.expect(isControlTag(.if_simple));
    try std.testing.expect(isControlTag(.for_simple));
    try std.testing.expect(isControlTag(.while_simple));
    try std.testing.expect(!isControlTag(.fn_decl));
    try std.testing.expect(!isControlTag(.block));
    try std.testing.expect(!isControlTag(.block_two));
}
