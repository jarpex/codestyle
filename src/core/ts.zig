const std = @import("std");
pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub extern fn tree_sitter_c() ?*const c.TSLanguage;
pub const getLanguageC = tree_sitter_c;

const Span = @import("diagnostic.zig").Span;

pub fn getNodeSpan(node: c.TSNode) Span {
    const start = c.ts_node_start_point(node);
    const end = c.ts_node_end_point(node);
    const sb: usize = @intCast(c.ts_node_start_byte(node));
    const eb: usize = @intCast(c.ts_node_end_byte(node));
    return .{
        .start_byte = sb,
        .end_byte = eb,
        .start_line = start.row + 1,
        .start_col = start.column + 1,
        .end_line = end.row + 1,
        .end_col = end.column + 1,
    };
}

pub fn getNodeText(node: c.TSNode, source: []const u8) []const u8 {
    if (c.ts_node_is_null(node)) return "";
    const start: usize = @intCast(c.ts_node_start_byte(node));
    const end: usize = @intCast(c.ts_node_end_byte(node));
    if (end <= start or start >= source.len) return "";
    const bounded_end = @min(end, source.len);
    return source[start..bounded_end];
}

pub fn getNodeType(node: c.TSNode) []const u8 {
    if (c.ts_node_is_null(node)) return "";
    const ptr = c.ts_node_type(node);
    return if (ptr == null) "" else std.mem.span(ptr);
}

pub fn childByField(node: c.TSNode, name: [:0]const u8) c.TSNode {
    return c.ts_node_child_by_field_name(node, name.ptr, @intCast(name.len));
}

pub fn isNull(node: c.TSNode) bool {
    return c.ts_node_is_null(node);
}

pub fn childCount(node: c.TSNode) u32 {
    return c.ts_node_child_count(node);
}

pub fn child(node: c.TSNode, index: u32) c.TSNode {
    return c.ts_node_child(node, index);
}

pub fn namedChildCount(node: c.TSNode) u32 {
    return c.ts_node_named_child_count(node);
}

pub fn namedChild(node: c.TSNode, index: u32) c.TSNode {
    return c.ts_node_named_child(node, index);
}

pub fn parent(node: c.TSNode) ?c.TSNode {
    const res = c.ts_node_parent(node);
    if (c.ts_node_is_null(res)) return null;
    return res;
}

pub fn nextSibling(node: c.TSNode) ?c.TSNode {
    const res = c.ts_node_next_sibling(node);
    if (c.ts_node_is_null(res)) return null;
    return res;
}

pub fn prevSibling(node: c.TSNode) ?c.TSNode {
    const res = c.ts_node_prev_sibling(node);
    if (c.ts_node_is_null(res)) return null;
    return res;
}
