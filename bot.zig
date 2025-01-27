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

const state_node = struct {
    board: d.Board,
    depth: u16,
    parent: ?*state_node,
    move_start: i8,
    move_end: i8,
    game_id: [*:0]const u8,

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
            state.mux.lock();
            state.live_children += 1;
            state.mux.unlock();

            const newnode: *WorkQueue.Node = heap.create(WorkQueue.Node) catch unreachable;

            newnode.data.mux = .{};
            newnode.data.best_eval = 0;
            newnode.data.best_move_start = -1;
            newnode.data.best_move_end = -1;
            newnode.data.live_children = 0;

            newnode.data.game_id = state.game_id;
            newnode.data.move_start = @intCast(sq);
            newnode.data.move_end = @intCast(movesq);

            newnode.data.depth = state.depth + 1;
            newnode.data.parent = null;
            if (link_parent) {
                newnode.data.parent = state;
            }

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
                cnode.best_move_start = pnode.move_end;
            } else if (cnode.board.flags.black_turn) {
                // this is black's turn, so it wants the eval that is most negative
                if (pbest < cnode.best_eval) {
                    cnode.best_eval = pbest;
                    cnode.best_move_start = pnode.move_start;
                    cnode.best_move_start = pnode.move_end;
                }
            } else {
                if (pbest > cnode.best_eval) {
                    cnode.best_eval = pbest;
                    cnode.best_move_start = pnode.move_start;
                    cnode.best_move_start = pnode.move_end;
                }
            }

            const prev_child_count = cnode.live_children;
            cnode.live_children -= 1;
            cnode.mux.unlock();

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

                send_move(cnode.game_id, cnode.best_move_start, cnode.best_move_end);

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

fn queue_board(gameid: []const u8, board: *const d.Board) void {
    _ = gameid;
    _ = board;
    //TODO
}

fn state_from_moves(moves: []const u8) d.Board {
    var board: d.Board = undefined;
    board.flags = d.START_FLAGS;
    board.layout = d.START_LAYOUT;
    board.occupied = d.START_OCCUPIED;
    board.white_occupied = d.START_WHITE_OCCUPIED;

    // progress the board with the moves
    //TODO
    _ = moves;
    unreachable;
}

fn sq_str(sq: i64) [2]u8 {
    if (sq < 0) {
        @panic("Negative square passed to sq_str");
    }
    if (sq >= NUMSQ) {
        @panic("Too large of sq passed to sq_str");
    }

    const rank = sq & (WIDTH - 1);
    const file = sq >> (d.WIDTH_SHIFT);

    var res: [2]u8 = undefined;

    res[0] = "abcdefg"[@intCast(rank)];
    res[1] = "12345678"[@intCast(file)];

    return res;
}

const MAX_GAMES = 3; //TODO test and raise
const MAX_POLFD = 1 + MAX_GAMES;
const HOST = "lichess.org";
const HTTPS_HOST = "https://" ++ HOST;
const POLL_TIMEOUT = 15000;
const MAX_ID_SZ = 0x10;

const gameinfo = struct {
    id: [MAX_ID_SZ]u8,
    idlen: usize,
    as_black: bool,
};

const game_write_ctx = struct {
    gamecount: usize,
    cmulti: *cURL.CURLM,
    gameinfos: [MAX_GAMES]gameinfo,
};

const one_game_ctx = struct {
    gameinfo: ?*gameinfo,
    gamectx: *game_write_ctx,
};

// TODO wrap game_write_ctx in one that can be game stream specific

