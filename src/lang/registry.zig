const std = @import("std");
const Language = @import("interface.zig").Language;
const c_language = @import("c/index.zig").c_language;
const zig_language = @import("zig/index.zig").zig_language;

pub const languages = [_]Language{
    c_language,
    zig_language,
};

pub fn findByExtension(ext: []const u8) ?Language {
    for (languages) |lang| {
        for (lang.extensions) |candidate| {
            if (std.mem.eql(u8, ext, candidate)) {
                return lang;
            }
        }
    }
    return null;
}

test "registry finds c language by extension" {
    const lang_c = findByExtension(".c");
    try std.testing.expect(lang_c != null);
    try std.testing.expectEqualStrings("c", lang_c.?.id);

    const lang_h = findByExtension(".h");
    try std.testing.expect(lang_h != null);
    try std.testing.expectEqualStrings("c", lang_h.?.id);

    const lang_unknown = findByExtension(".rs");
    try std.testing.expect(lang_unknown == null);
}

test "registry finds zig language by extension" {
    const lang_zig = findByExtension(".zig");
    try std.testing.expect(lang_zig != null);
    try std.testing.expectEqualStrings("zig", lang_zig.?.id);

    const lang_zon = findByExtension(".zon");
    try std.testing.expect(lang_zon != null);
    try std.testing.expectEqualStrings("zig", lang_zon.?.id);
}

test "only the c frontend needs a tree-sitter grammar" {
    for (languages) |lang| {
        const is_c = std.mem.eql(u8, lang.id, "c");
        try std.testing.expectEqual(is_c, lang.get_grammar != null);
    }
}
