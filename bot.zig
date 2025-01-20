const std = @import("std");
const AtomicOrder = std.builtin.AtomicOrder;

const luts = @import("./luts_common.zig");
const d = @import("./defs.zig");

const heap = std.heap.c_allocator;

const state_node = struct {
    board: d.Board,
    depth: u16,
    parent: ?*state_node,
    best_eval: std.atomic.Value(i32),
    live_children: std.atomic.Value(usize), // cannot propagate unless all children propagated
    //TODO use a futex here instead of two atomics?
    //TODO track best move here, not just eval?
};

fn evaluate(board: *d.Board) i32 {
    _ = board;
    //TODO
    return 0;
}

fn expand(state: *state_node) bool {
    var expanded = false;
    // given a position, go another layer down
    // adding new states to explore to our queue
    // cut off at the desired depth
    //TODO
    _ = state;
    expanded = false;

    // when placing children in the queue, make sure you have fetchAdd'd the live_count first
    //TODO

    return expanded;
}

var work_ready_sem = std.Thread.Semaphore{};
const WorkQueue = std.DoublyLinkedList(state_node);
var work_queue = WorkQueue{};
var work_queue_mux = std.Thread.Mutex{};

//TODO going to have to make this movable
const TARGET_DEPTH = 3;
var shutdown: bool = false;

fn work() void {
    while (true) {
        // check for work
        work_ready_sem.wait();

        // first see if we are quitting
        if (shutdown) {
            return;
        }

        // we have work!
        work_queue_mux.lock();

        // take a board state off the queue
        const node = work_queue.popFirst().?;

        work_queue_mux.unlock();

        // expand it if it needs expanding
        if (node.data.depth < TARGET_DEPTH) {
            if (expand(&node.data)) {
                // added children to the queue, we can drop this and grab more work
                continue;
            }
        }

        // otherwise
        // evaluate it if it wasn't expanded
        // this one doesn't need to be atomic, so unordered is fine
        node.data.best_eval.store(evaluate(&node.data.board), AtomicOrder.unordered);

        // propagate move values back up the tree, as far as you can
        // freeing memory as we propagate
        // this is where we need to be really careful about races
        // use @fieldParentPtr to get the node to free
        var cnode: ?*state_node = &node.data;
        var pnode: ?*state_node = null;
        while (true) {
            pnode = cnode;
            cnode = cnode.parent;

            // if we reached the top, don't free that one
            if (cnode == null) {
                break;
            }

            // propagate the best_eval, if it is the min/max we want
            const pbest = pnode.best_eval;

            if (cnode.board.flags.black_turn) {
                // this is black's turn, so it wants the eval that is most negative
                cnode.best_eval.fetchMin(pbest, AtomicOrder.monotonic);
            } else {
                cnode.best_eval.fetchMax(pbest, AtomicOrder.monotonic);
            }

            // free the lower node
            const tofree: WorkQueue.Node = @fieldParentPtr("data", pnode);
            heap.free(tofree);

            const prev_child_count = cnode.live_children.fetchSub(1, AtomicOrder.monotonic);
            if (prev_child_count < 1) {
                unreachable;
            } else if (prev_child_count > 1) {
                // we can't go any further, let the other children return to the fold as well
                break;
            }

            // we are the leaf! Move on up the tree
        }

        // continue to find other work
    }
}

pub fn main() !void {
    std.debug.print("Starting up {}\n", .{luts.g.king_moves.len});

    //var threads: [std.Thread.getCpuCount()]std.Thread = undefined;
    //DEBUG
    var threads: [1]std.Thread = undefined;

    const spawn_config = std.Thread.SpawnConfig{};

    // start up our worker threads
    for (0..threads.len) |i| {
        threads[i] = try std.Thread.spawn(spawn_config, work, .{});
    }

    // set up the game handler
    //TODO

    // done, signal the workers and wait for them to finish
    std.debug.print("Shutting down\n", .{});

    // signal and wake by posting enough
    shutdown = true;
    for (0..threads.len) |_| {
        work_ready_sem.post();
    }

    // join up
    for (0..threads.len) |i| {
        threads[i].join();
    }

    return;
}
