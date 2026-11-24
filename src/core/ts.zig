const std = @import("std");

pub const C = struct {
    pub const TSParser = opaque {};
    pub const TSTree = opaque {};
    pub const TSLanguage = opaque {};

    pub const TSPoint = extern struct {
        row: u32,
        column: u32,
    };

    pub const TSNode = extern struct {
        context: [4]u32,
        id: ?*const anyopaque,
        tree: ?*const TSTree,
    };

    pub const TSTreeCursor = extern struct {
        tree: ?*const anyopaque,
        id: ?*const anyopaque,
        context: [3]u32,
    };

    pub extern "c" fn ts_parser_new() ?*TSParser;
    pub extern "c" fn ts_parser_delete(self: ?*TSParser) void;
    pub extern "c" fn ts_parser_set_language(
        self: ?*TSParser,
        language: ?*const TSLanguage,
    ) bool;
    pub extern "c" fn ts_parser_parse_string(
        self: ?*TSParser,
        old_tree: ?*const TSTree,
        string: [*]const u8,
        length: u32,
    ) ?*TSTree;

    pub extern "c" fn ts_tree_delete(self: ?*TSTree) void;
    pub extern "c" fn ts_tree_root_node(self: ?*const TSTree) TSNode;

    pub extern "c" fn ts_tree_cursor_new(node: TSNode) TSTreeCursor;
    pub extern "c" fn ts_tree_cursor_delete(cursor: *TSTreeCursor) void;
    pub extern "c" fn ts_tree_cursor_current_node(cursor: *const TSTreeCursor) TSNode;
    pub extern "c" fn ts_tree_cursor_goto_first_child(cursor: *TSTreeCursor) bool;
    pub extern "c" fn ts_tree_cursor_goto_next_sibling(cursor: *TSTreeCursor) bool;
    pub extern "c" fn ts_tree_cursor_goto_parent(cursor: *TSTreeCursor) bool;

    pub extern "c" fn ts_node_type(self: TSNode) ?[*:0]const u8;
    pub extern "c" fn ts_node_is_null(self: TSNode) bool;
    pub extern "c" fn ts_node_start_byte(self: TSNode) u32;
    pub extern "c" fn ts_node_end_byte(self: TSNode) u32;
    pub extern "c" fn ts_node_start_point(self: TSNode) TSPoint;
    pub extern "c" fn ts_node_end_point(self: TSNode) TSPoint;
    pub extern "c" fn ts_node_child_by_field_name(
        self: TSNode,
        name: [*]const u8,
        name_length: u32,
    ) TSNode;
    pub extern "c" fn ts_node_child_count(self: TSNode) u32;
    pub extern "c" fn ts_node_child(self: TSNode, child_index: u32) TSNode;
    pub extern "c" fn ts_node_named_child_count(self: TSNode) u32;
    pub extern "c" fn ts_node_named_child(self: TSNode, child_index: u32) TSNode;
    pub extern "c" fn ts_node_parent(self: TSNode) TSNode;
    pub extern "c" fn ts_node_next_sibling(self: TSNode) TSNode;
    pub extern "c" fn ts_node_prev_sibling(self: TSNode) TSNode;
};

pub const c = C;

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
    if (c.ts_node_type(node)) |ptr| return std.mem.span(ptr);
    return "";
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
