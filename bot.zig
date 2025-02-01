const std = @import("std");
const cURL = @cImport({
    @cInclude("curl/curl.h");
});

const luts = @import("./luts_common.zig");
//const luts = @import("./luts.zig"); // test unified, to make sure
const d = @import("./defs.zig");

const NUMSQ = d.NUMSQ;
const WIDTH = d.WIDTH;

const heap = std.heap.c_allocator;

pub var send_move_f: ?*const fn (game_id: []const u8, best_move_start: i8, best_move_end: i8) void = null;

pub var shutdown: bool = false;
pub var work_ready_sem = std.Thread.Semaphore{};
const WorkQueue = std.DoublyLinkedList(state_node);
var work_queue = WorkQueue{};
var work_queue_mux = std.Thread.Mutex{};

const state_node = struct {
    board: d.Board,
    depth: u16,
    target_depth: u16,
    parent: ?*state_node,
    move_start: i8,
    move_end: i8,
    game_id: [d.MAX_ID_SZ]u8,
    game_id_sz: u16,

    mux: std.Thread.Mutex, // this mux protects below items
    best_eval: f32,
    best_move_end: i8,
    best_move_start: i8,
    live_children: usize, // cannot propagate unless all children propagated
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
            pos_luts += @floatFromInt(luts.g.value_by_num_pieces[(w_piece_count + b_piece_count) - d.LUT_MIN_PIECES][@intFromEnum(p)][sq]);
        }
    }

    // add it all together with some reasonable k values
    //TODO find/train better k values?
    return (pos_luts * 1.0) + (piece_balance * 2100.0);
}

