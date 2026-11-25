const std = @import("std");
const interface = @import("../interface.zig");
const Context = interface.Context;
const Language = interface.Language;
const CheckError = interface.CheckError;
const diagnostic = @import("../../core/diagnostic.zig");
const ts = @import("../../core/ts.zig");

const ast = @import("ast.zig");
const source = @import("source.zig");
const style = @import("rules/style.zig");
const safe = @import("rules/safe.zig");
const mem = @import("rules/mem.zig");
const io = @import("rules/io.zig");
const sec = @import("rules/sec.zig");
const cplx = @import("rules/cplx.zig");
const build = @import("rules/build.zig");
const migration = @import("rules/migration.zig");

pub const runPass = source.runPass;
pub const Tree = ast.Tree;

const max_file_size = 8 * 1024 * 1024;

/// `build.zig.zon` is a manifest, not Zig code: the manifest rules read the
/// raw text and the AST rules are skipped.
fn isManifest(path: []const u8) bool {
    return build.isManifest(path);
}

fn runRawChecks(ctx: *Context) CheckError!void {
    if (isManifest(ctx.file_path)) {
        try build.zonFingerprint(ctx);
        try build.zonNameLiteral(ctx);
        try build.zonMinVersion(ctx);
        try build.zonExplicitPaths(ctx);
        return;
    }

    var scanned = source.runPass(ctx.allocator, ctx) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.OutOfMemory;
    };
    defer scanned.deinit(ctx.allocator);

    if (scanned.aborted()) {
        ctx.aborted = true;
        return;
    }
}

fn runAstChecks(ctx: *Context, tree: ?*const ts.c.TSTree) CheckError!void {
    _ = tree;
    if (isManifest(ctx.file_path)) return;

    const arena = ctx.allocator;
    const source_z = arena.dupeSentinel(u8, ctx.source, 0) catch return error.OutOfMemory;

    var parsed = ast.Tree.parse(arena, source_z, .zig) catch {
        try reportParseError(ctx, ctx.source);
        return;
    };
    defer parsed.deinit();

    try migration.wave017(ctx, &parsed);
    if (parsed.ast.errors.len > 0) {
        try reportParseErrors(ctx, &parsed);
        return;
    }

    try style.fileNaming(ctx, &parsed);
    try style.typeNaming(ctx, &parsed);
    try style.fnNaming(ctx, &parsed);
    try style.varNaming(ctx, &parsed);
    try style.errorTagNaming(ctx, &parsed);
    try style.enumTagNaming(ctx, &parsed);
    try style.importAliasNaming(ctx, &parsed);
    try style.noRawIdentifiers(ctx, &parsed);

    try safe.noCatchUnreachable(ctx, &parsed);
    try safe.noSwallowedErrors(ctx, &parsed);
    try safe.noRuntimeSafetyOff(ctx, &parsed);
    try safe.noPanicUnreachable(ctx, &parsed);
    try safe.noAnyerror(ctx, &parsed);
    try safe.unsafeCasts(ctx, &parsed);
    try safe.wrappingOpsDoc(ctx, &parsed);
    try safe.noDebugInLib(ctx, &parsed);
    try safe.noCimportOutsideFfi(ctx, &parsed);
    try safe.noGlobalVar(ctx, &parsed);
    try safe.noExitInLib(ctx, &parsed);
    try safe.noPostOverflowCheck(ctx, &parsed);
    try safe.assertNoSideEffects(ctx, &parsed);
    try safe.noUndefinedStruct(ctx, &parsed);
    try safe.checkedCasts(ctx, &parsed);

    try mem.unboundedRead(ctx, &parsed);
    try mem.noGlobalAllocator(ctx, &parsed);
    try mem.allocationCleanup(ctx, &parsed);
    try mem.noRecursion(ctx, &parsed);

    try io.ioParameterThreading(ctx, &parsed);
    try io.writerFlush(ctx, &parsed);
    try io.asyncCancel(ctx, &parsed);
    try io.handledCancel(ctx, &parsed);
    try io.concurrencyFallback(ctx, &parsed);
    try io.noThreadSync(ctx, &parsed);
    try io.noDirectPosix(ctx, &parsed);
    try io.noRawEvented(ctx, &parsed);
    try io.threadedIoBypass(ctx, &parsed);
    try io.testStandaloneIo(ctx, &parsed);

    try sec.cryptoRandom(ctx, &parsed);
    try sec.secureZero(ctx, &parsed);
    try sec.timingSafeEql(ctx, &parsed);

    try cplx.blockDepth(ctx, &parsed);
    try migration.run(ctx, &parsed);
    try migration.readFileAllocOrder(ctx, &parsed);
    try migration.wave2(ctx, &parsed);
}

