const std = @import("std");
const ts = @import("../../core/ts.zig");
const diagnostic = @import("../../core/diagnostic.zig");
const interface = @import("../interface.zig");
const Context = interface.Context;

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isCamelCase(name: []const u8) bool {
    var has_lower = false;
    var has_upper = false;
    for (name) |c| {
        if (isLower(c)) has_lower = true;
        if (isUpper(c)) has_upper = true;
    }
    return has_lower and has_upper;
}

fn isUpperMacro(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (isLower(c)) return false;
    }
    return true;
}

fn isConstantSize(allocator: std.mem.Allocator, node: ts.c.TSNode, source: []const u8) bool {
    var stack = std.ArrayList(ts.c.TSNode).empty;
    defer stack.deinit(allocator);
    stack.append(allocator, node) catch return false;

    while (stack.items.len > 0) {
        const n = stack.pop().?;
        const ntype = ts.getNodeType(n);
        if (std.mem.eql(u8, ntype, "number_literal") or
            std.mem.eql(u8, ntype, "sizeof_expression")) continue;
        if (std.mem.eql(u8, ntype, "identifier")) {
            if (!isUpperMacro(ts.getNodeText(n, source))) return false;
            continue;
        }
        if (std.mem.eql(u8, ntype, "binary_expression")) {
            const left = ts.childByField(n, "left");
            const right = ts.childByField(n, "right");
            if (ts.isNull(left) or ts.isNull(right)) return false;
            stack.append(allocator, left) catch return false;
            stack.append(allocator, right) catch return false;
            continue;
        }
        if (std.mem.eql(u8, ntype, "parenthesized_expression")) {
            if (ts.namedChildCount(n) == 0) return false;
            stack.append(allocator, ts.namedChild(n, 0)) catch return false;
            continue;
        }
        return false;
    }
    return true;
}

fn hasChildOfTypeAndText(
    node: ts.c.TSNode,
    source: []const u8,
    node_type: []const u8,
    expected: []const u8,
) bool {
    const count = ts.childCount(node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const ch = ts.child(node, i);
        if (ts.isNull(ch)) continue;
        if (!std.mem.eql(u8, ts.getNodeType(ch), node_type)) continue;
        if (std.mem.eql(u8, ts.getNodeText(ch, source), expected)) return true;
    }
    return false;
}

fn hasStorageClass(node: ts.c.TSNode, source: []const u8, class_name: []const u8) bool {
    return hasChildOfTypeAndText(node, source, "storage_class_specifier", class_name);
}

fn hasTypeQualifier(node: ts.c.TSNode, source: []const u8, qual_name: []const u8) bool {
    return hasChildOfTypeAndText(node, source, "type_qualifier", qual_name);
}

fn isPowerOfTwo(val: u64) bool {
    return val >= 2 and (val & (val - 1)) == 0;
}

fn isDeclaratorWrapper(t: []const u8) bool {
    return isType(t, "pointer_declarator") or isType(t, "array_declarator") or
        isType(t, "parenthesized_declarator") or isType(t, "init_declarator");
}

fn reportCamelCase(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    if (!isCamelCase(ts.getNodeText(node, ctx.source))) return;
    try ctx.report(
        "c/no-camel-case",
        ts.getNodeSpan(node),
        "Identifier uses camelCase or mixed case",
        "Use short lowercase names (e.g. buf, len) or snake_case",
    );
}

/// Queue the declarator and every parameter declarator of a function.
fn pushFunctionDeclarator(
    ctx: *Context,
    node: ts.c.TSNode,
    stack: *std.ArrayList(ts.c.TSNode),
) interface.CheckError!void {
    const params = ts.childByField(node, "parameters");
    if (!ts.isNull(params)) {
        var pi: u32 = ts.namedChildCount(params);
        while (pi > 0) {
            pi -= 1;
            const param = ts.namedChild(params, pi);
            if (!isType(ts.getNodeType(param), "parameter_declaration")) continue;
            const ident = ts.childByField(param, "declarator");
            if (!ts.isNull(ident)) try stack.append(ctx.allocator, ident);
        }
    }
    const inner = ts.childByField(node, "declarator");
    if (!ts.isNull(inner)) try stack.append(ctx.allocator, inner);
}

fn visitDeclarator(
    ctx: *Context,
    node: ts.c.TSNode,
    stack: *std.ArrayList(ts.c.TSNode),
) interface.CheckError!void {
    const t = ts.getNodeType(node);
    if (isType(t, "identifier") or isType(t, "field_identifier") or
        isType(t, "type_identifier"))
    {
        return reportCamelCase(ctx, node);
    }
    if (isType(t, "function_declarator")) {
        return pushFunctionDeclarator(ctx, node, stack);
    }
    if (!isDeclaratorWrapper(t)) return;

    const inner = ts.childByField(node, "declarator");
    if (!ts.isNull(inner)) try stack.append(ctx.allocator, inner);
}

fn checkCamelCaseDeclarator(ctx: *Context, declarator: ts.c.TSNode) interface.CheckError!void {
    var stack = std.ArrayList(ts.c.TSNode).empty;
    defer stack.deinit(ctx.allocator);
    try stack.append(ctx.allocator, declarator);

    while (stack.items.len > 0) {
        const node = stack.pop().?;
        if (ts.isNull(node)) continue;
        try visitDeclarator(ctx, node, &stack);
    }
}

fn hasSideEffects(root: ts.c.TSNode, source: []const u8) bool {
    var cursor = ts.c.ts_tree_cursor_new(root);
    defer ts.c.ts_tree_cursor_delete(&cursor);
    while (true) {
        const node = ts.c.ts_tree_cursor_current_node(&cursor);
        const t = ts.getNodeType(node);
        if (std.mem.eql(u8, t, "assignment_expression") or
            std.mem.eql(u8, t, "update_expression")) return true;
        if (std.mem.eql(u8, t, "call_expression")) {
            const fn_node = ts.childByField(node, "function");
            if (ts.isNull(fn_node)) return true;
            const fn_name = ts.getNodeText(fn_node, source);
            const pure = std.mem.eql(u8, fn_name, "memcmp") or
                std.mem.eql(u8, fn_name, "strcmp") or
                std.mem.eql(u8, fn_name, "strncmp") or
                std.mem.eql(u8, fn_name, "strlen");
            if (!pure) return true;
        }
        if (ts.c.ts_tree_cursor_goto_first_child(&cursor)) continue;
        while (!ts.c.ts_tree_cursor_goto_next_sibling(&cursor)) {
            if (!ts.c.ts_tree_cursor_goto_parent(&cursor)) return false;
        }
    }
}

