const std = @import("std");
const diagnostic = @import("diagnostic.zig");

pub const Profile = enum {
    default,
    strict,
    migration,
};

pub const RuleDef = struct {
    id: []const u8,
    default_severity: diagnostic.Severity,
    strict_severity: ?diagnostic.Severity = null,
    migration_severity: ?diagnostic.Severity = null,
    description: []const u8,
};

/// Canonical registry of every rule any frontend can emit.
/// Severity lives here and nowhere else: Context.report reads it from this
/// table for the active profile, so a rule cannot disagree with the SARIF
/// metadata for the same profile.
pub const rules = [_]RuleDef{
    // Shared raw text rules (src/core/text_rules.zig)
    .{
        .id = "style/indent",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Indentation does not match the language indent style",
    },
    .{
        .id = "style/line-length",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Line exceeds the column limit",
    },
    .{
        .id = "style/line-endings",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "CRLF line endings detected",
    },
    .{
        .id = "style/trailing-whitespace",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Line contains trailing whitespace before newline",
    },

    // Suppression grammar (src/core/suppression.zig)
    .{
        .id = "codestyle/misplaced-file-suppression",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "File-level suppression directive appears after non-comment code",
    },
    .{
        .id = "codestyle/invalid-suppression-id",
        .default_severity = .warning,
        .strict_severity = .warning,
        .description = "Suppression directive specifies an unknown rule ID",
    },
    .{
        .id = "codestyle/missing-suppression-reason",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Suppression of a heuristic rule lacks a reason",
    },

    // C99 raw text rules (src/lang/c/raw_rules.zig)
    .{
        .id = "c/posix-source-first-line",
        .default_severity = .err,
        .description = "POSIX feature test macro must be defined on the first line",
    },

    // C99 AST rules: architecture
    .{
        .id = "c/no-vla",
        .default_severity = .err,
        .description = "Variable Length Array (VLA) is forbidden",
    },
    .{
        .id = "c/no-subroutine-abort",
        .default_severity = .err,
        .description = "Subroutine must not terminate the process directly",
    },
    // C99 AST rules: naming and layout
    .{
        .id = "c/no-camel-case",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Identifier uses camelCase or mixed case",
    },
    .{
        .id = "c/return-var-name",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Primary return status variable must be named 'res'",
    },
    // C99 AST rules: braces and formatting
    .{
        .id = "style/mandatory-braces",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Control block body must be enclosed in braces '{ ... }'",
    },
    .{
        .id = "style/brace-placement",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Invalid brace placement",
    },
    .{
        .id = "style/operator-linebreak",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Binary operator placed at the end of a broken line",
    },
    // C99 AST rules: types and scope
    .{
        .id = "c/explicit-int-types",
        .default_severity = .err,
        .description = "Bare C integer type with platform-dependent size is forbidden",
    },
    .{
        .id = "c/declarations-at-top",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Local variable must be declared at the very top of the function body",
    },
    .{
        .id = "c/uninitialized-local",
        .default_severity = .err,
        .description = "Local variable declared at function top must be explicitly initialized",
    },
    .{
        .id = "c/loop-counter-scope",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Loop counter assigned instead of declared inside the for header",
    },
    .{
        .id = "c/const-lookup-tables",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Initialized lookup array or table is not marked 'const'",
    },
    .{
        .id = "c/internal-linkage",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Global symbol lacks 'static' internal linkage specifier",
    },
    // C99 AST rules: security and system calls
    .{
        .id = "c/infinite-loop-for",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Use 'for (;;)' for infinite loops instead of 'while (1)'",
    },
    .{
        .id = "security/safe-realloc",
        .default_severity = .err,
        .description = "Direct reassignment of pointer in 'realloc' leaks memory on failure",
    },
    .{
        .id = "security/assert-no-side-effects",
        .default_severity = .err,
        .description = "Expression inside 'assert()' has side effects lost under -DNDEBUG",
    },
    .{
        .id = "security/no-post-overflow-check",
        .default_severity = .err,
        .description = "Post-addition overflow check relies on undefined signed overflow",
    },
    .{
        .id = "security/eintr-loop",
        .default_severity = .err,
        .description = "Interruptible blocking syscall is not wrapped in an EINTR retry loop",
    },
    .{
        .id = "security/cloexec-required",
        .default_severity = .err,
        .description = "File descriptor or socket opened without close-on-exec flag",
    },
    .{
        .id = "security/banned-functions",
        .default_severity = .err,
        .description = "Call to banned unsafe standard library routine",
    },
    .{
        .id = "security/no-plain-memset-scrub",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Plain 'memset' before return or cleanup may be " ++
            "optimized away by the compiler",
    },
    // C99 AST rules: arithmetic and macros
    .{
        .id = "c/bitwise-pow2",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Multiplication or division by a constant power of two",
    },
    .{
        .id = "c/local-macro-undef",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Function-local macro is not undefined after use",
    },
    // C99 AST rules: complexity
    .{
        .id = "complexity/max-nesting-depth",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Control flow nesting depth exceeds maximum limit of 3",
    },

    // Zig style rules (src/lang/zig/rules/style.zig)
    .{
        .id = "zig/type-naming",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Type identifier does not use TitleCase",
    },
    .{
        .id = "zig/fn-naming",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Function name does not use camelCase",
    },
    .{
        .id = "zig/var-naming",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Variable or parameter name does not use snake_case",
    },
    .{
        .id = "zig/error-tag-naming",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Error tag does not use TitleCase",
    },
    .{
        .id = "zig/enum-tag-naming",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Enum tag does not use snake_case",
    },
    .{
        .id = "zig/import-alias-naming",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Import alias does not match the target file name",
    },
    .{
        .id = "zig/file-naming",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Source filename does not use snake_case",
    },
    .{
        .id = "zig/no-raw-identifiers",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Raw identifier @\"...\" used outside FFI bindings",
    },

    // Zig safety rules (src/lang/zig/rules/safe.zig)
    .{
        .id = "zig/no-catch-unreachable",
        .default_severity = .err,
        .strict_severity = .err,
        .description = "Use of 'catch unreachable' is forbidden",
    },
    .{
        .id = "zig/no-swallowed-errors",
        .default_severity = .err,
        .strict_severity = .err,
        .description = "Error union result is discarded with an empty catch block",
    },
    .{
        .id = "zig/no-runtime-safety-off",
        .default_severity = .err,
        .strict_severity = .err,
        .description = "Runtime safety checks disabled with @setRuntimeSafety(false)",
    },
    .{
        .id = "zig/no-panic-in-lib",
        .default_severity = .err,
        .strict_severity = .err,
        .description = "Call to @panic() in library code",
    },
    .{
        .id = "zig/no-bare-unreachable",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Bare 'unreachable' in library code",
    },
    .{
        .id = "zig/no-anyerror",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Explicit 'anyerror' type in a function signature is prohibited",
    },
    .{
        .id = "zig/unsafe-casts",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Unchecked pointer or bit cast outside the FFI boundary module",
    },
    .{
        .id = "zig/wrapping-ops-doc",
        .default_severity = .warning,
        .strict_severity = .warning,
        .description = "Wrapping arithmetic operator lacks an explanatory comment",
    },
    .{
        .id = "zig/no-debug-in-lib",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Debug print or compile log remains in non-executable code",
    },
    .{
        .id = "zig/no-cimport-outside-ffi",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "@cImport located outside the designated FFI boundary module",
    },
    .{
        .id = "zig/no-global-var",
        .default_severity = .err,
        .strict_severity = .err,
        .description = "Mutable 'var' declared at file or namespace scope",
    },
    .{
        .id = "zig/no-exit-in-lib",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "std.process.exit called outside the main entry point",
    },
    .{
        .id = "zig/no-post-overflow-check",
        .default_severity = .err,
        .strict_severity = .err,
        .description = "Post-addition overflow check after the wrap",
    },
    .{
        .id = "zig/assert-no-side-effects",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Assertion expression has a side effect",
    },
    .{
        .id = "zig/no-undefined-struct",
        .default_severity = .off,
        .strict_severity = .note,
        .description = "Value initialised with 'undefined'",
    },
    .{
        .id = "zig/checked-casts",
        .default_severity = .off,
        .strict_severity = .warning,
        .description = "Narrowing cast without a bounds check",
    },

    // Zig memory rules (src/lang/zig/rules/mem.zig)
    .{
        .id = "zig/unbounded-read",
        .default_severity = .err,
        .strict_severity = .err,
        .description = "Stream read allocation without a byte bound",
    },
    .{
        .id = "zig/no-global-allocator",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Library function reaches for a global allocator",
    },
    .{
        .id = "zig/allocation-cleanup",
        .default_severity = .off,
        .strict_severity = .note,
        .description = "Allocation statement lacks a paired deallocation",
    },
    .{
        .id = "zig/no-recursion",
        .default_severity = .off,
        .strict_severity = .warning,
        .description = "Directly recursive function call without a depth bound",
    },

    // Zig async IO rules (src/lang/zig/rules/io.zig)
    .{
        .id = "zig/io-parameter-threading",
        .default_severity = .off,
        .strict_severity = .warning,
        .description = "I/O operation runs without an explicit std.Io parameter",
    },
    .{
        .id = "zig/writer-flush",
        .default_severity = .off,
        .strict_severity = .warning,
        .description = "Buffered writer is not flushed on every exit path",
    },
    .{
        .id = "zig/async-cancel",
        .default_severity = .off,
        .strict_severity = .warning,
        .description = "Async task has no cancellation or await on exit",
    },
    .{
        .id = "zig/handled-cancel",
        .default_severity = .off,
        .strict_severity = .warning,
        .description = "error.Canceled is caught without io.recancel()",
    },
    .{
        .id = "zig/concurrency-fallback",
        .default_severity = .off,
        .strict_severity = .warning,
        .description = "io.concurrent call does not handle error.ConcurrencyUnavailable",
    },
    .{
        .id = "zig/no-thread-sync",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Legacy std.Thread synchronization primitive used",
    },
    .{
        .id = "zig/no-direct-posix",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Direct call to std.posix or std.os.linux outside the backend layer",
    },
    .{
        .id = "zig/no-raw-evented",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Direct reference to an Io evented backend",
    },
    .{
        .id = "zig/threaded-io-bypass",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Io.Threaded or init_single_threaded used outside main",
    },
    .{
        .id = "zig/test-standalone-io",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Test initializes a standalone Io instance",
    },

    // Zig security rules (src/lang/zig/rules/sec.zig)
    .{
        .id = "zig/crypto-random",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "io.random used where crypto randomness is required",
    },
    .{
        .id = "zig/secure-zero",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Secret buffer cleared with a plain @memset or zero literal",
    },
    .{
        .id = "zig/timing-safe-eql",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "std.mem.eql used on a secret or signature",
    },

    // Zig complexity rule (src/lang/zig/rules/cplx.zig)
    .{
        .id = "zig/block-depth",
        .default_severity = .warning,
        .strict_severity = .err,
        .description = "Control flow block nesting depth exceeds maximum limit of 3",
    },

    // Zig manifest rules (src/lang/zig/rules/build.zig)
    .{
        .id = "zig/zon-fingerprint",
        .default_severity = .err,
        .strict_severity = .err,
        .description = "build.zig.zon lacks a valid .fingerprint",
    },
    .{
        .id = "zig/zon-name-literal",
        .default_severity = .err,
        .strict_severity = .err,
        .description = "build.zig.zon .name is a string literal instead of an enum literal",
    },
    .{
        .id = "zig/zon-min-version",
        .default_severity = .warning,
        .strict_severity = .warning,
        .description = "build.zig.zon lacks .minimum_zig_version",
    },
    .{
        .id = "zig/zon-explicit-paths",
        .default_severity = .err,
        .strict_severity = .err,
        .description = "build.zig.zon .paths packages the repository root",
    },

    // Zig migration rules (src/lang/zig/rules/migration.zig)
    .{
        .id = "zig/deprecated-gpa",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "GeneralPurposeAllocator used instead of DebugAllocator",
    },
    .{
        .id = "zig/legacy-std-io",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "Legacy std.io stream or generic reader/writer used",
    },
    .{
        .id = "zig/unmanaged-arraylist",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .warning,
        .description = "Stateful ArrayList.init(allocator) pattern used",
    },
    .{
        .id = "zig/renamed-read-file-alloc",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "readFileAlloc called with the pre-0.16 argument order",
    },
    .{
        .id = "zig/renamed-fs-path",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "std.fs.path moved to std.Io.Dir.path in 0.16",
    },
    .{
        .id = "zig/renamed-fs-cwd",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "std.fs.cwd moved to std.Io.Dir.cwd in 0.16",
    },
    .{
        .id = "zig/renamed-process-child",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "process.Child.init and spawn replaced by process.spawn",
    },
    .{
        .id = "zig/renamed-std-time",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "std.time moved under Io.Timestamp and Io.Duration",
    },
    .{
        .id = "zig/removed-std-once",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "std.once is removed in 0.16",
    },
    .{
        .id = "zig/removed-thread-pool",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "std.Thread.Pool replaced by Io.Group in 0.16",
    },
    .{
        .id = "zig/removed-segmented-list",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "std.SegmentedList is removed in 0.16",
    },
    .{
        .id = "zig/removed-thread-mutex-recursive",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "std.Thread.Mutex.Recursive is removed in 0.16",
    },
    .{
        .id = "zig/removed-std-io-null-writer",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "std.io.null_writer is removed in 0.16",
    },
    .{
        .id = "zig/removed-meta-decl-list",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "std.meta.declList is removed in 0.16",
    },
    .{
        .id = "zig/stream-too-long",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .warning,
        .description = "error.FileTooBig replaced by error.StreamTooLong in 0.16",
    },
    .{
        .id = "zig/dir-not-empty",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .warning,
        .description = "Dir.rename returns error.DirNotEmpty instead of error.PathAlreadyExists",
    },
    .{
        .id = "zig/atime-optional",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .warning,
        .description = "stat.atime is optional (?Timestamp) in 0.16",
    },
    .{
        .id = "zig/math-sign-type",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .warning,
        .description = "std.math.sign returns narrowed integer type in 0.16",
    },
    .{
        .id = "zig/memory-map-errors",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .warning,
        .description = "File.MemoryMap WASI error set changed in 0.16",
    },
    .{
        .id = "zig/clock-error-sets",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .warning,
        .description = "Clock error.ClockUnsupported removed in 0.16",
    },
    .{
        .id = "zig/component-iterator-infallible",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .warning,
        .description = "componentIterator is infallible in 0.16",
    },
    .{
        .id = "zig/tar-traversal-sanitize",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .warning,
        .description = "tar.extract automatically sanitizes path traversal in 0.16",
    },
    .{
        .id = "zig/removed-dupe-z",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "Allocator.dupeZ is removed in 0.17",
    },
    .{
        .id = "zig/removed-errdefer-capture",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "errdefer payload capture is removed in 0.17",
    },
    .{
        .id = "zig/removed-array-mul",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "Array multiplication operator ** is removed in 0.17",
    },
    .{
        .id = "zig/removed-build-args",
        .default_severity = .off,
        .strict_severity = .off,
        .migration_severity = .note,
        .description = "Build.args is removed in 0.17",
    },

    // Zig input fuses (src/lang/zig/source.zig)
    .{
        .id = "zig/invalid-nul-byte",
        .default_severity = .err,
        .strict_severity = .err,
        .description = "Source file contains an embedded NUL byte (0x00)",
    },
    .{
        .id = "zig/input-too-deep",
        .default_severity = .err,
        .strict_severity = .err,
        .description = "Nesting depth exceeds maximum parser limit of 200",
    },
    .{
        .id = "zig/syntax-error",
        .default_severity = .err,
        .strict_severity = .err,
        .description = "Source file does not parse",
    },
};