fn expand(state: *state_node) bool {
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
                    const diagmv = (@as(u64, 1) << @truncate(movesq - 1));
                    if ((diagmv & state.board.occupied) != 0) {
                        if (p.is_white() == ((diagmv & state.board.white_occupied) == 0)) {
                            moves |= (@as(u64, 1) << @truncate(movesq - 1));
                        }
                    }
                }
                if ((movesq & (WIDTH - 1)) != (WIDTH - 1)) {
                    const diagmv = (@as(u64, 1) << @truncate(movesq + 1));
                    if ((diagmv & state.board.occupied) != 0) {
                        if (p.is_white() == ((diagmv & state.board.white_occupied) == 0)) {
                            moves |= (@as(u64, 1) << @truncate(movesq + 1));
                        }
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
                const index = (mi.magic *% (mi.mask & state.board.occupied)) >> @truncate(mi.shift);

                moves = luts.g.lut_mem[index + mi.tbl_off];
            },
            d.Piece.w_rook, d.Piece.b_rook => {
                // use magic
                const mi: luts.MagicInfo = luts.g.rook_magic[sq];
                const index = (mi.magic *% (mi.mask & state.board.occupied)) >> @truncate(mi.shift);

                moves = luts.g.lut_mem[index + mi.tbl_off];
            },
            d.Piece.w_queen, d.Piece.b_queen => {
                // use magic
                var mi: luts.MagicInfo = luts.g.bishop_magic[sq];
                var index = (mi.magic *% (mi.mask & state.board.occupied)) >> @truncate(mi.shift);

                moves = luts.g.lut_mem[index + mi.tbl_off];

                mi = luts.g.rook_magic[sq];
                index = (mi.magic *% (mi.mask & state.board.occupied)) >> @truncate(mi.shift);

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
            state.mux.lock();
            state.live_children += 1;
            state.mux.unlock();

            const newnode: *WorkQueue.Node = heap.create(WorkQueue.Node) catch unreachable;

            newnode.data.mux = .{};
            newnode.data.best_eval = 0;
            newnode.data.best_move_start = -1;
            newnode.data.best_move_end = -1;
            newnode.data.live_children = 0;

            @memcpy(&newnode.data.game_id, &state.game_id);
            newnode.data.game_id_sz = state.game_id_sz;
            newnode.data.move_start = @intCast(sq);
            newnode.data.move_end = @intCast(movesq);

            newnode.data.depth = state.depth + 1;
            //TODO increase target depth for certain high priority moves?
            newnode.data.target_depth = state.target_depth;
            newnode.data.parent = state;

            newnode.data.board = state.board;
            newnode.data.board.flags.black_turn = !w_turn;

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

pub fn work() void {
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

        if (d.debug_mode) {
            if (node.data.move_start < 0) {
                std.debug.print("Working on root node\n", .{});
            } else {
                std.debug.print("Working on node {} {s}{s}\n", .{ node.data.depth, sq_str(node.data.move_start), sq_str(node.data.move_end) });
            }
        }

        // expand it if it needs expanding
        if (node.data.depth < node.data.target_depth) {
            if (expand(&node.data)) {
                // added children to the queue, we can drop this and grab more work
                continue;
            }
        }

        // otherwise
        // evaluate it if it wasn't expanded
        // this one doesn't need to be atomic, since it is a leaf
        node.data.best_eval = evaluate(&node.data.board);

        // propagate move values back up the tree, as far as you can
        // freeing memory as we propagate
        // this is where we need to be really careful about races
        // use @fieldParentPtr to get the node to free
        var cnode: *state_node = &node.data;
        var pnode: *state_node = undefined;
        while (true) {
            pnode = cnode;
            cnode = cnode.parent.?;

            // propagate the best_eval, if it is the min/max we want
            const pbest = pnode.best_eval;

            // do the mux instead of atomic

            cnode.mux.lock();
            if (cnode.best_move_start < 0) {
                cnode.best_eval = pbest;
                cnode.best_move_start = pnode.move_start;
                cnode.best_move_end = pnode.move_end;
            } else if (cnode.board.flags.black_turn) {
                // this is black's turn, so it wants the eval that is most negative
                if (pbest < cnode.best_eval) {
                    cnode.best_eval = pbest;
                    cnode.best_move_start = pnode.move_start;
                    cnode.best_move_end = pnode.move_end;
                }
            } else {
                if (pbest > cnode.best_eval) {
                    cnode.best_eval = pbest;
                    cnode.best_move_start = pnode.move_start;
                    cnode.best_move_end = pnode.move_end;
                }
            }

            const prev_child_count = cnode.live_children;
            cnode.live_children -= 1;
            cnode.mux.unlock();

            //std.debug.print("Parent pbest {}, now {}\n", .{ pbest, cnode.best_eval });

            // free the lower node
            const tofree: *WorkQueue.Node = @fieldParentPtr("data", pnode);
            heap.destroy(tofree);

            if (prev_child_count < 1) {
                unreachable;
            } else if (prev_child_count > 1) {
                // we can't go any further, let the other children return to the fold as well
                break;
            }

            if (cnode.parent == null) {
                // if we have returned all the live children, and are the root, we can send a response

                // this is safe because we can only reach this if we were the last child up
                // right?

                (send_move_f.?)(cnode.game_id[0..cnode.game_id_sz], cnode.best_move_start, cnode.best_move_end);

                // free it as well, now that we are done with it
                const roottofree: *WorkQueue.Node = @fieldParentPtr("data", cnode);
                heap.destroy(roottofree);

                break;
            }

            // we are a leaf! Move on up the tree
        }

        // continue to find other work
    }
}

pub fn queue_board(gameid: []const u8, board: *const d.Board, target_depth: u16) void {
    const newnode: *WorkQueue.Node = heap.create(WorkQueue.Node) catch unreachable;

    newnode.data.mux = .{};
    newnode.data.best_eval = 0;
    newnode.data.best_move_start = -1;
    newnode.data.best_move_end = -1;
    newnode.data.live_children = 0;

    @memset(&newnode.data.game_id, 0);
    @memcpy(newnode.data.game_id[0..gameid.len], gameid);
    newnode.data.game_id_sz = @intCast(gameid.len);
    newnode.data.move_start = -1;
    newnode.data.move_end = -1;

    newnode.data.depth = 0;
    //TODO increase target depth for certain high priority moves?
    newnode.data.target_depth = target_depth;
    newnode.data.parent = null;

    newnode.data.board = board.*;

    work_queue_mux.lock();
    work_queue.append(newnode);
    work_queue_mux.unlock();

    work_ready_sem.post();

    std.debug.print("Queued board\n", .{});
}

pub fn parse_fen(fen: []const u8) d.Board {

    //TODO

    _ = fen;
    unreachable;
}

pub fn state_from_moves(moves: []const u8, gi: *d.gameinfo) d.Board {
    var board: d.Board = gi.board_start;

    // progress the board with the moves
    var c: []const u8 = moves;
    var src: usize = 0;
    var dst: usize = 0;

    while (c.len > 0) : (board.flags.black_turn = !board.flags.black_turn) {
        while (c[0] == ' ') : (c = c[1..]) {}

        src = @intCast(str_sq(c));
        c = c[2..];
        dst = @intCast(str_sq(c));
        c = c[2..];

        // handle castling
        // we don't have to make sure it is legal, just handle it and flags
        // no need for checking in between spaces
        if (board.layout[src] == d.Piece.b_rook and src == 0x3c) {
            board.flags.b_can_ooo = false;
        } else if (board.layout[src] == d.Piece.b_rook and src == 0x3f) {
            board.flags.b_can_oo = false;
        } else if (board.layout[src] == d.Piece.w_rook and src == 0x00) {
            board.flags.w_can_ooo = false;
        } else if (board.layout[src] == d.Piece.w_rook and src == 0x07) {
            board.flags.w_can_oo = false;
        } else if (board.layout[src] == d.Piece.b_king) {
            board.flags.b_can_ooo = false;
            board.flags.b_can_oo = false;

            if (src == 0x3c) {
                if (dst == 0x38) {
                    // long
                    board.layout[0x38] = d.Piece.empty;
                    board.occupied &= ~(@as(u64, 1 << 0x38));
                    board.layout[0x3a] = d.Piece.b_king;
                    board.occupied |= (1 << 0x3a);
                    board.layout[0x3b] = d.Piece.b_rook;
                    board.occupied |= (1 << 0x3b);
                    board.layout[0x3c] = d.Piece.empty;
                    board.occupied &= ~(@as(u64, 1 << 0x3c));

                    continue;
                } else if (dst == 0x3f) {
                    // short
                    board.layout[0x3f] = d.Piece.empty;
                    board.occupied &= ~(@as(u64, 1 << 0x3f));
                    board.layout[0x3e] = d.Piece.b_king;
                    board.occupied |= (1 << 0x3e);
                    board.layout[0x3d] = d.Piece.b_rook;
                    board.occupied |= (1 << 0x3d);
                    board.layout[0x3c] = d.Piece.empty;
                    board.occupied &= ~(@as(u64, 1 << 0x3c));

                    continue;
                }
            }
        } else if (board.layout[src] == d.Piece.w_king and src == 0x04) {
            board.flags.w_can_ooo = false;
            board.flags.w_can_oo = false;

            if (src == 0x04) {
                if (dst == 0x00) {
                    // long
                    board.layout[0x00] = d.Piece.empty;
                    board.occupied &= ~(@as(u64, 1 << 0x00));
                    board.white_occupied &= ~(@as(u64, 1 << 0x00));
                    board.layout[0x02] = d.Piece.w_king;
                    board.occupied |= (1 << 0x02);
                    board.white_occupied |= (1 << 0x02);
                    board.layout[0x03] = d.Piece.w_rook;
                    board.occupied |= (1 << 0x03);
                    board.white_occupied |= (1 << 0x03);
                    board.layout[0x04] = d.Piece.empty;
                    board.occupied &= ~(@as(u64, 1 << 0x04));
                    board.white_occupied &= ~(@as(u64, 1 << 0x04));

                    continue;
                } else if (dst == 0x07) {
                    // short
                    board.layout[0x07] = d.Piece.empty;
                    board.occupied &= ~(@as(u64, 1 << 0x07));
                    board.white_occupied &= ~(@as(u64, 1 << 0x07));
                    board.layout[0x06] = d.Piece.w_king;
                    board.occupied |= (1 << 0x06);
                    board.white_occupied |= (1 << 0x06);
                    board.layout[0x05] = d.Piece.w_rook;
                    board.occupied |= (1 << 0x05);
                    board.white_occupied |= (1 << 0x05);
                    board.layout[0x04] = d.Piece.empty;
                    board.occupied &= ~(@as(u64, 1 << 0x04));
                    board.white_occupied &= ~(@as(u64, 1 << 0x04));

                    continue;
                }
            }
        }

        // handle marking flags for enpassantable
        //TODO

        // handle promotion
        if (c.len > 0 and c[0] != ' ') {
            //TODO

            c = c[1..];
        }

        // make the move
        board.layout[dst] = board.layout[src];
        board.layout[src] = d.Piece.empty;
        board.occupied |= @as(u64, @as(u64, 1) << @intCast(dst));
        board.occupied &= ~(@as(u64, @as(u64, 1) << @intCast(src)));
        if (board.layout[dst].is_white()) {
            board.white_occupied |= @as(u64, @as(u64, 1) << @intCast(dst));
            board.white_occupied &= ~(@as(u64, @as(u64, 1) << @intCast(src)));
        }
    }

    return board;
}

pub fn sq_str(sq: i64) [2]u8 {
    if (sq < 0) {
        @panic("Negative square passed to sq_str");
    }
    if (sq >= NUMSQ) {
        @panic("Too large of sq passed to sq_str");
    }

    const rank = sq & (WIDTH - 1);
    const file = sq >> (d.WIDTH_SHIFT);

    var res: [2]u8 = undefined;

    res[0] = "abcdefgh"[@intCast(rank)];
    res[1] = "12345678"[@intCast(file)];

    return res;
}

pub fn str_sq(s: []const u8) i8 {
    if (s[0] > 'g' or s[0] < 'a') {
        unreachable;
    }
    if (s[1] > '8' or s[1] < '1') {
        unreachable;
    }

    var sq: i8 = @intCast(s[0] - 'a');
    sq += @intCast((s[1] - '1') << d.WIDTH_SHIFT);
    return sq;
}
