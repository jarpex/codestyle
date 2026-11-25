const std = @import("std");
const ast = @import("../ast.zig");
const interface = @import("../../interface.zig");
const Context = interface.Context;

const Tree = ast.Tree;

/// Builtins that leave the FFI boundary module without an allowlist entry.
const unsafe_casts = [_][]const u8{
    "@ptrCast",
    "@alignCast",
    "@bitCast",
    "@ptrFromInt",
    "@constCast",
    "@volatileCast",
};

const debug_builtins = [_][]const u8{"@compileLog"};

/// `zig/no-catch-unreachable`: `catch unreachable`, `orelse unreachable`,
/// `catch undefined`, and `orelse undefined` are forbidden outside `comptime` and tests.
pub fn noCatchUnreachable(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const tag = tree.tokens[i].tag;
        const is_catch = tag == .keyword_catch or tag == .keyword_orelse;
        if (!is_catch) continue;

        var j = i + 1;
        // `catch |err| unreachable` skips the payload capture.
        if (j < tree.tokens.len and tree.tokens[j].tag == .pipe) {
            j += 1;
            while (j < tree.tokens.len and tree.tokens[j].tag != .pipe) : (j += 1) {}
            if (j < tree.tokens.len) j += 1;
        }
        if (j >= tree.tokens.len) continue;
        const rhs = tree.tokens[j].tag;
        const is_undef = rhs == .identifier and std.mem.eql(u8, tree.tokenText(j), "undefined");
        if (rhs != .keyword_unreachable and !is_undef) continue;
        if (ast.inTestBlockToken(tree, i) or ast.inComptimeBlockToken(tree, i)) continue;

        try ctx.report(
            "zig/no-catch-unreachable",
            tree.tokenSpan(i),
            if (is_undef)
                "Error path yields undefined instead of being handled"
            else
                "Error path marked unreachable instead of handled",
            "Handle the error, or propagate it to the caller with 'try'",
        );
    }
}

/// `zig/no-swallowed-errors`: an empty catch block drops the error.
pub fn noSwallowedErrors(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .keyword_catch) continue;

        // `catch { }` with nothing between the braces.
        var j = i + 1;
        if (j < tree.tokens.len and tree.tokens[j].tag == .pipe) {
            j += 1;
            while (j < tree.tokens.len and tree.tokens[j].tag != .pipe) : (j += 1) {}
            if (j < tree.tokens.len) j += 1;
        }
        if (j + 1 >= tree.tokens.len) continue;
        if (tree.tokens[j].tag != .l_brace or tree.tokens[j + 1].tag != .r_brace) continue;
        if (ast.inTestBlockToken(tree, i)) continue;
        if (isCancelCallBefore(tree, i)) continue;

        try ctx.report(
            "zig/no-swallowed-errors",
            tree.tokenSpan(i),
            "Error is discarded by an empty catch block",
            "Handle the error, log it, or propagate it with 'try'",
        );
    }
}

fn isCancelCallBefore(tree: *const Tree, catch_idx: usize) bool {
    if (catch_idx < 3 or tree.tokens[catch_idx - 1].tag != .r_paren) return false;
    var j = catch_idx - 1;
    var depth: usize = 0;
    while (j > 0) : (j -= 1) {
        if (tree.tokens[j].tag == .r_paren) depth += 1;
        if (tree.tokens[j].tag == .l_paren) {
            depth -= 1;
            if (depth == 0) {
                return j > 0 and tree.tokens[j - 1].tag == .identifier and
                    std.mem.eql(u8, tree.tokenText(j - 1), "cancel");
            }
        }
    }
    return false;
}

/// `zig/no-runtime-safety-off`: `@setRuntimeSafety(false)` is forbidden.
pub fn noRuntimeSafetyOff(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .builtin) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), "@setRuntimeSafety")) continue;
        if (i + 3 >= tree.tokens.len) continue;
        if (!std.mem.eql(u8, tree.tokenText(i + 2), "false")) continue;

        try ctx.report(
            "zig/no-runtime-safety-off",
            tree.tokenSpan(i),
            "Runtime safety checks disabled with @setRuntimeSafety(false)",
            "Keep runtime safety on so bounds and overflow checks stay live",
        );
    }
}

