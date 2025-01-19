const std = @import("std");

//TODO would using extern/export work better so we can have this in a separate .o?
// would save on compilation time. But we would have to hardcode the mem size for the common lut type
const luts = @import("./luts.zig");

pub fn main() void {
    std.debug.print("Starting up {}\n", .{luts.g.king_moves.len});
}
