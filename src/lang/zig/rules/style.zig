const std = @import("std");
const ast = @import("../ast.zig");
const interface = @import("../../interface.zig");
const Context = interface.Context;

const Tree = ast.Tree;

pub fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

pub fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn isTitleCase(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!isUpper(name[0])) return false;
    for (name[1..]) |c| {
        if (c == '_') return false;
    }
    return true;
}

pub fn isCamelCase(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!isLower(name[0])) return false;
    for (name) |c| {
        if (c == '_' or c == '-') return false;
    }
    return true;
}

pub fn isSnakeCase(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (isUpper(c)) return false;
        if (c != '_' and !isLower(c) and !isDigit(c)) return false;
    }
    return true;
}

/// File stem without the extension, so `ast.zig` yields `ast`.
pub fn fileStem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(base);
    return base[0 .. base.len - ext.len];
}

/// True when the text contains an uppercase letter, which no snake_case name
/// or snake_case filename may have.
pub fn hasUpper(text: []const u8) bool {
    for (text) |c| {
        if (isUpper(c)) return true;
    }
    return false;
}

fn reportName(
    ctx: *Context,
    rule_id: []const u8,
    tree: *const Tree,
    token_index: usize,
    message: []const u8,
    help: ?[]const u8,
) interface.CheckError!void {
    try ctx.report(rule_id, tree.tokenSpan(token_index), message, help);
}

/// `zig/file-naming`: the stem is snake_case and the extension is one the
/// analyzer handles.
pub fn fileNaming(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    _ = tree;
    const stem = fileStem(ctx.file_path);
    if (stem.len == 0) return;
    if (!isSnakeCase(stem)) {
        try ctx.report(
            "zig/file-naming",
            .{
                .start_byte = 0,
                .end_byte = 0,
                .start_line = 1,
                .start_col = 1,
                .end_line = 1,
                .end_col = stem.len + 1,
            },
            "Source filename does not use snake_case",
            "Name Zig source files using snake_case with a .zig or .zon extension",
        );
    }
}

/// `zig/type-naming`: struct, enum, union, opaque and error set declarations
/// use TitleCase.
/// `zig/type-naming`: the name bound to a container or an error set. The name
/// lives in the enclosing declaration, so the rule reads the `=` before the
/// `struct`/`enum`/`union`/`opaque`/`error` keyword.
pub fn typeNaming(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (!startsTypeBody(tree.tokens[i].tag)) continue;
        if (i == 0 or tree.tokens[i - 1].tag != .equal) continue;
        if (i < 2 or tree.tokens[i - 2].tag != .identifier) continue;

        const name_token = i - 2;
        if (isTitleCase(tree.tokenText(name_token))) continue;

        try reportName(
            ctx,
            "zig/type-naming",
            tree,
            name_token,
            "Type identifier does not use TitleCase",
            "Name types using TitleCase (e.g. MyStruct, AllocatorOptions)",
        );
    }
}

fn startsTypeBody(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .keyword_struct, .keyword_enum, .keyword_union, .keyword_opaque, .keyword_error => true,
        else => false,
    };
}

fn findToken(tree: *const Tree, start: usize, end: usize, tag: std.zig.Token.Tag) ?usize {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const t = tree.tokens[i];
        if (t.start < start) continue;
        if (t.start >= end) break;
        if (t.tag == tag) return i;
    }
    return null;
}

/// `zig/fn-naming`: functions use camelCase, except `main` and functions
/// with C linkage.
pub fn fnNaming(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        if (tree.tag(i) != .fn_decl) continue;
        if (ast.fnIsExempt(tree, i)) continue;

        const name = ast.fnName(tree, i) orelse continue;
        if (isCamelCase(name)) continue;
        if (ctx.allow.allowsFnName(name)) continue;

        const name_token = ast.fnProto(tree, i).?.name_token orelse continue;
        try reportName(
            ctx,
            "zig/fn-naming",
            tree,
            @intCast(name_token),
            "Function name does not use camelCase",
            "Name functions using camelCase (e.g. init, processBuffer)",
        );
    }
}

