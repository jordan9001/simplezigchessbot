const std = @import("std");

const luts = @import("./luts_common.zig");

pub fn main() void {
    std.debug.print("Starting up {}\n", .{luts.g.king_moves.len});
}
