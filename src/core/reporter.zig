const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const table = @import("table.zig");

pub const Format = enum {
    clippy,
    sarif,
};

pub const FileReport = struct {
    file_path: []const u8,
    source: []const u8,
    diagnostics: []const diagnostic.Diagnostic,
};

/// Normalize tab characters: replace tab with spaces up to next tab stop (default 4).
pub fn normalizeTabs(allocator: std.mem.Allocator, line: []const u8, tab_width: usize) ![]const u8 {
    var col: usize = 0;
    for (line) |ch| {
        if (ch == '\t') {
            const spaces = tab_width - (col % tab_width);
            col += spaces;
        } else {
            col += 1;
        }
    }

    var result = try allocator.alloc(u8, col);
    var write_idx: usize = 0;
    col = 0;
    for (line) |ch| {
        if (ch == '\t') {
            const spaces = tab_width - (col % tab_width);
            for (0..spaces) |_| {
                result[write_idx] = ' ';
                write_idx += 1;
            }
            col += spaces;
        } else {
            result[write_idx] = ch;
            write_idx += 1;
            col += 1;
        }
    }
    return result;
}

/// Map a 1-based raw column to normalized column based on tabs
pub fn mapColumnWithTabs(line: []const u8, raw_col_1based: usize, tab_width: usize) usize {
    var raw_col: usize = 1;
    var norm_col: usize = 1;
    for (line) |ch| {
        if (raw_col >= raw_col_1based) break;
        if (ch == '\t') {
            const spaces = tab_width - ((norm_col - 1) % tab_width);
            norm_col += spaces;
        } else {
            norm_col += 1;
        }
        raw_col += 1;
    }
    return norm_col;
}

pub fn extractLine(source: []const u8, target_line_1based: usize) []const u8 {
    var cur_line: usize = 1;
    var start_idx: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            if (cur_line == target_line_1based) {
                var line = source[start_idx..i];
                if (line.len > 0 and line[line.len - 1] == '\r') {
                    line = line[0 .. line.len - 1];
                }
                return line;
            }
            cur_line += 1;
            start_idx = i + 1;
        }
    }
    if (cur_line == target_line_1based and start_idx <= source.len) {
        var line = source[start_idx..];
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        return line;
    }
    return "";
}

pub fn renderClippyDiagnostic(
    allocator: std.mem.Allocator,
    out: anytype,
    d: diagnostic.Diagnostic,
    file_path: []const u8,
    source: []const u8,
    no_color: bool,
) !void {
    const color_red = if (no_color) "" else "\x1b[1;31m";
    const color_yellow = if (no_color) "" else "\x1b[1;33m";
    const color_blue = if (no_color) "" else "\x1b[1;34m";
    const color_cyan = if (no_color) "" else "\x1b[1;36m";
    const color_reset = if (no_color) "" else "\x1b[0m";

    const sev_str = d.severity.toClippyPrefix();
    const sev_color = switch (d.severity) {
        .err => color_red,
        .warning => color_yellow,
        else => color_cyan,
    };

    try out.print("{s}{s}[{s}]{s}: {s}\n", .{
        sev_color,
        sev_str,
        d.rule_id,
        color_reset,
        d.message,
    });

    try out.print("  {s}-->{s} {s}:{d}:{d}\n", .{
        color_blue,
        color_reset,
        file_path,
        d.span.start_line,
        d.span.start_col,
    });

    var line_num_buf: [32]u8 = undefined;
    const line_num_str = std.fmt.bufPrint(&line_num_buf, "{d}", .{d.span.start_line}) catch "1";
    const pad_len = line_num_str.len;

    for (0..pad_len) |_| try out.writeByte(' ');
    try out.print(" {s}|{s}\n", .{ color_blue, color_reset });

    const raw_line = extractLine(source, d.span.start_line);
    const norm_line = try normalizeTabs(allocator, raw_line, 4);
    defer allocator.free(norm_line);

    try out.print("{s}{s}{s} {s}|{s} {s}\n", .{
        color_blue,
        line_num_str,
        color_reset,
        color_blue,
        color_reset,
        norm_line,
    });

    for (0..pad_len) |_| try out.writeByte(' ');
    try out.print(" {s}|{s} ", .{ color_blue, color_reset });

    const norm_start_col = mapColumnWithTabs(raw_line, d.span.start_col, 4);
    var norm_end_col = if (d.span.end_line == d.span.start_line)
        mapColumnWithTabs(raw_line, d.span.end_col, 4)
    else
        norm_line.len + 1;

    if (norm_end_col <= norm_start_col) {
        norm_end_col = norm_start_col + 1;
    }
    const caret_count = norm_end_col - norm_start_col;

    if (norm_start_col > 1) {
        for (0..norm_start_col - 1) |_| {
            try out.writeByte(' ');
        }
    }

    try out.print("{s}", .{sev_color});
    for (0..caret_count) |_| {
        try out.writeByte('^');
    }
    try out.print("{s}\n", .{color_reset});

    if (d.help) |help_text| {
        for (0..pad_len) |_| try out.writeByte(' ');
        try out.print(" {s}={s} {s}help:{s} {s}\n", .{
            color_blue,
            color_reset,
            color_cyan,
            color_reset,
            help_text,
        });
    }

    try out.print("\n", .{});
}

