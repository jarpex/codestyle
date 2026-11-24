const std = @import("std");
const interface = @import("../interface.zig");
const Context = interface.Context;
const suppression = @import("../../core/suppression.zig");
const text_rules = @import("../../core/text_rules.zig");
const diagnostic = @import("../../core/diagnostic.zig");
const scan = @import("scan.zig");

pub const max_nesting_depth = 200;

/// Why analysis stopped before the AST stage.
pub const Fuse = enum {
    none,
    nul_byte,
    too_deep,
};

/// Result of the raw pass. `fuse` tells the caller to skip AST rules.
///
/// The suppression map is not owned here: `runPass` hands it to the context,
/// where the AST pass reads it, and the per-file arena releases it.
pub const Scan = struct {
    fuse: Fuse = .none,
    rejected: std.ArrayList(suppression.Rejected),

    pub fn deinit(self: *Scan, allocator: std.mem.Allocator) void {
        self.rejected.deinit(allocator);
    }

    pub fn aborted(self: Scan) bool {
        return self.fuse != .none;
    }
};

/// One streaming pass over the source. Fuses run first and cannot be
/// suppressed; the text rules and the suppression map follow.
pub fn runPass(allocator: std.mem.Allocator, ctx: *Context) interface.CheckError!Scan {
    var result: Scan = .{ .rejected = .empty };
    errdefer result.deinit(allocator);

    if (try nulByteFuse(ctx)) {
        result.fuse = .nul_byte;
        return result;
    }
    if (try depthFuse(allocator, ctx)) {
        result.fuse = .too_deep;
        return result;
    }

    // The map lives in the per-file arena so the AST pass can read it; a
    // stack local would dangle once this function returns.
    const stored = try allocator.create(suppression.Map);
    stored.* = try suppression.parse(allocator, ctx.source, .{}, &result.rejected);
    ctx.suppressions = stored;

    for (result.rejected.items) |rejected| {
        try reportRejection(ctx, rejected);
    }

    try text_rules.run(ctx, ctx.text);
    return result;
}

fn reportRejection(ctx: *Context, rejected: suppression.Rejected) interface.CheckError!void {
    const span = diagnostic.Span{
        .start_byte = 0,
        .end_byte = 0,
        .start_line = rejected.line,
        .start_col = 1,
        .end_line = rejected.line,
        .end_col = 1,
    };
    switch (rejected.reason) {
        .misplaced_file_directive => try ctx.report(
            "codestyle/misplaced-file-suppression",
            span,
            "File-level suppression directive appears after non-comment code",
            "Move file suppression directives to the top of the file before any code",
        ),
        .unknown_rule_id => try ctx.report(
            "codestyle/invalid-suppression-id",
            span,
            "Suppression directive specifies an unknown rule ID",
            "Verify spelling of the rule ID against the canonical catalog",
        ),
        .heuristic_without_reason => try ctx.report(
            "codestyle/missing-suppression-reason",
            span,
            "Suppression of a heuristic rule lacks a reason",
            "Add 'reason=...' to the directive so the exception is reviewable",
        ),
        .fuse_not_suppressible => try ctx.report(
            "codestyle/invalid-suppression-id",
            span,
            "Input fuses cannot be suppressed by a directive",
            "Remove the directive and fix the input instead",
        ),
    }
}

fn nulByteFuse(ctx: *Context) interface.CheckError!bool {
    const idx = std.mem.indexOfScalar(u8, ctx.source, 0) orelse return false;

    const lines = scan.LineIndex.init(ctx.allocator, ctx.source) catch {
        return true;
    };
    const pos = lines.lineCol(idx);

    try ctx.report(
        "zig/invalid-nul-byte",
        .{
            .start_byte = idx,
            .end_byte = idx + 1,
            .start_line = pos.line,
            .start_col = pos.col,
            .end_line = pos.line,
            .end_col = pos.col + 1,
        },
        "Source file contains an embedded NUL byte (0x00)",
        "Remove NUL bytes from the source text",
    );
    return true;
}

