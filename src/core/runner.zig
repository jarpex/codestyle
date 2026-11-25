const std = @import("std");
const ts = @import("ts.zig");
const diagnostic = @import("diagnostic.zig");
const table = @import("table.zig");
const reporter = @import("reporter.zig");
const registry = @import("../lang/registry.zig");
const interface = @import("../lang/interface.zig");
const Context = interface.Context;
const config = @import("config.zig");

pub const RunnerOptions = struct {
    format: reporter.Format = .clippy,
    no_color: bool = false,
    profile: table.Profile = .default,
    /// Root that `.codestyle.json` is read from.
    config_root: []const u8 = ".",
    /// Optional stream for fatal errors; defaults to `out` when null.
    err_out: ?*std.Io.Writer = null,
};

fn shouldSkipDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, ".zig-pkg-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "zig-pkg") or
        std.mem.eql(u8, name, "vendor");
}

/// Order diagnostics by file, then line, then column, then rule id.
/// Rendering walks the sorted slice, so output is deterministic.
fn lessThan(_: void, a: diagnostic.Diagnostic, b: diagnostic.Diagnostic) bool {
    if (a.span.start_line != b.span.start_line) return a.span.start_line < b.span.start_line;
    if (a.span.start_col != b.span.start_col) return a.span.start_col < b.span.start_col;
    return std.mem.order(u8, a.rule_id, b.rule_id) == .lt;
}

fn sortDiagnostics(diags: []diagnostic.Diagnostic) void {
    std.mem.sort(diagnostic.Diagnostic, diags, {}, lessThan);
}

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    targets: []const []const u8,
    options: RunnerOptions,
) !u8 {
    const err_out = options.err_out orelse out;
    var file_paths = std.ArrayList([]const u8).empty;
    defer {
        for (file_paths.items) |p| gpa.free(p);
        file_paths.deinit(gpa);
    }

    for (targets) |target_path| {
        collectFiles(gpa, io, target_path, &file_paths) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try err_out.print("Error accessing path '{s}': {t}\n", .{ target_path, err });
            try err_out.flush();
            return 2;
        };
    }

    // Report files in path order so runs are reproducible.
    std.mem.sort([]const u8, file_paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    if (file_paths.items.len == 0) {
        return 0;
    }

    // One config load per run: the allowlists are project-wide and live in an
    // arena that the run owns.
    var config_arena = std.heap.ArenaAllocator.init(gpa);
    defer config_arena.deinit();

    const allowlists = config.load(config_arena.allocator(), io, options.config_root) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try err_out.print("Error reading .codestyle.json: {t}\n", .{err});
        try err_out.flush();
        return 2;
    };

    var suppressed_rule_counts: std.StringHashMap(usize) = .init(gpa);
    defer suppressed_rule_counts.deinit();
    var suppressed_total: usize = 0;

    var file_arena = std.heap.ArenaAllocator.init(gpa);
    defer file_arena.deinit();

    var parser: ?*ts.c.TSParser = null;
    defer {
        if (parser) |p| ts.c.ts_parser_delete(p);
    }

    var file_reports = std.ArrayList(reporter.FileReport).empty;
    defer {
        if (options.format == .sarif) {
            for (file_reports.items) |rep| {
                gpa.free(rep.file_path);
                for (rep.diagnostics) |d| {
                    var mutable_d = d;
                    mutable_d.deinit(gpa);
                }
                gpa.free(rep.diagnostics);
            }
        }
        file_reports.deinit(gpa);
    }

    var has_errors = false;

    for (file_paths.items) |file_path| {
        const ext = std.Io.Dir.path.extension(file_path);
        const lang = registry.findByExtension(ext) orelse continue;

        _ = file_arena.reset(.retain_capacity);
        const arena_allocator = file_arena.allocator();

        const max = lang.max_file_size;
        const source = std.Io.Dir.cwd()
            .readFileAlloc(io, file_path, arena_allocator, .limited(max)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try err_out.print("Error reading file '{s}': {t}\n", .{ file_path, err });
            try err_out.flush();
            return 2;
        };

        var diags = std.ArrayList(diagnostic.Diagnostic).empty;
        var ctx = Context{
            .allocator = arena_allocator,
            .file_path = file_path,
            .source = source,
            .diagnostics = &diags,
            .profile = options.profile,
            .text = lang.text,
            .io = io,
            .allow = allowlists,
        };

        lang.run_raw_checks(&ctx) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try err_out.print("codestyle: rule pass failed on '{s}': {t}\n", .{ file_path, err });
            try err_out.flush();
            return 2;
        };

        if (!ctx.aborted) {
            const ast_ok = try runAstPass(
                lang,
                &ctx,
                &parser,
                err_out,
                file_path,
                source,
            );
            if (!ast_ok) return 2;
        }

        sortDiagnostics(diags.items);

        for (diags.items) |d| {
            if (d.severity == .err and !d.suppressed) has_errors = true;
        }

        if (options.format == .clippy) {
            try emitClippyFile(
                arena_allocator,
                out,
                diags.items,
                file_path,
                source,
                options.no_color,
                &suppressed_rule_counts,
                &suppressed_total,
            );
        } else {
            // Deep-clone into the GPA: the arena dies with this iteration.
            const cloned_diags = try gpa.alloc(diagnostic.Diagnostic, diags.items.len);
            var cloned_count: usize = 0;
            errdefer {
                for (cloned_diags[0..cloned_count]) |*d| d.deinit(gpa);
                gpa.free(cloned_diags);
            }
            for (diags.items, 0..) |d, i| {
                cloned_diags[i] = try d.clone(gpa);
                cloned_count += 1;
            }
            const cloned_path = try gpa.dupe(u8, file_path);
            errdefer gpa.free(cloned_path);
            try file_reports.append(gpa, .{
                .file_path = cloned_path,
                .source = "",
                .diagnostics = cloned_diags,
            });
        }
    }

    if (options.format == .sarif) {
        try reporter.renderSarifReport(gpa, out, file_reports.items, options.profile);
        try out.flush();
    }

    if (options.format == .clippy and suppressed_total > 0) {
        try printSuppressionSummary(out, &suppressed_rule_counts, suppressed_total);
    }

    return if (has_errors) 1 else 0;
}

