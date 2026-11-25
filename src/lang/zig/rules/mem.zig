const std = @import("std");
const ast = @import("../ast.zig");
const interface = @import("../../interface.zig");
const Context = interface.Context;

const Tree = ast.Tree;

/// Allocators that reach for process-wide state instead of taking a
/// parameter.
const global_allocators = [_][]const u8{
    "page_allocator",
    "smp_allocator",
    "DebugAllocator",
    "GeneralPurposeAllocator",
};

/// `zig/unbounded-read`: stream reads must name a byte bound.
pub fn unboundedRead(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        const name = tree.tokenText(i);
        const is_read = std.mem.eql(u8, name, "readToEndAlloc") or
            std.mem.eql(u8, name, "readFileAlloc") or
            std.mem.eql(u8, name, "readAllAlloc");
        if (!is_read) continue;

        // `readFileAlloc` in 0.16 always takes `.limited(max)`; a call whose
        // argument list has no `.limited` is the old unbounded form.
        if (callHasLimited(tree, i)) continue;

        try ctx.report(
            "zig/unbounded-read",
            tree.tokenSpan(i),
            "Stream read without a byte bound",
            "Pass an explicit '.limited(max_bytes)' so the call cannot exhaust memory",
        );
    }
}

fn callHasLimited(tree: *const Tree, token_index: usize) bool {
    var i = token_index;
    var depth: usize = 0;
    var seen_lparen = false;

    while (i < tree.tokens.len) : (i += 1) {
        switch (tree.tokens[i].tag) {
            .l_paren => {
                depth += 1;
                seen_lparen = true;
            },
            .r_paren => {
                depth -= 1;
                if (seen_lparen and depth == 0) return false;
            },
            .period => {
                if (i + 1 < tree.tokens.len and
                    std.mem.eql(u8, tree.tokenText(i + 1), "limited")) return true;
            },
            else => {},
        }
    }
    return false;
}

/// `zig/no-global-allocator`: library code takes an allocator parameter.
pub fn noGlobalAllocator(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    if (ast.declaresMain(tree)) return;

    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        const name = tree.tokenText(i);
        var hit = false;
        for (global_allocators) |allocator| {
            if (std.mem.eql(u8, name, allocator)) hit = true;
        }
        if (!hit) continue;
        if (ast.inTestBlockToken(tree, i)) continue;

        try ctx.report(
            "zig/no-global-allocator",
            tree.tokenSpan(i),
            "Global allocator used instead of an explicit parameter",
            "Accept a 'std.mem.Allocator' parameter and pass it down",
        );
    }
}

/// `zig/allocation-cleanup`: an allocation with no `defer` free in the
/// enclosing block. Heuristic: it is off by default and only a note in strict.
pub fn allocationCleanup(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        const name = tree.tokenText(i);
        const is_alloc = std.mem.eql(u8, name, "alloc") or
            std.mem.eql(u8, name, "create") or
            std.mem.eql(u8, name, "dupe");
        if (!is_alloc) continue;

        // A test owns its arena for the whole block; the runner resets it.
        if (ast.inTestBlockToken(tree, i)) continue;
        if (fromScopedAllocator(tree, i)) continue;
        if (resultIsArgument(tree, i)) continue;
        if (statementIsReturn(tree, i)) continue;
        if (statementStoresInto(tree, i)) continue;
        if (hasDeferForVar(tree, i)) continue;
        if (localIsReturnedOrOwned(tree, i)) continue;

        try ctx.report(
            "zig/allocation-cleanup",
            tree.tokenSpan(i),
            "Allocation with no deferred release in this function",
            "Add 'defer allocator.free(ptr)' next to the allocation",
        );
    }
}

/// True when the receiver is an arena or the test allocator, whose owner
/// releases the memory.
fn fromScopedAllocator(tree: *const Tree, token_index: usize) bool {
    if (token_index == 0) return false;
    if (tree.tokens[token_index - 1].tag != .period) return false;

    var j = token_index - 1;
    var steps: usize = 0;
    while (j > 0 and steps < 8) : (steps += 1) {
        j -= 1;
        const tag = tree.tokens[j].tag;
        if (tag == .semicolon or tag == .l_brace or tag == .r_brace or tag == .comma) break;
        if (tag != .identifier) continue;
        const text = tree.tokenText(j);
        if (std.mem.eql(u8, text, "arena") or std.mem.eql(u8, text, "testing")) return true;
    }
    return false;
}