/// `zig/no-panic-unreachable`: `@panic` and bare `unreachable` are forbidden
/// in library code.
pub fn noPanicUnreachable(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const tag = tree.tokens[i].tag;
        const is_panic = tag == .builtin and std.mem.eql(u8, tree.tokenText(i), "@panic");
        const is_bare = tag == .keyword_unreachable;
        if (!is_panic and !is_bare) continue;

        // `catch unreachable` and `orelse unreachable` have their own rule.
        if (is_bare and i > 0) {
            const prev = tree.tokens[i - 1].tag;
            if (prev == .keyword_catch or prev == .keyword_orelse or prev == .pipe) continue;
        }
        if (ast.inTestBlockToken(tree, i) or ast.inComptimeBlockToken(tree, i)) continue;
        if (is_panic and isInMainFn(tree, tree.tokens[i].start)) continue;

        try ctx.report(
            if (is_panic) "zig/no-panic-in-lib" else "zig/no-bare-unreachable",
            tree.tokenSpan(i),
            if (is_panic)
                "Call to @panic() aborts the process"
            else
                "Bare 'unreachable' aborts the process",
            "Return an error instead of aborting, so the caller can react",
        );
    }
}

/// `zig/no-anyerror`: explicit `anyerror` is forbidden in every signature.
/// Inferred `!T` is allowed in `main` and in root glue code.
pub fn noAnyerror(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), "anyerror")) continue;

        try ctx.report(
            "zig/no-anyerror",
            tree.tokenSpan(i),
            "Explicit 'anyerror' in a signature makes every caller infectious",
            "Declare a named error set, or use an inferred '!T' in main",
        );
    }
}

/// `zig/unsafe-casts`: unchecked casts are confined to the FFI boundary.
pub fn unsafeCasts(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    // The FFI boundary module owns the C ABI; an unchecked cast is
    // legitimate there and nowhere else.
    if (ctx.allow.allowsFfi(ctx.file_path)) return;

    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .builtin) continue;
        const name = tree.tokenText(i);
        for (unsafe_casts) |cast| {
            if (!std.mem.eql(u8, name, cast)) continue;
            try ctx.report(
                "zig/unsafe-casts",
                tree.tokenSpan(i),
                "Unchecked cast outside the FFI boundary module",
                "Move the cast into the module that owns the C ABI, or check the range first",
            );
        }
    }
}

/// `zig/no-debug-in-lib`: debug output and compile-time logs are for
/// executables and tests only.
pub fn noDebugInLib(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    if (ast.declaresMain(tree)) return;

    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag == .builtin and isDebugBuiltin(tree.tokenText(i))) {
            try reportDebug(ctx, tree, i, "Compile-time log left in library code");
        }
        if (isStdDebugPrint(tree, i)) {
            try reportDebug(ctx, tree, i, "Debug print left in library code");
        }
    }
}

fn isDebugBuiltin(name: []const u8) bool {
    for (debug_builtins) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return true;
    }
    return false;
}

fn reportDebug(
    ctx: *Context,
    tree: *const Tree,
    token_index: usize,
    message: []const u8,
) interface.CheckError!void {
    if (ast.inTestBlockToken(tree, token_index)) return;
    try ctx.report(
        "zig/no-debug-in-lib",
        tree.tokenSpan(token_index),
        message,
        "Remove the debug output, or route it through the logger the caller supplies",
    );
}

/// Match `std.debug.print` at token level.
fn isStdDebugPrint(tree: *const Tree, i: usize) bool {
    if (tree.tokens[i].tag != .identifier) return false;
    if (!std.mem.eql(u8, tree.tokenText(i), "std")) return false;
    if (i + 4 >= tree.tokens.len) return false;
    if (tree.tokens[i + 1].tag != .period) return false;
    if (tree.tokens[i + 2].tag != .identifier) return false;
    if (!std.mem.eql(u8, tree.tokenText(i + 2), "debug")) return false;
    if (tree.tokens[i + 3].tag != .period) return false;
    if (tree.tokens[i + 4].tag != .identifier) return false;
    return std.mem.eql(u8, tree.tokenText(i + 4), "print");
}

