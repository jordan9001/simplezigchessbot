const std = @import("std");

const luts = @import("./luts_common.zig");
const d = @import("./defs.zig");

const state_node = struct {
    board: d.Board,
    parent: *state_node,
    best_eval: std.atomic.Value(i32),
    live_children: std.atomic.Value(usize), // cannot propagate unless all children propagated
};

fn evaluate(board: d.Board) i32 {
    _ = board;
    //TODO
    return 0;
}

fn expand(state: state_node) void {

    // given a position, go another layer down
    // adding new states to explore to our queue
    // cut off at the desired depth
    //TODO
    _ = state;
}

fn work() void {
    // take a board state off the queue
    // expand it if it needs expanding
    // otherwise
    // evaluate it if it is deep enough
    // propagate move values back up the tree, as far as you can
    // freeing memory as we propagate
    // use fetchSub == 1 to know we are the node to get live_children to zero
    //TODO
}

pub fn main() !void {
    std.debug.print("Starting up {}\n", .{luts.g.king_moves.len});

    // start up our worker threads
}
