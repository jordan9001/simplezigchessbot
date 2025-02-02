const cURL = @cImport({
    @cInclude("curl/curl.h");
});

const std = @import("std");
const bot = @import("./bot.zig");
const d = @import("./defs.zig");

const heap = std.heap.c_allocator;

const MAX_GAMES = 3; //TODO test and raise
const MAX_POLFD = 1 + MAX_GAMES;
const HOST = "lichess.org";
const HTTPS_HOST = "https://" ++ HOST;
const POLL_TIMEOUT = 15000;

const StreamQueue = std.DoublyLinkedList(*one_game_ctx);

const game_write_ctx = struct {
    gamecount: usize,
    cmulti: *cURL.CURLM,
    gameinfos: [MAX_GAMES]d.gameinfo,
    add_stream_queue: StreamQueue,
    rm_stream_queue: StreamQueue,
    target_depth: u16,
};

const one_game_ctx = struct {
    gameinfo: ?*d.gameinfo,
    gamectx: *game_write_ctx,
    stream: ?*cURL.CURL,
};

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
        fen: []const u8,
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
    _ = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_HTTPHEADER, g_hdr_list.?);
    _ = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_WRITEFUNCTION, &ignore_data_cb);

    if (d.debug_mode) {
        //_ = cURL.curl_easy_setopt(chandle, cURL.CURLOPT_VERBOSE, @as(c_int, 1));
    }

    ec = cURL.curl_easy_perform(chandle);
    if (ec != cURL.CURLE_OK) {
        std.debug.print("When trying to send {s} to {s}, got error code {}\n", .{ if (is_post) "post" else "get", path, ec });
        return;
    }

    var response_code: c_long = 0;
    _ = cURL.curl_easy_getinfo(chandle, cURL.CURLINFO_RESPONSE_CODE, &response_code);

    std.debug.print("{s} {s} = {}\n", .{ if (is_post) "POST" else "GET", path, response_code });
    if (response_code != 200) {
        // do we need to drop the game or something
        // probably should return an error
        //TODO
        @panic("Got bad response, maybe illegal move?");
    }
}

fn send_move(game_id: []const u8, best_move_start: i8, best_move_end: i8) void {
    const url = std.fmt.allocPrintZ(heap, HTTPS_HOST ++ "/api/bot/game/{s}/move/{s}{s}", .{ game_id, bot.sq_str(best_move_start), bot.sq_str(best_move_end) }) catch unreachable;
    std.debug.print("Sending @ {s}\n", .{url});
    defer heap.free(url);

    send_req(url, true);
}

fn accept_challenge(id: []const u8) void {
    const url = std.fmt.allocPrintZ(heap, HTTPS_HOST ++ "/api/challenge/{s}/accept", .{id}) catch unreachable;
    std.debug.print("Accepting @ {s}\n", .{url});
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

fn game_loop_data_cb(ptr: [*]u8, _: usize, nmemb: usize, ctx: *one_game_ctx) callconv(.C) usize {
    // I thiiiiink this will always be in the same thread as game_loop
    // so no locking needed on pointers in ctx
    const data = ptr[0..nmemb];
    const gamectx: *game_write_ctx = ctx.gamectx;

    //DEBUG
    if (d.debug_mode) {
        std.debug.print("Debug: {} {s}", .{ nmemb, data });
    }

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
            // just accept it
            // there is a race on the gamecount this way, but TODO
            accept_challenge(chal_data.value.challenge.id);
        } else {
            reject_challenge(chal_data.value.challenge.id);
        }
    } else if (std.mem.eql(u8, msg_data.value.type, "challengeCanceled")) {
        // okay whatever

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
        newctx.stream = null;

        for (0..gamectx.gameinfos.len) |gi_i| {
            // find first with an empty id
            if (gamectx.gameinfos[gi_i].id[0] != 0) {
                continue;
            }

            newctx.gameinfo = &gamectx.gameinfos[gi_i];

            const idlen = game_data.value.game.id.len;
            gamectx.gameinfos[gi_i].idlen = idlen;
            @memset(gamectx.gameinfos[gi_i].id[0..], 0);
            @memcpy(gamectx.gameinfos[gi_i].id[0..idlen], game_data.value.game.id);

            gamectx.gameinfos[gi_i].as_black = true;
            if (std.mem.eql(u8, game_data.value.game.color, "white")) {
                gamectx.gameinfos[gi_i].as_black = false;
            }

            break;
        } else {
            @panic("All slots taken on gameinfos, race from challenges?");
        }

        gamectx.gamecount += 1;

        //TODO parse FEN for initial state
        newctx.gameinfo.?.board_start = bot.parse_fen(game_data.value.game.fen);

        // add the stream for a game start
        // /api/bot/game/stream/{}

        // add to the queue so we can do this outside of the callback
        const new_stream_node = heap.create(StreamQueue.Node) catch unreachable;
        new_stream_node.data = newctx;
        gamectx.add_stream_queue.append(new_stream_node);
    } else if (std.mem.eql(u8, msg_data.value.type, "gameFinish")) {
        // okay, I thiiiiink we can ignore this and just look for a winner field in the state to know when we are done

    } else if ((std.mem.eql(u8, msg_data.value.type, "gameFull")) or (std.mem.eql(u8, msg_data.value.type, "gameState"))) {
        // this one should have a ctx.gameinfo that is non-null
        if (ctx.gameinfo == null) {
            @panic("Game streams should have a gameinfo allocated");
        }

        // don't evaluate positions from finished games
        if (std.mem.indexOf(u8, data, "winner") != null) {
            std.debug.print("Got final state message\n", .{});
            // remove the game from our tracked ids
            ctx.gameinfo.?.idlen = 0;
            ctx.gameinfo.?.id[0] = 0;
            ctx.gameinfo = null;
            gamectx.gamecount -= 1;

            // queue this game stream to be closed
            const new_stream_node = heap.create(StreamQueue.Node) catch unreachable;
            new_stream_node.data = ctx;
            gamectx.rm_stream_queue.append(new_stream_node);
        } else {
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

            const board = bot.state_from_moves(state_data.moves, ctx.gameinfo.?);

            // see if it is my turn or not
            std.debug.print("board_turn = {}, gi_black = {}\n", .{ board.flags.black_turn, ctx.gameinfo.?.as_black });
            if (board.flags.black_turn == ctx.gameinfo.?.as_black) {
                // when we get a move, make a board and put it on the queue
                bot.queue_board(ctx.gameinfo.?.id[0..ctx.gameinfo.?.idlen], &board, gamectx.target_depth);
            }
        }
    }

    return nmemb;
}

