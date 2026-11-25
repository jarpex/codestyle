const std = @import("std");
const ast = @import("../ast.zig");
const interface = @import("../../interface.zig");
const Context = interface.Context;

const Tree = ast.Tree;

/// Legacy thread primitives. Zig 0.16 moves synchronization under `Io`.
const legacy_thread_sync = [_][]const u8{
    "Mutex",
    "Condition",
    "WaitGroup",
    "ThreadPool",
};

/// Backends that general code must not name directly.
const raw_evented = [_][]const u8{ "Uring", "Kqueue", "Evented" };

/// `zig/io-parameter-threading`: a function that touches the file system or
/// a stream takes an `io` parameter. Heuristic: off by default.
pub fn ioParameterThreading(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        if (tree.tag(i) != .fn_decl) continue;
        if (!ast.fnHasBody(tree, i)) continue;
        // Only a function that performs I/O can be missing its `io` handle.
        if (!fnMentionsIo(tree, i)) continue;

        if (fnHasIoOrContextParam(ctx.allocator, tree, i)) continue;

        try ctx.report(
            "zig/io-parameter-threading",
            tree.nodeSpan(i),
            "Function performs I/O without an 'io' parameter",
            "Thread an 'std.Io' parameter through the call chain",
        );
    }
}

fn fnHasIoOrContextParam(allocator: std.mem.Allocator, tree: *const Tree, fn_decl: usize) bool {
    var params: std.ArrayList([]const u8) = .empty;
    defer params.deinit(allocator);
    ast.paramNames(tree, fn_decl, &params) catch return true;

    for (params.items) |name| {
        if (std.mem.eql(u8, name, "io") or std.mem.eql(u8, name, "ctx") or
            std.mem.eql(u8, name, "context"))
        {
            return true;
        }
    }

    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const proto = tree.ast.fullFnProto(&buffer, tree.nodeAt(fn_decl)) orelse return false;
    var it = proto.iterate(&tree.ast);
    while (it.next()) |param| {
        const type_expr = param.type_expr orelse continue;
        const type_txt = tree.ast.getNodeSource(type_expr);
        if (std.mem.indexOf(u8, type_txt, "std.Io") != null or
            std.mem.eql(u8, std.mem.trim(u8, type_txt, " \t"), "Io") or
            std.mem.indexOf(u8, type_txt, "Context") != null)
        {
            return true;
        }
    }
    return false;
}

fn fnMentionsIo(tree: *const Tree, fn_decl: usize) bool {
    const bounds = ast.fnBytes(tree, fn_decl);
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const t = tree.tokens[i];
        if (t.start < bounds.start or t.end > bounds.end) continue;
        if (t.tag != .identifier) continue;
        const name = tree.tokenText(i);
        if (std.mem.eql(u8, name, "readFileAlloc") or
            std.mem.eql(u8, name, "createFile") or
            std.mem.eql(u8, name, "openDir") or
            std.mem.eql(u8, name, "cwd"))
        {
            return true;
        }
    }
    return false;
}

/// `zig/writer-flush`: a locally created buffered writer is flushed or ended on every path.
/// Heuristic: off by default.
pub fn writerFlush(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.nodeCount()) : (i += 1) {
        const tag = tree.tag(i);
        const is_decl = tag == .local_var_decl or tag == .simple_var_decl or
            tag == .aligned_var_decl;
        if (!is_decl) continue;

        const decl = tree.ast.fullVarDecl(tree.nodeAt(i)) orelse continue;
        if (tree.ast.tokenTag(decl.ast.mut_token) != .keyword_var) continue;
        const init_idx = decl.ast.init_node.unwrap() orelse continue;
        const init_txt = tree.ast.getNodeSource(init_idx);
        if (std.mem.indexOf(u8, init_txt, ".writer(") == null) continue;

        const fn_decl = ast.fnAtOffset(tree, tree.nodeBytes(i).start) orelse continue;
        if (hasFlushInFunction(tree, fn_decl)) continue;

        try ctx.report(
            "zig/writer-flush",
            tree.nodeSpan(i),
            "Buffered writer with no flush on this path",
            "Call 'flush()' or 'end()' before the function returns",
        );
    }
}

