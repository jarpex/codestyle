const std = @import("std");
const diagnostic = @import("../../core/diagnostic.zig");
const interface = @import("../interface.zig");

pub const Token = struct {
    tag: std.zig.Token.Tag,
    start: usize,
    end: usize,
};

/// One tokenization pass. Comments and whitespace are gone, so a token index
/// is also the position in the code.
pub fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) interface.CheckError![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);

    var tokenizer: std.zig.Tokenizer = .init(source);
    while (true) {
        const t = tokenizer.next();
        if (t.tag == .eof) break;
        try tokens.append(allocator, .{ .tag = t.tag, .start = t.loc.start, .end = t.loc.end });
    }
    return tokens.toOwnedSlice(allocator);
}

/// Build `Token` slices directly from `std.zig.Ast.tokens` without re-lexing.
pub fn tokensFromAst(
    allocator: std.mem.Allocator,
    ast: *const std.zig.Ast,
) interface.CheckError![]Token {
    const tags = ast.tokens.items(.tag);
    const starts = ast.tokens.items(.start);
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);
    try tokens.ensureTotalCapacity(allocator, tags.len);

    for (tags, starts, 0..) |tag, start, i| {
        if (tag == .eof) break;
        const len = ast.tokenSlice(@intCast(i)).len;
        tokens.appendAssumeCapacity(.{ .tag = tag, .start = start, .end = start + len });
    }
    return tokens.toOwnedSlice(allocator);
}

/// Byte offset to 1-based line and column. Columns count bytes, which matches
/// the span columns the reporters print.
pub const LineIndex = struct {
    source: []const u8,
    starts: []const usize,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) interface.CheckError!LineIndex {
        var starts: std.ArrayList(usize) = .empty;
        errdefer starts.deinit(allocator);
        try starts.append(allocator, 0);
        for (source, 0..) |ch, i| {
            if (ch == '\n') try starts.append(allocator, i + 1);
        }
        return .{ .source = source, .starts = try starts.toOwnedSlice(allocator) };
    }

    pub fn lineCol(self: LineIndex, offset: usize) struct { line: usize, col: usize } {
        var lo: usize = 0;
        var hi: usize = self.starts.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts[mid] <= offset) lo = mid else hi = mid;
        }
        return .{ .line = lo + 1, .col = offset - self.starts[lo] + 1 };
    }

    pub fn span(self: LineIndex, start: usize, end: usize) diagnostic.Span {
        const a = self.lineCol(start);
        const b = if (end > start) self.lineCol(end - 1) else a;
        return .{
            .start_byte = start,
            .end_byte = end,
            .start_line = a.line,
            .start_col = a.col,
            .end_line = b.line,
            .end_col = b.col + 1,
        };
    }

    /// Text of the line that contains `offset`, without the line terminator.
    pub fn lineText(self: LineIndex, offset: usize) []const u8 {
        const start = self.starts[self.lineCol(offset).line - 1];
        var end = start;
        while (end < self.source.len and self.source[end] != '\n') : (end += 1) {}
        return std.mem.trimEnd(u8, self.source[start..end], "\r");
    }

    /// Line that precedes the line containing `offset`, or null at the top.
    pub fn prevLine(self: LineIndex, offset: usize) ?[]const u8 {
        const line = self.lineCol(offset).line;
        if (line <= 1) return null;
        const start = self.starts[line - 2];
        var end = start;
        while (end < self.source.len and self.source[end] != '\n') : (end += 1) {}
        return std.mem.trimEnd(u8, self.source[start..end], "\r");
    }
};

pub fn isWord(tag: std.zig.Token.Tag) bool {
    return tag == .identifier;
}

pub fn isEof(tag: std.zig.Token.Tag) bool {
    return tag == .eof;
}

test "tokenize drops comments and whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tokens = try tokenize(a, "const x: u8 = 1; // note\n");
    try std.testing.expectEqual(@as(usize, 7), tokens.len);
    try std.testing.expectEqual(std.zig.Token.Tag.keyword_const, tokens[0].tag);
    try std.testing.expectEqual(@as(usize, 0), tokens[0].start);
    try std.testing.expectEqual(@as(usize, 5), tokens[0].end);
}

test "line index maps offsets to one-based positions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lines = try LineIndex.init(a, "ab\ncde\n");
    const first = lines.lineCol(0);
    try std.testing.expectEqual(@as(usize, 1), first.line);
    try std.testing.expectEqual(@as(usize, 1), first.col);

    const second = lines.lineCol(4);
    try std.testing.expectEqual(@as(usize, 2), second.line);
    try std.testing.expectEqual(@as(usize, 2), second.col);

    const span = lines.span(3, 6);
    try std.testing.expectEqual(@as(usize, 2), span.start_line);
    try std.testing.expectEqual(@as(usize, 1), span.start_col);
    try std.testing.expectEqual(@as(usize, 2), span.end_line);
    try std.testing.expectEqual(@as(usize, 4), span.end_col);
}

test "line text and previous line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lines = try LineIndex.init(a, "one\ntwo\nthree\n");
    try std.testing.expectEqualStrings("two", lines.lineText(4));
    try std.testing.expectEqualStrings("one", lines.prevLine(4).?);
    try std.testing.expect(lines.prevLine(0) == null);
}
