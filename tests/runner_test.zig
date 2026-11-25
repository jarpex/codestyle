const std = @import("std");
const codestyle = @import("codestyle");
const runner = codestyle.runner;
const reporter = codestyle.reporter;
const table = codestyle.table;

const capture_capacity = 1 << 20;

const Capture = struct {
    exit_code: u8,
    text: []u8,
};

/// Run the analyzer over `path` into a fixed buffer and return the exit code
/// plus everything the reporter wrote. The buffer is arena-owned.
fn runCapture(
    arena: std.mem.Allocator,
    path: []const u8,
    format: reporter.Format,
    profile: table.Profile,
) !Capture {
    const paths = [_][]const u8{path};
    const buf = try arena.alloc(u8, capture_capacity);
    var writer = std.Io.Writer.fixed(buf);
    const exit_code = try runner.run(arena, std.testing.io, &writer, &paths, .{
        .format = format,
        .no_color = true,
        .profile = profile,
    });
    return .{ .exit_code = exit_code, .text = buf[0..writer.end] };
}

test "valid C fixture analyzes clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try runCapture(arena.allocator(), "tests/fixtures/c/valid.c", .clippy, .default);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), result.text.len);
}

test "invalid C fixture reports violations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try runCapture(
        arena.allocator(),
        "tests/fixtures/c/invalid.c",
        .clippy,
        .default,
    );
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "error[") != null);
}

test "clippy output is sorted by line then rule id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try runCapture(
        arena.allocator(),
        "tests/fixtures/c/invalid.c",
        .clippy,
        .default,
    );

    var last_line: usize = 0;
    var lines = std.mem.splitScalar(u8, result.text, '\n');
    while (lines.next()) |line| {
        const marker = "--> tests/fixtures/c/invalid.c:";
        const idx = std.mem.indexOf(u8, line, marker) orelse continue;
        const rest = line[idx + marker.len ..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
        const line_no = std.fmt.parseInt(usize, rest[0..colon], 10) catch continue;
        try std.testing.expect(line_no >= last_line);
        last_line = line_no;
    }
}

test "SARIF output carries results and the full rule catalog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try runCapture(
        arena.allocator(),
        "tests/fixtures/c/invalid.c",
        .sarif,
        .default,
    );
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), result.text, .{});
    defer parsed.deinit();

    const runs = parsed.value.object.get("runs").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), runs.len);

    const driver = runs[0].object.get("tool").?.object.get("driver").?.object;
    const rules = driver.get("rules").?.array.items;
    try std.testing.expectEqual(table.rules.len, rules.len);

    // Every reported result must name a rule the driver declares.
    const results = runs[0].object.get("results").?.array.items;
    try std.testing.expect(results.len > 0);
    for (results) |item| {
        const rule_id = item.object.get("ruleId").?.string;
        try std.testing.expect(table.findRule(rule_id) != null);

        var declared = false;
        for (rules) |rule| {
            if (std.mem.eql(u8, rule.object.get("id").?.string, rule_id)) declared = true;
        }
        try std.testing.expect(declared);
    }
}

test "strict profile escalates style findings to err" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A file whose only violation is style: line too long.
    const result = try runCapture(a, "tests/fixtures/c/style_only.c", .clippy, .default);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "warning[style/line-length]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "error[") == null);

    var strict_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer strict_arena.deinit();
    const strict_result = try runCapture(
        strict_arena.allocator(),
        "tests/fixtures/c/style_only.c",
        .clippy,
        .strict,
    );
    try std.testing.expectEqual(@as(u8, 1), strict_result.exit_code);
    try std.testing.expect(
        std.mem.indexOf(u8, strict_result.text, "error[style/line-length]") != null,
    );
}

test "analyzing a directory skips vendored and cache trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try runCapture(arena.allocator(), "src", .clippy, .default);
    // Self-scan on src/ must pass with zero errors.
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

fn sarifRun(allocator: std.mem.Allocator, path: []const u8) !void {
    const paths = [_][]const u8{path};
    const buf = try allocator.alloc(u8, capture_capacity);
    defer allocator.free(buf);
    var writer = std.Io.Writer.fixed(buf);
    _ = try runner.run(allocator, std.testing.io, &writer, &paths, .{
        .format = .sarif,
        .no_color = true,
    });
    try writer.flush();
}

test "sarif clone loop releases partial results when allocation fails" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        sarifRun,
        .{"tests/fixtures/c/invalid.c"},
    );
}

test "valid Zig fixture analyzes clean under strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try runCapture(
        arena.allocator(),
        "tests/fixtures/zig/valid.zig",
        .clippy,
        .strict,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), result.text.len);
}

test "Zig style_only fixture escalates under strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const def_res = try runCapture(
        arena.allocator(),
        "tests/fixtures/zig/style_only.zig",
        .clippy,
        .default,
    );
    try std.testing.expectEqual(@as(u8, 0), def_res.exit_code);
    try std.testing.expect(
        std.mem.indexOf(u8, def_res.text, "warning[style/line-length]") != null,
    );

    const strict_res = try runCapture(
        arena.allocator(),
        "tests/fixtures/zig/style_only.zig",
        .clippy,
        .strict,
    );
    try std.testing.expectEqual(@as(u8, 1), strict_res.exit_code);
    try std.testing.expect(
        std.mem.indexOf(u8, strict_res.text, "error[style/line-length]") != null,
    );
}

test "invalid Zig fixture reports safety, complexity, and migration rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try runCapture(
        arena.allocator(),
        "tests/fixtures/zig/invalid.zig",
        .clippy,
        .default,
    );
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "zig/no-anyerror") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "zig/block-depth") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "zig/no-catch-unreachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "zig/deprecated-gpa") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "zig/stream-too-long") == null);

    var mig_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer mig_arena.deinit();
    const mig_res = try runCapture(
        mig_arena.allocator(),
        "tests/fixtures/zig/invalid.zig",
        .clippy,
        .migration,
    );
    try std.testing.expectEqual(@as(u8, 1), mig_res.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, mig_res.text, "zig/deprecated-gpa") != null);
    try std.testing.expect(std.mem.indexOf(u8, mig_res.text, "zig/stream-too-long") != null);
}