fn send_req(path: [:0]const u8, is_post: bool) void {
    var ec: cURL.CURLcode = undefined;
    const chandle = cURL.curl_easy_init();
    if (chandle == null) {
        @panic("Cannot init easy curl handle");
    }

    defer cURL.curl_easy_cleanup(chandle);

    if (is_post) {
        _ = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_POST, @as(c_long, 1));
    } else {
        _ = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_HTTPGET, @as(c_long, 1));
    }
    _ = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_POSTFIELDSIZE, @as(c_long, 0));
    _ = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_URL, path.ptr);
    //_ = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_VERBOSE, @as(c_int, 1));
    _ = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_HTTPHEADER, g_hdr_list.?);
    _ = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_WRITEFUNCTION, &ignore_data_cb);

    ec = cURL.curl_easy_perform(chandle);
    if (ec != cURL.CURLE_OK) {
        std.debug.print("When trying to send {s} to {s}, got error code {}\n", .{ if (is_post) "post" else "get", path, ec });
        return;
    }

    var response_code: c_long = 0;
    _ = cURL.curl_easy_getinfo(chandle, cURL.CURLINFO_RESPONSE_CODE, &response_code);

    std.debug.print("{s} = {}\n", .{ path, response_code });
    if (response_code != 200) {
        // do we need to drop the game or something
        // probably should return an error
        //TODO
    }
}

fn send_move(game_id: [*:0]const u8, best_move_start: i8, best_move_end: i8) void {
    const url = std.fmt.allocPrintZ(heap, HTTPS_HOST ++ "/api/bot/game/{s}/move/{s}{s}", .{ game_id, sq_str(best_move_start), sq_str(best_move_end) }) catch unreachable;
    std.debug.print("Rejecting @ {s}\n", .{url});
    defer heap.free(url);

    send_req(url, true);
}

fn accept_challenge(id: []const u8) void {
    const url = std.fmt.allocPrintZ(heap, HTTPS_HOST ++ "/api/challenge/{s}/accept", .{id}) catch unreachable;
    std.debug.print("Rejecting @ {s}\n", .{url});
    defer heap.free(url);

    send_req(url, true);
}

fn ignore_data_cb(ptr: [*]u8, _: usize, nmemb: usize, ctx: *anyopaque) callconv(.C) usize {
    _ = ptr;
    _ = ctx;

    return nmemb;
}

fn reject_challenge(id: []const u8) void {
    const url = std.fmt.allocPrintZ(heap, HTTPS_HOST ++ "/api/challenge/{s}/decline", .{id}) catch unreachable;
    std.debug.print("Rejecting @ {s}\n", .{url});
    defer heap.free(url);

    send_req(url, true);
}

const stream_msg_type = struct {
    type: []const u8,
};

// gameStart Start of a game
// don't up game count, we do that in challenges
const stream_msg_type_game_evt = struct {
    type: []const u8,
    game: struct {
        id: []const u8,
        //TODO what is fullId about?
        color: []const u8,
        // don't need to parse the fen here, we can use the game stream I think
    },
};

// gameFinish Completion of a game
// match with gameStart

// challenge A player sends you a challenge or you challenge someone
// just need the id to accept the challenge or reject it
const stream_msg_type_challenge = struct {
    type: []const u8,
    challenge: struct {
        id: []const u8,
        finalColor: []const u8,
    },
};

// challengeCanceled A player cancels their challenge to you
// match with challenge

// challengeDeclined The opponent declines your challenge
// Don't care

// gameState Current state of the game. Immutable values not included.
const stream_msg_type_gamestate = struct {
    type: []const u8,
    moves: []const u8,
    //TODO uh oh, there is no ID in this! We have to alter the ctx for the write per game?
};

// gameFull Full game data. All values are immutable, except for the state field.
const stream_msg_type_gamefull = struct {
    type: []const u8,
    state: stream_msg_type_gamestate,
    id: []const u8,
};

// chatLine Chat message sent by a user (or the bot itself) in the room "player" or "spectator".
// Don't care

// opponentGone Whether the opponent has left the game, and how long before you can claim a win or draw.
// Don't care?

