const std = @import("std");
const AtomicOrder = std.builtin.AtomicOrder;

const luts = @import("./luts_common.zig");
//const luts = @import("./luts.zig"); // test unified, to make sure
const d = @import("./defs.zig");
const NUMSQ = d.NUMSQ;
const WIDTH = d.WIDTH;

const heap = std.heap.c_allocator;

const state_node = struct {
    board: d.Board,
    depth: u16,
    parent: ?*state_node,
    best_eval: std.atomic.Value(f32),
    live_children: std.atomic.Value(usize), // cannot propagate unless all children propagated
    //TODO use a futex here instead of two atomics?
    //TODO track best move combo here, not just eval?
};

fn evaluate(board: *d.Board) f32 {
    // given the board, what do we guess it's centi or milipawn value is?

    // count the actual piece amount
    var piece_balance: f32 = 0.0;

    var b_piece_count: usize = 0;
    var w_piece_count: usize = 0;

    var num_bishops_w: usize = 0;
    var num_bishops_b: usize = 0;
    for (board.layout) |p| {
        piece_balance += switch (p) {
            d.Piece.b_pawn => -1,
            d.Piece.w_pawn => 1,
            d.Piece.b_knight => -3,
            d.Piece.b_bishop => blk: {
                num_bishops_b += 1;
                break :blk -3;
            },
            d.Piece.w_knight => 3,
            d.Piece.w_bishop => blk: {
                num_bishops_w += 1;
                break :blk 3;
            },
            d.Piece.b_rook => -5,
            d.Piece.w_rook => 5,
            d.Piece.b_queen => -9,
            d.Piece.w_queen => 9,
            d.Piece.b_king => 900,
            d.Piece.w_king => 900,
            d.Piece.empty => 0,
        };

        if (p != d.Piece.empty) {
            if (!p.is_white()) {
                b_piece_count += 1;
            } else {
                w_piece_count += 1;
            }
        }
    }

    // add bonus for both bishops
    if (num_bishops_w >= 2) {
        // should we have checked for a white sq and black sq bishop specifically?
        piece_balance += 0.45;
    }
    if (num_bishops_b >= 2) {
        piece_balance -= 0.45;
    }

    // check for pawn structure
    //TODO

    // check for pass pawn
    //TODO

    // check for check and checkmate
    //TODO

    // check our position in the LUTs
    var pos_luts: f32 = 0;

    for (board.layout, 0..board.layout.len) |p, sq| {
        if (p != d.Piece.empty) {
            var num_enemies = w_piece_count;
            if (p.is_white()) {
                num_enemies = b_piece_count;
            }

            pos_luts += @floatFromInt(luts.g.value_by_num_enemies[num_enemies - d.LUT_MIN_ENEMIES][@intFromEnum(p)][sq]);
            pos_luts += @floatFromInt(luts.g.value_by_num_enemies[(w_piece_count + b_piece_count) - d.LUT_MIN_PIECES][@intFromEnum(p)][sq]);
        }
    }

    // add it all together with some reasonable k values
    //TODO find/train better k values?
    return (pos_luts * 1.0) + (piece_balance * 2100.0);
}

