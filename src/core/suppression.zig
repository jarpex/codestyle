const std = @import("std");
const table = @import("table.zig");
const interface = @import("../lang/interface.zig");

pub const Kind = enum {
    /// Suppresses the named rule for the rest of the file.
    file,
    /// Suppresses the named rule on one line.
    line,
};

pub const Entry = struct {
    rule_id: []const u8,
    kind: Kind,
    /// 1-based line the directive applies to. 0 for a file directive.
    line: usize,
};

/// Why a directive was rejected. `reason` names the rule for the two
/// rule-specific rejections and is null otherwise.
pub const Rejected = struct {
    line: usize,
    reason: Reason,
};

pub const Reason = enum {
    misplaced_file_directive,
    unknown_rule_id,
    heuristic_without_reason,
    fuse_not_suppressible,
};

/// Every directive found in one file. Rule ids point into the per-file arena,
/// so the map dies with the file it describes.
pub const Map = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Map, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn isSuppressed(self: *const Map, rule_id: []const u8, line: usize) bool {
        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.rule_id, rule_id)) continue;
            switch (entry.kind) {
                .file => return true,
                .line => if (entry.line == line) return true,
            }
        }
        return false;
    }
};

/// Comment syntax that may introduce a directive. Zig uses `//` only; C99 also
/// accepts `/* ... */` on one line.
pub const Options = struct {
    block_open: []const u8 = "",
    block_close: []const u8 = "",
};

const line_marker = "codestyle:ignore";
const file_marker = "codestyle:ignore-file";

/// Parse every suppression directive in `source`. Directives the grammar
/// rejects are appended to `rejected` instead of the map, so the caller
/// reports them without this module knowing about diagnostics.
pub fn parse(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
    rejected: *std.ArrayList(Rejected),
) interface.CheckError!Map {
    var map: Map = .{};
    errdefer map.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 1;
    var seen_code = false;

    while (lines.next()) |raw_line| : (line_no += 1) {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        // A directive is either the whole trimmed line (a comment-only line)
        // or the trailing comment of a code line.
        const own_line = directiveBody(trimmed, options);
        const trailing = trailingDirectiveBody(trimmed, options);

        if (own_line == null and trailing == null) {
            seen_code = true;
            continue;
        }

        if (own_line == null) {
            // The code line keeps seen_code set, then its trailing comment is read.
            seen_code = true;
            const tbody = trailing orelse continue;
            if (takeMarker(file_marker, tbody) != null) {
                try rejected.append(allocator, .{
                    .line = line_no,
                    .reason = .misplaced_file_directive,
                });
            } else if (takeMarker(line_marker, tbody)) |args| {
                try addEntries(allocator, &map, args, .line, line_no, rejected, line_no);
            }
            continue;
        }

        const body = own_line.?;
        if (takeMarker(file_marker, body)) |args| {
            if (seen_code) {
                try rejected.append(allocator, .{
                    .line = line_no,
                    .reason = .misplaced_file_directive,
                });
                continue;
            }
            try addEntries(allocator, &map, args, .file, 0, rejected, line_no);
            continue;
        }
        if (takeMarker(line_marker, body)) |args| {
            try addEntries(allocator, &map, args, .line, line_no + 1, rejected, line_no);
        }
    }

    return map;
}

fn isOwnLineComment(trimmed: []const u8) bool {
    return std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*");
}

fn directiveBody(trimmed: []const u8, options: Options) ?[]const u8 {
    if (std.mem.startsWith(u8, trimmed, "//")) {
        return stripCommentMarker(trimmed[2..]);
    }
    if (options.block_open.len > 0 and
        std.mem.startsWith(u8, trimmed, options.block_open) and
        std.mem.endsWith(u8, trimmed, options.block_close))
    {
        const inner = trimmed[options.block_open.len .. trimmed.len - options.block_close.len];
        return std.mem.trim(u8, inner, " \t");
    }
    return null;
}