/// Count `{` and `(` nesting with the tokenizer, so strings and comments do
/// not count. Brackets do not nest the parser and are ignored.
fn depthFuse(allocator: std.mem.Allocator, ctx: *Context) interface.CheckError!bool {
    const source_z = try allocator.dupeSentinel(u8, ctx.source, 0);
    defer allocator.free(source_z);
    const tokens = scan.tokenize(allocator, source_z) catch return true;
    defer allocator.free(tokens);

    const lines = scan.LineIndex.init(ctx.allocator, ctx.source) catch {
        return true;
    };

    var depth: usize = 0;
    for (tokens) |t| {
        switch (t.tag) {
            .l_brace, .l_paren => {
                depth += 1;
                if (depth <= max_nesting_depth) continue;
                const pos = lines.lineCol(t.start);
                try ctx.report(
                    "zig/input-too-deep",
                    .{
                        .start_byte = t.start,
                        .end_byte = t.end,
                        .start_line = pos.line,
                        .start_col = pos.col,
                        .end_line = pos.line,
                        .end_col = pos.col + (t.end - t.start),
                    },
                    "Nesting depth exceeds maximum parser limit of 200",
                    "Refactor deeply nested code structures",
                );
                return true;
            },
            .r_brace, .r_paren => if (depth > 0) {
                depth -= 1;
            },
            else => {},
        }
    }
    return false;
}

test "nul byte aborts the scan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    defer diags.deinit(a);

    const src = try a.dupeSentinel(u8, "const x = 1;\x00const y = 2;\n", 0);
    var ctx = Context{
        .allocator = a,
        .file_path = "test.zig",
        .source = src,
        .diagnostics = &diags,
    };

    var result = try runPass(a, &ctx);
    defer result.deinit(a);

    try std.testing.expectEqual(Fuse.nul_byte, result.fuse);
    try std.testing.expect(result.aborted());
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("zig/invalid-nul-byte", diags.items[0].rule_id);
    try std.testing.expectEqual(@as(usize, 1), diags.items[0].span.start_line);
}

test "nesting deeper than the limit aborts the scan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "const x = ");
    for (0..max_nesting_depth + 10) |_| try src.append(a, '(');
    try src.appendSlice(a, "1");
    for (0..max_nesting_depth + 10) |_| try src.append(a, ')');
    try src.appendSlice(a, ";\n");

    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    defer diags.deinit(a);

    var ctx = Context{
        .allocator = a,
        .file_path = "test.zig",
        .source = try a.dupeSentinel(u8, src.items, 0),
        .diagnostics = &diags,
    };

    var result = try runPass(a, &ctx);
    defer result.deinit(a);

    try std.testing.expectEqual(Fuse.too_deep, result.fuse);
    try std.testing.expectEqualStrings("zig/input-too-deep", diags.items[0].rule_id);
}

test "a clean file reaches the suppression map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    defer diags.deinit(a);

    const src = try a.dupeSentinel(u8, "// codestyle:ignore zig/fn-naming\nfn f() void {}\n", 0);
    var ctx = Context{
        .allocator = a,
        .file_path = "test.zig",
        .source = src,
        .diagnostics = &diags,
    };

    var result = try runPass(a, &ctx);
    defer result.deinit(a);

    try std.testing.expectEqual(Fuse.none, result.fuse);
    // The map is handed to the context for the AST pass to read.
    try std.testing.expect(ctx.suppressions.isSuppressed("zig/fn-naming", 2));
}

test "tab indentation is reported in zig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    defer diags.deinit(a);

    const src = try a.dupeSentinel(u8, "fn f() void {\n\tconst x = 1;\n}\n", 0);
    var ctx = Context{
        .allocator = a,
        .file_path = "test.zig",
        .source = src,
        .diagnostics = &diags,
    };

    var result = try runPass(a, &ctx);
    defer result.deinit(a);

    var found = false;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule_id, "style/indent")) found = true;
    }
    try std.testing.expect(found);
}