fn hasFlushInFunction(tree: *const Tree, fn_decl: usize) bool {
    const bounds = ast.fnBytes(tree, fn_decl);
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const t = tree.tokens[i];
        if (t.start < bounds.start or t.end > bounds.end) continue;
        if (t.tag != .identifier) continue;
        const name = tree.tokenText(i);
        if (std.mem.eql(u8, name, "flush") or std.mem.eql(u8, name, "end")) return true;
    }
    return false;
}

/// `zig/async-cancel`: an async task is awaited or cancelled on exit.
/// Heuristic: off by default.
pub fn asyncCancel(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), "async")) continue;
        if (i == 0 or tree.tokens[i - 1].tag != .period) continue;

        const fn_decl = ast.fnAtOffset(tree, tree.tokens[i].start) orelse continue;
        if (hasAwaitOrCancel(tree, fn_decl)) continue;

        try ctx.report(
            "zig/async-cancel",
            tree.tokenSpan(i),
            "Async task neither awaited nor cancelled",
            "Await the task, or cancel it on every exit branch",
        );
    }
}

fn hasAwaitOrCancel(tree: *const Tree, fn_decl: usize) bool {
    const bounds = ast.fnBytes(tree, fn_decl);
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const t = tree.tokens[i];
        if (t.start < bounds.start or t.end > bounds.end) continue;
        if (t.tag != .identifier) continue;
        const name = tree.tokenText(i);
        if (std.mem.eql(u8, name, "await") or
            std.mem.eql(u8, name, "cancel") or
            std.mem.eql(u8, name, "recancel"))
        {
            return true;
        }
    }
    return false;
}

/// `zig/handled-cancel`: `error.Canceled` is caught without recancelling.
/// Heuristic: off by default.
pub fn handledCancel(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), "Canceled")) continue;

        const fn_decl = ast.fnAtOffset(tree, tree.tokens[i].start) orelse continue;
        if (hasCancelRecovery(tree, fn_decl)) continue;

        try ctx.report(
            "zig/handled-cancel",
            tree.tokenSpan(i),
            "error.Canceled handled without restoring cancellation",
            "Call 'io.recancel()' or 'swapCancelProtection()' in the handler",
        );
    }
}

fn hasCancelRecovery(tree: *const Tree, fn_decl: usize) bool {
    const bounds = ast.fnBytes(tree, fn_decl);
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const t = tree.tokens[i];
        if (t.start < bounds.start or t.end > bounds.end) continue;
        if (t.tag != .identifier) continue;
        const name = tree.tokenText(i);
        if (std.mem.eql(u8, name, "recancel") or
            std.mem.eql(u8, name, "swapCancelProtection"))
        {
            return true;
        }
    }
    return false;
}

/// `zig/concurrency-fallback`: `io.concurrent` handles the unavailable case.
/// Heuristic: off by default.
pub fn concurrencyFallback(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), "concurrent")) continue;
        if (i < 2 or tree.tokens[i - 1].tag != .period) continue;
        if (tree.tokens[i - 2].tag != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenText(i - 2), "io")) continue;

        const fn_decl = ast.fnAtOffset(tree, tree.tokens[i].start) orelse continue;
        if (hasConcurrencyFallback(tree, fn_decl)) continue;

        try ctx.report(
            "zig/concurrency-fallback",
            tree.tokenSpan(i),
            "io.concurrent without a ConcurrencyUnavailable branch",
            "Handle 'error.ConcurrencyUnavailable' with a synchronous fallback",
        );
    }
}

fn hasConcurrencyFallback(tree: *const Tree, fn_decl: usize) bool {
    const bounds = ast.fnBytes(tree, fn_decl);
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        const t = tree.tokens[i];
        if (t.start < bounds.start or t.end > bounds.end) continue;
        if (t.tag != .identifier) continue;
        if (std.mem.eql(u8, tree.tokenText(i), "ConcurrencyUnavailable")) return true;
    }
    return false;
}

