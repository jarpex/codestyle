const std = @import("std");
const ast = @import("../ast.zig");
const interface = @import("../../interface.zig");
const Context = interface.Context;

const Tree = ast.Tree;

/// Names that mark a value as key material. A comparison or an `@memset` on
/// one of these is a timing or a zeroization hazard.
const secret_names = [_][]const u8{
    "api_key",
    "priv_key",
    "auth_token",
    "session_token",
    "secret",
    "password",
    "passwd",
    "nonce",
    "salt",
    "signature",
    "hmac",
};

/// Split `name` on `_` and compare each part with `target`, so `keyword` does
/// not read as `key`.
fn nameHasWord(name: []const u8, target: []const u8) bool {
    var it = std.mem.splitScalar(u8, name, '_');
    while (it.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, target)) return true;
    }
    return false;
}

fn nameIsSecret(name: []const u8) bool {
    for (secret_names) |secret| {
        if (std.ascii.eqlIgnoreCase(name, secret)) return true;
        if (nameHasWord(name, secret)) return true;
    }
    return false;
}

fn precedingIdentifier(tree: *const Tree, i: usize) ?[]const u8 {
    if (i == 0) return null;
    var j = i;
    while (j > 0) {
        j -= 1;
        if (tree.tokens[j].tag == .identifier) return tree.tokenText(j);
        if (tree.tokens[j].tag == .period) continue;
        return null;
    }
    return null;
}

/// `zig/crypto-random`: `io.random` is not a cryptographic source.
pub fn cryptoRandom(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), "random")) continue;

        // `io.random` and `std.crypto.random` differ: the second is secure.
        const is_crypto = i >= 2 and std.mem.eql(u8, tree.tokenText(i - 2), "crypto");
        if (is_crypto) continue;
        if (i > 0 and std.mem.eql(u8, tree.tokenText(i - 1), "secure")) continue;

        const prev = precedingIdentifier(tree, i) orelse continue;
        if (!std.mem.eql(u8, prev, "io")) continue;

        try ctx.report(
            "zig/crypto-random",
            tree.tokenSpan(i),
            "Non-cryptographic randomness where key material is expected",
            "Use 'io.randomSecure' or 'std.crypto.random' for keys, salts and nonces",
        );
    }
}

/// `zig/secure-zero`: clearing a secret with `@memset` or a zero literal can
/// be optimized away.
pub fn secureZero(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .builtin) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), "@memset")) continue;

        const target = firstArgumentText(tree, i) orelse continue;
        if (!nameIsSecret(target)) continue;

        try ctx.report(
            "zig/secure-zero",
            tree.tokenSpan(i),
            "Secret buffer cleared with a plain @memset",
            "Use 'std.crypto.secureZero' or a volatile write loop so the write survives",
        );
    }
}

fn firstArgumentText(tree: *const Tree, builtin_index: usize) ?[]const u8 {
    var i = builtin_index + 1;
    while (i < tree.tokens.len and tree.tokens[i].tag != .l_paren) : (i += 1) {}
    if (i >= tree.tokens.len) return null;
    i += 1;
    while (i < tree.tokens.len and tree.tokens[i].tag != .identifier) : (i += 1) {}
    if (i >= tree.tokens.len) return null;
    return tree.tokenText(i);
}

/// `zig/timing-safe-eql`: `std.mem.eql` on key material leaks timing.
pub fn timingSafeEql(ctx: *Context, tree: *const Tree) interface.CheckError!void {
    var i: usize = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokens[i].tag != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenText(i), "eql")) continue;
        if (i < 2 or tree.tokens[i - 1].tag != .period) continue;
        if (!std.mem.eql(u8, tree.tokenText(i - 2), "mem")) continue;

        // Either argument may hold the secret, so both are inspected.
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(ctx.allocator);
        collectCallArgs(ctx.allocator, tree, i, &args);

        var secret = false;
        for (args.items) |arg| {
            if (nameIsSecret(arg)) secret = true;
        }
        if (!secret) continue;

        try ctx.report(
            "zig/timing-safe-eql",
            tree.tokenSpan(i),
            "Secret compared with a short-circuiting equality check",
            "Use 'std.crypto.timing_safe.eql' so the comparison time does not leak the value",
        );
    }
}

/// First identifier of each argument of the call whose callee ends at
/// `callee_index`. Nested calls contribute their own first identifier, which
/// is enough to spot `mem.eql(u8, key, other)`.
fn collectCallArgs(
    allocator: std.mem.Allocator,
    tree: *const Tree,
    callee_index: usize,
    out: *std.ArrayList([]const u8),
) void {
    var i = callee_index + 1;
    while (i < tree.tokens.len and tree.tokens[i].tag != .l_paren) : (i += 1) {}
    if (i >= tree.tokens.len) return;
    i += 1;

    var depth: usize = 1;
    var at_arg_start = true;

    while (i < tree.tokens.len and depth > 0) : (i += 1) {
        switch (tree.tokens[i].tag) {
            .l_paren, .l_brace, .l_bracket => depth += 1,
            .r_paren, .r_brace, .r_bracket => {
                depth -= 1;
                if (depth == 0) break;
            },
            .comma => if (depth == 1) {
                at_arg_start = true;
                continue;
            },
            .identifier => if (at_arg_start) {
                at_arg_start = false;
                out.append(allocator, tree.tokenText(i)) catch return;
            },
            else => {},
        }
    }
}

test "secret name matching is case insensitive" {
    try std.testing.expect(nameIsSecret("api_key"));
    try std.testing.expect(nameIsSecret("auth_token"));
    try std.testing.expect(nameIsSecret("hmac"));
    try std.testing.expect(!nameIsSecret("key"));
    try std.testing.expect(!nameIsSecret("token"));
    try std.testing.expect(!nameIsSecret("mac"));
    try std.testing.expect(!nameIsSecret("keyword"));
    try std.testing.expect(!nameIsSecret("buffer"));
}

test "crypto random names are distinct" {
    try std.testing.expect(secret_names.len > 5);
}