/// One line naming how many findings a directive removed and for which rules.
fn printSuppressionSummary(
    out: anytype,
    counts: *std.StringHashMap(usize),
    total: usize,
) !void {
    try out.print("suppressed: {d} finding(s) [", .{total});

    var it = counts.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try out.print(", ", .{});
        try out.print("{s}: {d}", .{ entry.key_ptr.*, entry.value_ptr.* });
        first = false;
    }
    try out.print("]\n", .{});
}

fn collectFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    target_path: []const u8,
    file_paths: *std.ArrayList([]const u8),
) !void {
    const stat_res = std.Io.Dir.cwd().statFile(io, target_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => |e| return e,
    };

    if (stat_res.kind == .file) {
        const duped = try gpa.dupe(u8, target_path);
        errdefer gpa.free(duped);
        try file_paths.append(gpa, duped);
        return;
    }

    if (stat_res.kind != .directory) return;

    var dir = try std.Io.Dir.cwd().openDir(io, target_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (shouldSkipDir(entry.basename)) walker.leave(io);
            continue;
        }
        if (entry.kind != .file) continue;
        const full_sub_path = try std.Io.Dir.path.join(
            gpa,
            &.{ target_path, entry.path },
        );
        errdefer gpa.free(full_sub_path);
        try file_paths.append(gpa, full_sub_path);
    }
}

fn runAstPass(
    lang: interface.Language,
    ctx: *Context,
    parser: *?*ts.c.TSParser,
    err_out: *std.Io.Writer,
    file_path: []const u8,
    source: []const u8,
) !bool {
    const grammar_fn = lang.get_grammar orelse {
        lang.run_ast_checks(ctx, null) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try err_out.print("codestyle: rule pass failed on '{s}': {t}\n", .{ file_path, err });
            try err_out.flush();
            return false;
        };
        return true;
    };

    if (parser.* == null) parser.* = ts.c.ts_parser_new();
    const p = parser.*.?;
    const grammar = grammar_fn() orelse {
        try err_out.print("codestyle: grammar initialization failed for '{s}'\n", .{file_path});
        try err_out.flush();
        return false;
    };
    _ = ts.c.ts_parser_set_language(p, grammar);
    const tree = ts.c.ts_parser_parse_string(p, null, source.ptr, @intCast(source.len));
    if (tree == null) return true;
    defer ts.c.ts_tree_delete(tree);

    lang.run_ast_checks(ctx, tree) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try err_out.print("codestyle: rule pass failed on '{s}': {t}\n", .{ file_path, err });
        try err_out.flush();
        return false;
    };
    return true;
}

fn emitClippyFile(
    arena_allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    diags: []const diagnostic.Diagnostic,
    file_path: []const u8,
    source: []const u8,
    no_color: bool,
    suppressed_rule_counts: *std.StringHashMap(usize),
    suppressed_total: *usize,
) !void {
    for (diags) |d| {
        if (d.severity == .off) continue;
        if (d.suppressed) {
            const seen = suppressed_rule_counts.get(d.rule_id) orelse 0;
            try suppressed_rule_counts.put(d.rule_id, seen + 1);
            suppressed_total.* += 1;
            continue;
        }
        try reporter.renderClippyDiagnostic(
            arena_allocator,
            out,
            d,
            file_path,
            source,
            no_color,
        );
    }
    try out.flush();
}
