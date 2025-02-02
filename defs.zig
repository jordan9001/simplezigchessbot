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

    pub fn is_white(piece: Piece) bool {
        const p: u4 = @intFromEnum(piece);
        return (p >= @intFromEnum(Piece.w_pawn) and
            p <= @intFromEnum(Piece.w_king));
    }
};

pub const BoardFlags = packed struct {
    enpassant_sq: u6,
    black_turn: bool,
    w_can_oo: bool,
    w_can_ooo: bool,
    b_can_oo: bool,
    b_can_ooo: bool,
};

pub const START_FLAGS: BoardFlags = .{
    .enpassant_sq = 0,
    .black_turn = false,
    .w_can_oo = true,
    .w_can_ooo = true,
    .b_can_oo = true,
    .b_can_ooo = true,
};

pub const Board = struct {
    flags: BoardFlags,
    layout: [NUMSQ]Piece,
    occupied: u64,
    white_occupied: u64,
};

pub const START_LAYOUT: [NUMSQ]Piece = [NUMSQ]Piece{
    Piece.w_rook, Piece.w_knight, Piece.w_bishop, Piece.w_queen, Piece.w_king, Piece.w_bishop, Piece.w_knight, Piece.w_rook,
    Piece.w_pawn, Piece.w_pawn,   Piece.w_pawn,   Piece.w_pawn,  Piece.w_pawn, Piece.w_pawn,   Piece.w_pawn,   Piece.w_pawn,
    Piece.empty,  Piece.empty,    Piece.empty,    Piece.empty,   Piece.empty,  Piece.empty,    Piece.empty,    Piece.empty,
    Piece.empty,  Piece.empty,    Piece.empty,    Piece.empty,   Piece.empty,  Piece.empty,    Piece.empty,    Piece.empty,
    Piece.empty,  Piece.empty,    Piece.empty,    Piece.empty,   Piece.empty,  Piece.empty,    Piece.empty,    Piece.empty,
    Piece.empty,  Piece.empty,    Piece.empty,    Piece.empty,   Piece.empty,  Piece.empty,    Piece.empty,    Piece.empty,
    Piece.b_pawn, Piece.b_pawn,   Piece.b_pawn,   Piece.b_pawn,  Piece.b_pawn, Piece.b_pawn,   Piece.b_pawn,   Piece.b_pawn,
    Piece.b_rook, Piece.b_knight, Piece.b_bishop, Piece.b_queen, Piece.b_king, Piece.b_bishop, Piece.b_knight, Piece.b_rook,
};

pub const START_OCCUPIED: u64 = 0b11111111_11111111_00000000_00000000_00000000_00000000_11111111_11111111;

pub const START_WHITE_OCCUPIED: u64 = 0b00000000_00000000_00000000_00000000_00000000_00000000_11111111_11111111;

pub const NUMPIECETYPES = 12;
pub const MAX_ENEMIES = 16;
pub const MAX_PIECES = MAX_ENEMIES * 2;
pub const LUT_MIN_ENEMIES = 1;
pub const LUT_MIN_PIECES = 3;
pub const MAX_ID_SZ = 0x10;
pub const DEFAULT_NUM_THREADS = 0x4;

pub const gameinfo = struct {
    id: [MAX_ID_SZ]u8,
    idlen: usize,
    as_black: bool,
    board_start: Board,
};

pub var default_depth: u16 = 4;
pub var debug_mode: bool = false;

pub const value_by_num_enemies_t = [MAX_ENEMIES + 1 - LUT_MIN_ENEMIES][NUMPIECETYPES][NUMSQ]i16;
pub const value_by_num_pieces_t = [MAX_PIECES + 1 - LUT_MIN_PIECES][NUMPIECETYPES][NUMSQ]i16;