fn add_stream(path: [:0]const u8, ctx: *one_game_ctx) *cURL.CURL {
    // can't call from within a callback, btw
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
        std.debug.panic("failed to add initial curl handle for a stream to {s}: {}", .{ path, mc });
    }

    ctx.stream = chandle;

    return chandle;
}

fn game_loop() void {
    var gamectx: game_write_ctx = .{
        .gamecount = 0,
        .cmulti = cURL.curl_multi_init() orelse @panic("Can't init curl multi"),
        .gameinfos = undefined,
        .add_stream_queue = .{},
        .rm_stream_queue = .{},
        .target_depth = d.default_depth,
    };

    var ctx: one_game_ctx = .{
        .gameinfo = null,
        .gamectx = &gamectx,
        .stream = null,
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

            // free the one_game_ctx as well here?
            // or can we free it earlier in a gameFinish message?
        }

        // remove done streams

        while (true) {
            const node: ?*StreamQueue.Node = gamectx.rm_stream_queue.pop();
            if (node == null) {
                break;
            }

            const oldctx: *one_game_ctx = node.?.data;

            heap.destroy(node.?);

            const chandle = oldctx.stream.?;

            heap.destroy(oldctx);

            mc = cURL.curl_multi_remove_handle(ctx.gamectx.cmulti, chandle);
            // if it was already removed, fine, leave it
            // hmmm, is this a UAF kinda situation? do the handles get reused?
            //TODO TODO TODO
            if (mc != cURL.CURLM_OK) {
                std.debug.print("Unhandled multi error when removing rm_queued handle: {}", .{mc});
                //TODO
            } else {
                cURL.curl_easy_cleanup(chandle);
            }

            std.debug.print("Closed a stream\n", .{});
        }

        // add waiting stream nodes

        while (true) {
            const node: ?*StreamQueue.Node = gamectx.add_stream_queue.pop();
            if (node == null) {
                break;
            }

            const newctx: *one_game_ctx = node.?.data;

            heap.destroy(node.?);

            const url = std.fmt.allocPrintZ(heap, HTTPS_HOST ++ "/api/bot/game/stream/{s}", .{newctx.gameinfo.?.id[0..newctx.gameinfo.?.idlen]}) catch unreachable;

            // we can't actually do this here, dang it, add it to some queue I guess
            _ = add_stream(url, newctx);
            heap.free(url); // libcurl docs say we can free this immediately after the curl_easy_setopt
        }

        // close waiting games
        //TODO
    }

    std.debug.print("Ending Game Loop\n", .{});
}

var g_hdr_list: ?*cURL.curl_slist = null;

pub fn game() void {
    std.debug.print("Starting up\n", .{});

    // set the bot to use the correct send_move
    bot.send_move_f = send_move;

    if (cURL.curl_global_init(cURL.CURL_GLOBAL_ALL) != cURL.CURLE_OK) {
        std.debug.print("Curl Global Init Failed\n", .{});
        return;
    }
    defer cURL.curl_global_cleanup();

    // set up the game handler
    const token = std.c.getenv("LICHESS_TOK") orelse @panic("LICHESS_TOK env var is required");
    // create a global list of headers we can use for every request
    const auth_hdr = std.fmt.allocPrintZ(heap, "Authorization: Bearer {s}", .{token}) catch unreachable;
    defer heap.free(auth_hdr);
    g_hdr_list = cURL.curl_slist_append(g_hdr_list, auth_hdr);
    defer cURL.curl_slist_free_all(g_hdr_list);

    game_loop();

    return;
}