fn enclosingLoop(node: ts.c.TSNode) ?ts.c.TSNode {
    var maybe_parent = ts.parent(node);
    while (maybe_parent) |curr| {
        const t = ts.getNodeType(curr);
        if (std.mem.eql(u8, t, "for_statement") or
            std.mem.eql(u8, t, "while_statement") or
            std.mem.eql(u8, t, "do_statement")) return curr;
        if (std.mem.eql(u8, t, "function_definition")) break;
        maybe_parent = ts.parent(curr);
    }
    return null;
}

fn subtreeHasIdent(root: ts.c.TSNode, source: []const u8, wanted: []const u8) bool {
    var cursor = ts.c.ts_tree_cursor_new(root);
    defer ts.c.ts_tree_cursor_delete(&cursor);
    while (true) {
        const node = ts.c.ts_tree_cursor_current_node(&cursor);
        if (std.mem.eql(u8, ts.getNodeType(node), "identifier") and
            std.mem.eql(u8, ts.getNodeText(node, source), wanted))
        {
            return true;
        }
        if (ts.c.ts_tree_cursor_goto_first_child(&cursor)) continue;
        while (!ts.c.ts_tree_cursor_goto_next_sibling(&cursor)) {
            if (!ts.c.ts_tree_cursor_goto_parent(&cursor)) return false;
        }
    }
}

fn subtreeHasNodeType(root: ts.c.TSNode, type_name: []const u8) bool {
    var cursor = ts.c.ts_tree_cursor_new(root);
    defer ts.c.ts_tree_cursor_delete(&cursor);
    while (true) {
        const node = ts.c.ts_tree_cursor_current_node(&cursor);
        if (std.mem.eql(u8, ts.getNodeType(node), type_name)) return true;
        if (ts.c.ts_tree_cursor_goto_first_child(&cursor)) continue;
        while (!ts.c.ts_tree_cursor_goto_next_sibling(&cursor)) {
            if (!ts.c.ts_tree_cursor_goto_parent(&cursor)) return false;
        }
    }
}

fn isMacroDef(ntype: []const u8) bool {
    return std.mem.eql(u8, ntype, "preproc_def") or
        std.mem.eql(u8, ntype, "preproc_function_def");
}

fn isMatchingUndef(node: ts.c.TSNode, source: []const u8, name: []const u8) bool {
    if (!std.mem.eql(u8, ts.getNodeType(node), "preproc_call")) return false;
    const directive = ts.childByField(node, "directive");
    if (ts.isNull(directive)) return false;
    const dtext = ts.getNodeText(directive, source);
    if (!std.mem.startsWith(u8, dtext, "#")) return false;
    const word = std.mem.trimStart(u8, dtext[1..], " \t");
    if (!std.mem.eql(u8, word, "undef")) return false;
    const arg = ts.childByField(node, "argument");
    if (ts.isNull(arg)) return false;
    const atext = std.mem.trim(u8, ts.getNodeText(arg, source), " \t\r");
    return std.mem.eql(u8, atext, name);
}

fn checkLocalMacroUndef(ctx: *Context, root: ts.c.TSNode) interface.CheckError!void {
    const count = ts.namedChildCount(root);
    var seen_function = false;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const item = ts.namedChild(root, i);
        const t = ts.getNodeType(item);
        if (std.mem.eql(u8, t, "function_definition")) {
            seen_function = true;
            try checkFnBodyMacroUndef(ctx, item, root, i + 1);
            continue;
        }
        if (!seen_function or !isMacroDef(t)) continue;

        const name_node = ts.childByField(item, "name");
        if (ts.isNull(name_node)) continue;
        const name = ts.getNodeText(name_node, ctx.source);

        var undef_found = false;
        var j: u32 = i + 1;
        while (j < count) : (j += 1) {
            if (isMatchingUndef(ts.namedChild(root, j), ctx.source, name)) {
                undef_found = true;
                break;
            }
        }
        if (!undef_found) {
            try ctx.report(
                "c/local-macro-undef",
                ts.getNodeSpan(item),
                "Function-local macro is not undefined after use",
                "Add '#undef MACRO_NAME' immediately after the function where it is used",
            );
        }
    }
}

fn checkFnBodyMacroUndef(
    ctx: *Context,
    fn_node: ts.c.TSNode,
    root: ts.c.TSNode,
    after_fn_idx: u32,
) interface.CheckError!void {
    var cursor = ts.c.ts_tree_cursor_new(fn_node);
    defer ts.c.ts_tree_cursor_delete(&cursor);

    while (true) {
        const node = ts.c.ts_tree_cursor_current_node(&cursor);
        if (isMacroDef(ts.getNodeType(node))) {
            try reportBodyMacroIfUndef(ctx, node, fn_node, root, after_fn_idx);
        }
        if (ts.c.ts_tree_cursor_goto_first_child(&cursor)) continue;
        while (!ts.c.ts_tree_cursor_goto_next_sibling(&cursor)) {
            if (!ts.c.ts_tree_cursor_goto_parent(&cursor)) return;
        }
    }
}

fn reportBodyMacroIfUndef(
    ctx: *Context,
    node: ts.c.TSNode,
    fn_node: ts.c.TSNode,
    root: ts.c.TSNode,
    after_fn_idx: u32,
) interface.CheckError!void {
    const name_node = ts.childByField(node, "name");
    if (ts.isNull(name_node)) return;
    const name = ts.getNodeText(name_node, ctx.source);
    const def_end = ts.c.ts_node_end_byte(node);
    if (hasUndefAfterByte(fn_node, ctx.source, name, def_end)) return;

    const root_count = ts.namedChildCount(root);
    var j = after_fn_idx;
    while (j < root_count) : (j += 1) {
        if (isMatchingUndef(ts.namedChild(root, j), ctx.source, name)) return;
    }
    try ctx.report(
        "c/local-macro-undef",
        ts.getNodeSpan(node),
        "Function-local macro is not undefined after use",
        "Add '#undef MACRO_NAME' immediately after the function where it is used",
    );
}

fn hasUndefAfterByte(
    scope: ts.c.TSNode,
    source: []const u8,
    name: []const u8,
    min_byte: u32,
) bool {
    var cursor = ts.c.ts_tree_cursor_new(scope);
    defer ts.c.ts_tree_cursor_delete(&cursor);
    while (true) {
        const node = ts.c.ts_tree_cursor_current_node(&cursor);
        if (ts.c.ts_node_start_byte(node) >= min_byte and
            isMatchingUndef(node, source, name))
        {
            return true;
        }
        if (ts.c.ts_tree_cursor_goto_first_child(&cursor)) continue;
        while (!ts.c.ts_tree_cursor_goto_next_sibling(&cursor)) {
            if (!ts.c.ts_tree_cursor_goto_parent(&cursor)) return false;
        }
    }
}