/// `zig/no-cimport-outside-ffi`: `@cImport`, `@cInclude`, and `extern "c"`
/// are confined to the FFI boundary.
pub fn noCimportOutsideFfi(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    if (ctx.allow.allowsFfi(ctx.file_path)) return;

    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const tag = tree.tokens[i].tag;
        if (tag == .builtin) {
            const name = tree.tokenText(i);
            if (!std.mem.eql(u8, name, "@cImport") and !std.mem.eql(u8, name, "@cInclude")) {
                continue;
            }
            try ctx.report(
                "zig/no-cimport-outside-ffi",
                tree.tokenSpan(i),
                "C header imported outside the FFI boundary module",
                "Move C ABI bindings into the FFI boundary module and re-export the types",
            );
        } else if (tag == .keyword_extern and i + 1 < tree.tokens.len and
            tree.tokens[i + 1].tag == .string_literal and
            std.mem.eql(u8, tree.tokenText(i + 1), "\"c\""))
        {
            try ctx.report(
                "zig/no-cimport-outside-ffi",
                tree.tokenSpan(i),
                "C ABI extern declaration outside the FFI boundary module",
                "Move C ABI bindings into the FFI boundary module and re-export the types",
            );
        }
    }
}

/// `zig/no-global-var`: file-scope `var` is forbidden outside tests.
pub fn noGlobalVar(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        const tag = tree.tag(i);
        const is_decl = tag == .global_var_decl or tag == .simple_var_decl or
            tag == .aligned_var_decl or tag == .local_var_decl;
        if (!is_decl) continue;

        const decl = tree.ast.fullVarDecl(tree.nodeAt(i)) orelse continue;
        if (tree.ast.tokenTag(decl.ast.mut_token) != .keyword_var) continue;

        // A declaration inside a block is a local; only a declaration at
        // container scope is global mutable state. Tests are exempt.
        if (ast.insideBlock(tree, tree.nodeBytes(i).start)) continue;
        if (ast.inTestBlock(tree, i)) continue;

        try ctx.report(
            "zig/no-global-var",
            tree.nodeSpan(i),
            "Mutable state at file or namespace scope",
            "Pass the state in through a parameter or a context struct",
        );
    }
}

/// `zig/no-exit-in-lib`: `std.process.exit` is only allowed in `main` with no active `defer`.
pub fn noExitInLib(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (!isStdProcessExit(tree, i)) continue;
        if (ast.inTestBlockToken(tree, i)) continue;

        const off = tree.tokens[i].start;
        if (isInMainFn(tree, off)) {
            const fn_decl = ast.fnAtOffset(tree, off).?;
            if (!hasDeferBefore(tree, fn_decl, off)) continue;
        }

        try ctx.report(
            "zig/no-exit-in-lib",
            tree.tokenSpan(i),
            "Process exit called from library code or with active defer",
            "Return an error and let main decide the exit code",
        );
    }
}

fn isInMainFn(tree: *const Tree, offset: usize) bool {
    const fn_decl = ast.fnAtOffset(tree, offset) orelse return false;
    const name = ast.fnName(tree, fn_decl) orelse return false;
    return std.mem.eql(u8, name, "main");
}

fn hasDeferBefore(tree: *const Tree, fn_decl: usize, offset: usize) bool {
    const bounds = ast.fnBytes(tree, fn_decl);
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const t = tree.tokens[i];
        if (t.start < bounds.start or t.start >= offset) continue;
        if (t.tag == .keyword_defer or t.tag == .keyword_errdefer) return true;
    }
    return false;
}

fn isStdProcessExit(tree: *const Tree, i: usize) bool {
    if (tree.tokens[i].tag != .identifier) return false;
    if (!std.mem.eql(u8, tree.tokenText(i), "std")) return false;
    if (i + 4 >= tree.tokens.len) return false;
    if (tree.tokens[i + 1].tag != .period) return false;
    if (!std.mem.eql(u8, tree.tokenText(i + 2), "process")) return false;
    if (tree.tokens[i + 3].tag != .period) return false;
    return std.mem.eql(u8, tree.tokenText(i + 4), "exit");
}

