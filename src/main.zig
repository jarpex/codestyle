const std = @import("std");
const builtin = @import("builtin");
pub const ts = @import("core/ts.zig");
pub const diagnostic = @import("core/diagnostic.zig");
pub const reporter = @import("core/reporter.zig");
pub const runner = @import("core/runner.zig");
pub const interface = @import("lang/interface.zig");
pub const table = @import("core/table.zig");
pub const registry = @import("lang/registry.zig");

pub const CliAction = enum {
    help,
    run,
    err,
};

pub const ParsedArgs = struct {
    action: CliAction,
    format: reporter.Format = .clippy,
    no_color: bool = false,
    profile: table.Profile = .default,
    targets: std.ArrayList([]const u8),

    pub fn deinit(self: *ParsedArgs, allocator: std.mem.Allocator) void {
        for (self.targets.items) |t| allocator.free(t);
        self.targets.deinit(allocator);
    }
};

fn printHelp(io: std.Io) !void {
    const help_text =
        "Usage: codestyle [options] <path1> [path2 ...]\n\n" ++
        "Options:\n" ++
        "  --format=clippy   Clippy-style human-readable terminal output (default)\n" ++
        "  --format=sarif    Standard SARIF v2.1.0 JSON format\n" ++
        "  --profile=NAME    Rule profile: default, strict, migration (default: default)\n" ++
        "  --no-color        Disable ANSI color codes\n" ++
        "  -h, --help        Show this help message\n\n";
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(help_text);
    try stdout_writer.interface.flush();
}

fn parseProfile(name: []const u8) ?table.Profile {
    if (std.mem.eql(u8, name, "default")) return .default;
    if (std.mem.eql(u8, name, "strict")) return .strict;
    if (std.mem.eql(u8, name, "migration")) return .migration;
    return null;
}

pub fn parseArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    env_no_color: bool,
) !ParsedArgs {
    var parsed = ParsedArgs{
        .action = .run,
        .format = .clippy,
        .no_color = env_no_color,
        .targets = std.ArrayList([]const u8).empty,
    };

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            parsed.action = .help;
            return parsed;
        } else if (std.mem.eql(u8, arg, "--format=clippy")) {
            parsed.format = .clippy;
        } else if (std.mem.eql(u8, arg, "--format=sarif")) {
            parsed.format = .sarif;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            if (!builtin.is_test) std.debug.print("Unknown format '{s}'\n", .{arg});
            parsed.action = .err;
            return parsed;
        } else if (std.mem.startsWith(u8, arg, "--profile=")) {
            const name = arg["--profile=".len..];
            parsed.profile = parseProfile(name) orelse {
                if (!builtin.is_test) std.debug.print(
                    "Unknown profile '{s}' (expected default, strict, or migration)\n",
                    .{name},
                );
                parsed.action = .err;
                return parsed;
            };
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            parsed.no_color = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            if (!builtin.is_test) std.debug.print("Unknown option '{s}'\n", .{arg});
            parsed.action = .err;
            return parsed;
        } else {
            try parsed.targets.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (parsed.targets.items.len == 0) {
        if (!builtin.is_test) std.debug.print("Missing target path\n", .{});
        parsed.action = .err;
    }

    return parsed;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var args_iter = std.process.Args.Iterator.initAllocator(init.minimal.args, gpa) catch {
        return 2;
    };
    defer args_iter.deinit();

    _ = args_iter.next(); // Skip executable path

    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(gpa);

    while (args_iter.next()) |arg| {
        try raw_args.append(gpa, arg);
    }

    const env_no_color = init.environ_map.get("NO_COLOR") != null;
    var parsed = parseArgs(gpa, raw_args.items, env_no_color) catch {
        return 2;
    };
    defer parsed.deinit(gpa);

    switch (parsed.action) {
        .help => {
            try printHelp(io);
            return 0;
        },
        .err => return 2,
        .run => {
            var stdout_buffer: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
            const out = &stdout_writer.interface;
            var stderr_buffer: [1024]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
            const exit_code = try runner.run(gpa, io, out, parsed.targets.items, .{
                .format = parsed.format,
                .no_color = parsed.no_color,
                .profile = parsed.profile,
                .err_out = &stderr_writer.interface,
            });
            try out.flush();
            return exit_code;
        },
    }
}

test "cli parser options" {
    const args1 = [_][]const u8{ "--format=sarif", "--no-color", "path/to/code" };
    var p1 = try parseArgs(std.testing.allocator, &args1, false);
    defer p1.deinit(std.testing.allocator);

    try std.testing.expectEqual(CliAction.run, p1.action);
    try std.testing.expectEqual(reporter.Format.sarif, p1.format);
    try std.testing.expect(p1.no_color);
    try std.testing.expectEqual(@as(usize, 1), p1.targets.items.len);
    try std.testing.expectEqualStrings("path/to/code", p1.targets.items[0]);

    const args_help = [_][]const u8{"-h"};
    var p_help = try parseArgs(std.testing.allocator, &args_help, false);
    defer p_help.deinit(std.testing.allocator);
    try std.testing.expectEqual(CliAction.help, p_help.action);

    const args_invalid = [_][]const u8{"--unknown-flag"};
    var p_invalid = try parseArgs(std.testing.allocator, &args_invalid, false);
    defer p_invalid.deinit(std.testing.allocator);
    try std.testing.expectEqual(CliAction.err, p_invalid.action);

    const args_empty = [_][]const u8{};
    var p_empty = try parseArgs(std.testing.allocator, &args_empty, false);
    defer p_empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(CliAction.err, p_empty.action);
}

test {
    _ = ts;
    _ = diagnostic;
    _ = reporter;
    _ = runner;
    _ = interface;
    _ = registry;
}