const WalkState = struct {
    fn_node: ?ts.c.TSNode,
    depth: usize,
};

pub fn run(ctx: *Context, root: ts.c.TSNode) interface.CheckError!void {
    var states = std.ArrayList(WalkState).empty;
    defer states.deinit(ctx.allocator);
    try states.append(ctx.allocator, .{ .fn_node = null, .depth = 0 });

    var cursor = ts.c.ts_tree_cursor_new(root);
    defer ts.c.ts_tree_cursor_delete(&cursor);

    walk: while (true) {
        const node = ts.c.ts_tree_cursor_current_node(&cursor);
        const state = states.items[states.items.len - 1];
        const child_state = try visit(ctx, node, state.fn_node, state.depth);

        if (ts.c.ts_tree_cursor_goto_first_child(&cursor)) {
            try states.append(ctx.allocator, child_state);
            continue;
        }
        while (!ts.c.ts_tree_cursor_goto_next_sibling(&cursor)) {
            if (!ts.c.ts_tree_cursor_goto_parent(&cursor)) break :walk;
            _ = states.pop();
        }
    }

    try checkLocalMacroUndef(ctx, root);
}

fn isType(ntype: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, ntype, name);
}

/// Text of the innermost identifier of a declarator, peeling the
/// `function_declarator` and `pointer_declarator` wrappers first.
fn declaratorName(decl: ts.c.TSNode, source: []const u8) []const u8 {
    var inner = decl;
    while (isType(ts.getNodeType(inner), "function_declarator") or
        isType(ts.getNodeType(inner), "pointer_declarator"))
    {
        const next_inner = ts.childByField(inner, "declarator");
        if (ts.isNull(next_inner)) break;
        inner = next_inner;
    }
    return ts.getNodeText(inner, source);
}

fn checkInternalLinkage(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    if (!std.mem.endsWith(u8, ctx.file_path, ".c")) return;
    if (hasStorageClass(node, ctx.source, "static")) return;
    if (hasStorageClass(node, ctx.source, "extern")) return;

    const decl = ts.childByField(node, "declarator");
    if (!ts.isNull(decl) and std.mem.eql(u8, declaratorName(decl, ctx.source), "main")) return;

    try ctx.report(
        "c/internal-linkage",
        ts.getNodeSpan(node),
        "Global symbol lacks 'static' internal linkage specifier",
        "Mark functions and file-scope variables as 'static' unless part of " ++
            "the public header API",
    );
}

/// `style/brace-placement`: the body must open on the header's last line.
fn checkBracePlacement(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    const body = ts.childByField(node, "body");
    if (ts.isNull(body)) return;

    try checkBlockBraces(ctx, body);
}

fn reportBadBrace(ctx: *Context, block: ts.c.TSNode) interface.CheckError!void {
    try ctx.report(
        "style/brace-placement",
        ts.getNodeSpan(block),
        "Invalid brace placement",
        "Place opening '{' on the same line as the statement header and closing " ++
            "'}' on its own line",
    );
}

/// True when every byte between `line_start` and `stop` is a space or tab.
fn blankBefore(source: []const u8, line_start: usize, stop: usize) bool {
    var i = line_start;
    while (i < stop and i < source.len) : (i += 1) {
        if (source[i] != ' ' and source[i] != '\t') return false;
    }
    return true;
}

/// Opening `{` stays on the header line; closing `}` sits alone on its own.
fn checkBlockBraces(ctx: *Context, block: ts.c.TSNode) interface.CheckError!void {
    const start = ts.c.ts_node_start_byte(block);
    const end = ts.c.ts_node_end_byte(block);

    // Only whitespace before `{` means the brace sits on its own line.
    if (blankBefore(ctx.source, lineStart(ctx.source, start), start)) {
        try reportBadBrace(ctx, block);
        return;
    }
    if (end == 0 or end > ctx.source.len) return;

    const close = end - 1;
    if (lineStart(ctx.source, close) == lineStart(ctx.source, start)) {
        if (ts.namedChildCount(block) == 0) return;
        try reportBadBrace(ctx, block);
        return;
    }
    if (!blankBefore(ctx.source, lineStart(ctx.source, close), close)) {
        try reportBadBrace(ctx, block);
    }
}

fn lineStart(source: []const u8, offset: usize) usize {
    var i = if (offset < source.len) offset else source.len;
    while (i > 0 and source[i - 1] != '\n') : (i -= 1) {}
    return i;
}

/// The block of a statement or type definition, when it has braces.
fn blockNode(node: ts.c.TSNode, ntype: []const u8) ?ts.c.TSNode {
    const field = if (isType(ntype, "if_statement")) "consequence" else "body";
    const block = ts.childByField(node, field);
    if (ts.isNull(block)) return null;

    const bt = ts.getNodeType(block);
    if (!isType(bt, "compound_statement") and !isType(bt, "field_declaration_list")) return null;
    return block;
}

fn checkStatementBraces(
    ctx: *Context,
    node: ts.c.TSNode,
    ntype: []const u8,
) interface.CheckError!void {
    const block = blockNode(node, ntype) orelse return;
    try checkBlockBraces(ctx, block);
}

fn reportUninitialised(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    try ctx.report(
        "c/uninitialized-local",
        ts.getNodeSpan(node),
        "Local variable declared at function top must be explicitly initialized",
        "Initialize the variable to a safe default (0, -1, NULL, or {0}) for " ++
            "deterministic cleanup",
    );
}

/// `c/uninitialized-local`: a top-of-body declaration without a value.
fn checkDeclaratorInitialised(ctx: *Context, stmt: ts.c.TSNode) interface.CheckError!void {
    var di: u32 = 0;
    const count = ts.childCount(stmt);
    while (di < count) : (di += 1) {
        const dchild = ts.child(stmt, di);
        if (ts.isNull(dchild)) continue;

        const dt = ts.getNodeType(dchild);
        if (isType(dt, "init_declarator")) {
            if (ts.isNull(ts.childByField(dchild, "value"))) try reportUninitialised(ctx, dchild);
            continue;
        }
        if (isType(dt, "identifier") or isType(dt, "array_declarator") or
            isType(dt, "pointer_declarator")) try reportUninitialised(ctx, dchild);
    }
}