/// `zig/wrapping-ops-doc`: `+%`, `-%` and `*%` need a comment that says why
/// the wrap is intended.
pub fn wrappingOpsDoc(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    const wrapping = [_]std.zig.Token.Tag{ .plus_percent, .minus_percent, .asterisk_percent };

    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        var matched = false;
        for (wrapping) |tag| {
            if (tree.tokens[i].tag == tag) matched = true;
        }
        if (!matched) continue;

        if (hasCommentOnLine(tree, tree.tokens[i].start)) continue;
        if (tree.lines.prevLine(tree.tokens[i].start)) |prev| {
            if (commentText(prev) != null) continue;
        }

        try ctx.report(
            "zig/wrapping-ops-doc",
            tree.tokenSpan(i),
            "Wrapping arithmetic without a comment explaining the wrap",
            "Add a comment that says why the wraparound is intended",
        );
    }
}

fn commentText(line: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, line, "//") orelse return null;
    return std.mem.trim(u8, line[idx + 2 ..], " \t");
}

fn hasCommentOnLine(tree: *const Tree, offset: usize) bool {
    const line = tree.lines.lineText(offset);
    const idx = std.mem.indexOf(u8, line, "//") orelse return false;
    return idx < line.len;
}

test "unsafe cast names are all builtin calls" {
    for (unsafe_casts) |name| {
        try std.testing.expect(std.mem.startsWith(u8, name, "@"));
    }
}

test "debug builtin list covers compileLog" {
    try std.testing.expectEqual(@as(usize, 1), debug_builtins.len);
}

/// `zig/no-post-overflow-check`: `a + b < a` is undefined behaviour in
/// ReleaseFast because the addition already wrapped.
pub fn noPostOverflowCheck(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        if (!isComparisonNode(tree.tag(i))) continue;
        const lhs, const rhs = tree.ast.nodeData(tree.nodeAt(i)).node_and_node;
        if (!sumsInto(tree, lhs, rhs) and !sumsInto(tree, rhs, lhs)) continue;

        try ctx.report(
            "zig/no-post-overflow-check",
            tree.nodeSpan(i),
            "Post-addition overflow check after the wrap",
            "Use 'std.math.add' or '@addWithOverflow' before comparing",
        );
    }
}

fn isComparisonNode(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .less_than,
        .less_or_equal,
        .greater_than,
        .greater_or_equal,
        => true,
        else => false,
    };
}

fn sumsInto(
    tree: *const Tree,
    sum_node: std.zig.Ast.Node.Index,
    other_node: std.zig.Ast.Node.Index,
) bool {
    const unwrapped_sum = unwrapGrouped(tree, sum_node);
    if (tree.ast.nodeTag(unwrapped_sum) != .add) return false;
    const s_lhs, const s_rhs = tree.ast.nodeData(unwrapped_sum).node_and_node;
    const target = std.mem.trim(u8, tree.ast.getNodeSource(unwrapGrouped(tree, other_node)), " \t");
    const l_txt = std.mem.trim(u8, tree.ast.getNodeSource(unwrapGrouped(tree, s_lhs)), " \t");
    const r_txt = std.mem.trim(u8, tree.ast.getNodeSource(unwrapGrouped(tree, s_rhs)), " \t");
    return std.mem.eql(u8, l_txt, target) or std.mem.eql(u8, r_txt, target);
}

fn unwrapGrouped(tree: *const Tree, node: std.zig.Ast.Node.Index) std.zig.Ast.Node.Index {
    var cur = node;
    while (tree.ast.nodeTag(cur) == .grouped_expression) {
        cur = tree.ast.nodeData(cur).node_and_token[0];
    }
    return cur;
}

