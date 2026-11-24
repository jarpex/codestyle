const std = @import("std");

pub fn addNumbers(a: u32, b: u32) u32 {
    return a + b;
}

test "addNumbers sums two integers" {
    try std.testing.expectEqual(@as(u32, 5), addNumbers(2, 3));
}