/// `c/declarations-at-top` over the function's outer block.
fn checkStatementsAtTop(ctx: *Context, body: ts.c.TSNode) interface.CheckError!void {
    var seen_statement = false;
    var ci: u32 = 0;
    const count = ts.namedChildCount(body);
    while (ci < count) : (ci += 1) {
        const stmt = ts.namedChild(body, ci);
        if (ts.isNull(stmt)) continue;

        const st = ts.getNodeType(stmt);
        if (isType(st, "comment") or isType(st, "type_definition")) continue;

        if (!isType(st, "declaration")) {
            seen_statement = true;
            continue;
        }
        if (seen_statement) {
            try ctx.report(
                "c/declarations-at-top",
                ts.getNodeSpan(stmt),
                "Local variable must be declared at the very top of the function body",
                "Move this declaration to the top of the function and initialize " ++
                    "it to a safe default",
            );
        }
        try checkDeclaratorInitialised(ctx, stmt);
    }
}

fn checkFunctionDefinition(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    const decl = ts.childByField(node, "declarator");
    if (!ts.isNull(decl)) try checkCamelCaseDeclarator(ctx, decl);

    try checkInternalLinkage(ctx, node);
    try checkBracePlacement(ctx, node);

    const body = ts.childByField(node, "body");
    if (!ts.isNull(body)) try checkStatementsAtTop(ctx, body);
}

/// `c/explicit-int-types`: bare `int` and sized specifiers outside `main`.
fn checkExplicitIntTypes(
    ctx: *Context,
    node: ts.c.TSNode,
    fn_node: ?ts.c.TSNode,
) interface.CheckError!void {
    if (fn_node) |definition| {
        if (isMainSignatureNode(definition, node, ctx.source)) return;
    }
    try ctx.report(
        "c/explicit-int-types",
        ts.getNodeSpan(node),
        "Bare C integer type with platform-dependent size is forbidden",
        "Use explicit types from <stdint.h> or <stddef.h> (e.g. int32_t, " ++
            "uint32_t, size_t, ssize_t, ptrdiff_t)",
    );
}

/// True when `node` is the return type or the first parameter type of `main`,
/// which the C standard fixes as `int`.
fn isMainSignatureNode(fn_node: ts.c.TSNode, node: ts.c.TSNode, source: []const u8) bool {
    const decl = ts.childByField(fn_node, "declarator");
    if (ts.isNull(decl)) return false;
    if (!std.mem.eql(u8, declaratorName(decl, source), "main")) return false;

    const type_node = ts.childByField(fn_node, "type");
    if (!ts.isNull(type_node) and
        ts.c.ts_node_start_byte(type_node) == ts.c.ts_node_start_byte(node)) return true;

    const params = ts.childByField(decl, "parameters");
    if (ts.isNull(params) or ts.namedChildCount(params) == 0) return false;

    const first_param = ts.childByField(ts.namedChild(params, 0), "type");
    return !ts.isNull(first_param) and
        ts.c.ts_node_start_byte(first_param) == ts.c.ts_node_start_byte(node);
}

/// `c/const-lookup-tables`: a file-scope initialised array must be `const`.
fn checkConstLookupTable(
    ctx: *Context,
    node: ts.c.TSNode,
    at_file_scope: bool,
) interface.CheckError!void {
    if (!at_file_scope and !hasStorageClass(node, ctx.source, "static")) return;
    if (hasTypeQualifier(node, ctx.source, "const")) return;
    if (!declaresInitialisedArray(node)) return;

    try ctx.report(
        "c/const-lookup-tables",
        ts.getNodeSpan(node),
        "Initialized lookup array or table is not marked 'const'",
        "Add the 'const' qualifier to read-only array declarations",
    );
}

fn declaresInitialisedArray(node: ts.c.TSNode) bool {
    var ai: u32 = 0;
    const count = ts.namedChildCount(node);
    while (ai < count) : (ai += 1) {
        const child = ts.namedChild(node, ai);
        if (ts.isNull(child)) continue;
        if (!isType(ts.getNodeType(child), "init_declarator")) continue;

        const decl = ts.childByField(child, "declarator");
        if (ts.isNull(decl)) continue;
        if (isType(ts.getNodeType(decl), "array_declarator")) return true;
    }
    return false;
}

fn checkDeclaration(
    ctx: *Context,
    node: ts.c.TSNode,
    fn_node: ?ts.c.TSNode,
) interface.CheckError!void {
    var di: u32 = 0;
    const count = ts.namedChildCount(node);
    while (di < count) : (di += 1) {
        const child = ts.namedChild(node, di);
        if (!ts.isNull(child)) try checkCamelCaseDeclarator(ctx, child);
    }

    if (fn_node == null) {
        if (!hasStorageClass(node, ctx.source, "static") and
            !hasStorageClass(node, ctx.source, "extern"))
        {
            try checkInternalLinkage(ctx, node);
        }
    } else {
        try checkDeclarationIsAtTop(ctx, node);
    }

    try checkConstLookupTable(ctx, node, fn_node == null);
}

/// `c/declarations-at-top` for a declaration inside a nested block. A loop
/// initializer declares its own counter and is exempt.
fn checkDeclarationIsAtTop(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    const parent = ts.parent(node) orelse return;
    if (!isType(ts.getNodeType(parent), "compound_statement")) return;

    // A compound statement whose parent is the function definition is the
    // function body, where declarations belong.
    const grand = ts.parent(parent) orelse return;
    if (isType(ts.getNodeType(grand), "function_definition")) return;

    try ctx.report(
        "c/declarations-at-top",
        ts.getNodeSpan(node),
        "Local variable must be declared at the very top of the function body",
        "Move this declaration to the top of the function and initialize it to " ++
            "a safe default",
    );
}

/// `c/no-vla`: an array bound that is not a compile-time constant.
fn checkVla(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    const size_node = ts.childByField(node, "size");
    if (ts.isNull(size_node)) return;
    if (isConstantSize(ctx.allocator, size_node, ctx.source)) return;

    try ctx.report(
        "c/no-vla",
        ts.getNodeSpan(node),
        "Variable Length Array (VLA) is forbidden",
        "Use a compile-time constant bound (macro or enum) for stack arrays",
    );
}

fn checkLoopCounterScope(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    const init = ts.childByField(node, "initializer");
    if (ts.isNull(init) or !isType(ts.getNodeType(init), "assignment_expression")) return;

    try ctx.report(
        "c/loop-counter-scope",
        ts.getNodeSpan(init),
        "Loop counter assigned instead of declared inside the for header",
        "Declare the iteration variable directly inside the loop header (e.g. " ++
            "'for (size_t i = 0; ...)')",
    );
}

fn checkInfiniteLoopFor(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    const cond = ts.childByField(node, "condition");
    if (ts.isNull(cond)) return;

    const txt = ts.getNodeText(cond, ctx.source);
    if (!std.mem.eql(u8, txt, "(1)") and !std.mem.eql(u8, txt, "(true)")) return;

    try ctx.report(
        "c/infinite-loop-for",
        ts.getNodeSpan(node),
        "Use 'for (;;)' for infinite loops instead of 'while (1)'",
        "Replace 'while (1)' with 'for (;;)'",
    );
}