/// `zig/var-naming`: locals, parameters, fields and error captures use
/// snake_case.
pub fn varNaming(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        const tag = tree.tag(i);
        const is_decl = switch (tag) {
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => true,
            else => false,
        };
        if (is_decl) {
            // Container-scope constants name types and namespaces, which the
            // type and import rules own. Only function-local declarations are
            // checked here.
            if (ast.fnAtOffset(tree, tree.nodeBytes(i).start) == null) continue;
            if (tree.ast.fullVarDecl(tree.nodeAt(i))) |decl| {
                const name_token = decl.ast.mut_token + 1;
                const name = tree.ast.tokenSlice(name_token);
                if (name.len > 0 and !isSnakeCase(name)) {
                    try reportName(
                        ctx,
                        "zig/var-naming",
                        tree,
                        @intCast(name_token),
                        "Variable or parameter name does not use snake_case",
                        "Name variables using snake_case (e.g. buffer_size, item_count)",
                    );
                }
            }
            continue;
        }

        if (tag == .container_field_init or tag == .container_field_align or
            tag == .container_field)
        {
            // Enum tags are the enum-tag-naming rule's business.
            if (ast.isInsideEnum(tree, i)) continue;
            const field = tree.ast.fullContainerField(tree.nodeAt(i)) orelse continue;
            if (ast.fieldIsExternalSchema(tree, i)) continue;
            const name_token = field.ast.main_token;
            const name = tree.ast.tokenSlice(name_token);
            if (name.len > 0 and !isSnakeCase(name)) {
                try reportName(
                    ctx,
                    "zig/var-naming",
                    tree,
                    @intCast(name_token),
                    "Variable or parameter name does not use snake_case",
                    "Name fields using snake_case (e.g. buffer_size, item_count)",
                );
            }
            continue;
        }

        if (tag == .fn_decl) {
            var params: std.ArrayList([]const u8) = .empty;
            defer params.deinit(ctx.allocator);
            try ast.paramNames(tree, i, &params);
            for (params.items) |name| {
                if (!isSnakeCase(name)) {
                    // Parameter tokens are re-found by scanning the signature.
                    try reportParamName(ctx, tree, i, name);
                }
            }
        }
    }
}

fn reportParamName(
    ctx: *Context,
    tree: *const Tree,
    fn_decl: usize,
    name: []const u8,
) interface.CheckError!void {
    const bounds = tree.nodeBytes(fn_decl);

    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const t = tree.tokens[i];
        if (t.start < bounds.start or t.end > bounds.end) continue;
        if (t.tag != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), name)) continue;
        try reportName(
            ctx,
            "zig/var-naming",
            tree,
            i,
            "Variable or parameter name does not use snake_case",
            "Name parameters using snake_case (e.g. buffer_size, item_count)",
        );
        return;
    }
}

/// `zig/error-tag-naming`: error set members use TitleCase.
pub fn errorTagNaming(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        if (tree.tag(i) != .error_set_decl) continue;
        const b = tree.nodeBytes(i);
        const lbrace = findToken(tree, b.start, b.end, .l_brace) orelse continue;
        const rbrace = findTokenBack(tree, b.start, b.end, .r_brace) orelse continue;

        var t: usize = lbrace + 1;
        while (t < rbrace) : (t += 1) {
            if (tree.tokens[t].tag != .identifier) continue;
            const name = tree.tokenText(t);
            if (isTitleCase(name)) continue;
            try reportName(
                ctx,
                "zig/error-tag-naming",
                tree,
                t,
                "Error tag does not use TitleCase",
                "Name error tags using TitleCase (e.g. OutOfMemory, FileNotFound)",
            );
        }
    }
}

fn findTokenBack(tree: *const Tree, start: usize, end: usize, tag: std.zig.Token.Tag) ?usize {
    var found: ?usize = null;
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const t = tree.tokens[i];
        if (t.start < start) continue;
        if (t.start >= end) break;
        if (t.tag == tag) found = i;
    }
    return found;
}