/// `zig/no-thread-sync`: legacy thread primitives are forbidden.
pub fn noThreadSync(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), "Thread")) continue;
        if (i + 2 >= tree.tokens.len or tree.tokens[i + 1].tag != .period) continue;
        if (tree.tokens[i + 2].tag != .identifier) continue;

        const member = tree.tokenText(i + 2);
        for (legacy_thread_sync) |name| {
            if (!std.mem.eql(u8, member, name)) continue;
            try ctx.report(
                "zig/no-thread-sync",
                tree.tokenSpan(i + 2),
                "Legacy std.Thread synchronization primitive",
                "Use the Io synchronization primitives instead",
            );
        }
    }
}

/// `zig/no-direct-posix`: direct `std.posix` and `std.os.linux` calls are
/// confined to the backend layer.
pub fn noDirectPosix(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    if (ctx.allow.allowsDirectPosix(ctx.file_path)) return;

    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        const name = tree.tokenText(i);
        const is_std_posix = std.mem.eql(u8, name, "posix") and i >= 2 and
            tree.tokens[i - 1].tag == .period and
            std.mem.eql(u8, tree.tokenText(i - 2), "std");
        const is_posix_system = std.mem.eql(u8, name, "posix") and i + 2 < tree.tokens.len and
            tree.tokens[i + 1].tag == .period and
            std.mem.eql(u8, tree.tokenText(i + 2), "system");
        const is_os_linux = std.mem.eql(u8, name, "linux") and i >= 2 and
            tree.tokens[i - 1].tag == .period and
            std.mem.eql(u8, tree.tokenText(i - 2), "os");
        if (!is_std_posix and !is_posix_system and !is_os_linux) continue;

        try ctx.report(
            "zig/no-direct-posix",
            tree.tokenSpan(i),
            "Direct platform call outside the backend layer",
            "Go through 'std.Io' so the code stays portable",
        );
    }
}

/// `zig/no-raw-evented`: general code names no evented backend.
pub fn noRawEvented(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), "Io")) continue;
        if (i + 2 >= tree.tokens.len or tree.tokens[i + 1].tag != .period) continue;
        if (tree.tokens[i + 2].tag != .identifier) continue;

        const member = tree.tokenText(i + 2);
        for (raw_evented) |name| {
            if (!std.mem.eql(u8, member, name)) continue;
            try ctx.report(
                "zig/no-raw-evented",
                tree.tokenSpan(i + 2),
                "Evented backend named directly",
                "Write against the generic Io interface so the backend stays replaceable",
            );
        }
    }
}

/// `zig/threaded-io-bypass`: `Io.Threaded` and `init_single_threaded` are
/// confined to main.
pub fn threadedIoBypass(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    if (ast.declaresMain(tree)) return;

    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        const name = tree.tokenText(i);
        const hit = std.mem.eql(u8, name, "Threaded") or
            std.mem.eql(u8, name, "init_single_threaded");
        if (!hit) continue;
        if (ast.inTestBlockToken(tree, i)) continue;

        try ctx.report(
            "zig/threaded-io-bypass",
            tree.tokenSpan(i),
            "Threaded Io created outside main",
            "Accept an 'std.Io' parameter so the caller owns the event loop",
        );
    }
}

/// `zig/test-standalone-io`: a test builds its own Io instead of using the
/// runner's.
pub fn testStandaloneIo(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (!ast.inTestBlockToken(tree, i)) continue;
        if (tree.tokens[i].tag != .identifier) continue;
        const name = tree.tokenText(i);
        const hit = std.mem.eql(u8, name, "Threaded") or
            std.mem.eql(u8, name, "init_single_threaded") or
            std.mem.eql(u8, name, "initEvented");
        if (!hit) continue;

        try ctx.report(
            "zig/test-standalone-io",
            tree.tokenSpan(i),
            "Test builds its own Io instance",
            "Use the Io instance the test runner provides",
        );
    }
}

test "legacy thread primitives are distinct" {
    for (legacy_thread_sync, 0..) |name, i| {
        for (legacy_thread_sync[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, name, other));
        }
    }
}

test "raw evented backends are distinct" {
    try std.testing.expectEqual(@as(usize, 3), raw_evented.len);
}