fn reportBraceless(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    try ctx.report(
        "style/mandatory-braces",
        ts.getNodeSpan(node),
        "Control block body must be enclosed in braces '{ ... }'",
        "Add curly braces around the statement body",
    );
}

/// `style/mandatory-braces` for `if`, including the `else` chain.
fn checkIfBraces(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    const cons = ts.childByField(node, "consequence");
    if (!ts.isNull(cons) and !isType(ts.getNodeType(cons), "compound_statement")) {
        try reportBraceless(ctx, node);
    }

    const alt = ts.childByField(node, "alternative");
    if (ts.isNull(alt) or ts.namedChildCount(alt) == 0) return;

    const alt_body = ts.namedChild(alt, 0);
    const at = ts.getNodeType(alt_body);
    if (isType(at, "compound_statement") or isType(at, "if_statement")) return;
    try reportBraceless(ctx, alt);
}

fn isLoopNode(ntype: []const u8) bool {
    return isType(ntype, "for_statement") or isType(ntype, "while_statement") or
        isType(ntype, "do_statement") or isType(ntype, "switch_statement");
}

/// `style/mandatory-braces` for a loop or switch body.
fn checkLoopBraces(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    const body = ts.childByField(node, "body");
    if (ts.isNull(body)) return;
    if (isType(ts.getNodeType(body), "compound_statement")) return;
    try reportBraceless(ctx, node);
}

/// True when `node` opens a nesting level. An `else if` continues the level
/// of its `if`, so it does not count.
fn opensNesting(node: ts.c.TSNode, ntype: []const u8) bool {
    if (isLoopNode(ntype)) return true;
    if (!isType(ntype, "if_statement")) return false;

    const parent_node = ts.parent(node) orelse return true;
    return !isType(ts.getNodeType(parent_node), "else_clause");
}

fn checkNestingDepth(ctx: *Context, node: ts.c.TSNode, depth: usize) interface.CheckError!void {
    if (depth <= 3) return;
    try ctx.report(
        "complexity/max-nesting-depth",
        ts.getNodeSpan(node),
        "Control flow nesting depth exceeds maximum limit of 3",
        "Flatten nested blocks using early returns, guard clauses, or 'goto cleanup;'",
    );
}

fn checkBitwisePow2(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    const op = ts.childByField(node, "operator");
    if (ts.isNull(op)) return;

    const op_text = ts.getNodeText(op, ctx.source);
    if (!std.mem.eql(u8, op_text, "*") and !std.mem.eql(u8, op_text, "/")) return;

    const right = ts.childByField(node, "right");
    if (ts.isNull(right) or !isType(ts.getNodeType(right), "number_literal")) return;

    const val = std.fmt.parseInt(u64, ts.getNodeText(right, ctx.source), 0) catch 0;
    if (!isPowerOfTwo(val)) return;

    try ctx.report(
        "c/bitwise-pow2",
        ts.getNodeSpan(node),
        "Multiplication or division by a constant power of two",
        "Use bitwise shift ('<<' or '>>') for power-of-two arithmetic on " ++
            "unsigned values",
    );
}

fn checkOperatorLinebreak(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    const left = ts.childByField(node, "left");
    const op = ts.childByField(node, "operator");
    const right = ts.childByField(node, "right");
    if (ts.isNull(left) or ts.isNull(op) or ts.isNull(right)) return;

    // The operator stayed on the left operand's line while the right operand
    // moved down, leaving the operator dangling at the end.
    const op_row = ts.c.ts_node_start_point(op).row;
    if (op_row != ts.c.ts_node_end_point(left).row) return;
    if (ts.c.ts_node_start_point(right).row <= op_row) return;

    try ctx.report(
        "style/operator-linebreak",
        ts.getNodeSpan(op),
        "Binary operator placed at the end of a broken line",
        "Move the binary operator to the beginning of the next line",
    );
}

/// True when `sum` is an addition and one of its operands equals `bound`.
fn sumsInto(sum: ts.c.TSNode, bound: ts.c.TSNode, source: []const u8) bool {
    if (!isType(ts.getNodeType(sum), "binary_expression")) return false;

    const op = ts.childByField(sum, "operator");
    if (ts.isNull(op)) return false;
    if (!std.mem.eql(u8, ts.getNodeText(op, source), "+")) return false;

    return additionUses(sum, ts.getNodeText(bound, source), source);
}

/// True when either side of `sum` equals `bound`.
fn additionUses(sum: ts.c.TSNode, bound: []const u8, source: []const u8) bool {
    const left = ts.childByField(sum, "left");
    if (!ts.isNull(left) and std.mem.eql(u8, ts.getNodeText(left, source), bound)) return true;

    const right = ts.childByField(sum, "right");
    return !ts.isNull(right) and std.mem.eql(u8, ts.getNodeText(right, source), bound);
}

/// `security/no-post-overflow-check`: `a + b < a` tests after the overflow.
fn checkPostOverflowCheck(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    const op = ts.childByField(node, "operator");
    if (ts.isNull(op)) return;

    const op_text = ts.getNodeText(op, ctx.source);
    if (!isComparison(op_text)) return;

    const left = ts.childByField(node, "left");
    const right = ts.childByField(node, "right");
    if (ts.isNull(left) or ts.isNull(right)) return;

    const suspicious = sumsInto(left, right, ctx.source) or sumsInto(right, left, ctx.source);
    if (!suspicious) return;

    try ctx.report(
        "security/no-post-overflow-check",
        ts.getNodeSpan(node),
        "Post-addition overflow check relies on undefined signed overflow or " ++
            "pointer wraparound",
        "Use a pre-condition bounds check before addition (e.g. 'a > SIZE_MAX - b')",
    );
}

fn isComparison(op_text: []const u8) bool {
    return std.mem.eql(u8, op_text, "<") or std.mem.eql(u8, op_text, "<=") or
        std.mem.eql(u8, op_text, ">") or std.mem.eql(u8, op_text, ">=");
}

/// `security/safe-realloc` for `p = realloc(p, n)` and for the initialised
/// declaration `void *p = realloc(p, n)`.
fn checkSafeRealloc(ctx: *Context, node: ts.c.TSNode) interface.CheckError!void {
    if (isType(ts.getNodeType(node), "init_declarator")) {
        const target = ts.childByField(node, "declarator");
        const value = ts.childByField(node, "value");
        if (ts.isNull(target) or ts.isNull(value)) return;
        return reportReallocIntoSelf(ctx, node, target, value);
    }

    const left = ts.childByField(node, "left");
    const right = ts.childByField(node, "right");
    if (ts.isNull(left) or ts.isNull(right)) return;
    return reportReallocIntoSelf(ctx, node, left, right);
}

