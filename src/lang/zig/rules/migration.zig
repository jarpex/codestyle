const std = @import("std");
const interface = @import("../../interface.zig");
const Context = interface.Context;
const scan = @import("../scan.zig");

const Tree = @import("../ast.zig").Tree;

/// A symbol that 0.16 removed or renamed, with the rule that reports it and
/// the text that replaces it.
pub const Migration = struct {
    needle: []const u8,
    rule_id: []const u8,
    message: []const u8,
    help: []const u8,
    /// Match the whole token, so `Thread` does not fire on `ThreadSafe`.
    whole_token: bool = true,
    /// Only fire when the token is followed by `.init(`.
    requires_init_call: bool = false,
};

pub const migrations = [_]Migration{
    .{
        .needle = "GeneralPurposeAllocator",
        .rule_id = "zig/deprecated-gpa",
        .message = "GeneralPurposeAllocator is replaced by DebugAllocator",
        .help = "Use 'std.heap.DebugAllocator' in 0.16",
    },
    .{
        .needle = "fixedBufferStream",
        .rule_id = "zig/legacy-std-io",
        .message = "std.io.fixedBufferStream is replaced by Io.Reader.fixed and Io.Writer.fixed",
        .help = "Use 'std.Io.Reader.fixed' or 'std.Io.Writer.fixed'",
    },
    .{
        .needle = "getStdOut",
        .rule_id = "zig/legacy-std-io",
        .message = "std.io.getStdOut is removed in 0.16",
        .help = "Use 'std.Io.File.stdout()' with an explicit writer",
    },
    .{
        .needle = "GenericReader",
        .rule_id = "zig/legacy-std-io",
        .message = "GenericReader is replaced by Io.Reader",
        .help = "Use 'std.Io.Reader'",
    },
    .{
        .needle = "GenericWriter",
        .rule_id = "zig/legacy-std-io",
        .message = "GenericWriter is replaced by Io.Writer",
        .help = "Use 'std.Io.Writer'",
    },
    .{
        .needle = "null_writer",
        .rule_id = "zig/removed-std-io-null-writer",
        .message = "std.io.null_writer is removed in 0.16",
        .help = "Write to a sink the caller supplies, or drop the write",
    },
    .{
        .needle = "CountingReader",
        .rule_id = "zig/removed-std-io-null-writer",
        .message = "std.io.CountingReader is removed in 0.16",
        .help = "Count the bytes yourself from the reader you already hold",
    },
    // The bare type name is the 0.16 default and must not be flagged. The
    // rule fires on the stateful `init(allocator)` call only.
    .{
        .needle = "ArrayList",
        .rule_id = "zig/unmanaged-arraylist",
        .message = "ArrayList.init(allocator) is the legacy stateful form",
        .help = "Use 'std.ArrayList(T).empty' and pass the allocator to each call",
        .requires_init_call = true,
    },
    .{
        .needle = "std.once",
        .rule_id = "zig/removed-std-once",
        .message = "std.once is removed in 0.16",
        .help = "Use the Io synchronization primitives",
    },
    .{
        .needle = "Thread.Pool",
        .rule_id = "zig/removed-thread-pool",
        .message = "std.Thread.Pool is replaced by Io.Group",
        .help = "Use 'Io.Group' and 'io.async'",
    },
    .{
        .needle = "SegmentedList",
        .rule_id = "zig/removed-segmented-list",
        .message = "std.SegmentedList is removed in 0.16",
        .help = "Use 'std.ArrayList' or a chunked structure you own",
    },
    .{
        .needle = "Mutex.Recursive",
        .rule_id = "zig/removed-thread-mutex-recursive",
        .message = "std.Thread.Mutex.Recursive is removed in 0.16",
        .help = "Restructure the critical section, or use 'Io.Mutex'",
    },
    .{
        .needle = "declList",
        .rule_id = "zig/removed-meta-decl-list",
        .message = "std.meta.declList is removed in 0.16",
        .help = "Iterate the container's decls with a generated block instead",
    },
    .{
        .needle = "process.Child",
        .rule_id = "zig/renamed-process-child",
        .message = "process.Child is replaced by process.spawn with an Io parameter",
        .help = "Use 'std.process.spawn(io, .{})'",
    },
    .{
        .needle = "std.time",
        .rule_id = "zig/renamed-std-time",
        .message = "std.time moved under Io.Timestamp and Io.Duration",
        .help = "Use 'std.Io.Timestamp' and 'std.Io.Duration'",
    },
    .{
        .needle = "fs.path",
        .rule_id = "zig/renamed-fs-path",
        .message = "std.fs.path moved to std.Io.Dir.path",
        .help = "Use 'std.Io.Dir.path'",
    },
    .{
        .needle = "fs.cwd",
        .rule_id = "zig/renamed-fs-cwd",
        .message = "std.fs.cwd moved to std.Io.Dir.cwd",
        .help = "Use 'std.Io.Dir.cwd()' with an explicit Io parameter",
    },
};