fn expand(state: *state_node, link_parent: bool) bool {
    var expanded = false;
    // given a position, go another layer down
    // adding new states to explore to our queue
    // cut off at the desired depth
    var moves: u64 = 0;
    var movesq: usize = NUMSQ;

    // could unroll this?
    sqloop: for (0..NUMSQ) |sq| {
        const p = state.board.layout[sq];

        const w_turn: bool = !state.board.flags.black_turn;

        if ((p == d.Piece.empty) or
            (p.is_white() != w_turn))
        {
            continue;
        }

        moves = 0;

        switch (p) {
            d.Piece.empty => {
                continue :sqloop;
            },
            d.Piece.w_pawn, d.Piece.b_pawn => {
                //TODO check for enpassant, double move
                //TODO handle promotion
                // promotion and double move require flag changes

                if (p == d.Piece.b_pawn) {
                    movesq = sq - WIDTH;
                    if (movesq < 0) {
                        continue :sqloop;
                    }
                } else {
                    movesq = sq + WIDTH;
                    if (movesq > NUMSQ) {
                        continue :sqloop;
                    }
                }

                // only more forward if unocc
                if ((state.board.occupied & (@as(u64, 1) << @truncate(movesq))) == 0) {
                    moves |= (@as(u64, 1) << @truncate(movesq));
                }

                // check if we can take
                if ((movesq & (WIDTH - 1)) != 0) {
                    if (((@as(u64, 1) << @truncate(movesq - 1)) & state.board.occupied) == 0) {
                        moves |= (@as(u64, 1) << @truncate(movesq - 1));
                    }
                }
                if ((movesq & (WIDTH - 1)) != (WIDTH - 1)) {
                    if (((@as(u64, 1) << @truncate(movesq + 1)) & state.board.occupied) == 0) {
                        moves |= (@as(u64, 1) << @truncate(movesq + 1));
                    }
                }
            },
            d.Piece.w_king, d.Piece.b_king => {
                //TODO handle OO and OOO, which require flag changes and two pieces moving
                moves = luts.g.king_moves[sq];
            },
            d.Piece.w_knight, d.Piece.b_knight => {
                moves = luts.g.knight_moves[sq];
            },
            d.Piece.w_bishop, d.Piece.b_bishop => {
                // use magic
                const mi: luts.MagicInfo = luts.g.bishop_magic[sq];
                const index = (mi.magic * (mi.mask & state.board.occupied)) >> @truncate(mi.shift);

                moves = luts.g.lut_mem[index + mi.tbl_off];
            },
            d.Piece.w_rook, d.Piece.b_rook => {
                // use magic
                const mi: luts.MagicInfo = luts.g.rook_magic[sq];
                const index = (mi.magic * (mi.mask & state.board.occupied)) >> @truncate(mi.shift);

                moves = luts.g.lut_mem[index + mi.tbl_off];
            },
            d.Piece.w_queen, d.Piece.b_queen => {
                // use magic
                var mi: luts.MagicInfo = luts.g.bishop_magic[sq];
                var index = (mi.magic * (mi.mask & state.board.occupied)) >> @truncate(mi.shift);

                moves = luts.g.lut_mem[index + mi.tbl_off];

                mi = luts.g.rook_magic[sq];
                index = (mi.magic * (mi.mask & state.board.occupied)) >> @truncate(mi.shift);

                moves |= luts.g.lut_mem[index + mi.tbl_off];
            },
        }

        // if we didn't continue by here, make the moves
        if (moves == 0) {
            continue;
        }

        var move: u64 = 1;
        movesq = 0;
        while (movesq < NUMSQ) : ({
            move <<= 1;
            movesq += 1;
        }) {
            if ((move & moves) == 0) {
                continue;
            }

            // for each move in moves, check it is not a self-capture
            if (w_turn) {
                if ((move & state.board.white_occupied) != 0) {
                    continue;
                }
            } else {
                if (((move & state.board.occupied) != 0) and ((move & state.board.white_occupied) == 0)) {
                    continue;
                }
            }

            // okay, make the move!
            expanded = true;
            // when placing children in the queue, make sure you have fetchAdd'd the live_count first
            _ = state.live_children.fetchAdd(1, AtomicOrder.monotonic);

            const newnode: *WorkQueue.Node = heap.create(WorkQueue.Node) catch unreachable;

            newnode.data.depth = state.depth + 1;
            newnode.data.parent = null;
            if (link_parent) {
                newnode.data.parent = state;
            }

            newnode.data.board = state.board;

            // initial eval needs to be worst possible
            var worst: f32 = undefined;
            if (w_turn) {
                // so this new node will be black's turn, they will choose the most negative
                worst = std.math.inf(f32);
            } else {
                // so this new node will be white's turn, they will choose the most positive
                worst = -std.math.inf(f32);
            }
            newnode.data.board.flags.black_turn = !w_turn;
            newnode.data.best_eval = std.atomic.Value(f32).init(worst);
            newnode.data.live_children = std.atomic.Value(usize).init(0);

            // clear the enpassant each turn, unless we just did a double, then set it
            //TODO
            newnode.data.board.flags.enpassant_sq = 0;

            // update the layout, occupied, and white_occupied
            newnode.data.board.layout[sq] = d.Piece.empty;
            newnode.data.board.layout[movesq] = p;
            newnode.data.board.occupied |= move;
            newnode.data.board.occupied &= ~move;

            if (w_turn) {
                newnode.data.board.white_occupied |= move;
                newnode.data.board.white_occupied &= ~move;
            }

            // add the move to the queue!
            work_queue_mux.lock();
            work_queue.append(newnode);
            work_queue_mux.unlock();

            work_ready_sem.post();
        }
    }

    return expanded;
}

var work_ready_sem = std.Thread.Semaphore{};
const WorkQueue = std.DoublyLinkedList(state_node);
var work_queue = WorkQueue{};
var work_queue_mux = std.Thread.Mutex{}; // TODO better as a futex?

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
            if (expand(&node.data, true)) {
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
        var cnode: *state_node = &node.data;
        var pnode: *state_node = undefined;
        while (true) {

            // if we reached the top, don't free that one
            if (cnode.parent == null) {
                break;
            }

            pnode = cnode;
            cnode = cnode.parent.?;

            // propagate the best_eval, if it is the min/max we want
            const pbest = pnode.best_eval.load(AtomicOrder.unordered);

            if (cnode.board.flags.black_turn) {
                // this is black's turn, so it wants the eval that is most negative
                _ = cnode.best_eval.fetchMin(pbest, AtomicOrder.monotonic);
            } else {
                _ = cnode.best_eval.fetchMax(pbest, AtomicOrder.monotonic);
            }

            // free the lower node
            const tofree: *WorkQueue.Node = @fieldParentPtr("data", pnode);
            heap.destroy(tofree);

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

fn game_loop() void {
    // get game commands
    // expand a board state into possible moves
    // wait until we have the results
}

pub fn main() !void {
    std.debug.print("Starting up {}\n", .{luts.g.king_moves.len});

    //var threads: [std.Thread.getCpuCount() - 2]std.Thread = undefined;
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
