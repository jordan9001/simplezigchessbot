const d = @import("./defs.zig");

pub const MagicInfo = extern struct {
    mask: u64,
    magic: u64,
    shift: u64,
    tbl_off: usize,
};

// see compile log from building luts.zig
// wish we had a way to check this!
// doesn't matter too much if it is too small? The real object is the correct size
const LUT_MEM_SZ = 116864;

const LUTs = extern struct {
    bishop_magic: [d.NUMSQ]MagicInfo,
    rook_magic: [d.NUMSQ]MagicInfo,
    knight_moves: [d.NUMSQ]u64,
    king_moves: [d.NUMSQ]u64,
    lut_mem: [LUT_MEM_SZ]u64,
    value_by_num_enemies: d.value_by_num_enemies_t,
    value_by_num_pieces: d.value_by_num_pieces_t,
};

//TODO make sure we don't end up with extra weight because gen_LUTS ends up compiled in the binary?
pub extern const g: LUTs;