fn reportReallocIntoSelf(
    ctx: *Context,
    node: ts.c.TSNode,
    left: ts.c.TSNode,
    right: ts.c.TSNode,
) interface.CheckError!void {
    if (!isType(ts.getNodeType(right), "call_expression")) return;

    const fn_node = ts.childByField(right, "function");
    if (ts.isNull(fn_node)) return;
    if (!std.mem.eql(u8, ts.getNodeText(fn_node, ctx.source), "realloc")) return;

    const args = ts.childByField(right, "arguments");
    if (ts.isNull(args) or ts.namedChildCount(args) == 0) return;

    const first_arg = ts.namedChild(args, 0);
    const left_txt = ts.getNodeText(left, ctx.source);
    if (!std.mem.eql(u8, left_txt, ts.getNodeText(first_arg, ctx.source))) return;

    try ctx.report(
        "security/safe-realloc",
        ts.getNodeSpan(node),
        "Direct reassignment of pointer in 'realloc' leaks memory on failure",
        "Assign 'realloc' result to a temporary pointer 'void *tmp' and check for " ++
            "NULL before updating target pointer",
    );
}

fn checkSubroutineAbort(
    ctx: *Context,
    node: ts.c.TSNode,
    fn_node: ?ts.c.TSNode,
) interface.CheckError!void {
    const fn_ref = ts.childByField(node, "function");
    if (ts.isNull(fn_ref)) return;
    if (!isTerminatingCall(ts.getNodeText(fn_ref, ctx.source))) return;
    if (fn_node) |definition| {
        const decl = ts.childByField(definition, "declarator");
        if (!ts.isNull(decl) and std.mem.eql(u8, declaratorName(decl, ctx.source), "main")) return;
    }

    try ctx.report(
        "c/no-subroutine-abort",
        ts.getNodeSpan(node),
        "Subroutine must not terminate the process directly",
        "Propagate an explicit error status code back to the caller",
    );
}

fn isTerminatingCall(fn_name: []const u8) bool {
    const names = [_][]const u8{ "exit", "_Exit", "quick_exit", "die", "err", "errx" };
    for (names) |name| {
        if (std.mem.eql(u8, fn_name, name)) return true;
    }
    return false;
}

fn checkBannedFunctions(
    ctx: *Context,
    node: ts.c.TSNode,
    fn_name: []const u8,
) interface.CheckError!void {
    const names = [_][]const u8{
        "strcpy", "strcat", "sprintf", "vsprintf", "gets",
        "atoi",   "atol",   "atoll",   "strtok",
    };
    for (names) |name| {
        if (!std.mem.eql(u8, fn_name, name)) continue;
        try ctx.report(
            "security/banned-functions",
            ts.getNodeSpan(node),
            "Call to banned unsafe standard library routine",
            "Use bounded alternatives (snprintf, memcpy with explicit bounds, " ++
                "strtol/strtoul)",
        );
        return;
    }
}

fn checkAssertSideEffects(
    ctx: *Context,
    node: ts.c.TSNode,
    fn_name: []const u8,
) interface.CheckError!void {
    if (!std.mem.eql(u8, fn_name, "assert")) return;

    const args = ts.childByField(node, "arguments");
    if (ts.isNull(args) or ts.namedChildCount(args) == 0) return;

    const arg0 = ts.namedChild(args, 0);
    if (!hasSideEffects(arg0, ctx.source)) return;

    try ctx.report(
        "security/assert-no-side-effects",
        ts.getNodeSpan(arg0),
        "Expression inside 'assert()' contains side effects or function calls " ++
            "that vanish under -DNDEBUG",
        "Evaluate the operation into a variable before calling assert(), or use " ++
            "an explicit guard with abort()",
    );
}

fn checkEintrLoop(
    ctx: *Context,
    node: ts.c.TSNode,
    fn_name: []const u8,
) interface.CheckError!void {
    const names = [_][]const u8{ "read", "write", "poll", "waitpid" };
    var matched = false;
    for (names) |name| {
        if (std.mem.eql(u8, fn_name, name)) matched = true;
    }
    if (!matched) return;

    if (enclosingLoop(node)) |loop| {
        if (subtreeHasIdent(loop, ctx.source, "EINTR")) return;
    }

    try ctx.report(
        "security/eintr-loop",
        ts.getNodeSpan(node),
        "Interruptible blocking syscall is not wrapped in an EINTR retry loop",
        "Wrap read/write/poll in a loop that retries when return value is -1 " ++
            "and errno == EINTR",
    );
}

fn checkCloexec(ctx: *Context, node: ts.c.TSNode, fn_name: []const u8) interface.CheckError!void {
    const names = [_][]const u8{
        "open",    "openat",        "socket",
        "accept4", "epoll_create1", "pipe2",
    };
    var matched = false;
    for (names) |name| {
        if (std.mem.eql(u8, fn_name, name)) matched = true;
    }
    if (!matched) return;

    const args = ts.childByField(node, "arguments");
    if (!ts.isNull(args) and
        std.mem.indexOf(u8, ts.getNodeText(args, ctx.source), "CLOEXEC") != null) return;

    try ctx.report(
        "security/cloexec-required",
        ts.getNodeSpan(node),
        "File descriptor or socket opened without close-on-exec flag",
        "Bitwise-OR 'O_CLOEXEC' or 'SOCK_CLOEXEC' into the flags argument",
    );
}

fn isZeroLiteral(text: []const u8) bool {
    return std.mem.eql(u8, text, "0") or
        std.mem.eql(u8, text, "0x0") or
        std.mem.eql(u8, text, "0X0") or
        std.mem.eql(u8, text, "0u") or
        std.mem.eql(u8, text, "0U") or
        std.mem.eql(u8, text, "'\\0'");
}

fn checkMemsetScrub(
    ctx: *Context,
    node: ts.c.TSNode,
    fn_name: []const u8,
) interface.CheckError!void {
    if (!std.mem.eql(u8, fn_name, "memset")) return;

    const args = ts.childByField(node, "arguments");
    if (ts.isNull(args) or ts.namedChildCount(args) < 3) return;
    const fill = std.mem.trim(u8, ts.getNodeText(ts.namedChild(args, 1), ctx.source), " \t");
    if (!isZeroLiteral(fill)) return;

    const parent_stmt = ts.parent(node) orelse return;
    const next_sib = ts.c.ts_node_next_sibling(parent_stmt);
    if (ts.isNull(next_sib)) return;

    const sib_txt = ts.getNodeText(next_sib, ctx.source);
    if (!precedesRelease(sib_txt)) return;

    try ctx.report(
        "security/no-plain-memset-scrub",
        ts.getNodeSpan(node),
        "Plain 'memset' before return or cleanup may be optimized away by the " ++
            "compiler",
        "For sensitive buffers, use a volatile pointer loop paired with a " ++
            "compiler memory barrier",
    );
}

