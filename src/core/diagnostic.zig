const std = @import("std");

pub const Severity = enum {
    /// Registered but not reported under the active profile.
    off,
    err,
    warning,
    note,

    pub fn toSarifLevel(self: Severity) []const u8 {
        return switch (self) {
            .off => "none",
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
    }

    pub fn toClippyPrefix(self: Severity) []const u8 {
        return switch (self) {
            .off => "none",
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
    }
};

pub const Span = struct {
    start_byte: usize,
    end_byte: usize,
    start_line: usize, // 1-based
    start_col: usize, // 1-based
    end_line: usize, // 1-based
    end_col: usize, // 1-based
};

/// Where a diagnostic's string slices live. Rules build diagnostics with
/// static literals or per-file arena slices, so `deinit` must not free them.
/// Only `clone` produces a `.heap` diagnostic, and only those are freeable.
pub const Storage = enum {
    static_literal,
    heap,
};

pub const Diagnostic = struct {
    rule_id: []const u8,
    severity: Severity,
    message: []const u8,
    span: Span,
    help: ?[]const u8 = null,
    /// Set when a suppression directive covered this span. The diagnostic is
    /// kept so SARIF can carry it with a suppression entry.
    suppressed: bool = false,
    storage: Storage = .static_literal,

    /// Deep-copy every string into `allocator`. The result owns its slices
    /// and must be released with `deinit` using the same allocator.
    pub fn clone(
        self: Diagnostic,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!Diagnostic {
        const rule_id_copy = try allocator.dupe(u8, self.rule_id);
        errdefer allocator.free(rule_id_copy);

        const message_copy = try allocator.dupe(u8, self.message);
        errdefer allocator.free(message_copy);

        var help_copy: ?[]const u8 = null;
        if (self.help) |h| {
            help_copy = try allocator.dupe(u8, h);
        }

        return Diagnostic{
            .rule_id = rule_id_copy,
            .severity = self.severity,
            .message = message_copy,
            .span = self.span,
            .help = help_copy,
            .suppressed = self.suppressed,
            .storage = .heap,
        };
    }

    /// Release a heap diagnostic. Called on a rule-built diagnostic this is a
    /// no-op, because those slices are owned by the arena or by static storage.
    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        if (self.storage == .static_literal) return;
        allocator.free(self.rule_id);
        allocator.free(self.message);
        if (self.help) |h| allocator.free(h);
        self.storage = .static_literal;
    }
};

test "diagnostic clone detaches strings from the per-file arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rule_id = try a.dupe(u8, "style/line-length");
    const message = try a.dupe(u8, "Line exceeds 80 columns");
    const help = try a.dupe(u8, "Break the line before binary operators");

    const original = Diagnostic{
        .rule_id = rule_id,
        .severity = .err,
        .message = message,
        .span = .{
            .start_byte = 0,
            .end_byte = 4,
            .start_line = 1,
            .start_col = 1,
            .end_line = 1,
            .end_col = 5,
        },
        .help = help,
    };

    const cloned = try original.clone(std.testing.allocator);
    var owned = cloned;
    defer owned.deinit(std.testing.allocator);

    // Drop the arena contents and overwrite the freed bytes. A shallow copy
    // keeps pointers into this block and reads back garbage here.
    _ = arena.reset(.retain_capacity);
    const poison = try a.alloc(u8, 512);
    @memset(poison, 0xff);

    try std.testing.expectEqualStrings("style/line-length", owned.rule_id);
    try std.testing.expectEqualStrings("Line exceeds 80 columns", owned.message);
    try std.testing.expectEqualStrings("Break the line before binary operators", owned.help.?);
    try std.testing.expectEqual(@as(usize, 1), owned.span.start_line);
}

test "diagnostic clone handles a null help note" {
    const original = Diagnostic{
        .rule_id = "style/indent",
        .severity = .warning,
        .message = "Tabs used for indentation instead of 4 spaces",
        .span = .{
            .start_byte = 0,
            .end_byte = 4,
            .start_line = 1,
            .start_col = 1,
            .end_line = 1,
            .end_col = 5,
        },
    };

    const cloned = try original.clone(std.testing.allocator);
    var owned = cloned;
    defer owned.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("style/indent", owned.rule_id);
    try std.testing.expect(owned.help == null);
    try std.testing.expectEqual(Severity.warning, owned.severity);
}

test "diagnostic deinit on a rule-built diagnostic is a no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rule_id = try arena.allocator().dupe(u8, "style/line-length");
    const message = try arena.allocator().dupe(u8, "Line exceeds 80 columns");

    var d = Diagnostic{
        .rule_id = rule_id,
        .severity = .err,
        .message = message,
        .span = .{
            .start_byte = 0,
            .end_byte = 4,
            .start_line = 1,
            .start_col = 1,
            .end_line = 1,
            .end_col = 5,
        },
        .help = "Break the line before binary operators or after commas",
    };

    // Arena-owned slices must survive: the analyzer frees only clones.
    d.deinit(std.testing.allocator);
    d.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("style/line-length", d.rule_id);
    try std.testing.expectEqualStrings("Line exceeds 80 columns", d.message);
    try std.testing.expectEqualStrings(
        "Break the line before binary operators or after commas",
        d.help.?,
    );
    try std.testing.expectEqual(Storage.static_literal, d.storage);
}

test "diagnostic initialization" {
    const d = Diagnostic{
        .rule_id = "style/indent",
        .severity = .warning,
        .span = .{
            .start_byte = 0,
            .end_byte = 4,
            .start_line = 1,
            .start_col = 1,
            .end_line = 1,
            .end_col = 5,
        },
        .message = "Tabs used for indentation instead of 4 spaces",
        .help = "Indent using exactly 4 spaces per logical indentation level",
    };
    try std.testing.expectEqualStrings("style/indent", d.rule_id);
    try std.testing.expectEqual(Severity.warning, d.severity);
    try std.testing.expectEqualStrings("warning", d.severity.toSarifLevel());
    try std.testing.expectEqual(@as(usize, 1), d.span.start_line);
}

test "off severity renders as none and never as an error" {
    try std.testing.expectEqualStrings("none", Severity.off.toSarifLevel());
    try std.testing.expectEqualStrings("none", Severity.off.toClippyPrefix());
}