/// `zig/deprecated-gpa`, `zig/legacy-std-io`, the removed-symbol rules and
/// the renamed-symbol rules. Every entry is a note or a warning: none of them
/// breaks the build, the compiler already refuses the old name.
pub fn run(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    for (migrations) |migration| {
        var i: usize = 0;
        while (i < tree.tokens.len) : (i += 1) {
            const token = tree.tokens[i];
            if (token.tag != .identifier and token.tag != .builtin) continue;

            const text = tree.tokenText(i);
            if (!containsSymbol(text, migration.needle)) continue;
            if (migration.requires_init_call and !followedByInit(tree, i)) continue;

            try ctx.report(
                migration.rule_id,
                tree.tokenSpan(i),
                migration.message,
                migration.help,
            );
        }
    }
}

/// True when the token is followed by `.init(`, the stateful constructor. A
/// generic argument list such as `ArrayList(u8)` is stepped over first.
fn followedByInit(tree: *const Tree, i: usize) bool {
    var j = i + 1;
    if (j < tree.tokens.len and tree.tokens[j].tag == .l_paren) {
        const close = matchingParen(tree, j) orelse return false;
        j = close + 1;
    }

    if (j + 2 >= tree.tokens.len) return false;
    if (tree.tokens[j].tag != .period) return false;
    if (tree.tokens[j + 1].tag != .identifier) return false;
    if (!std.mem.eql(u8, tree.tokenText(j + 1), "init")) return false;
    return tree.tokens[j + 2].tag == .l_paren;
}

fn matchingParen(tree: *const Tree, open: usize) ?usize {
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

/// True when `text` mentions `needle` as a whole dotted component, so
/// `std.fs.paths` does not match `fs.path`.
fn containsSymbol(text: []const u8, needle: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, needle)) |idx| {
        const before_ok = idx == 0 or !isSymbolChar(text[idx - 1]);
        const end = idx + needle.len;
        const after_ok = end == text.len or !isSymbolChar(text[end]);
        if (before_ok and after_ok) return true;
        from = idx + 1;
    }
    return false;
}

fn isSymbolChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `zig/renamed-read-file-alloc`: the 0.16 signature takes `io` first and
/// returns `error.StreamTooLong` at the bound.
pub fn readFileAllocOrder(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), "readFileAlloc")) continue;

        var j = i + 1;
        while (j < tree.tokens.len and tree.tokens[j].tag != .l_paren) : (j += 1) {}
        if (j >= tree.tokens.len) continue;
        j += 1;
        if (j >= tree.tokens.len) continue;

        // The old form starts with the allocator: `readFileAlloc(allocator, ...)`.
        const first = tree.tokenText(j);
        const looks_old = std.mem.eql(u8, first, "allocator") or
            std.mem.eql(u8, first, "gpa") or
            std.mem.eql(u8, first, "ally");
        if (!looks_old) continue;

        try ctx.report(
            "zig/renamed-read-file-alloc",
            tree.tokenSpan(i),
            "readFileAlloc called with the pre-0.16 argument order",
            "Call 'readFileAlloc(io, path, allocator, .limited(max))' and " ++
                "handle error.StreamTooLong",
        );
    }
}

