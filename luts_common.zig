const WIDTH_SHIFT = 3;
const WIDTH = 1 << WIDTH_SHIFT;
const HEIGHT = WIDTH;
const NUMSQ = WIDTH * HEIGHT;

const MagicInfo = extern struct {
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
    bishop_magic: [NUMSQ]MagicInfo,
    rook_magic: [NUMSQ]MagicInfo,
    knight_moves: [NUMSQ]u64,
    king_moves: [NUMSQ]u64,
    lut_mem: [LUT_MEM_SZ]u64,
};

//TODO make sure we don't end up with extra weight because gen_LUTS ends up compiled in the binary?
pub extern const g: LUTs;