/// True when the text after the scrub releases the buffer or jumps to the
/// cleanup label.
fn precedesRelease(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "free") != null or
        std.mem.indexOf(u8, text, "return") != null or
        std.mem.indexOf(u8, text, "cleanup:") != null;
}

fn checkCalls(
    ctx: *Context,
    node: ts.c.TSNode,
    fn_node: ?ts.c.TSNode,
) interface.CheckError!void {
    const fn_ref = ts.childByField(node, "function");
    if (ts.isNull(fn_ref)) return;
    const fn_name = ts.getNodeText(fn_ref, ctx.source);

    try checkSubroutineAbort(ctx, node, fn_node);
    try checkBannedFunctions(ctx, node, fn_name);
    try checkAssertSideEffects(ctx, node, fn_name);
    try checkEintrLoop(ctx, node, fn_name);
    try checkCloexec(ctx, node, fn_name);
    try checkMemsetScrub(ctx, node, fn_name);
}

/// `c/return-var-name`: the status returned from a `goto cleanup` function is
/// named `res`.
fn checkReturnVarName(
    ctx: *Context,
    node: ts.c.TSNode,
    fn_node: ts.c.TSNode,
) interface.CheckError!void {
    if (!subtreeHasNodeType(fn_node, "labeled_statement")) return;

    const expr = ts.namedChild(node, 0);
    if (ts.isNull(expr) or !isType(ts.getNodeType(expr), "identifier")) return;
    if (std.mem.eql(u8, ts.getNodeText(expr, ctx.source), "res")) return;

    try ctx.report(
        "c/return-var-name",
        ts.getNodeSpan(expr),
        "Primary return status variable must be named 'res'",
        "Rename the return status variable to 'res'",
    );
}

fn visit(
    ctx: *Context,
    node: ts.c.TSNode,
    current_fn: ?ts.c.TSNode,
    depth: usize,
) interface.CheckError!WalkState {
    if (ts.isNull(node)) return .{ .fn_node = current_fn, .depth = depth };

    const ntype = ts.getNodeType(node);
    var state = WalkState{ .fn_node = current_fn, .depth = depth };

    if (isType(ntype, "function_definition")) {
        state.fn_node = node;
        state.depth = 0;
        try checkFunctionDefinition(ctx, node);
    }
    if (isType(ntype, "declaration")) try checkDeclaration(ctx, node, current_fn);
    if (isType(ntype, "field_declaration") or isType(ntype, "type_definition")) {
        var di: u32 = 0;
        const count = ts.namedChildCount(node);
        while (di < count) : (di += 1) {
            const child = ts.namedChild(node, di);
            if (!ts.isNull(child)) try checkCamelCaseDeclarator(ctx, child);
        }
    }
    if (isType(ntype, "struct_specifier")) {
        const name = ts.childByField(node, "name");
        if (!ts.isNull(name)) try checkCamelCaseDeclarator(ctx, name);
    }
    if (isType(ntype, "array_declarator") and current_fn != null) try checkVla(ctx, node);
    if (isType(ntype, "for_statement")) try checkLoopCounterScope(ctx, node);
    if (isType(ntype, "while_statement")) try checkInfiniteLoopFor(ctx, node);

    if (isType(ntype, "sized_type_specifier") or
        (isType(ntype, "primitive_type") and
            std.mem.eql(u8, ts.getNodeText(node, ctx.source), "int")))
    {
        try checkExplicitIntTypes(ctx, node, current_fn);
    }

    if (isLoopNode(ntype) or isType(ntype, "if_statement")) {
        try checkStatementBraces(ctx, node, ntype);
    }
    if (isType(ntype, "struct_specifier") or isType(ntype, "union_specifier") or
        isType(ntype, "enum_specifier")) try checkStatementBraces(ctx, node, ntype);
    if (isLoopNode(ntype)) try checkLoopBraces(ctx, node);
    if (isType(ntype, "if_statement")) try checkIfBraces(ctx, node);
    if (opensNesting(node, ntype)) {
        state.depth += 1;
        try checkNestingDepth(ctx, node, state.depth);
    }

    if (isType(ntype, "binary_expression")) {
        try checkBitwisePow2(ctx, node);
        try checkOperatorLinebreak(ctx, node);
        try checkPostOverflowCheck(ctx, node);
    }
    if (isType(ntype, "assignment_expression") or isType(ntype, "init_declarator")) {
        try checkSafeRealloc(ctx, node);
    }
    if (isType(ntype, "call_expression")) try checkCalls(ctx, node, current_fn);
    if (isType(ntype, "return_statement")) {
        if (current_fn) |definition| try checkReturnVarName(ctx, node, definition);
    }

    return state;
}

fn checkSource(source: []const u8, file_path: []const u8) !std.ArrayList(diagnostic.Diagnostic) {
    const parser = ts.c.ts_parser_new();
    defer ts.c.ts_parser_delete(parser);
    _ = ts.c.ts_parser_set_language(parser, ts.tree_sitter_c());

    const tree = ts.c.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len));
    defer ts.c.ts_tree_delete(tree);
    const root = ts.c.ts_tree_root_node(tree);

    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    var ctx = Context{
        .allocator = std.testing.allocator,
        .file_path = file_path,
        .source = source,
        .diagnostics = &diags,
    };
    try run(&ctx, root);
    return diags;
}

test "valid.c produces zero diagnostics" {
    // Same text as tests/fixtures/c/valid.c; the fixture is not importable
    // from here, so the sample is repeated line by line.
    const src =
        "#define _POSIX_C_SOURCE 200809L\n" ++
        "#include <stdio.h>\n" ++
        "#include <stdint.h>\n" ++
        "\n" ++
        "static int32_t calculate_total(int32_t a, int32_t b) {\n" ++
        "    int32_t res = 0;\n" ++
        "    if (a > 0) {\n" ++
        "        res = a + b;\n" ++
        "    } else {\n" ++
        "        res = b;\n" ++
        "    }\n" ++
        "    return res;\n" ++
        "}\n" ++
        "\n" ++
        "int main(int argc, char **argv) {\n" ++
        "    int32_t total = calculate_total(10, 20);\n" ++
        "    (void)argc;\n" ++
        "    (void)argv;\n" ++
        "    return total == 30 ? 0 : 1;\n" ++
        "}\n";
    var diags = try checkSource(src, "tests/fixtures/c/valid.c");
    defer diags.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "c/no-vla trigger" {
    const src = "static void foo(size_t n) { uint8_t arr[n]; }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "c/no-vla")) found = true;
    }
    try std.testing.expect(found);
}