/// Wave 2 quiet semantic migration checks from `docs/zig-0.16-migration.md`.
pub fn wave2(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    const has_rename = hasToken(tree, "rename");
    const has_mmap = hasToken(tree, "MemoryMap") or hasToken(tree, "memoryMap");
    const has_clock = hasToken(tree, "Clock") or hasToken(tree, "clock_gettime");

    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const tag = tree.tokens[i].tag;
        if (tag == .period and i + 1 < tree.tokens.len and tree.tokens[i + 1].tag == .identifier) {
            const field = tree.tokenText(i + 1);
            if (isErrorField(tree, i, "FileTooBig")) {
                try ctx.report(
                    "zig/stream-too-long",
                    tree.tokenSpan(i + 1),
                    "error.FileTooBig replaced by error.StreamTooLong in 0.16",
                    "Handle 'error.StreamTooLong' from bounded 0.16 reads",
                );
            } else if (has_rename and isErrorField(tree, i, "PathAlreadyExists")) {
                try ctx.report(
                    "zig/dir-not-empty",
                    tree.tokenSpan(i + 1),
                    "Dir.rename returns error.DirNotEmpty instead of error.PathAlreadyExists",
                    "Handle 'error.DirNotEmpty' for non-empty target directories",
                );
            } else if (std.mem.eql(u8, field, "atime") and !isOptionalGuarded(tree, i + 1)) {
                try ctx.report(
                    "zig/atime-optional",
                    tree.tokenSpan(i + 1),
                    "stat.atime is optional (?Timestamp) in 0.16",
                    "Unwrap with 'orelse', '.?', or 'if (stat.atime) |atime|'",
                );
            } else if (has_mmap and isErrorField(tree, i, "NotOpenForReading")) {
                try ctx.report(
                    "zig/memory-map-errors",
                    tree.tokenSpan(i + 1),
                    "File.MemoryMap WASI error set changed in 0.16",
                    "Handle 'error.IsDir' for directory mappings",
                );
            } else if (isErrorField(tree, i, "ClockUnsupported") or
                (has_clock and isErrorField(tree, i, "Unexpected")))
            {
                try ctx.report(
                    "zig/clock-error-sets",
                    tree.tokenSpan(i + 1),
                    "Clock error.ClockUnsupported removed in 0.16",
                    "Remove dead clock error branches and query resolution ahead of time",
                );
            }
        }

        if (tag == .identifier) {
            const tok = tree.tokenText(i);
            if (std.mem.eql(u8, tok, "sign") and isDottedCall(tree, i, "math") and
                !hasAsCastBefore(tree, i))
            {
                try ctx.report(
                    "zig/math-sign-type",
                    tree.tokenSpan(i),
                    "std.math.sign returns narrowed integer type in 0.16",
                    "Wrap with '@as(T, ...)' when the caller expects the input type",
                );
            } else if (std.mem.eql(u8, tok, "componentIterator") and
                isFallibleComponentIter(tree, i))
            {
                try ctx.report(
                    "zig/component-iterator-infallible",
                    tree.tokenSpan(i),
                    "componentIterator is infallible in 0.16",
                    "Remove 'try' or 'catch' around componentIterator",
                );
            } else if ((std.mem.eql(u8, tok, "extract") and isDottedCall(tree, i, "tar")) or
                (std.mem.eql(u8, tok, "pipeToFileSystem") and isFollowedByLParen(tree, i)))
            {
                try ctx.report(
                    "zig/tar-traversal-sanitize",
                    tree.tokenSpan(i),
                    "tar.extract automatically sanitizes path traversal in 0.16",
                    "Inspect archive extraction handling for invalid path components",
                );
            }
        }
    }
}

fn hasToken(tree: *const Tree, needle: []const u8) bool {
    for (tree.tokens, 0..) |tok, idx| {
        if (tok.tag == .identifier and std.mem.eql(u8, tree.tokenText(idx), needle)) return true;
    }
    return false;
}

fn isErrorField(tree: *const Tree, period_idx: usize, name: []const u8) bool {
    if (period_idx == 0) return false;
    if (tree.tokens[period_idx - 1].tag != .keyword_error) return false;
    return std.mem.eql(u8, tree.tokenText(period_idx + 1), name);
}

fn isOptionalGuarded(tree: *const Tree, field_idx: usize) bool {
    if (field_idx + 1 < tree.tokens.len) {
        const next = tree.tokens[field_idx + 1].tag;
        if (next == .keyword_orelse or next == .question_mark) return true;
        if (next == .period and field_idx + 2 < tree.tokens.len and
            tree.tokens[field_idx + 2].tag == .question_mark) return true;
    }
    var j = field_idx;
    while (j > 0) {
        j -= 1;
        const t = tree.tokens[j].tag;
        if (t == .keyword_if) return true;
        if (t == .semicolon or t == .l_brace or t == .r_brace) break;
    }
    return false;
}

