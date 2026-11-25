const std = @import("std");
const diagnostic = @import("../../core/diagnostic.zig");
pub const scan = @import("scan.zig");
const interface = @import("../interface.zig");

pub const Mode = enum {
    zig,
    zon,

    pub fn fromExtension(path: []const u8) Mode {
        return if (std.mem.endsWith(u8, path, ".zon")) .zon else .zig;
    }
};

pub const Range = struct {
    start: usize,
    end: usize,
    index: usize,
};

/// A parsed file plus the indexes the rules read. Every field is owned by the
/// caller's arena, so `deinit` only releases what `parse` allocated.
pub const Tree = struct {
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    ast: std.zig.Ast,
    tokens: []scan.Token,
    lines: scan.LineIndex,
    test_ranges: []Range,
    fn_ranges: []Range,
    enum_ranges: []Range,
    block_ranges: []Range,

    pub fn parse(
        allocator: std.mem.Allocator,
        source: [:0]const u8,
        mode: Mode,
    ) interface.CheckError!Tree {
        var ast = try std.zig.Ast.parse(allocator, source, .{
            .mode = switch (mode) {
                .zig => .zig,
                .zon => .zon,
            },
        });
        errdefer ast.deinit(allocator);

        var tree = Tree{
            .allocator = allocator,
            .source = source,
            .ast = ast,
            .tokens = try scan.tokensFromAst(allocator, &ast),
            .lines = try scan.LineIndex.init(allocator, source),
            .test_ranges = &.{},
            .fn_ranges = &.{},
            .enum_ranges = &.{},
            .block_ranges = &.{},
        };
        try buildRangeIndexes(allocator, &tree);
        return tree;
    }

    pub fn deinit(self: *Tree) void {
        self.ast.deinit(self.allocator);
        self.allocator.free(self.tokens);
        self.allocator.free(self.lines.starts);
        self.allocator.free(self.test_ranges);
        self.allocator.free(self.fn_ranges);
        self.allocator.free(self.enum_ranges);
        self.allocator.free(self.block_ranges);
    }

    pub fn nodeCount(self: *const Tree) usize {
        return self.ast.nodes.len;
    }

    pub fn nodeAt(self: *const Tree, index: usize) std.zig.Ast.Node.Index {
        _ = self;
        return @enumFromInt(index);
    }

    pub fn tag(self: *const Tree, index: usize) std.zig.Ast.Node.Tag {
        return self.ast.nodeTag(self.nodeAt(index));
    }

    pub fn nodeText(self: *const Tree, index: usize) []const u8 {
        return self.ast.getNodeSource(self.nodeAt(index));
    }

    /// Byte span of a node, from its first token to the end of its last one.
    pub fn nodeBytes(self: *const Tree, index: usize) struct { start: usize, end: usize } {
        const node = self.nodeAt(index);
        const first = self.ast.firstToken(node);
        const last = self.ast.lastToken(node);
        return .{
            .start = self.ast.tokenStart(first),
            .end = self.ast.tokenStart(last) + @as(usize, @intCast(self.ast.tokenSlice(last).len)),
        };
    }

    pub fn nodeSpan(self: *const Tree, index: usize) diagnostic.Span {
        const b = self.nodeBytes(index);
        return self.lines.span(b.start, b.end);
    }

    pub fn tokenSpan(self: *const Tree, token_index: usize) diagnostic.Span {
        const start = self.ast.tokenStart(@intCast(token_index));
        const slice = self.ast.tokenSlice(@intCast(token_index));
        return self.lines.span(start, start + slice.len);
    }

    pub fn tokenText(self: *const Tree, token_index: usize) []const u8 {
        return self.ast.tokenSlice(@intCast(token_index));
    }

    pub fn tokenTag(self: *const Tree, token_index: usize) std.zig.Token.Tag {
        return self.ast.tokenTag(@intCast(token_index));
    }

    /// Every node index whose tag is `wanted`, in source order.
    pub fn nodesWithTag(
        self: *const Tree,
        wanted: std.zig.Ast.Node.Tag,
        out: *std.ArrayList(usize),
    ) interface.CheckError!void {
        var i: usize = 0;
        while (i < self.nodeCount()) : (i += 1) {
            if (self.tag(i) == wanted) try out.append(self.allocator, i);
        }
    }
};

/// Line of a byte offset, 1-based.
pub fn lineOf(tree: *const Tree, offset: usize) usize {
    return tree.lines.lineCol(offset).line;
}

/// True when `offset` sits inside a `test` declaration. Rules that allow
/// `unreachable`, debug prints or standalone Io in tests use this.
pub fn inTestBlock(tree: *const Tree, index: usize) bool {
    return inTestBlockAt(tree, tree.nodeBytes(index).start);
}