/// Trailing comment of a code line: the text after the first `//` or
/// `options.block_open` outside string literals.
fn trailingDirectiveBody(trimmed: []const u8, options: Options) ?[]const u8 {
    const line_idx = commentStart(trimmed, "//");
    const block_idx = if (options.block_open.len > 0)
        commentStart(trimmed, options.block_open)
    else
        null;

    if (block_idx) |bi| {
        if (line_idx == null or bi < line_idx.?) {
            if (bi == 0) return null;
            const after = trimmed[bi + options.block_open.len ..];
            const end_rel = std.mem.indexOf(u8, after, options.block_close) orelse return null;
            return std.mem.trim(u8, after[0..end_rel], " \t");
        }
    }
    const li = line_idx orelse return null;
    if (li == 0) return null;
    return stripCommentMarker(trimmed[li + 2 ..]);
}

fn stripCommentMarker(body: []const u8) []const u8 {
    var text = std.mem.trim(u8, body, " \t");
    if (std.mem.startsWith(u8, text, "!")) text = std.mem.trim(u8, text[1..], " \t");
    return text;
}

/// Byte index of `marker` outside string literals (handling `\"` and `\\`).
fn commentStart(line: []const u8, marker: []const u8) ?usize {
    if (marker.len == 0) return null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '"') {
            i = skipStringLiteral(line, i);
            continue;
        }
        if (std.mem.startsWith(u8, line[i..], marker)) return i;
    }
    return null;
}

fn skipStringLiteral(line: []const u8, open_quote: usize) usize {
    var i = open_quote + 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\' and i + 1 < line.len) {
            i += 1;
            continue;
        }
        if (line[i] == '"') return i;
    }
    return line.len - 1;
}

/// Match `marker` at the head of `text` and return what follows it.
fn takeMarker(marker: []const u8, text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, marker)) return null;
    const rest = text[marker.len..];
    if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\t') return null;
    return rest;
}

fn addEntries(
    allocator: std.mem.Allocator,
    map: *Map,
    args: []const u8,
    kind: Kind,
    target_line: usize,
    rejected: *std.ArrayList(Rejected),
    line_no: usize,
) interface.CheckError!void {
    var text = std.mem.trim(u8, args, " \t");
    var has_reason = false;
    if (std.mem.indexOf(u8, text, "reason=")) |idx| {
        has_reason = text[idx + "reason=".len ..].len > 0;
        text = std.mem.trimEnd(u8, text[0..idx], " \t");
    }

    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |item| {
        const id = std.mem.trim(u8, item, " \t");
        if (id.len == 0) continue;

        if (table.findRule(id) == null) {
            try rejected.append(allocator, .{ .line = line_no, .reason = .unknown_rule_id });
            continue;
        }
        if (table.isFuse(id)) {
            try rejected.append(allocator, .{ .line = line_no, .reason = .fuse_not_suppressible });
            continue;
        }
        if (table.isHeuristic(id) and !has_reason) {
            const entry = Rejected{ .line = line_no, .reason = .heuristic_without_reason };
            try rejected.append(allocator, entry);
            continue;
        }
        try map.entries.append(allocator, .{ .rule_id = id, .kind = kind, .line = target_line });
    }
}

const ParseResult = struct { map: Map, rejected: std.ArrayList(Rejected) };

fn parseTest(allocator: std.mem.Allocator, src: []const u8, options: Options) !ParseResult {
    var rejected: std.ArrayList(Rejected) = .empty;
    const map = try parse(allocator, src, options, &rejected);
    return .{ .map = map, .rejected = rejected };
}

test "line directive suppresses only the next line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "fn f() void {}\n// codestyle:ignore zig/fn-naming\nfn g() void {}\n";
    var r = try parseTest(a, src, .{});
    defer r.map.deinit(a);
    defer r.rejected.deinit(a);

    try std.testing.expect(r.map.isSuppressed("zig/fn-naming", 3));
    try std.testing.expect(!r.map.isSuppressed("zig/fn-naming", 2));
    try std.testing.expect(!r.map.isSuppressed("zig/type-naming", 3));
    try std.testing.expectEqual(@as(usize, 0), r.rejected.items.len);
}

test "trailing directive suppresses its own line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = try parseTest(a, "const x = 1; // codestyle:ignore zig/var-naming\n", .{});
    defer r.map.deinit(a);
    defer r.rejected.deinit(a);

    try std.testing.expect(r.map.isSuppressed("zig/var-naming", 1));
    try std.testing.expect(!r.map.isSuppressed("zig/var-naming", 2));
}