pub fn findRule(rule_id: []const u8) ?RuleDef {
    for (rules) |r| {
        if (std.mem.eql(u8, r.id, rule_id)) return r;
    }
    return null;
}

/// Severity for a known rule under `profile`. Takes a `RuleDef` rather than an
/// id so there is no silent unknown-id default anywhere in the codebase.
pub fn severityOf(r: RuleDef, profile: Profile) diagnostic.Severity {
    return switch (profile) {
        .default => r.default_severity,
        .strict => r.strict_severity orelse r.default_severity,
        .migration => r.migration_severity orelse r.default_severity,
    };
}

/// True when the rule escalates from warning to err under the strict profile.
pub fn escalatesUnderStrict(rule_id: []const u8) bool {
    const r = findRule(rule_id) orelse return false;
    if (r.strict_severity) |strict| {
        return strict == .err and r.default_severity == .warning;
    }
    return false;
}

/// Rules that abort analysis and cannot be suppressed by any directive.
pub fn isFuse(rule_id: []const u8) bool {
    const fuses = [_][]const u8{
        "zig/invalid-nul-byte",
        "zig/input-too-deep",
        "zig/syntax-error",
    };
    for (fuses) |id| {
        if (std.mem.eql(u8, id, rule_id)) return true;
    }
    return false;
}