fn game_loop_data_cb(ptr: [*]u8, _: usize, nmemb: usize, ctx: *one_game_ctx) callconv(.C) usize {
    // I thiiiiink this will always be in the same thread as game_loop
    // so no locking needed on pointers in ctx
    const data = ptr[0..nmemb];
    const gamectx: *game_write_ctx = ctx.gamectx;

    //DEBUG
    std.debug.print("Debug: {} {s}", .{ nmemb, data });

    if (nmemb <= 1) {
        // just a keepalive
        return nmemb;
    }

    // we only ever get messages here from event stream or a game stream
    // so it will always be json, and include a "type" field"
    const msg_data = std.json.parseFromSlice(
        stream_msg_type,
        heap,
        data,
        .{ .ignore_unknown_fields = true },
    ) catch @panic("unable to parse response from lichess");
    defer msg_data.deinit();

    std.debug.print("Got {s} message\n", .{msg_data.value.type});

    // accept challenges (up to a certain amount of live games)
    if (std.mem.eql(u8, msg_data.value.type, "challenge")) {
        // parse out the id
        const chal_data = std.json.parseFromSlice(
            stream_msg_type_challenge,
            heap,
            data,
            .{ .ignore_unknown_fields = true },
        ) catch @panic("unable to parse challenge msg");
        defer chal_data.deinit();

        if (gamectx.gamecount < MAX_GAMES) {
            // save the game info and accept it

            for (0..gamectx.gameinfos.len) |gi_i| {
                // find first with an empty id
                if (gamectx.gameinfos[gi_i].id[0] != 0) {
                    continue;
                }
                const idlen = chal_data.value.challenge.id.len;
                gamectx.gameinfos[gi_i].idlen = idlen;
                @memcpy(gamectx.gameinfos[gi_i].id[0..idlen], chal_data.value.challenge.id);

                gamectx.gameinfos[gi_i].as_black = true;
                if (std.mem.eql(u8, chal_data.value.challenge.finalColor, "white")) {
                    gamectx.gameinfos[gi_i].as_black = false;
                }

                break;
            } else {
                @panic("All slots taken on gameinfos?");
            }

            gamectx.gamecount += 1;
            accept_challenge(chal_data.value.challenge.id);
        } else {
            reject_challenge(chal_data.value.challenge.id);
        }
    } else if (std.mem.eql(u8, msg_data.value.type, "challengeCanceled")) {
        const chal_data = std.json.parseFromSlice(
            stream_msg_type_challenge,
            heap,
            data,
            .{ .ignore_unknown_fields = true },
        ) catch @panic("unable to parse challenge msg");
        defer chal_data.deinit();

        // if we get a canceled challenge that we accepted, then we need to remove that from the gameinfos
        for (0..gamectx.gameinfos.len) |gi_i| {
            const idlen = gamectx.gameinfos[gi_i].idlen;
            if (std.mem.eql(u8, chal_data.value.challenge.id, gamectx.gameinfos[gi_i].id[0..idlen])) {
                gamectx.gameinfos[gi_i].id[0] = 0;
                gamectx.gameinfos[gi_i].idlen = 0;
                gamectx.gamecount -= 1;
                break;
            }
        } else {
            std.debug.print("Got a cancel for a challenge we haven't stored: {s}\n", .{chal_data.value.challenge.id});
        }
    } else if (std.mem.eql(u8, msg_data.value.type, "gameStart")) {
        const game_data = std.json.parseFromSlice(
            stream_msg_type_game_evt,
            heap,
            data,
            .{ .ignore_unknown_fields = true },
        ) catch @panic("unable to parse game event msg");

        // allocate the new one_game_ctx
        var newctx: *one_game_ctx = heap.create(one_game_ctx) catch unreachable;
        newctx.gamectx = gamectx;

        // check the color/id matches what we are storing
        for (0..gamectx.gameinfos.len) |gi_i| {
            const idlen = gamectx.gameinfos[gi_i].idlen;
            if (std.mem.eql(u8, game_data.value.game.id, gamectx.gameinfos[gi_i].id[0..idlen])) {
                newctx.gameinfo = &gamectx.gameinfos[gi_i];

                // found it, check the colors match

                if (std.mem.eql(u8, game_data.value.game.color, "black") != gamectx.gameinfos[gi_i].as_black) {
                    @panic("gameStart and Challenge colors do not match");
                }
                break;
            }
        } else {
            std.debug.panic("Got a start for a game not from a challenge: {s}\n", .{game_data.value.game.id});
            //TODO just add it if we can? might have been added by hand
        }

        // add the stream for a game start
        // /api/bot/game/stream/{}
        const url = std.fmt.allocPrintZ(heap, HTTPS_HOST ++ "/api/bot/game/stream/{s}", .{game_data.value.game.id}) catch unreachable;

        _ = add_stream(url, newctx);
        heap.free(url); // libcurl docs say we can free this immediately after the curl_easy_setopt
    } else if (std.mem.eql(u8, msg_data.value.type, "gameFinish")) {
        const game_data = std.json.parseFromSlice(
            stream_msg_type_game_evt,
            heap,
            data,
            .{ .ignore_unknown_fields = true },
        ) catch @panic("unable to parse game event msg");

        // close the game stream? Will that happen automatically for us?
        // if not this is a problem since those streams still have pointers to this slot
        // we could store the handle in the gameinfo?
        //TODO test and see!

        // remove the game from our tracked ids
        for (0..gamectx.gameinfos.len) |gi_i| {
            const idlen = gamectx.gameinfos[gi_i].idlen;
            if (std.mem.eql(u8, game_data.value.game.id, gamectx.gameinfos[gi_i].id[0..idlen])) {
                gamectx.gameinfos[gi_i].idlen = 0;
                gamectx.gameinfos[gi_i].id[0] = 0;
                gamectx.gamecount -= 1;
                break;
            }
        } else {
            std.debug.panic("Got a finish for a game we haven't stored: {s}\n", .{game_data.value.game.id});
        }
    } else if ((std.mem.eql(u8, msg_data.value.type, "gameFull")) or (std.mem.eql(u8, msg_data.value.type, "gameState"))) {
        // this one should have a ctx.gameinfo that is non-null
        if (ctx.gameinfo == null) {
            @panic("Game streams should have a gameinfo allocated");
        }

        var state_data: stream_msg_type_gamestate = undefined;
        if (std.mem.eql(u8, msg_data.value.type, "gameFull")) {
            const fullgame_data = std.json.parseFromSlice(
                stream_msg_type_gamefull,
                heap,
                data,
                .{ .ignore_unknown_fields = true },
            ) catch @panic("unable to parse gamefull msg");

            const idlen = ctx.gameinfo.?.idlen;
            if (!std.mem.eql(u8, fullgame_data.value.id, ctx.gameinfo.?.id[0..idlen])) {
                @panic("id does not match in fullgame data");
            }

            state_data = fullgame_data.value.state;
        } else {
            // get the state
            const stategame_data = std.json.parseFromSlice(
                stream_msg_type_gamestate,
                heap,
                data,
                .{ .ignore_unknown_fields = true },
            ) catch @panic("unable to parse game state msg");

            state_data = stategame_data.value;
        }

        const board = state_from_moves(state_data.moves);

        // see if it is my turn or not
        if (board.flags.black_turn == ctx.gameinfo.?.as_black) {
            // when we get a move, make a board and put it on the queue
            queue_board(ctx.gameinfo.?.id[0..ctx.gameinfo.?.idlen], &board);
        }
    }

    return nmemb;
}

