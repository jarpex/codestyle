const std = @import("std");
const ts = @import("../../core/ts.zig");
const table = @import("../../core/table.zig");
const interface = @import("../interface.zig");
const suppression = @import("../../core/suppression.zig");
const diagnostic = @import("../../core/diagnostic.zig");
const Context = interface.Context;
const Language = interface.Language;
pub const raw_rules = @import("raw_rules.zig");
pub const ast_rules = @import("ast_rules.zig");

// Embedded so registry tests never depend on the process working directory.
const raw_rules_embedded = @embedFile("raw_rules.zig");
const ast_rules_embedded = @embedFile("ast_rules.zig");

fn getGrammar() ?*const ts.c.TSLanguage {
    return ts.tree_sitter_c();
}

fn runRawChecks(ctx: *Context) interface.CheckError!void {
    // C directives live in block comments as well as line comments.
    var rejected: std.ArrayList(suppression.Rejected) = .empty;
    defer rejected.deinit(ctx.allocator);
    // The map lives in the per-file arena: the runner resets it after this
    // file, so a stack local would dangle for the AST pass.
    const arena = ctx.allocator;
    const map = try arena.create(suppression.Map);
    map.* = try suppression.parse(ctx.allocator, ctx.source, .{
        .block_open = "/*",
        .block_close = "*/",
    }, &rejected);
    ctx.suppressions = map;

    for (rejected.items) |item| {
        try reportRejection(ctx, item);
    }

    try raw_rules.run(ctx);
}

fn reportRejection(ctx: *Context, item: suppression.Rejected) interface.CheckError!void {
    const span = diagnostic.Span{
        .start_byte = 0,
        .end_byte = 0,
        .start_line = item.line,
        .start_col = 1,
        .end_line = item.line,
        .end_col = 1,
    };
    switch (item.reason) {
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

fn runAstChecks(ctx: *Context, tree: ?*const ts.c.TSTree) interface.CheckError!void {
    const t = tree orelse return;
    const root = ts.c.ts_tree_root_node(t);
    try ast_rules.run(ctx, root);
}

pub const c_language = Language{
    .id = "c",
    .extensions = &.{ ".c", ".h" },
    .get_grammar = getGrammar,
    .run_raw_checks = runRawChecks,
    .run_ast_checks = runAstChecks,
    .text = .{
        .indent = .tabs,
        .max_line_len = 80,
        .line_len_message = "Line exceeds 80 columns",
    },
};

fn isRuleId(candidate: []const u8) bool {
    if (candidate.len == 0) return false;
    var slash: ?usize = null;
    for (candidate, 0..) |ch, i| {
        if (ch == '/') {
            if (slash != null) return false;
            slash = i;
            continue;
        }
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\\') return false;
    }
    const split = slash orelse return false;
    if (split == 0 or split + 1 == candidate.len) return false;
    const family = candidate[0..split];
    const known = [_][]const u8{ "c", "style", "security", "complexity" };
    for (known) |k| {
        if (std.mem.eql(u8, family, k)) return true;
    }
    return false;
}

/// Collect every `"<family>/<name>"` literal from a rule source file.
fn collectSourceRuleIds(
    allocator: std.mem.Allocator,
    src: []const u8,
    ids: *std.ArrayList([]const u8),
) !void {
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] != '"') continue;
        const start = i + 1;
        var end = start;
        while (end < src.len and src[end] != '"') : (end += 1) {}
        if (end >= src.len) break;
        const candidate = src[start..end];
        if (isRuleId(candidate)) {
            try ids.append(allocator, candidate);
        }
        i = end;
    }
}

test "every rule id in the C rule sources is registered" {
    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(std.testing.allocator);

    try collectSourceRuleIds(std.testing.allocator, raw_rules_embedded, &ids);
    try collectSourceRuleIds(std.testing.allocator, ast_rules_embedded, &ids);

    try std.testing.expect(ids.items.len > 0);
    for (ids.items) |id| {
        if (table.findRule(id) == null) {
            std.debug.print(
                "rule id '{s}' is emitted by the C rules but missing from table.zig\n",
                .{id},
            );
            return error.UnregisteredRuleId;
        }
    }
}

/// Run both passes over `src` and return every rule id the C frontend emitted.
fn collectEmittedRuleIds(allocator: std.mem.Allocator, src: []const u8) !std.ArrayList([]const u8) {
    var ids = std.ArrayList([]const u8).empty;

    const parser = ts.c.ts_parser_new();
    defer ts.c.ts_parser_delete(parser);
    _ = ts.c.ts_parser_set_language(parser, getGrammar().?);

    const tree = ts.c.ts_parser_parse_string(parser, null, src.ptr, @intCast(src.len));
    defer ts.c.ts_tree_delete(tree);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var diags = std.ArrayList(@import("../../core/diagnostic.zig").Diagnostic).empty;
    var ctx = Context{
        .allocator = arena.allocator(),
        .file_path = "tests/fixtures/c/invalid.c",
        .source = src,
        .diagnostics = &diags,
    };

    try runRawChecks(&ctx);
    try runAstChecks(&ctx, tree);

    for (diags.items) |d| {
        try ids.append(allocator, d.rule_id);
    }
    return ids;
}

test "every rule id emitted on the C fixture is registered" {
    const src = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/fixtures/c/invalid.c",
        std.testing.allocator,
        .limited(50 * 1024 * 1024),
    ) catch |err| {
        std.debug.print("cannot read fixture: {t}\n", .{err});
        return err;
    };
    defer std.testing.allocator.free(src);

    var ids = try collectEmittedRuleIds(std.testing.allocator, src);
    defer ids.deinit(std.testing.allocator);

    try std.testing.expect(ids.items.len > 0);
    for (ids.items) |id| {
        if (table.findRule(id) == null) {
            std.debug.print(
                "rule id '{s}' was emitted on the fixture but is missing from table.zig\n",
                .{id},
            );
            return error.UnregisteredRuleId;
        }
    }
}

test {
    _ = raw_rules;
    _ = ast_rules;
}