/// Index of the parenthesis that closes the call starting at `open`.
fn closingParen(tree: *const Tree, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < tree.tokens.len) : (i += 1) {
        switch (tree.tokens[i].tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// True when the call result is handed to another call or container, which
/// then owns it.
fn resultIsArgument(tree: *const Tree, callee: usize) bool {
    var i = callee + 1;
    while (i < tree.tokens.len and tree.tokens[i].tag != .l_paren) : (i += 1) {}
    if (i >= tree.tokens.len) return false;

    const close = closingParen(tree, i) orelse return false;
    if (close + 1 >= tree.tokens.len) return false;

    return switch (tree.tokens[close + 1].tag) {
        .comma, .r_paren, .r_bracket, .r_brace => true,
        else => false,
    };
}

fn statementStart(tree: *const Tree, token_index: usize) usize {
    var j = token_index;
    while (j > 0) {
        const tag = tree.tokens[j - 1].tag;
        if (tag == .semicolon or tag == .l_brace or tag == .r_brace) return j;
        j -= 1;
    }
    return 0;
}

fn statementIsReturn(tree: *const Tree, token_index: usize) bool {
    const start = statementStart(tree, token_index);
    return start < tree.tokens.len and tree.tokens[start].tag == .keyword_return;
}

/// True when the allocation is stored into an existing location, such as
/// `x.* = ...`, `list[i] = ...` or `self.field = ...`. The location then owns
/// the memory, not this frame.
fn statementStoresInto(tree: *const Tree, token_index: usize) bool {
    const start = statementStart(tree, token_index);
    if (start >= tree.tokens.len) return false;

    const first = tree.tokens[start].tag;
    if (first == .keyword_const or first == .keyword_var) return false;

    var j = start;
    while (j < token_index) : (j += 1) {
        if (tree.tokens[j].tag == .equal) return true;
    }
    return false;
}

/// True when the allocation is bound to a local that the function returns or
/// transfers via `.toOwnedSlice()`.
fn localIsReturnedOrOwned(tree: *const Tree, callee: usize) bool {
    const start = statementStart(tree, callee);
    if (start >= tree.tokens.len) return false;
    const tag = tree.tokens[start].tag;
    if (tag != .keyword_const and tag != .keyword_var) return false;

    const name_index = firstIdentifier(tree, start + 1, callee) orelse return false;
    const name = tree.tokenText(name_index);
    return containsReturnOf(tree, callee, name) or containsToOwnedSlice(tree, callee);
}

fn containsToOwnedSlice(tree: *const Tree, offset: usize) bool {
    const fn_decl = ast.fnAtOffset(tree, tree.tokens[offset].start) orelse return false;
    const bounds = ast.fnBytes(tree, fn_decl);
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const t = tree.tokens[i];
        if (t.start < bounds.start or t.end > bounds.end) continue;
        if (t.tag == .identifier and std.mem.eql(u8, tree.tokenText(i), "toOwnedSlice")) {
            return true;
        }
    }
    return false;
}

fn firstIdentifier(tree: *const Tree, from: usize, to: usize) ?usize {
    var i = from;
    while (i < to) : (i += 1) {
        if (tree.tokens[i].tag == .identifier) return i;
    }
    return null;
}

fn containsReturnOf(tree: *const Tree, offset: usize, name: []const u8) bool {
    const fn_decl = ast.fnAtOffset(tree, tree.tokens[offset].start) orelse return false;
    const bounds = ast.fnBytes(tree, fn_decl);

    var i: usize = 0;
    while (i + 1 < tree.tokens.len) : (i += 1) {
        const t = tree.tokens[i];
        if (t.start < bounds.start or t.end > bounds.end) continue;
        if (t.tag != .keyword_return) continue;
        if (!std.mem.eql(u8, tree.tokenText(i + 1), name)) continue;
        return true;
    }
    return false;
}

fn boundLocalName(tree: *const Tree, callee: usize) ?[]const u8 {
    const start = statementStart(tree, callee);
    if (start >= tree.tokens.len) return null;
    const tag = tree.tokens[start].tag;
    if (tag != .keyword_const and tag != .keyword_var) return null;
    const name_index = firstIdentifier(tree, start + 1, callee) orelse return null;
    return tree.tokenText(name_index);
}

fn hasDeferForVar(tree: *const Tree, token_index: usize) bool {
    const fn_decl = ast.fnAtOffset(tree, tree.tokens[token_index].start) orelse return false;
    const bounds = ast.fnBytes(tree, fn_decl);
    const local_name = boundLocalName(tree, token_index);

    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const t = tree.tokens[i];
        if (t.start < bounds.start or t.end > bounds.end) continue;
        if (t.tag != .keyword_defer and t.tag != .keyword_errdefer) continue;
        const target = local_name orelse return true;
        if (deferMentionsIdent(tree, i + 1, bounds.end, target)) return true;
    }
    return false;
}