fn add_stream(path: [:0]const u8, ctx: *one_game_ctx) *cURL.CURL {
    var ec: cURL.CURLcode = 0;
    var mc: cURL.CURLMcode = 0;

    const chandle = cURL.curl_easy_init() orelse @panic("Can't allocate curl handle");

    ec = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_URL, path.ptr);
    if (ec != cURL.CURLE_OK) {
        @panic("Setopt failed for url");
    }

    ec = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_WRITEFUNCTION, &game_loop_data_cb);
    if (ec != cURL.CURLE_OK) {
        @panic("Setopt failed for writefunction");
    }

    ec = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_WRITEDATA, ctx);
    if (ec != cURL.CURLE_OK) {
        @panic("Setopt failed for writedata");
    }

    ec = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_HTTPHEADER, g_hdr_list.?);
    if (ec != cURL.CURLE_OK) {
        @panic("Setopt failed for headers");
    }

    mc = cURL.curl_multi_add_handle(ctx.gamectx.cmulti, chandle);
    if (mc != cURL.CURLM_OK) {
        @panic("failed to add initial curl handle");
    }

    return chandle;
}

fn game_loop() void {
    var gamectx: game_write_ctx = .{
        .gamecount = 0,
        .cmulti = cURL.curl_multi_init() orelse @panic("Can't init curl multi"),
        .gameinfos = undefined,
    };

    var ctx: one_game_ctx = .{
        .gameinfo = null,
        .gamectx = &gamectx,
    };

    for (&ctx.gamectx.gameinfos) |*gi| {
        // empty id means empty game
        gi.id[0] = 0;
        gi.idlen = 0;
    }

    var mc: cURL.CURLMcode = 0;

    defer {
        mc = cURL.curl_multi_cleanup(ctx.gamectx.cmulti);
        if (mc != cURL.CURLM_OK) {
            std.debug.print("Error cleaning up curl multi: {}\n", .{mc});
        }
    }

    // get stream for overall events
    // /api/stream/event
    const event_stream = add_stream(HTTPS_HOST ++ "/api/stream/event", &ctx);
    defer cURL.curl_easy_cleanup(event_stream);

    // get all our ongoing games, and add them to our set
    // and for each of them that are awaiting our moves, make sure we will handle those?
    // /api/account/playing
    //TODO

    // add streams for each game we are involved with
    // /api/bot/game/stream/{}
    //TODO

    var still_running: c_int = 1;
    var numfds: c_int = 0;
    var remaining: c_int = 0;

    while (still_running != 0) {
        mc = cURL.curl_multi_perform(ctx.gamectx.cmulti, &still_running);

        if (mc == cURL.CURLM_OK and still_running != 0) {
            // poll on the handles
            mc = cURL.curl_multi_wait(ctx.gamectx.cmulti, null, 0, POLL_TIMEOUT, &numfds);
        }

        if (mc != cURL.CURLM_OK) {
            std.debug.panic("Unhandled multi error: {}", .{mc});
        }

        remaining = 1;
        while (remaining > 0) {
            const msg = cURL.curl_multi_info_read(ctx.gamectx.cmulti, &remaining);
            if (msg == null) {
                break;
            }

            if (msg.*.msg != cURL.CURLMSG_DONE) {
                unreachable;
            }

            std.debug.print("Closing handle with status {}", .{msg.*.data.result});

            // we only get here if our streams finish
            // if it is the event stream, what do we do? open another one I guess
            if (msg.*.easy_handle == event_stream) {
                @panic("event stream closed");
            }

            // if it is a game stream, remove it
            // and cancel any moves waiting to be sent?
            mc = cURL.curl_multi_remove_handle(ctx.gamectx.cmulti, msg.*.easy_handle);
            if (mc != cURL.CURLM_OK) {
                std.debug.panic("Unhandled multi error when removing handle: {}", .{mc});
            }

            cURL.curl_easy_cleanup(msg.*.easy_handle);
        }
    }

    std.debug.print("Ending Game Loop\n", .{});
}

