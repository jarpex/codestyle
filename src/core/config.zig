const std = @import("std");

/// Path patterns that opt out of one rule. A pattern matches a file path when
/// it equals the path, ends with the pattern, or contains it.
pub const Allowlists = struct {
    /// Modules that own the C ABI: unchecked casts and `@cImport` are allowed
    /// there and nowhere else. The key keeps the documented name.
    unsafe_casts: []const []const u8 = &.{"src/core/ts.zig"},
    /// Files allowed to use `@"..."` identifiers.
    raw_identifiers: []const []const u8 = &.{ "src/core/ts.zig", "src/lang/c/ast_rules.zig" },
    /// Files allowed to call `std.posix` and `std.os.linux` directly.
    direct_posix: []const []const u8 = &.{"src/core/runner.zig"},
    /// Function names exempt from `zig/fn-naming`, on top of `main` and
    /// C-ABI functions. Entries are exact names, not paths.
    fn_naming: []const []const u8 = &.{},

    pub fn matches(list: []const []const u8, file_path: []const u8) bool {
        for (list) |pattern| {
            if (std.mem.eql(u8, pattern, file_path)) return true;
            if (std.mem.endsWith(u8, file_path, pattern)) return true;
            if (std.mem.find(u8, file_path, pattern) != null) return true;
        }
        return false;
    }

    pub fn allowsFfi(self: Allowlists, file_path: []const u8) bool {
        return matches(self.unsafe_casts, file_path);
    }

    pub fn allowsRawIdentifier(self: Allowlists, file_path: []const u8) bool {
        return matches(self.raw_identifiers, file_path);
    }

    pub fn allowsDirectPosix(self: Allowlists, file_path: []const u8) bool {
        return matches(self.direct_posix, file_path);
    }

    /// True when `name` is listed in `fn_naming`. Entries are exact names.
    pub fn allowsFnName(self: Allowlists, name: []const u8) bool {
        for (self.fn_naming) |allowed| {
            if (std.mem.eql(u8, allowed, name)) return true;
        }
        return false;
    }
};

pub const default_allowlists = Allowlists{};

const config_file = ".codestyle.json";

const FileConfig = struct {
    unsafe_casts: ?[][]const u8 = null,
    raw_identifiers: ?[][]const u8 = null,
    direct_posix: ?[][]const u8 = null,
    fn_naming: ?[][]const u8 = null,
};

/// Load `.codestyle.json` from the project root. A missing file yields the
/// embedded defaults; a file that does not parse is an error, because a
/// silently ignored config makes the run disagree with the author's intent.
///
/// The returned lists are copied into `allocator`, so they outlive the parsed
/// JSON and the caller owns nothing beyond the run.
pub const LoadError = std.Io.Dir.ReadFileAllocError || std.json.ParseError(std.json.Scanner);

pub fn load(allocator: std.mem.Allocator, io: std.Io, root: []const u8) LoadError!Allowlists {
    var result = default_allowlists;

    const path = try std.Io.Dir.path.join(allocator, &.{ root, config_file });
    defer allocator.free(path);

    const text = std.Io.Dir.cwd()
        .readFileAlloc(io, path, allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return err,
    };
    defer allocator.free(text);

    const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    var parsed = try std.json.parseFromSlice(FileConfig, allocator, text, parse_options);
    defer parsed.deinit();

    const cfg = parsed.value;
    result.unsafe_casts = try adopt(allocator, cfg.unsafe_casts, result.unsafe_casts);
    result.raw_identifiers = try adopt(allocator, cfg.raw_identifiers, result.raw_identifiers);
    result.direct_posix = try adopt(allocator, cfg.direct_posix, result.direct_posix);
    result.fn_naming = try adopt(allocator, cfg.fn_naming, result.fn_naming);

    return result;
}

/// Copy a configured list, or keep `fallback` when the key is absent.
fn adopt(
    allocator: std.mem.Allocator,
    configured: ?[][]const u8,
    fallback: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const source = configured orelse return fallback;

    const out = try allocator.alloc([]const u8, source.len);
    for (source, 0..) |item, i| out[i] = try allocator.dupe(u8, item);
    return out;
}

test "embedded defaults cover the FFI boundary module" {
    const a = default_allowlists;
    try std.testing.expect(a.allowsFfi("src/core/ts.zig"));
    try std.testing.expect(a.allowsRawIdentifier("src/core/ts.zig"));
    try std.testing.expect(!a.allowsFfi("src/main.zig"));
    try std.testing.expect(!a.allowsDirectPosix("src/lang/c/ast_rules.zig"));
}

test "pattern match accepts a full path, a suffix and a substring" {
    const list = [_][]const u8{"src/core/ts.zig"};
    try std.testing.expect(Allowlists.matches(&list, "src/core/ts.zig"));
    try std.testing.expect(Allowlists.matches(&list, "/repo/src/core/ts.zig"));
    try std.testing.expect(!Allowlists.matches(&list, "src/core/other.zig"));
}

test "a missing config yields the embedded defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const loaded = try load(a, std.testing.io, "/nonexistent-codestyle-root");
    try std.testing.expect(loaded.allowsFfi("src/core/ts.zig"));
    try std.testing.expectEqual(default_allowlists.raw_identifiers.len, loaded.raw_identifiers.len);
}