test "file directive suppresses every line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "//! codestyle:ignore-file zig/fn-naming\nfn a() void {}\nfn b() void {}\n";
    var r = try parseTest(a, src, .{});
    defer r.map.deinit(a);
    defer r.rejected.deinit(a);

    try std.testing.expect(r.map.isSuppressed("zig/fn-naming", 2));
    try std.testing.expect(r.map.isSuppressed("zig/fn-naming", 3));
    try std.testing.expect(!r.map.isSuppressed("zig/type-naming", 2));
}

test "file directive after code is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = try parseTest(a, "const x = 1;\n//! codestyle:ignore-file zig/fn-naming\n", .{});
    defer r.map.deinit(a);
    defer r.rejected.deinit(a);

    try std.testing.expectEqual(@as(usize, 0), r.map.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.rejected.items.len);
    try std.testing.expectEqual(Reason.misplaced_file_directive, r.rejected.items[0].reason);
}

test "unknown rule id is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = try parseTest(a, "// codestyle:ignore zig/no-such-rule\nconst x = 1;\n", .{});
    defer r.map.deinit(a);
    defer r.rejected.deinit(a);

    try std.testing.expectEqual(Reason.unknown_rule_id, r.rejected.items[0].reason);
}

test "heuristic rule without a reason is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "// codestyle:ignore zig/checked-casts\nconst x = @intCast(1);\n";
    var bare = try parseTest(a, src, .{});
    defer bare.map.deinit(a);
    defer bare.rejected.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), bare.map.entries.items.len);
    try std.testing.expectEqual(Reason.heuristic_without_reason, bare.rejected.items[0].reason);

    const with_reason = "// codestyle:ignore zig/checked-casts reason=repr stable\n" ++
        "const x = @intCast(1);\n";
    var kept = try parseTest(a, with_reason, .{});
    defer kept.map.deinit(a);
    defer kept.rejected.deinit(a);
    try std.testing.expect(kept.map.isSuppressed("zig/checked-casts", 2));
}

test "block comment carries a directive for C99" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "/* codestyle:ignore-file c/no-vla */\nint f(int n) { int a[n]; }\n";
    var r = try parseTest(a, src, .{
        .block_open = "/*",
        .block_close = "*/",
    });
    defer r.map.deinit(a);
    defer r.rejected.deinit(a);

    try std.testing.expect(r.map.isSuppressed("c/no-vla", 2));
}

test "fuses cannot be suppressed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The fuse ids are valid rules but a directive naming one is rejected, so
    // no entry ever shields a fuse.
    var r = try parseTest(a, "//! codestyle:ignore-file zig/invalid-nul-byte\n", .{});
    defer r.map.deinit(a);
    defer r.rejected.deinit(a);

    try std.testing.expect(!r.map.isSuppressed("zig/invalid-nul-byte", 1));
    try std.testing.expectEqual(Reason.fuse_not_suppressible, r.rejected.items[0].reason);
}

test "escaped quotes in string, C trailing block directive, and file heuristic reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zig_src = "const s = \"a \\\" // b\"; // codestyle:ignore zig/var-naming\n";
    var rz = try parseTest(a, zig_src, .{});
    defer rz.map.deinit(a);
    defer rz.rejected.deinit(a);
    try std.testing.expect(rz.map.isSuppressed("zig/var-naming", 1));

    const c_src = "int x = 1; /* codestyle:ignore c/explicit-int-types */\n";
    var rc = try parseTest(a, c_src, .{ .block_open = "/*", .block_close = "*/" });
    defer rc.map.deinit(a);
    defer rc.rejected.deinit(a);
    try std.testing.expect(rc.map.isSuppressed("c/explicit-int-types", 1));

    const file_src = "//! codestyle:ignore-file zig/checked-casts\n";
    var rf = try parseTest(a, file_src, .{});
    defer rf.map.deinit(a);
    defer rf.rejected.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), rf.rejected.items.len);
    try std.testing.expectEqual(Reason.heuristic_without_reason, rf.rejected.items[0].reason);
}
