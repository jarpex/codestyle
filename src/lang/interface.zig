const std = @import("std");
const ts = @import("../core/ts.zig");
const diagnostic = @import("../core/diagnostic.zig");
const table = @import("../core/table.zig");
const suppression = @import("../core/suppression.zig");
const text_rules = @import("../core/text_rules.zig");
const config = @import("../core/config.zig");

pub const CheckError = error{ OutOfMemory, UnregisteredRule };

pub const Context = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
    diagnostics: *std.ArrayList(diagnostic.Diagnostic),
    profile: table.Profile = .default,
    suppressions: *const suppression.Map = &empty_suppressions,
    text: text_rules.Options = .{},
    /// Set by the runner. Rules that resolve a sibling file, such as the
    /// import alias check, need it; rules that never touch disk ignore it.
    io: ?std.Io = null,
    /// Per-project exceptions loaded from `.codestyle.json`.
    allow: config.Allowlists = config.default_allowlists,
    /// Public symbols declared in C header files across the project.
    c_header_symbols: ?*const std.StringHashMap(void) = null,
    /// Set by `run_raw_checks` when an input fuse aborts further analysis.
    aborted: bool = false,

    /// Severity always comes from the rule table for the active profile.
    /// Rules never pass a literal severity, so a rule cannot silently
    /// downgrade itself or disagree with SARIF metadata.
    pub fn report(
        self: *Context,
        rule_id: []const u8,
        span: diagnostic.Span,
        message: []const u8,
        help: ?[]const u8,
    ) CheckError!void {
        const rule = table.findRule(rule_id) orelse return error.UnregisteredRule;

        const severity = table.severityOf(rule, self.profile);
        if (severity == .off) return;

        if (self.suppressions.isSuppressed(rule_id, span.start_line)) {
            try self.diagnostics.append(self.allocator, .{
                .rule_id = rule_id,
                .severity = severity,
                .span = span,
                .message = message,
                .help = help,
                .suppressed = true,
            });
            return;
        }

        try self.diagnostics.append(self.allocator, .{
            .rule_id = rule_id,
            .severity = severity,
            .span = span,
            .message = message,
            .help = help,
        });
    }
};

pub const empty_suppressions = suppression.Map{};

pub const Language = struct {
    id: []const u8,
    extensions: []const []const u8,
    /// Null for frontends that parse with the host compiler instead of
    /// Tree-sitter. The runner then calls run_ast_checks with a null tree.
    get_grammar: ?*const fn () ?*const ts.c.TSLanguage = null,
    run_raw_checks: *const fn (ctx: *Context) CheckError!void,
    run_ast_checks: *const fn (ctx: *Context, tree: ?*const ts.c.TSTree) CheckError!void,
    /// Per-language caps for the shared text rules and the file size fuse.
    text: text_rules.Options = .{},
    max_file_size: usize = 50 * 1024 * 1024,
};

test "report resolves severity from the table" {
    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    defer diags.deinit(std.testing.allocator);

    var ctx = Context{
        .allocator = std.testing.allocator,
        .file_path = "test.c",
        .source = "int x = 0;\n",
        .diagnostics = &diags,
        .profile = .default,
    };

    try ctx.report("style/line-length", .{
        .start_byte = 0,
        .end_byte = 1,
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 2,
    }, "Line exceeds 80 columns", null);

    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    const rule = table.findRule("style/line-length") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(table.severityOf(rule, .default), diags.items[0].severity);
    try std.testing.expect(!diags.items[0].suppressed);
}

test "report rejects rule ids missing from the table" {
    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    defer diags.deinit(std.testing.allocator);

    var ctx = Context{
        .allocator = std.testing.allocator,
        .file_path = "test.c",
        .source = "int x = 0;\n",
        .diagnostics = &diags,
    };

    try std.testing.expectError(error.UnregisteredRule, ctx.report("c/not-a-real-rule", .{
        .start_byte = 0,
        .end_byte = 1,
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 2,
    }, "message", null));
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "a suppressed rule is recorded but marked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "// codestyle:ignore zig/fn-naming\nfn f() void {}\n";
    var rejected: std.ArrayList(suppression.Rejected) = .empty;
    defer rejected.deinit(a);
    const map = try suppression.parse(a, src, .{}, &rejected);

    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    defer diags.deinit(a);

    var ctx = Context{
        .allocator = a,
        .file_path = "test.zig",
        .source = src,
        .diagnostics = &diags,
        .suppressions = &map,
    };

    try ctx.report("zig/fn-naming", .{
        .start_byte = 0,
        .end_byte = 1,
        .start_line = 2,
        .start_col = 1,
        .end_line = 2,
        .end_col = 2,
    }, "Function name does not use camelCase", null);

    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(diags.items[0].suppressed);
}

test "an off rule reports nothing" {
    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    defer diags.deinit(std.testing.allocator);

    var ctx = Context{
        .allocator = std.testing.allocator,
        .file_path = "test.zig",
        .source = "const x = 1;\n",
        .diagnostics = &diags,
    };

    try ctx.report("zig/allocation-cleanup", .{
        .start_byte = 0,
        .end_byte = 1,
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 2,
    }, "Allocation statement lacks a paired deallocation", null);

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}