test "c/no-subroutine-abort trigger" {
    const src = "static void foo(void) { exit(1); }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "c/no-subroutine-abort")) found = true;
    }
    try std.testing.expect(found);
}

test "c/no-camel-case trigger" {
    const src = "static void myFunc(void) {}";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "c/no-camel-case")) found = true;
    }
    try std.testing.expect(found);
}

test "c/return-var-name trigger" {
    const src = "static int32_t foo(void) { int32_t status = 0; goto cleanup; " ++
        "cleanup: return status; }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "c/return-var-name")) found = true;
    }
    try std.testing.expect(found);
}

test "style/mandatory-braces trigger" {
    const src = "static void foo(int32_t x) { if (x > 0) return; }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "style/mandatory-braces")) found = true;
    }
    try std.testing.expect(found);
}

test "style/brace-placement trigger" {
    const src = "static void foo(void)\n{\n}";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "style/brace-placement")) found = true;
    }
    try std.testing.expect(found);
}

test "c/explicit-int-types trigger" {
    const src = "static int foo(void) { short x = 1; return 0; }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "c/explicit-int-types")) found = true;
    }
    try std.testing.expect(found);
}

test "c/declarations-at-top and c/uninitialized-local trigger" {
    const src = "static void foo(void) { int32_t a = 1; a += 1; int32_t b; }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found_top = false;
    var found_uninit = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "c/declarations-at-top")) found_top = true;
        if (std.mem.eql(u8, d.rule_id, "c/uninitialized-local")) found_uninit = true;
    }
    try std.testing.expect(found_top);
    try std.testing.expect(found_uninit);
}

test "c/loop-counter-scope trigger" {
    const src = "static void foo(void) { size_t i = 0; for (i = 0; i < 10; i++) {} }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "c/loop-counter-scope")) found = true;
    }
    try std.testing.expect(found);
}

test "c/const-lookup-tables trigger" {
    const src = "static uint8_t table[] = { 1, 2, 3 };";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "c/const-lookup-tables")) found = true;
    }
    try std.testing.expect(found);
}

test "c/internal-linkage trigger" {
    const src = "void foo(void) {}";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "c/internal-linkage")) found = true;
    }
    try std.testing.expect(found);
}

test "c/infinite-loop-for trigger" {
    const src = "static void foo(void) { while (1) {} }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "c/infinite-loop-for")) found = true;
    }
    try std.testing.expect(found);
}

test "security/safe-realloc trigger" {
    const src = "static void foo(void) { void *buf = NULL; buf = realloc(buf, 100); }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "security/safe-realloc")) found = true;
    }
    try std.testing.expect(found);
}

test "security/assert-no-side-effects trigger" {
    const src = "static void foo(int32_t x) { assert(x++ > 0); }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "security/assert-no-side-effects")) found = true;
    }
    try std.testing.expect(found);
}

test "security/no-post-overflow-check trigger" {
    const src = "static void foo(uint32_t a, uint32_t b) { if (a + b < a) { return; } }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "security/no-post-overflow-check")) found = true;
    }
    try std.testing.expect(found);
}

test "security/eintr-loop trigger" {
    const src = "static void foo(int32_t fd, void *buf) { read(fd, buf, 10); }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "security/eintr-loop")) found = true;
    }
    try std.testing.expect(found);
}

test "security/cloexec-required trigger" {
    const src = "static void foo(void) { open(path, 0); }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "security/cloexec-required")) found = true;
    }
    try std.testing.expect(found);
}

test "security/banned-functions trigger" {
    const src = "static void foo(char *dst, const char *src_str) { strcpy(dst, src_str); }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "security/banned-functions")) found = true;
    }
    try std.testing.expect(found);
}

test "security/no-plain-memset-scrub trigger" {
    const src = "static void foo(void *ptr) { memset(ptr, 0, 100); free(ptr); }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "security/no-plain-memset-scrub")) found = true;
    }
    try std.testing.expect(found);
}

test "c/bitwise-pow2 trigger" {
    const src = "static int32_t foo(int32_t x) { return x * 4; }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "c/bitwise-pow2")) found = true;
    }
    try std.testing.expect(found);
}

test "complexity/max-nesting-depth trigger" {
    const src = "static void foo(int32_t x) { if (x > 0) { for (size_t i = 0; " ++
        "i < 10; i++) { while (x > 1) { switch (x) { default: break; } } } } }";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "complexity/max-nesting-depth")) found = true;
    }
    try std.testing.expect(found);
}

test "declarations-at-top ignores comments" {
    const src = "static void foo(void) {\n\t// comment\n\tint32_t x = 0;\n\t(void)x;\n}";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    for (diags.items) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.rule_id, "c/declarations-at-top"));
    }
}

test "style/operator-linebreak trigger" {
    const src = "static int32_t foo(int32_t a, int32_t b) {\n\treturn a +\n\t\tb;\n}";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "style/operator-linebreak")) found = true;
    }
    try std.testing.expect(found);
}

test "style/operator-linebreak allows operator on next line" {
    const src = "static int32_t foo(int32_t a, int32_t b) {\n\treturn a\n\t\t+ b;\n}";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    for (diags.items) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.rule_id, "style/operator-linebreak"));
    }
}

test "c/local-macro-undef trigger" {
    const src = "static void foo(void) {}\n#define LOCAL_MAX 16\nstatic void bar(void) {}\n";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "c/local-macro-undef")) found = true;
    }
    try std.testing.expect(found);
}

test "c/local-macro-undef satisfied by undef" {
    const src = "static void foo(void) {}\n#define LOCAL_MAX 16\n" ++
        "static void bar(void) {}\n#undef LOCAL_MAX\n";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    for (diags.items) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.rule_id, "c/local-macro-undef"));
    }
}

test "c/local-macro-undef ignores top-of-file macros" {
    const src = "#define _POSIX_C_SOURCE 200809L\n#define BUF_SIZE 64\nstatic void foo(void) {}\n";
    var diags = try checkSource(src, "test.c");
    defer diags.deinit(std.testing.allocator);
    for (diags.items) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.rule_id, "c/local-macro-undef"));
    }
}

test "deep nesting does not overflow stack" {
    var src = std.ArrayList(u8).empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "static void foo(void) { int32_t x = ");
    for (0..5000) |_| try src.appendSlice(std.testing.allocator, "(");
    try src.appendSlice(std.testing.allocator, "0");
    for (0..5000) |_| try src.appendSlice(std.testing.allocator, ")");
    try src.appendSlice(std.testing.allocator, "; (void)x; }");
    var diags = try checkSource(src.items, "test.c");
    defer diags.deinit(std.testing.allocator);
}