/// Rules whose findings are structural heuristics. Suppressing one of these
/// requires a reason, because the finding may be a false positive.
pub fn isHeuristic(rule_id: []const u8) bool {
    const heuristic = [_][]const u8{
        "security/no-plain-memset-scrub",
        "zig/no-post-overflow-check",
        "zig/checked-casts",
        "zig/assert-no-side-effects",
        "zig/no-undefined-struct",
        "zig/allocation-cleanup",
        "zig/io-parameter-threading",
        "zig/writer-flush",
        "zig/async-cancel",
        "zig/handled-cancel",
        "zig/concurrency-fallback",
        "zig/no-recursion",
        "zig/crypto-random",
        "zig/secure-zero",
        "zig/timing-safe-eql",
    };
    for (heuristic) |id| {
        if (std.mem.eql(u8, id, rule_id)) return true;
    }
    return false;
}

test "findRule resolves registered rules" {
    try std.testing.expect(findRule("c/posix-source-first-line") != null);
    try std.testing.expect(findRule("style/indent") != null);
    try std.testing.expect(findRule("security/safe-realloc") != null);
    try std.testing.expect(findRule("complexity/max-nesting-depth") != null);
    try std.testing.expect(findRule("zig/no-catch-unreachable") != null);
    try std.testing.expect(findRule("zig/zon-fingerprint") != null);
    try std.testing.expect(findRule("c/does-not-exist") == null);
}