/// SARIF v2.1.0 payload. The JSON schema is external, so its camelCase field
/// names live in `jsonStringify`; the Zig fields stay snake_case.
const sarif_schema_host = "https://raw.githubusercontent.com/oasis-tcs/sarif-spec";
const sarif_schema_path = "/master/Schemata/sarif-schema-2.1.0.json";
const sarif_schema_uri = sarif_schema_host ++ sarif_schema_path;

pub const SarifReport = struct {
    version: []const u8 = "2.1.0",
    schema: []const u8 = sarif_schema_uri,
    runs: []const SarifRun,

    pub fn jsonStringify(self: SarifReport, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("$schema");
        try jw.write(self.schema);
        try jw.objectField("version");
        try jw.write(self.version);
        try jw.objectField("runs");
        try jw.write(self.runs);
        try jw.endObject();
    }
};

pub const SarifRun = struct {
    tool: SarifTool,
    results: []const SarifResult,
};

pub const SarifTool = struct {
    driver: SarifDriver,
};

pub const SarifRule = struct {
    id: []const u8,
    short_description: SarifMessage,
    default_configuration: SarifConfiguration,

    pub fn jsonStringify(self: SarifRule, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("shortDescription");
        try jw.write(self.short_description);
        try jw.objectField("defaultConfiguration");
        try jw.write(self.default_configuration);
        try jw.endObject();
    }
};

pub const SarifConfiguration = struct {
    level: []const u8,
};

/// Build the SARIF rule descriptors from the canonical rule table.
/// Level comes from the table entry for the active profile.
pub fn buildSarifRules(allocator: std.mem.Allocator, profile: table.Profile) ![]const SarifRule {
    const rules = try allocator.alloc(SarifRule, table.rules.len);
    for (table.rules, 0..) |r, i| {
        rules[i] = .{
            .id = r.id,
            .short_description = .{ .text = r.description },
            .default_configuration = .{
                .level = table.severityOf(r, profile).toSarifLevel(),
            },
        };
    }
    return rules;
}

pub const SarifDriver = struct {
    name: []const u8 = "codestyle",
    version: []const u8 = "1.0.0",
    information_uri: []const u8 = "https://suckless.ru",
    rules: []const SarifRule = &.{},

    pub fn jsonStringify(self: SarifDriver, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("version");
        try jw.write(self.version);
        try jw.objectField("informationUri");
        try jw.write(self.information_uri);
        try jw.objectField("rules");
        try jw.write(self.rules);
        try jw.endObject();
    }
};

pub const SarifSuppression = struct {
    kind: []const u8 = "inSource",
};