var g_hdr_list: ?*cURL.curl_slist = null;

pub fn main() !void {
    std.debug.print("Starting up {}\n", .{luts.g.king_moves.len});

    if (cURL.curl_global_init(cURL.CURL_GLOBAL_ALL) != cURL.CURLE_OK) {
        std.debug.print("Curl Global Init Failed\n", .{});
        return;
    }
    defer cURL.curl_global_cleanup();

    //var threads: [std.Thread.getCpuCount() - 3]std.Thread = undefined;
    //DEBUG
    var threads: [1]std.Thread = undefined;

    const spawn_config = std.Thread.SpawnConfig{};

    // start up our worker threads
    for (0..threads.len) |i| {
        threads[i] = try std.Thread.spawn(spawn_config, work, .{});
    }

    // set up the game handler
    const token = std.c.getenv("LICHESS_TOK") orelse @panic("LICHESS_TOK env var is required");
    // create a global list of headers we can use for every request
    const auth_hdr = try std.fmt.allocPrintZ(heap, "Authorization: Bearer {s}", .{token});
    defer heap.free(auth_hdr);
    g_hdr_list = cURL.curl_slist_append(g_hdr_list, auth_hdr);
    defer cURL.curl_slist_free_all(g_hdr_list);

    game_loop();

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