test "noPostOverflowCheck flags a + b < a but allows a.start + a.len < a.end and a - b < a" {
    const src: [:0]const u8 =
        \\fn f(a: anytype, b: usize) bool {
        \\    if (a.start + a.len < a.end) return true;
        \\    if (b - 1 < b) return true;
        \\    return b + 1 < b;
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
    };
    try noPostOverflowCheck(&ctx, &tree);

    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqual(@as(usize, 4), diags.items[0].span.start_line);
}

test "safe rules honor comptime, cancel(io), catch undefined, and main defer" {
    const src: [:0]const u8 =
        \\pub fn main() void {
        \\    defer {}
        \\    std.process.exit(1);
        \\}
        \\fn helper(io: anytype, x: anytype) void {
        \\    comptime { unreachable; }
        \\    _ = io.cancel(io) catch {};
        \\    _ = x catch undefined;
        \\    std.process.exit(2);
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
    };
    try noCatchUnreachable(&ctx, &tree);
    try noSwallowedErrors(&ctx, &tree);
    try noPanicUnreachable(&ctx, &tree);
    try noExitInLib(&ctx, &tree);

    try std.testing.expectEqual(@as(usize, 3), diags.items.len);
}

/// `zig/assert-no-side-effects`: the argument of `std.debug.assert` must be a
/// pure predicate, because `-DNDEBUG`-style release builds drop it.
pub fn assertNoSideEffects(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), "assert")) continue;
        if (!isStdDebugCall(tree, i)) continue;

        const open = nextParen(tree, i) orelse continue;
        const close = closingParen(tree, open) orelse continue;
        if (hasCallOrAssignment(tree, open + 1, close)) {
            try ctx.report(
                "zig/assert-no-side-effects",
                tree.tokenSpan(i),
                "Assertion expression has a side effect",
                "Evaluate the effect into a variable, then assert on the value",
            );
        }
    }
}

fn isStdDebugCall(tree: *const Tree, name_index: usize) bool {
    if (name_index < 4) return false;
    if (tree.tokens[name_index - 1].tag != .period) return false;
    if (!std.mem.eql(u8, tree.tokenText(name_index - 2), "debug")) return false;
    if (tree.tokens[name_index - 3].tag != .period) return false;
    return std.mem.eql(u8, tree.tokenText(name_index - 4), "std");
}

fn nextParen(tree: *const Tree, from: usize) ?usize {
    var i = from;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag == .l_paren) return i;
    }
    return null;
}

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

/// True when the token window calls a function or assigns to something.
fn hasCallOrAssignment(tree: *const Tree, start: usize, end: usize) bool {
    var i = start;
    while (i + 1 < end) : (i += 1) {
        const tag = tree.tokens[i].tag;
        if (tag == .equal or tag == .plus_equal or tag == .minus_equal or
            tag == .asterisk_equal or tag == .slash_equal) return true;
        if (tag != .identifier) continue;
        if (tree.tokens[i + 1].tag == .l_paren) return true;
    }
    return false;
}

/// `zig/no-undefined-struct`: `= undefined` leaves a value uninitialised until
/// something writes it. A buffer passed by mutable pointer is filled by the
/// callee, so it is allowed.
pub fn noUndefinedStruct(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), "undefined")) continue;

        const start = statementStart(tree, i);
        if (start >= tree.tokens.len) continue;
        const decl_tag = tree.tokens[start].tag;
        if (decl_tag != .keyword_var and decl_tag != .keyword_const) continue;

        const name_index = firstIdentifier(tree, start + 1, i) orelse continue;
        if (isFilledByCode(tree, i, tree.tokenText(name_index))) continue;

        try ctx.report(
            "zig/no-undefined-struct",
            tree.tokenSpan(i),
            "Value initialised with 'undefined'",
            "Initialise the value, or pass it by pointer to the function that fills it",
        );
    }
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

fn firstIdentifier(tree: *const Tree, from: usize, to: usize) ?usize {
    var i = from;
    while (i < to) : (i += 1) {
        if (tree.tokens[i].tag == .identifier) return i;
    }
    return null;
}