test "severityOf mirrors the registered severity in every profile" {
    for (rules) |r| {
        const expected_strict = r.strict_severity orelse r.default_severity;
        const expected_migration = r.migration_severity orelse r.default_severity;
        try std.testing.expectEqual(r.default_severity, severityOf(r, .default));
        try std.testing.expectEqual(expected_migration, severityOf(r, .migration));
        try std.testing.expectEqual(expected_strict, severityOf(r, .strict));
    }
}

test "style and naming rules warn by default and fail under strict" {
    const style_rules = [_][]const u8{
        "style/indent",
        "style/line-length",
        "style/line-endings",
        "style/trailing-whitespace",
        "style/mandatory-braces",
        "style/brace-placement",
        "style/operator-linebreak",
        "c/no-camel-case",
        "c/return-var-name",
        "zig/type-naming",
        "zig/fn-naming",
        "zig/var-naming",
        "zig/error-tag-naming",
        "zig/enum-tag-naming",
        "zig/import-alias-naming",
        "zig/file-naming",
        "zig/no-raw-identifiers",
    };
    for (style_rules) |id| {
        const r = findRule(id) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(diagnostic.Severity.warning, severityOf(r, .default));
        try std.testing.expectEqual(diagnostic.Severity.err, severityOf(r, .strict));
        try std.testing.expect(escalatesUnderStrict(id));
    }
}