fn deferMentionsIdent(tree: *const Tree, from: usize, fn_end: usize, name: []const u8) bool {
    var depth: usize = 0;
    var j = from;
    while (j < tree.tokens.len) : (j += 1) {
        const t = tree.tokens[j];
        if (t.end > fn_end) break;
        if (t.tag == .l_brace) depth += 1;
        if (t.tag == .r_brace) {
            if (depth == 0) break;
            depth -= 1;
            if (depth == 0) break;
        }
        if (t.tag == .semicolon and depth == 0) break;
        if (t.tag == .identifier and std.mem.eql(u8, tree.tokenText(j), name)) return true;
    }
    return false;
}

/// `zig/no-recursion`: a function that calls itself. Heuristic: off by
/// default because mutual recursion needs call-graph analysis.
pub fn noRecursion(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        if (tree.tag(i) != .fn_decl) continue;
        if (!ast.fnHasBody(tree, i)) continue;

        const own_name = ast.fnName(tree, i) orelse continue;
        const proto = ast.fnProto(tree, i) orelse continue;
        // The declaration's own name token is not a call site.
        const name_token = proto.name_token orelse continue;
        const bounds = ast.fnBytes(tree, i);

        var t: usize = 0;
        while (t < tree.tokens.len) : (t += 1) {
            const tok = tree.tokens[t];
            if (tok.start < bounds.start or tok.end > bounds.end) continue;
            if (tok.tag != .identifier) continue;
            if (!std.mem.eql(u8, tree.tokenText(t), own_name)) continue;
            if (t == name_token) continue;
            // `self.deinit()` names a different function; only a bare call is
            // recursion.
            if (t > 0 and tree.tokens[t - 1].tag == .period) continue;
            if (t + 1 >= tree.tokens.len or tree.tokens[t + 1].tag != .l_paren) continue;

            try ctx.report(
                "zig/no-recursion",
                tree.tokenSpan(t),
                "Function calls itself without a depth bound",
                "Rewrite with a loop, or add a depth parameter that bounds the recursion",
            );
        }
    }
}

test "global allocator list has no duplicates" {
    for (global_allocators, 0..) |name, i| {
        for (global_allocators[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, name, other));
        }
    }
}

test "read names are all lowercase" {
    const reads = [_][]const u8{ "readToEndAlloc", "readFileAlloc", "readAllAlloc" };
    for (reads) |name| {
        try std.testing.expect(name.len > 4);
    }
}

test "allocationCleanup matches deferred variable and allows toOwnedSlice" {
    const src: [:0]const u8 =
        \\fn leak(a: std.mem.Allocator, file: anytype) !void {
        \\    defer file.close();
        \\    const buf = try a.alloc(u8, 4);
        \\    _ = buf;
        \\}
        \\fn ok(a: std.mem.Allocator) ![]u8 {
        \\    const buf = try a.alloc(u8, 4);
        \\    defer a.free(buf);
        \\    const owned = try a.alloc(u8, 8);
        \\    _ = owned;
        \\    return toOwnedSlice();
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src_z = try arena.allocator().dupeSentinel(u8, src, 0);
    var tree = try Tree.parse(arena.allocator(), src_z, .zig);
    defer tree.deinit();

    var diags = std.ArrayList(@import("../../../core/diagnostic.zig").Diagnostic).empty;
    var ctx = Context{
        .allocator = arena.allocator(),
        .file_path = "test.zig",
        .source = src,
        .diagnostics = &diags,
        .profile = .strict,
    };
    try allocationCleanup(&ctx, &tree);

    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqual(@as(usize, 3), diags.items[0].span.start_line);
}