/// True when `index` is a field of a container that defines its own
/// `jsonStringify`. Such a container owns its field names because they are
/// the serialized schema, so the naming rules skip them.
pub fn fieldIsExternalSchema(tree: *const Tree, index: usize) bool {
    const target = tree.nodeBytes(index);
    return fieldIsExternalSchemaAt(tree, target.start);
}

/// True when `offset` sits inside a container that defines `jsonStringify`.
pub fn fieldIsExternalSchemaAt(tree: *const Tree, offset: usize) bool {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        if (!isContainerTag(tree.tag(i))) continue;
        const b = tree.nodeBytes(i);
        if (b.start > offset or b.end < offset) continue;
        if (containerDeclaresJsonStringify(tree, i)) return true;
    }
    return false;
}

fn buildRangeIndexes(allocator: std.mem.Allocator, tree: *Tree) interface.CheckError!void {
    var tests: std.ArrayList(Range) = .empty;
    var fns: std.ArrayList(Range) = .empty;
    var enums: std.ArrayList(Range) = .empty;
    var blocks: std.ArrayList(Range) = .empty;
    errdefer {
        tests.deinit(allocator);
        fns.deinit(allocator);
        enums.deinit(allocator);
        blocks.deinit(allocator);
    }

    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        const tag = tree.tag(i);
        if (tag == .test_decl) {
            const b = tree.nodeBytes(i);
            try tests.append(allocator, .{ .start = b.start, .end = b.end, .index = i });
        } else if (tag == .fn_decl) {
            const b = fnBytes(tree, i);
            try fns.append(allocator, .{ .start = b.start, .end = b.end, .index = i });
        } else if (isContainerTag(tag) and
            tree.tokenTag(tree.ast.nodeMainToken(tree.nodeAt(i))) == .keyword_enum)
        {
            const b = tree.nodeBytes(i);
            try enums.append(allocator, .{ .start = b.start, .end = b.end, .index = i });
        } else if (tag == .block or tag == .block_two or
            tag == .block_two_semicolon or tag == .block_semicolon)
        {
            const b = tree.nodeBytes(i);
            try blocks.append(allocator, .{ .start = b.start, .end = b.end, .index = i });
        }
    }

    tree.test_ranges = try tests.toOwnedSlice(allocator);
    tree.fn_ranges = try fns.toOwnedSlice(allocator);
    tree.enum_ranges = try enums.toOwnedSlice(allocator);
    tree.block_ranges = try blocks.toOwnedSlice(allocator);
}

/// True when `index` sits inside an `enum { ... }` body, whose members are
/// tags rather than fields.
pub fn isInsideEnum(tree: *const Tree, index: usize) bool {
    const inner = tree.nodeBytes(index);
    for (tree.enum_ranges) |r| {
        if (inner.start >= r.start and inner.end <= r.end) return true;
    }
    return false;
}

pub fn isContainerTag(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => true,
        else => false,
    };
}

fn containerDeclaresJsonStringify(tree: *const Tree, index: usize) bool {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const body = tree.ast.fullContainerDecl(&buffer, tree.nodeAt(index)) orelse return false;
    for (body.ast.members) |member| {
        const member_index = @intFromEnum(member);
        if (tree.tag(member_index) != .fn_decl) continue;
        const name = fnName(tree, member_index) orelse continue;
        if (std.mem.eql(u8, name, "jsonStringify")) return true;
    }
    return false;
}

/// True when `offset` sits inside any `{ ... }` block. A container-scope
/// declaration is never inside one, so this separates locals from globals.
pub fn insideBlock(tree: *const Tree, offset: usize) bool {
    for (tree.block_ranges) |r| {
        if (r.start <= offset and offset <= r.end) return true;
    }
    return false;
}

/// True when the token at `token_index` sits inside a `test` declaration.
pub fn inTestBlockToken(tree: *const Tree, token_index: usize) bool {
    if (token_index >= tree.tokens.len) return false;
    return inTestBlockAt(tree, tree.tokens[token_index].start);
}

pub fn inTestBlockAt(tree: *const Tree, offset: usize) bool {
    for (tree.test_ranges) |r| {
        if (r.start <= offset and offset <= r.end) return true;
    }
    return false;
}

/// True when the token at `token_index` sits inside a `comptime` block or expression.
pub fn inComptimeBlockToken(tree: *const Tree, token_index: usize) bool {
    if (token_index >= tree.tokens.len) return false;
    const offset = tree.tokens[token_index].start;
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        if (tree.tag(i) != .@"comptime") continue;
        const b = tree.nodeBytes(i);
        if (b.start <= offset and offset <= b.end) return true;
    }
    return false;
}