fn isDottedCall(tree: *const Tree, fn_idx: usize, receiver: []const u8) bool {
    if (fn_idx < 2) return false;
    if (tree.tokens[fn_idx - 1].tag != .period) return false;
    if (tree.tokens[fn_idx - 2].tag != .identifier) return false;
    if (!std.mem.eql(u8, tree.tokenText(fn_idx - 2), receiver)) return false;
    return isFollowedByLParen(tree, fn_idx);
}

fn isFollowedByLParen(tree: *const Tree, idx: usize) bool {
    return idx + 1 < tree.tokens.len and tree.tokens[idx + 1].tag == .l_paren;
}

fn hasAsCastBefore(tree: *const Tree, idx: usize) bool {
    var j = idx;
    while (j > 0) {
        j -= 1;
        const t = tree.tokens[j].tag;
        if (t == .builtin and std.mem.eql(u8, tree.tokenText(j), "@as")) return true;
        if (t == .semicolon or t == .l_brace or t == .r_brace) break;
    }
    return false;
}

fn isFallibleComponentIter(tree: *const Tree, idx: usize) bool {
    var j = idx;
    while (j > 0) {
        j -= 1;
        const t = tree.tokens[j].tag;
        if (t == .keyword_try) return true;
        if (t == .semicolon or t == .l_brace or t == .r_brace or t == .equal) break;
    }
    var k = idx + 1;
    while (k < tree.tokens.len) : (k += 1) {
        const t = tree.tokens[k].tag;
        if (t == .keyword_catch) return true;
        if (t == .semicolon or t == .l_brace or t == .r_brace) break;
    }
    return false;
}

test "migration table has no duplicate needles per rule" {
    for (migrations, 0..) |m, i| {
        for (migrations[i + 1 ..]) |other| {
            const same_rule = std.mem.eql(u8, m.rule_id, other.rule_id);
            const same_needle = std.mem.eql(u8, m.needle, other.needle);
            try std.testing.expect(!(same_rule and same_needle));
        }
    }
}

test "every migration rule id is registered" {
    const table = @import("../../../core/table.zig");
    for (migrations) |m| {
        try std.testing.expect(table.findRule(m.rule_id) != null);
    }
    try std.testing.expect(table.findRule("zig/renamed-read-file-alloc") != null);
    try std.testing.expect(table.findRule("zig/stream-too-long") != null);
    try std.testing.expect(table.findRule("zig/dir-not-empty") != null);
    try std.testing.expect(table.findRule("zig/atime-optional") != null);
    try std.testing.expect(table.findRule("zig/math-sign-type") != null);
    try std.testing.expect(table.findRule("zig/memory-map-errors") != null);
    try std.testing.expect(table.findRule("zig/clock-error-sets") != null);
    try std.testing.expect(table.findRule("zig/component-iterator-infallible") != null);
    try std.testing.expect(table.findRule("zig/tar-traversal-sanitize") != null);
}

test "wave2 migration rules detect 0.16 quiet semantic changes" {
    const src: [:0]const u8 =
        \\fn f(stat: anytype, tar: anytype, p: anytype) !void {
        \\    _ = error.FileTooBig;
        \\    _ = rename;
        \\    _ = error.PathAlreadyExists;
        \\    _ = stat.atime;
        \\    _ = std.math.sign(1);
        \\    _ = MemoryMap;
        \\    _ = error.NotOpenForReading;
        \\    _ = error.ClockUnsupported;
        \\    _ = try p.componentIterator();
        \\    _ = tar.extract();
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
    try wave2(&ctx, &tree);

    const expected = [_][]const u8{
        "zig/stream-too-long",
        "zig/dir-not-empty",
        "zig/atime-optional",
        "zig/math-sign-type",
        "zig/memory-map-errors",
        "zig/clock-error-sets",
        "zig/component-iterator-infallible",
        "zig/tar-traversal-sanitize",
    };
    for (expected) |id| {
        var found = false;
        for (diags.items) |d| {
            if (std.mem.eql(u8, d.rule_id, id)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "symbol containment finds dotted names" {
    try std.testing.expect(containsSymbol("std.fs.path", "fs.path"));
    try std.testing.expect(containsSymbol("std.process.Child", "process.Child"));
    // A longer sibling name is not a match.
    try std.testing.expect(!containsSymbol("std.fs.paths", "fs.path"));
}