pub const SarifResult = struct {
    rule_id: []const u8,
    level: []const u8,
    message: SarifMessage,
    locations: []const SarifLocation,
    /// Present only when a suppression directive covered the span.
    suppressions: []const SarifSuppression = &.{},

    pub fn jsonStringify(self: SarifResult, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("ruleId");
        try jw.write(self.rule_id);
        try jw.objectField("level");
        try jw.write(self.level);
        try jw.objectField("message");
        try jw.write(self.message);
        try jw.objectField("locations");
        try jw.write(self.locations);
        if (self.suppressions.len > 0) {
            try jw.objectField("suppressions");
            try jw.write(self.suppressions);
        }
        try jw.endObject();
    }
};

pub const SarifMessage = struct {
    text: []const u8,
};

pub const SarifLocation = struct {
    physical_location: SarifPhysicalLocation,

    pub fn jsonStringify(self: SarifLocation, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("physicalLocation");
        try jw.write(self.physical_location);
        try jw.endObject();
    }
};

pub const SarifPhysicalLocation = struct {
    artifact_location: SarifArtifactLocation,
    region: SarifRegion,

    pub fn jsonStringify(self: SarifPhysicalLocation, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("artifactLocation");
        try jw.write(self.artifact_location);
        try jw.objectField("region");
        try jw.write(self.region);
        try jw.endObject();
    }
};

pub const SarifArtifactLocation = struct {
    uri: []const u8,
};

pub const SarifRegion = struct {
    start_line: usize,
    start_column: usize,
    end_line: usize,
    end_column: usize,

    pub fn jsonStringify(self: SarifRegion, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("startLine");
        try jw.write(self.start_line);
        try jw.objectField("startColumn");
        try jw.write(self.start_column);
        try jw.objectField("endLine");
        try jw.write(self.end_line);
        try jw.objectField("endColumn");
        try jw.write(self.end_column);
        try jw.endObject();
    }
};

pub fn renderSarifReport(
    allocator: std.mem.Allocator,
    out: anytype,
    reports: []const FileReport,
    profile: table.Profile,
) !void {
    var total_results: usize = 0;
    for (reports) |rep| {
        for (rep.diagnostics) |d| {
            if (d.severity != .off) total_results += 1;
        }
    }

    var results = try allocator.alloc(SarifResult, total_results);
    defer allocator.free(results);

    var locs = try allocator.alloc(SarifLocation, total_results);
    defer allocator.free(locs);

    const suppressed_entries = [_]SarifSuppression{.{}};

    const sarif_rules = try buildSarifRules(allocator, profile);
    defer allocator.free(sarif_rules);

    var idx: usize = 0;
    for (reports) |rep| {
        for (rep.diagnostics) |d| {
            if (d.severity == .off) continue;
            locs[idx] = .{
                .physical_location = .{
                    .artifact_location = .{ .uri = rep.file_path },
                    .region = .{
                        .start_line = d.span.start_line,
                        .start_column = d.span.start_col,
                        .end_line = d.span.end_line,
                        .end_column = d.span.end_col,
                    },
                },
            };
            results[idx] = .{
                .rule_id = d.rule_id,
                .level = d.severity.toSarifLevel(),
                .message = .{ .text = d.message },
                .locations = locs[idx .. idx + 1],
                .suppressions = if (d.suppressed) &suppressed_entries else &.{},
            };
            idx += 1;
        }
    }

    const run_item = SarifRun{
        .tool = .{
            .driver = .{ .rules = sarif_rules },
        },
        .results = results,
    };
    const runs_slice = [_]SarifRun{run_item};
    const sarif_obj = SarifReport{
        .runs = &runs_slice,
    };

    try std.json.Stringify.value(sarif_obj, .{ .whitespace = .indent_2 }, out);
    try out.writeByte('\n');
}

test "normalizeTabs replaces tabs with proper spaces" {
    const line = "\tint x = 1;";
    const norm = try normalizeTabs(std.testing.allocator, line, 4);
    defer std.testing.allocator.free(norm);
    try std.testing.expectEqualStrings("    int x = 1;", norm);
}

