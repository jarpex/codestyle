const std = @import("std");

pub fn badZigExample(err_val: anyerror, a: bool, b: bool, c: bool, d: bool) !void {
    _ = err_val;
    _ = std.heap.GeneralPurposeAllocator(.{}){};
    _ = error.FileTooBig;
    if (a) {
        if (b) {
            if (c) {
                if (d) {
                    if (a) {
                        return;
                    }
                }
            }
        }
    }
    const x: ?u32 = null;
    _ = x orelse unreachable;
}
