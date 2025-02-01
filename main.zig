const std = @import("std");

const bot = @import("./bot.zig");
const lic = @import("./lichess.zig");
const d = @import("./defs.zig");

const heap = std.heap.c_allocator;

fn usage() noreturn {
    std.debug.print(
        \\Arguments:
        \\  -h : print this information
        \\  -v : print debug information
        \\  -d : select evalutation depth
        \\
        \\
    , .{});
    std.process.exit(255);
}

pub fn main() !void {
    //TODO add param for number of threads
    //TODO accept new games from gameStart and parse FEN for initial start point

    var args = try std.process.argsWithAllocator(heap);
    _ = args.next();
    while (args.next()) |arg| {
        if (arg[0] != '-') {
            usage();
            return;
        }

        switch (arg[1]) {
            'v' => {
                d.debug_mode = true;
            },
            'd' => {
                const a = args.next();
                if (a == null) {
                    usage();
                }

                d.default_depth = std.fmt.parseUnsigned(u16, a.?, 0) catch usage();
            },
            else => usage(),
        }
    }

    args.deinit();

    std.debug.print("Starting up, using depth of {} \n", .{d.default_depth});

    var threads: [2]std.Thread = undefined;

    const spawn_config = std.Thread.SpawnConfig{};

    // start up our worker threads
    for (0..threads.len) |i| {
        threads[i] = try std.Thread.spawn(spawn_config, bot.work, .{});
    }

    // start the lichess game
    //TODO add a debug mode that does not use lichess
    // for now we can just use the lichess board editor and debug prints
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
