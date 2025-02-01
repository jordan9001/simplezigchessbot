const std = @import("std");

const bot = @import("./bot.zig");
const lic = @import("./lichess.zig");

const heap = std.heap.c_allocator;

pub fn main() !void {
    //TODO move lichess stuff to own file
    //TODO add dbg verbosity level param
    //TODO add param for number of threads
    //TODO add param for depth
    //TODO add param for FEN test case
    //TODO accept new games from gameStart and parse FEN for initial start point

    std.debug.print("Starting up\n", .{});

    var threads: [2]std.Thread = undefined;

    const spawn_config = std.Thread.SpawnConfig{};

    // start up our worker threads
    for (0..threads.len) |i| {
        threads[i] = try std.Thread.spawn(spawn_config, bot.work, .{});
    }

    // start the lichess game
    //TODO add a debug mode that does not use lichess
    lic.game();

    // done, signal the workers and wait for them to finish
    std.debug.print("Shutting down\n", .{});

    // signal and wake by posting enough
    bot.shutdown = true;

    for (0..threads.len) |_| {
        bot.work_ready_sem.post();
    }

    // join up
    for (0..threads.len) |i| {
        threads[i].join();
    }

    return;
}