/// True when the same function writes into the value: `&name` handed to a
/// callee, `name[i] =`, `name.field =` or a plain reassignment. An immediate
/// initialising write is what the canon permits.
fn isFilledByCode(tree: *const Tree, offset: usize, name: []const u8) bool {
    const fn_decl = ast.fnAtOffset(tree, tree.tokens[offset].start) orelse return false;
    const bounds = ast.fnBytes(tree, fn_decl);

    var i: usize = 0;
    while (i + 1 < tree.tokens.len) : (i += 1) {
        const t = tree.tokens[i];
        if (t.start < bounds.start or t.end > bounds.end) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), name)) continue;
        if (isStoreTarget(tree, i)) return true;
        if (i > 0 and tree.tokens[i - 1].tag == .ampersand) return true;
    }
    return false;
}

/// True when the token at `name` begins an assignment target such as
/// `name[i] =`, `name.field =` or `name =`.
fn isStoreTarget(tree: *const Tree, name_index: usize) bool {
    var i = name_index + 1;
    var depth: usize = 0;

    while (i < tree.tokens.len) : (i += 1) {
        switch (tree.tokens[i].tag) {
            .l_bracket, .l_paren => depth += 1,
            .r_bracket, .r_paren => {
                if (depth == 0) return false;
                depth -= 1;
            },
            .equal => return depth == 0,
            .semicolon, .colon => return false,
            .period => {
                if (i + 1 >= tree.tokens.len) return false;
                if (tree.tokens[i + 1].tag == .asterisk or
                    tree.tokens[i + 1].tag == .identifier) continue;
                return false;
            },
            else => {},
        }
    }
    return false;
}

test "isStoreTarget accepts an indexed store and rejects a read" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const src = "fn f() void { var b: [4]u8 = undefined; b[0] = 1; }\n";
    const src_z = try arena.allocator().dupeSentinel(u8, src, 0);
    const tree = try Tree.parse(arena.allocator(), src_z, .zig);
    var owned = tree;
    defer owned.deinit();

    var seen: usize = 0;
    var i: usize = 0;
    while (i < owned.tokens.len) : (i += 1) {
        if (owned.tokens[i].tag != .identifier) continue;
        if (!std.mem.eql(u8, owned.tokenText(i), "b")) continue;

        // The declaration `b:` is not a store; the assignment `b[0] = 1` is.
        const expected = seen == 1;
        try std.testing.expectEqual(expected, isStoreTarget(&owned, i));
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

/// `zig/checked-casts`: `@truncate` is lossy by definition, and an `@intCast`
/// of an arithmetic result can wrap. Without type information the analyzer can
/// only prove these two shapes; a plain identifier cast is left to review.
pub fn checkedCasts(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .builtin) continue;

        const name = tree.tokenText(i);
        const is_truncate = std.mem.eql(u8, name, "@truncate");
        const is_int_cast = std.mem.eql(u8, name, "@intCast");
        if (!is_truncate and !is_int_cast) continue;
        if (ast.inTestBlockToken(tree, i) or ast.inComptimeBlockToken(tree, i)) continue;

        const open = nextParen(tree, i) orelse continue;
        const close = closingParen(tree, open) orelse continue;

        if (is_int_cast and !argumentHasArithmetic(tree, open + 1, close)) continue;

        try ctx.report(
            "zig/checked-casts",
            tree.tokenSpan(i),
            "Narrowing cast without a bounds check",
            "Prove the range first, or use 'std.math.cast' which returns an optional",
        );
    }
}

/// True when the argument computes a value: a subtraction, a multiplication or
/// a wrapping builtin can leave the range of the destination type.
fn argumentHasArithmetic(tree: *const Tree, start: usize, end: usize) bool {
    var i = start;
    while (i < end) : (i += 1) {
        switch (tree.tokens[i].tag) {
            .minus, .asterisk, .minus_percent, .asterisk_percent => return true,
            .builtin => {
                const name = tree.tokenText(i);
                if (std.mem.eql(u8, name, "@subWithOverflow") or
                    std.mem.eql(u8, name, "@mulWithOverflow") or
                    std.mem.eql(u8, name, "@divTrunc") or
                    std.mem.eql(u8, name, "@rem")) return true;
            },
            else => {},
        }
    }
    return false;
}
