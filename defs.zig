pub const WIDTH_SHIFT = 3;
pub const WIDTH = 1 << WIDTH_SHIFT;
pub const HEIGHT = WIDTH;
pub const NUMSQ = WIDTH * HEIGHT;

pub const Piece = enum(u4) {
    w_pawn = 0,
    w_knight = 1,
    w_bishop = 2,
    w_rook = 3,
    w_queen = 4,
    w_king = 5,
    b_pawn = 6,
    b_knight = 7,
    b_bishop = 8,
    b_rook = 9,
    b_queen = 10,
    b_king = 11,
    empty = 0xf,
};

pub const BoardFlags = packed struct {
    enpassant_sq: u6,
    black_turn: bool,
    w_can_oo: bool,
    w_can_ooo: bool,
    b_can_oo: bool,
    b_can_ooo: bool,
};

pub const Board = struct {
    flags: BoardFlags,
    layout: [NUMSQ]Piece,
    occupied: u64,
    white_occupied: u64,
};

pub const NUMPIECETYPES = 12;
pub const MAX_ENEMIES = 16;
pub const MAX_PIECES = MAX_ENEMIES * 2;
pub const LUT_MIN_ENEMIES = 1;
pub const LUT_MIN_PIECES = 3;

pub const value_by_num_enemies_t = [MAX_ENEMIES + 1 - LUT_MIN_ENEMIES][NUMPIECETYPES][NUMSQ]i16;
pub const value_by_num_pieces_t = [MAX_PIECES + 1 - LUT_MIN_PIECES][NUMPIECETYPES][NUMSQ]i16;