/// True when `path` resolves to a file that declares a container type at
/// scope. `import-alias-naming` needs this to tell a struct import from a
/// namespace import. Returns false when the file cannot be read.
pub fn importsStruct(
    allocator: std.mem.Allocator,
    io: std.Io,
    from: []const u8,
    import_path: []const u8,
) bool {
    if (import_path.len == 0 or std.mem.startsWith(u8, import_path, "/")) return false;

    const dir_path = std.Io.Dir.path.dirname(from) orelse ".";
    const joined = std.Io.Dir.path.join(allocator, &.{ dir_path, import_path }) catch {
        return false;
    };
    defer allocator.free(joined);

    const source = std.Io.Dir.cwd()
        .readFileAlloc(io, joined, allocator, .limited(8 * 1024 * 1024)) catch return false;
    defer allocator.free(source);

    const source_z = allocator.dupeSentinel(u8, source, 0) catch return false;
    defer allocator.free(source_z);

    var tree = std.zig.Ast.parse(allocator, source_z, .{ .mode = .zig }) catch return false;
    defer tree.deinit(allocator);

    for (tree.rootDecls()) |decl_idx| {
        switch (tree.nodeTag(decl_idx)) {
            .container_field_init,
            .container_field_align,
            .container_field,
            => return true,
            else => {},
        }
    }
    return false;
}

/// Names of functions declared at container scope: the recursion rule and the
/// allowlist check both need them.
pub fn declaredFnNames(tree: *const Tree, out: *std.StringHashMap(void)) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        if (tree.tag(i) != .fn_decl) continue;
        const name = fnName(tree, i) orelse continue;
        try out.put(name, {});
    }
}

/// Index of the prototype inside a `fn_decl`. The parser builds a `fn_decl`
/// only when a body follows, and stores the pair `(fn_proto, body_block)`.
/// The prototype is one of the four `fn_proto*` shapes, so it goes through
/// `fullFnProto` rather than `fnProto`, which asserts on `.fn_proto` only.
pub fn protoNode(tree: *const Tree, fn_decl: usize) ?usize {
    if (tree.tag(fn_decl) != .fn_decl) return null;
    const pair = tree.ast.nodeData(tree.nodeAt(fn_decl)).node_and_node;
    return @intFromEnum(pair[0]);
}

/// Full prototype of a function, whatever shape the parser chose.
pub fn fnProto(tree: *const Tree, fn_decl: usize) ?std.zig.Ast.full.FnProto {
    const proto_idx = protoNode(tree, fn_decl) orelse return null;
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    return tree.ast.fullFnProto(&buffer, tree.nodeAt(proto_idx));
}

/// Name of the function declared by a `fn_decl` node, or null for a
/// declaration without a name (a function pointer type, for example).
pub fn fnName(tree: *const Tree, fn_decl: usize) ?[]const u8 {
    const proto = protoNode(tree, fn_decl) orelse return null;
    return fnProtoName(tree, proto);
}

pub fn fnProtoName(tree: *const Tree, fn_proto: usize) ?[]const u8 {
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const proto = tree.ast.fullFnProto(&buffer, tree.nodeAt(fn_proto)) orelse return null;
    const name_token = proto.name_token orelse return null;
    return tree.ast.tokenSlice(name_token);
}

/// True when the node is a function with a body. The parser only builds a
/// `fn_decl` for a declaration followed by `{}`, so the tag is the test.
pub fn fnHasBody(tree: *const Tree, fn_decl: usize) bool {
    return tree.tag(fn_decl) == .fn_decl;
}

/// Byte range of a `fn_decl`, from the start of its prototype to the end of
/// its body block. `nodeToSpan` stops at the last prototype token for a
/// declaration, so the body block supplies the real end.
pub fn fnBytes(tree: *const Tree, fn_decl: usize) struct { start: usize, end: usize } {
    const pair = tree.ast.nodeData(tree.nodeAt(fn_decl)).node_and_node;
    const proto_start = tree.ast.tokenStart(tree.ast.firstToken(pair[0]));
    const body = tree.nodeBytes(@intFromEnum(pair[1]));
    return .{ .start = proto_start, .end = body.end };
}

/// Innermost `fn_decl` whose byte range contains `offset`, or null at
/// container scope. Takes a byte offset because a token is not a node.
pub fn fnAtOffset(tree: *const Tree, offset: usize) ?usize {
    var best: ?usize = null;
    var best_start: usize = 0;

    for (tree.fn_ranges) |r| {
        if (r.start > offset or r.end < offset) continue;
        if (best == null or r.start >= best_start) {
            best = r.index;
            best_start = r.start;
        }
    }
    return best;
}