/// `zig/enum-tag-naming`: enum members use snake_case. Only the members of an
/// enum body are tags; methods and their parameters are checked elsewhere.
pub fn enumTagNaming(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        const tag = tree.tag(i);
        if (tag != .container_field and tag != .container_field_init and
            tag != .container_field_align) continue;
        if (!ast.isInsideEnum(tree, i)) continue;

        const field = tree.ast.fullContainerField(tree.nodeAt(i)) orelse continue;
        const name_token = field.ast.main_token;
        const name = tree.ast.tokenSlice(name_token);
        if (name.len == 0 or isSnakeCase(name)) continue;

        try reportName(
            ctx,
            "zig/enum-tag-naming",
            tree,
            @intCast(name_token),
            "Enum tag does not use snake_case",
            "Name enum tags using snake_case (e.g. read_only, default_value)",
        );
    }
}

/// `zig/import-alias-naming`: an `@import` of a file that declares a struct
/// binds with TitleCase; every other namespace binds with snake_case.
pub fn importAliasNaming(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        const tag = tree.tag(i);
        const is_decl = tag == .global_var_decl or tag == .local_var_decl or
            tag == .simple_var_decl or tag == .aligned_var_decl;
        if (!is_decl) continue;

        const decl = tree.ast.fullVarDecl(tree.nodeAt(i)) orelse continue;
        if (decl.ast.init_node == .none) continue;
        const init_node: std.zig.Ast.Node.Index = @enumFromInt(@intFromEnum(decl.ast.init_node));
        const call_tag = tree.tag(@intFromEnum(init_node));
        if (call_tag != .builtin_call_two and call_tag != .builtin_call) continue;

        const name_token = decl.ast.mut_token + 1;
        const alias = tree.ast.tokenSlice(name_token);
        const import_path = importPath(tree, @intFromEnum(init_node)) orelse continue;

        // The alias must be the target file stem in snake_case or in the
        // TitleCase form used for a file-as-struct import. Anything else hides
        // which file the name came from.
        if (aliasMatchesImport(ctx, alias, import_path)) continue;

        try reportName(
            ctx,
            "zig/import-alias-naming",
            tree,
            @intCast(name_token),
            "Import alias does not match the target file name",
            "Use TitleCase for a file that declares a struct, snake_case for a namespace",
        );
    }
}

fn aliasMatchesImport(ctx: *const Context, alias: []const u8, import_path: []const u8) bool {
    const stem = fileStem(import_path);
    if (stem.len == 0) return true;

    if (ctx.io) |io| {
        if (std.mem.endsWith(u8, import_path, ".zig")) {
            if (ast.importsStruct(ctx.allocator, io, ctx.file_path, import_path)) {
                return isTitleCaseStem(alias, stem);
            }
            return std.mem.eql(u8, alias, stem);
        }
    }
    return aliasMatchesStem(alias, import_path);
}

fn isTitleCaseStem(alias: []const u8, stem: []const u8) bool {
    if (!isSnakeCase(stem)) return false;

    var title_buf: [256]u8 = undefined;
    if (stem.len > title_buf.len) return false;
    var len: usize = 0;
    var upper_next = true;
    for (stem) |ch| {
        if (ch == '_') {
            upper_next = true;
            continue;
        }
        title_buf[len] = if (upper_next) std.ascii.toUpper(ch) else ch;
        len += 1;
        upper_next = false;
    }
    return std.mem.eql(u8, alias, title_buf[0..len]);
}

/// True when `alias` is the stem of `import_path` in snake_case, or the same
/// stem in TitleCase.
fn aliasMatchesStem(alias: []const u8, import_path: []const u8) bool {
    const stem = fileStem(import_path);
    if (stem.len == 0) return true;
    if (std.mem.eql(u8, alias, stem)) return true;
    return isTitleCaseStem(alias, stem);
}