test "mapColumnWithTabs maps 1-based column correctly" {
    const line = "\tint x;";
    try std.testing.expectEqual(@as(usize, 1), mapColumnWithTabs(line, 1, 4));
    try std.testing.expectEqual(@as(usize, 5), mapColumnWithTabs(line, 2, 4));
}

test "clippy reporter renders diagnostic" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const d = diagnostic.Diagnostic{
        .rule_id = "security/unsafe-call",
        .severity = .err,
        .span = .{
            .start_byte = 0,
            .end_byte = 4,
            .start_line = 1,
            .start_col = 1,
            .end_line = 1,
            .end_col = 5,
        },
        .message = "Call to gets() is forbidden",
        .help = "Use fgets() instead",
    };
    try renderClippyDiagnostic(
        std.testing.allocator,
        &aw.writer,
        d,
        "src/test.c",
        "gets(buf);\n",
        true,
    );
    const output = aw.written();
    const header = "error[security/unsafe-call]: Call to gets() is forbidden";
    try std.testing.expect(std.mem.indexOf(u8, output, header) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--> src/test.c:1:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "^^^^") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "= help: Use fgets() instead") != null);
}

test "sarif reporter serialization" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const diags = [_]diagnostic.Diagnostic{
        .{
            .rule_id = "style/no-trailing-whitespace",
            .severity = .warning,
            .span = .{
                .start_byte = 10,
                .end_byte = 12,
                .start_line = 2,
                .start_col = 5,
                .end_line = 2,
                .end_col = 7,
            },
            .message = "Trailing whitespace detected",
            .help = null,
        },
    };
    const reports = [_]FileReport{
        .{
            .file_path = "foo.c",
            .source = "int x = 0;\nfoo  \n",
            .diagnostics = &diags,
        },
    };
    try renderSarifReport(std.testing.allocator, &aw.writer, &reports, .default);
    const json_str = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"version\": \"2.1.0\"") != null);
    const rule_key = "\"ruleId\": \"style/no-trailing-whitespace\"";
    try std.testing.expect(std.mem.indexOf(u8, json_str, rule_key) != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"level\": \"warning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"startLine\": 2") != null);
}

test "sarif driver emits every table rule with its profile level" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    const reports = [_]FileReport{
        .{
            .file_path = "foo.c",
            .source = "int x = 0;\n",
            .diagnostics = &.{},
        },
    };

    try renderSarifReport(std.testing.allocator, &aw.writer, &reports, .default);
    const json_str = aw.written();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const runs = root.get("runs").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), runs.len);

    const driver = runs[0].object.get("tool").?.object.get("driver").?.object;
    try std.testing.expectEqualStrings("codestyle", driver.get("name").?.string);
    const uri = driver.get("informationUri").?.string;
    try std.testing.expectEqualStrings("https://suckless.ru", uri);

    const rules = driver.get("rules").?.array.items;
    try std.testing.expectEqual(table.rules.len, rules.len);

    for (table.rules) |expected| {
        var found = false;
        for (rules) |rule| {
            const id = rule.object.get("id").?.string;
            if (!std.mem.eql(u8, id, expected.id)) continue;
            found = true;
            const text = rule.object.get("shortDescription").?.object.get("text").?.string;
            try std.testing.expectEqualStrings(expected.description, text);
            const level = rule.object.get("defaultConfiguration").?.object.get("level").?.string;
            try std.testing.expectEqualStrings(expected.default_severity.toSarifLevel(), level);
        }
        try std.testing.expect(found);
    }
}

test "sarif rule levels follow the active profile" {
    const strict_rules = try buildSarifRules(std.testing.allocator, .strict);
    defer std.testing.allocator.free(strict_rules);

    for (table.rules, 0..) |expected, i| {
        const want = table.severityOf(expected, .strict).toSarifLevel();
        try std.testing.expectEqualStrings(want, strict_rules[i].default_configuration.level);
    }
}