fn reportParseError(ctx: *Context, source_text: []const u8) interface.CheckError!void {
    const lines = ast.scan.LineIndex.init(ctx.allocator, source_text) catch {
        try ctx.report(
            "zig/syntax-error",
            .{
                .start_byte = 0,
                .end_byte = 0,
                .start_line = 1,
                .start_col = 1,
                .end_line = 1,
                .end_col = 1,
            },
            "Source file does not parse",
            "Fix the syntax error before running the analyzer",
        );
        return;
    };
    const end = lines.lineCol(source_text.len);
    try ctx.report(
        "zig/syntax-error",
        .{
            .start_byte = 0,
            .end_byte = source_text.len,
            .start_line = 1,
            .start_col = 1,
            .end_line = end.line,
            .end_col = end.col,
        },
        "Source file does not parse",
        "Fix the syntax error before running the analyzer",
    );
}

fn reportParseErrors(ctx: *Context, tree: *const ast.Tree) interface.CheckError!void {
    var reported: usize = 0;
    for (tree.ast.errors) |parse_error| {
        if (reported >= 50) return;
        reported += 1;

        var message_buf: [1024]u8 = undefined;
        var fixed = std.Io.Writer.fixed(&message_buf);
        const raw_msg = if (tree.ast.renderError(parse_error, &fixed)) |_|
            message_buf[0..fixed.end]
        else |_| blk: {
            const suffix = "... [truncated]";
            const end = @min(fixed.end, message_buf.len - suffix.len);
            @memcpy(message_buf[end .. end + suffix.len], suffix);
            break :blk message_buf[0 .. end + suffix.len];
        };
        const arena = ctx.allocator;
        const message = try arena.dupe(u8, raw_msg);

        const token = @as(usize, @intCast(parse_error.token));
        const span = if (token < tree.tokens.len)
            tree.tokenSpan(token)
        else
            tree.tokenSpan(0);

        try ctx.report(
            "zig/syntax-error",
            span,
            message,
            "Fix the syntax error before running the analyzer",
        );
    }
}

pub const zig_language = Language{
    .id = "zig",
    .extensions = &.{ ".zig", ".zon" },
    .get_grammar = null,
    .run_raw_checks = runRawChecks,
    .run_ast_checks = runAstChecks,
    .text = .{
        .indent = .spaces4,
        .max_line_len = 100,
        .line_len_message = "Line exceeds 100 columns",
    },
    .max_file_size = max_file_size,
};

test "zig language has no grammar and names both extensions" {
    try std.testing.expect(zig_language.get_grammar == null);
    try std.testing.expectEqualStrings("zig", zig_language.id);
    try std.testing.expectEqual(@as(usize, 2), zig_language.extensions.len);
    try std.testing.expectEqual(max_file_size, zig_language.max_file_size);
}

test "manifest detection follows the file name" {
    try std.testing.expect(isManifest("build.zig.zon"));
    try std.testing.expect(!isManifest("src/main.zig"));
}

test "scan is re-exported for the registry tests" {
    _ = runPass;
    _ = diagnostic;
}