/// Innermost `fn_decl` whose byte range contains `index`, or null at
/// container scope.
pub fn enclosingFn(tree: *const Tree, index: usize) ?usize {
    const target = tree.nodeBytes(index);
    return fnAtOffset(tree, target.start);
}

/// True when `fn_decl` is `main`, `export` or `extern`. Those keep C linkage
/// names and are exempt from the camelCase rule.
pub fn fnIsExempt(tree: *const Tree, fn_decl: usize) bool {
    const proto = fnProto(tree, fn_decl) orelse return false;
    if (proto.extern_export_inline_token != null) return true;
    const name = fnName(tree, fn_decl) orelse return false;
    return std.mem.eql(u8, name, "main");
}

/// True when the file declares an entry point. Used to tell a library from an
/// executable: debug prints and process exits are allowed in `main.zig`.
pub fn declaresMain(tree: *const Tree) bool {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        if (tree.tag(i) != .fn_decl) continue;
        const name = fnName(tree, i) orelse continue;
        if (std.mem.eql(u8, name, "main")) return true;
    }
    return false;
}

/// Parameter names of a function declaration, in order. `anytype` and `...`
/// parameters have no name and are skipped.
pub fn paramNames(
    tree: *const Tree,
    fn_decl: usize,
    out: *std.ArrayList([]const u8),
) interface.CheckError!void {
    out.clearRetainingCapacity();
    if (tree.tag(fn_decl) != .fn_decl) return;

    const proto = fnProto(tree, fn_decl) orelse return;
    var it = proto.iterate(&tree.ast);
    while (it.next()) |param| {
        const name_token = param.name_token orelse continue;
        try out.append(tree.allocator, tree.ast.tokenSlice(name_token));
    }
}

/// Parameter type node of a parameter, or null when it has no type
/// (`anytype` and `...`).
pub fn paramType(tree: *const Tree, fn_decl: usize) ?[]const u8 {
    if (tree.tag(fn_decl) != .fn_decl) return null;
    const proto = fnProto(tree, fn_decl) orelse return null;
    var it = proto.iterate(&tree.ast);
    const first = it.next() orelse return null;
    const type_expr = first.type_expr orelse return null;
    return tree.ast.getNodeSource(type_expr);
}

test "tree spans map to one-based coordinates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "const x: u8 = 1;\n";
    const tree = try Tree.parse(a, try a.dupeSentinel(u8, src, 0), .zig);
    var owned = tree;
    defer owned.deinit();

    // Node indices follow the parse order, not the source order, so the
    // declaration is found by tag rather than by index.
    var decl: ?usize = null;
    var i: usize = 0;
    while (i < owned.nodeCount()) : (i += 1) {
        if (owned.tag(i) == .simple_var_decl) decl = i;
    }
    try std.testing.expect(decl != null);

    const span = owned.nodeSpan(decl.?);
    try std.testing.expectEqual(@as(usize, 1), span.start_line);
    try std.testing.expectEqual(@as(usize, 1), span.start_col);
    try std.testing.expectEqual(@as(usize, 0), span.start_byte);
    try std.testing.expectEqual(@as(usize, src.len - 2), span.end_byte);
}

test "mode follows the file extension" {
    try std.testing.expectEqual(Mode.zon, Mode.fromExtension("build.zig.zon"));
    try std.testing.expectEqual(Mode.zig, Mode.fromExtension("src/main.zig"));
}

test "inTestBlock separates test code from runtime code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "fn f() void {}\ntest \"t\" {\n    _ = f;\n}\n";
    const tree = try Tree.parse(a, try a.dupeSentinel(u8, src, 0), .zig);
    var owned = tree;
    defer owned.deinit();

    var test_node: usize = 0;
    var i: usize = 0;
    while (i < owned.nodeCount()) : (i += 1) {
        if (owned.tag(i) == .test_decl) test_node = i;
    }
    try std.testing.expect(test_node != 0);
    try std.testing.expect(inTestBlock(&owned, test_node));

    var fn_node: usize = 0;
    i = 0;
    while (i < owned.nodeCount()) : (i += 1) {
        if (owned.tag(i) == .fn_decl) fn_node = i;
    }
    try std.testing.expect(!inTestBlock(&owned, fn_node));
}

test "declaredFnNames collects container-scope functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "fn alpha() void {}\nfn beta() void {}\n";
    const tree = try Tree.parse(a, try a.dupeSentinel(u8, src, 0), .zig);
    var owned = tree;
    defer owned.deinit();

    var names: std.StringHashMap(void) = .init(a);
    defer names.deinit();
    try declaredFnNames(&owned, &names);

    try std.testing.expect(names.contains("alpha"));
    try std.testing.expect(names.contains("beta"));
    try std.testing.expect(!names.contains("gamma"));
}