test "safety rules fail under every profile" {
    const err_always = [_][]const u8{
        "zig/no-catch-unreachable",
        "zig/no-swallowed-errors",
        "zig/no-runtime-safety-off",
        "zig/no-global-var",
        "zig/zon-fingerprint",
        "zig/zon-name-literal",
        "c/no-vla",
        "security/safe-realloc",
        "security/banned-functions",
        "c/explicit-int-types",
        "c/uninitialized-local",
    };
    for (err_always) |id| {
        const r = findRule(id) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(diagnostic.Severity.err, severityOf(r, .default));
        try std.testing.expectEqual(diagnostic.Severity.err, severityOf(r, .strict));
    }
}

test "migration notes stay off in default and strict, active in migration" {
    for (rules) |r| {
        const mig = r.migration_severity orelse continue;
        try std.testing.expectEqual(diagnostic.Severity.off, severityOf(r, .default));
        try std.testing.expectEqual(diagnostic.Severity.off, severityOf(r, .strict));
        try std.testing.expectEqual(mig, severityOf(r, .migration));
    }
    const gpa = findRule("zig/deprecated-gpa") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(diagnostic.Severity.off, severityOf(gpa, .default));
    try std.testing.expectEqual(diagnostic.Severity.note, severityOf(gpa, .migration));
}

test "off rules stay off until strict promotes them" {
    for (rules) |r| {
        if (r.migration_severity != null) continue;
        if (r.default_severity != .off) continue;
        try std.testing.expectEqual(diagnostic.Severity.off, severityOf(r, .migration));
    }
    const cleanup = findRule("zig/allocation-cleanup") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(diagnostic.Severity.off, severityOf(cleanup, .default));
    try std.testing.expectEqual(diagnostic.Severity.note, severityOf(cleanup, .strict));
}

test "table has no duplicate rule ids" {
    for (rules, 0..) |r, i| {
        for (rules[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, r.id, other.id));
        }
    }
}

test "every rule id matches the family/name schema" {
    for (rules) |r| {
        const slash = std.mem.indexOfScalar(u8, r.id, '/') orelse return error.TestUnexpectedResult;
        try std.testing.expect(slash > 0);
        try std.testing.expect(slash + 1 < r.id.len);
        try std.testing.expect(std.mem.indexOfScalar(u8, r.id[slash + 1 ..], '/') == null);
        for (r.id) |ch| {
            try std.testing.expect(!std.ascii.isUpper(ch));
        }
    }
}