/// True when the call node is an `@import("...")` builtin.
fn importPath(tree: *const Tree, call: usize) ?[]const u8 {
    const text = tree.nodeText(call);
    if (!std.mem.startsWith(u8, text, "@import")) return null;

    const b = tree.nodeBytes(call);
    const lparen = findToken(tree, b.start, b.end, .l_paren) orelse return null;
    const token = lparen + 1;
    if (token >= tree.tokens.len) return null;
    if (tree.tokens[token].tag != .string_literal) return null;
    const raw = tree.tokenText(token);
    if (raw.len < 2) return null;
    return raw[1 .. raw.len - 1];
}

/// `zig/no-raw-identifiers`: `@"name"` is only allowed in FFI modules.
pub fn noRawIdentifiers(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    if (ctx.allow.allowsRawIdentifier(ctx.file_path)) return;

    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const text = tree.tokenText(i);
        if (text.len < 3 or text[0] != '@' or text[1] != '"') continue;
        if (ast.inTestBlockToken(tree, i)) continue;
        // A raw identifier that spells a keyword is the only way to name it.
        if (isKeyword(text[2 .. text.len - 1])) continue;
        // A field named by an external schema is not ours to rename; the
        // container signals that with its own jsonStringify.
        if (ast.fieldIsExternalSchema(tree, i)) continue;
        try ctx.report(
            "zig/no-raw-identifiers",
            tree.tokenSpan(i),
            "Raw identifier @\"...\" used outside FFI bindings",
            "Use a plain identifier unless the name is a keyword",
        );
    }
}

/// Zig keywords. A raw identifier is the only way to spell one, so the
/// `zig/no-raw-identifiers` rule must not flag it.
const zig_keywords = [_][]const u8{
    "addrspace",
    "align",
    "allowzero",
    "and",
    "anyframe",
    "anytype",
    "asm",
    "async",
    "await",
    "break",
    "callconv",
    "catch",
    "comptime",
    "const",
    "continue",
    "defer",
    "else",
    "enum",
    "errdefer",
    "error",
    "export",
    "extern",
    "fn",
    "for",
    "if",
    "inline",
    "linksection",
    "noalias",
    "noinline",
    "nosuspend",
    "opaque",
    "or",
    "orelse",
    "packed",
    "pub",
    "resume",
    "return",
    "struct",
    "suspend",
    "switch",
    "test",
    "threadlocal",
    "try",
    "union",
    "unreachable",
    "var",
    "volatile",
    "while",
};

fn isKeyword(name: []const u8) bool {
    for (zig_keywords) |keyword| {
        if (std.mem.eql(u8, name, keyword)) return true;
    }
    return false;
}

test "isTitleCase accepts PascalCase and rejects snake_case" {
    try std.testing.expect(isTitleCase("MyStruct"));
    try std.testing.expect(isTitleCase("A"));
    try std.testing.expect(!isTitleCase("myStruct"));
    try std.testing.expect(!isTitleCase("my_struct"));
}

test "isCamelCase accepts lower camel and rejects the rest" {
    try std.testing.expect(isCamelCase("processBuffer"));
    try std.testing.expect(isCamelCase("init"));
    try std.testing.expect(!isCamelCase("ProcessBuffer"));
    try std.testing.expect(!isCamelCase("process_buffer"));
}

test "isSnakeCase accepts lower snake and rejects the rest" {
    try std.testing.expect(isSnakeCase("buffer_size"));
    try std.testing.expect(isSnakeCase("x"));
    try std.testing.expect(!isSnakeCase("bufferSize"));
    try std.testing.expect(!isSnakeCase("Buffer"));
}

test "fileStem drops the extension" {
    try std.testing.expectEqualStrings("ast", fileStem("src/lang/zig/ast.zig"));
    try std.testing.expectEqualStrings("build.zig", fileStem("build.zig.zon"));
}

test "hasUpper finds any uppercase letter" {
    try std.testing.expect(hasUpper("myFile"));
    try std.testing.expect(!hasUpper("my_file"));
}
