const std = @import("std");

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

const lut_init = struct {
    const MagicInfoStarter = struct {
        mask: u64,
        padding: i32,
        magic: u64,
    };

    fn new_starter(comptime m: u64, comptime p: i32, comptime mg: u64) MagicInfoStarter {
        return MagicInfoStarter{
            .mask = m,
            .padding = p,
            .magic = mg,
        };
    }

    //TODO these are terrrrrrible constants
    // because they were calculated without considering
    // good answer collisions can happen
    // so we need to calcuate them again, and hopefully get all <=0 padding
    const bishop_starter = [NUMSQ]MagicInfoStarter{
        new_starter(0x40201008040200, 0, 0x9fe0a01d1d0700b2),
        new_starter(0x402010080400, 0, 0x8c08b87803a2d30f),
        new_starter(0x4020100a00, 0, 0x1a18080b03b9230e),
        new_starter(0x40221400, 0, 0x79680c8f0e74b778),
        new_starter(0x2442800, 0, 0xb18d104185a62863),
        new_starter(0x204085000, 0, 0x7db0108405c7842),
        new_starter(0x20408102000, 0, 0xd656c23030385fa4),
        new_starter(0x2040810204000, 0, 0x6a630242d00c1018),
        new_starter(0x20100804020000, 0, 0xae5c4828a5041c02),
        new_starter(0x40201008040000, 0, 0x39048c7000f718ed),
        new_starter(0x4020100a0000, 0, 0xfb306122278a0104),
        new_starter(0x4022140000, 0, 0x310b2c3c0681888c),
        new_starter(0x244280000, 0, 0x38b8dc504097f1b1),
        new_starter(0x20408500000, 0, 0xa24f60324e0a356),
        new_starter(0x2040810200000, 0, 0xbc40738c102e1088),
        new_starter(0x4081020400000, 0, 0x8ba46e9333006e5),
        new_starter(0x10080402000200, 0, 0xe041421970ac075f),
        new_starter(0x20100804000400, 0, 0x3c9bc8cf0fb216a7),
        new_starter(0x4020100a000a00, 0, 0x4ab0034803c3c27a),
        new_starter(0x402214001400, 0, 0x8b340558094030e2),
        new_starter(0x24428002800, 0, 0x2dcc008a81e0037c),
        new_starter(0x2040850005000, 0, 0xa8460073008db401),
        new_starter(0x4081020002000, 0, 0x86841bc082845050),
        new_starter(0x8102040004000, 0, 0x86dc347b0308d064),
        new_starter(0x8040200020400, 0, 0xe1059d0c0774d8f),
        new_starter(0x10080400040800, 0, 0x2091ab6260080a2d),
        new_starter(0x20100a000a1000, 0, 0x8ae11000fd0c07a0),
        new_starter(0x40221400142200, 0, 0x92c00401c600a038),
        new_starter(0x2442800284400, 0, 0xe806840152812005),
        new_starter(0x4085000500800, 0, 0x325982009362101b),
        new_starter(0x8102000201000, 0, 0x487e0bdbc6014d95),
        new_starter(0x10204000402000, 0, 0x9bd9060989068e91),
        new_starter(0x4020002040800, 0, 0xae3e1a409fe1783c),
        new_starter(0x8040004081000, 0, 0x60380334c1f03c1c),
        new_starter(0x100a000a102000, 0, 0x323abb300b680052),
        new_starter(0x22140014224000, 0, 0xc0a6a0180169010c),
        new_starter(0x44280028440200, 0, 0xbf321206001c00c8),
        new_starter(0x8500050080400, 0, 0x3a6b01c900e60120),
        new_starter(0x10200020100800, 0, 0xe1e70806837d1c11),
        new_starter(0x20400040201000, 0, 0x58081a0b89d742c4),
        new_starter(0x2000204081000, 0, 0xcc78180c35a050ea),
        new_starter(0x4000408102000, 0, 0x8cda51381f79c89d),
        new_starter(0xa000a10204000, 0, 0x4e520a1f00ca800),
        new_starter(0x14001422400000, 0, 0xbeee6ca01105080e),
        new_starter(0x28002844020000, 0, 0xd35b220e0a008401),
        new_starter(0x50005008040200, 0, 0xe0204e0f4ac16601),
        new_starter(0x20002010080400, 0, 0xfff00e0e185c440a),
        new_starter(0x40004020100800, 0, 0x13d00b571b00a657),
        new_starter(0x20408102000, 0, 0xd656c23030385fa4),
        new_starter(0x40810204000, 0, 0x53f194075a506220),
        new_starter(0xa1020400000, 0, 0x629edd444c500371),
        new_starter(0x142240000000, 0, 0x8b83298fc20218c7),
        new_starter(0x284402000000, 0, 0xfb26a5191024191f),
        new_starter(0x500804020000, 0, 0xe273e0ae222a01f8),
        new_starter(0x201008040200, 0, 0x320ac2f760c03ee),
        new_starter(0x402010080400, 0, 0x8c08b87803a2d30f),
        new_starter(0x2040810204000, 0, 0x6a630242d00c1018),
        new_starter(0x4081020400000, 0, 0x8ba46e9333006e5),
        new_starter(0xa102040000000, 0, 0xaed520c3424c3001),
        new_starter(0x14224000000000, 0, 0x53212edf7442120a),
        new_starter(0x28440200000000, 0, 0xc46c403b675cf402),
        new_starter(0x50080402000000, 0, 0xb59d3ca9b06d3603),
        new_starter(0x20100804020000, 0, 0xae5c4828a5041c02),
        new_starter(0x40201008040200, 0, 0x9fe0a01d1d0700b2),
    };

    const rook_starter = [NUMSQ]MagicInfoStarter{
        new_starter(0x101010101017e, 0, 0xe880006cc0017918),
        new_starter(0x202020202027c, 1, 0xac0b0b02e681bc7c),
        new_starter(0x404040404047a, 1, 0xecf914a910699037),
        new_starter(0x8080808080876, 1, 0x3b2e5b2e44a608d2),
        new_starter(0x1010101010106e, 0, 0x960010788c202a00),
        new_starter(0x2020202020205e, 1, 0x9c1273ed8f9544ab),
        new_starter(0x4040404040403e, 0, 0xa400102836890204),
        new_starter(0x8080808080807e, 0, 0x150002039450d100),
        new_starter(0x1010101017e00, 0, 0x2f84800240009364),
        new_starter(0x2020202027c00, 0, 0x15e8802005c0018b),
        new_starter(0x4040404047a00, 0, 0x5f8200220151c280),
        new_starter(0x8080808087600, 0, 0xc1e1002010011902),
        new_starter(0x10101010106e00, 0, 0x688d003068003500),
        new_starter(0x20202020205e00, 0, 0xe3720010a85c6a00),
        new_starter(0x40404040403e00, 0, 0x20fc0004102a383d),
        new_starter(0x80808080807e00, 0, 0xf143003b00034082),
        new_starter(0x10101017e0100, 0, 0x359fe98007400086),
        new_starter(0x20202027c0200, 0, 0x3ee5020046028123),
        new_starter(0x40404047a0400, 0, 0x39e8b60022c20080),
        new_starter(0x8080808760800, 0, 0x12c7e1001901f002),
        new_starter(0x101010106e1000, 0, 0x3d160a00106a0022),
        new_starter(0x202020205e2000, 1, 0x7f5d2494ed4c950b),
        new_starter(0x404040403e4000, 0, 0xa5be9400501a2805),
        new_starter(0x808080807e8000, 0, 0xa24cee000d490984),
        new_starter(0x101017e010100, 0, 0x1e97c00180058471),
        new_starter(0x202027c020200, 0, 0xa64103850021c008),
        new_starter(0x404047a040400, 0, 0x2bc28202002340f2),
        new_starter(0x8080876080800, 0, 0xaf35b86100100101),
        new_starter(0x1010106e101000, 0, 0x167a001e00104b16),
        new_starter(0x2020205e202000, 0, 0x7286006200087084),
        new_starter(0x4040403e404000, 0, 0x73ac700400680146),
        new_starter(0x8080807e808000, 0, 0x322bf5020000c88c),
        new_starter(0x1017e01010100, 0, 0xd12c8a4003800461),
        new_starter(0x2027c02020200, 0, 0xd97b034a02002187),
        new_starter(0x4047a04040400, 0, 0xa6d7764082002201),
        new_starter(0x8087608080800, 0, 0xaf54ea4022001200),
        new_starter(0x10106e10101000, 0, 0xe52a032b6000600),
        new_starter(0x20205e20202000, 0, 0xdf6e0048c2001084),
        new_starter(0x40403e40404000, 0, 0x8ba4ad6e4c001810),
        new_starter(0x80807e80808000, 0, 0xd4252ae6660006ac),
        new_starter(0x17e0101010100, 0, 0x3b938128c002800a),
        new_starter(0x27c0202020200, 0, 0x5830022003d0c004),
        new_starter(0x47a0404040400, 0, 0x9e8de04600820010),
        new_starter(0x8760808080800, 0, 0xfa2b006170010019),
        new_starter(0x106e1010101000, 0, 0x3d160a00106a0022),
        new_starter(0x205e2020202000, 0, 0xe88a005048820024),
        new_starter(0x403e4040404000, 0, 0x4dbf90283d34002a),
        new_starter(0x807e8080808000, 0, 0x57033f8f034e0014),
        new_starter(0x7e010101010100, 0, 0xa09b02c28e5e0e00),
        new_starter(0x7c020202020200, 0, 0xa09b02c28e5e0e00),
        new_starter(0x7a040404040400, 0, 0x3c414420b0820600),
        new_starter(0x76080808080800, 0, 0xc3c9a0fa0012c200),
        new_starter(0x6e101010101000, 0, 0x31ddd60047603200),
        new_starter(0x5e202020202000, 0, 0x2c692040103c5801),
        new_starter(0x3e404040404000, 0, 0x461db03302282c00),
        new_starter(0x7e808080808000, 0, 0xff704507b3b40e00),
        new_starter(0x7e01010101010100, 0, 0xb67262c3d0820102),
        new_starter(0x7c02020202020200, 0, 0xd102f301834003a1),
        new_starter(0x7a04040404040400, 0, 0x1ea5e04472820036),
        new_starter(0x7608080808080800, 0, 0xd67700885d201001),
        new_starter(0x6e10101010101000, 0, 0xc4ce00d8204c5036),
        new_starter(0x5e20202020202000, 0, 0x6632003043341822),
        new_starter(0x3e40404040404000, 0, 0x5376df0824b00a14),
        new_starter(0x7e80808080808000, 0, 0xca450f7231015402),
    };

    fn get_magic_sz() usize {
        var amt: usize = 0;
        var bits: usize = 0;

        for (bishop_starter) |s| {
            bits = @popCount(s.mask);
            bits += s.padding;
            amt += (1 << bits);
        }

        for (rook_starter) |s| {
            bits = @popCount(s.mask);
            bits += s.padding;
            amt += (1 << bits);
        }

        return amt;
    }

    fn get_rook_moves(sq: i32, maskcase: u64) u64 {
        const file = sq >> WIDTH_SHIFT;
        const rank = sq & (WIDTH - 1);

        var moves: u64 = 0;
        var mv: u64 = 0;
        var f: i32 = undefined;
        var r: i32 = undefined;

        f = file + 1;
        r = rank;
        while (f < HEIGHT) : (f += 1) {
            mv = (1 << (r + (f << WIDTH_SHIFT)));
            moves |= mv;

            if ((mv & maskcase) != 0) {
                break;
            }
        }

        f = file - 1;
        r = rank;
        while (f >= 0) : (f -= 1) {
            mv = (1 << (r + (f << WIDTH_SHIFT)));
            moves |= mv;

            if ((mv & maskcase) != 0) {
                break;
            }
        }

        f = file;
        r = rank + 1;
        while (r < WIDTH) : (r += 1) {
            mv = (1 << (r + (f << WIDTH_SHIFT)));
            moves |= mv;

            if ((mv & maskcase) != 0) {
                break;
            }
        }

        f = file;
        r = rank - 1;
        while (r >= 0) : (r -= 1) {
            mv = (1 << (r + (f << WIDTH_SHIFT)));
            moves |= mv;

            if ((mv & maskcase) != 0) {
                break;
            }
        }

        return moves;
    }

    fn get_bishop_moves(sq: i32, maskcase: u64) u64 {
        const file = sq >> WIDTH_SHIFT;
        const rank = sq & (WIDTH - 1);

        var moves: u64 = 0;

        for (0..4) |dir| {
            var off: i32 = 1;
            while (true) : (off += 1) {
                const r: i32 = if ((dir & 1) != 0)
                    rank + off
                else
                    rank - off;
                if (r < 0 or r >= WIDTH) {
                    break;
                }

                const f: i32 = if ((dir & 2) != 0)
                    file + off
                else
                    file - off;
                if (f < 0 or f >= HEIGHT) {
                    break;
                }

                const mv = (1 << (r + (f << WIDTH_SHIFT)));
                moves |= mv;

                if ((mv & maskcase) != 0) {
                    break;
                }
            }
        }

        return moves;
    }

    fn gen_magic(comptime starter: [NUMSQ]MagicInfoStarter, comptime is_bishop: bool, comptime cursor: usize, comptime out_info: *[NUMSQ]MagicInfo, magic_mem: []u64) usize {
        var c = cursor;

        var sq: i32 = 0;

        var shifts: [64]i8 = undefined;

        @setEvalBranchQuota(10000000);

        for (0..WIDTH) |fi| {
            const f = @as(i32, fi);
            for (0..HEIGHT) |ri| {
                const r = @as(i32, ri);

                sq = r + (f * WIDTH);

                const mask = starter[sq].mask;
                const magic = starter[sq].magic;
                const shift = @popCount(starter[sq].mask) + starter[sq].padding;
                const tblsz = (1 << shift);
                const tbl = magic_mem[c..(c + tblsz)];

                out_info[sq] = MagicInfo{
                    .mask = mask,
                    .magic = magic,
                    .shift = 64 - shift,
                    .tbl_off = c,
                };

                c += tblsz;

                // now fill out the tbl based on the masks
                // first build a shift mask to be able to convert from index to masked occ
                var popcount = 0;
                for (0..64) |bit_i| {
                    const s = 1 << bit_i;
                    if ((s & mask) != 0) {
                        shifts[popcount] = (bit_i - popcount);
                        popcount += 1;
                    }
                }

                for (0..(1 << popcount)) |poscase| {
                    var maskcase: u64 = 0;
                    for (0..popcount) |bit_i| {
                        maskcase |= ((poscase & (1 << bit_i)) << shifts[bit_i]);
                    }

                    // make the index from the magic
                    const idx: u64 = (magic *% maskcase) >> (64 - shift);
                    if (idx > tblsz) {
                        @compileError(std.fmt.comptimePrint("magic {} mask {} idx {} shift {} tblsz {}\n", .{ magic, mask, idx, shift, tblsz }));
                    }

                    tbl[idx] = if (is_bishop) get_bishop_moves(sq, maskcase) else get_rook_moves(sq, maskcase);
                }
            }
        }

        return c;
    }

    fn gen_king_moves() [NUMSQ]u64 {
        var moves: [NUMSQ]u64 = undefined;
        var sq_moves: u64 = 0;

        for (0..WIDTH) |fi| {
            const f = @as(i32, fi);
            for (0..HEIGHT) |ri| {
                const r = @as(i32, ri);

                sq_moves = 0;

                if ((r - 1) >= 0) {
                    sq_moves |= (1 << ((r - 1) + (f * WIDTH)));

                    if ((f - 1) >= 0) {
                        sq_moves |= (1 << ((r - 1) + ((f - 1) * WIDTH)));
                    }
                    if ((f + 1) < HEIGHT) {
                        sq_moves |= (1 << ((r - 1) + ((f + 1) * WIDTH)));
                    }
                }
                if ((f - 1) >= 0) {
                    sq_moves |= (1 << (r + ((f - 1) * WIDTH)));
                }
                if ((f + 1) < HEIGHT) {
                    sq_moves |= (1 << (r + ((f + 1) * WIDTH)));
                }
                if ((r + 1) < WIDTH) {
                    sq_moves |= (1 << ((r + 1) + (f * WIDTH)));

                    if ((f - 1) >= 0) {
                        sq_moves |= (1 << ((r + 1) + ((f - 1) * WIDTH)));
                    }
                    if ((f + 1) < HEIGHT) {
                        sq_moves |= (1 << ((r + 1) + ((f + 1) * WIDTH)));
                    }
                }

                moves[r + (f * WIDTH)] = sq_moves;
            }
        }

        return moves;
    }

    fn gen_knight_moves() [NUMSQ]u64 {
        var moves: [NUMSQ]u64 = undefined;
        var sq_moves: u64 = 0;

        for (0..WIDTH) |fi| {
            const f = @as(i32, fi);
            for (0..HEIGHT) |ri| {
                const r = @as(i32, ri);
                sq_moves = 0;

                if ((r - 2) >= 0) {
                    if ((f - 1) >= 0) {
                        sq_moves |= (1 << ((r - 2) + ((f - 1) * WIDTH)));
                    }
                    if ((f + 1) < HEIGHT) {
                        sq_moves |= (1 << ((r - 2) + ((f + 1) * WIDTH)));
                    }
                }
                if ((r - 1) >= 0) {
                    if ((f - 2) >= 0) {
                        sq_moves |= (1 << ((r - 1) + ((f - 2) * WIDTH)));
                    }
                    if ((f + 2) < HEIGHT) {
                        sq_moves |= (1 << ((r - 1) + ((f + 2) * WIDTH)));
                    }
                }
                if ((r + 2) < WIDTH) {
                    if ((f - 1) >= 0) {
                        sq_moves |= (1 << ((r + 2) + ((f - 1) * WIDTH)));
                    }
                    if ((f + 1) < HEIGHT) {
                        sq_moves |= (1 << ((r + 2) + ((f + 1) * WIDTH)));
                    }
                }
                if ((r + 1) < WIDTH) {
                    if ((f - 2) >= 0) {
                        sq_moves |= (1 << ((r + 1) + ((f - 2) * WIDTH)));
                    }
                    if ((f + 2) < HEIGHT) {
                        sq_moves |= (1 << ((r + 1) + ((f + 2) * WIDTH)));
                    }
                }

                moves[r + (f * WIDTH)] = sq_moves;
            }
        }

        return moves;
    }

    fn gen_LUTs() LUTs {
        var out = LUTs{
            .bishop_magic = undefined,
            .rook_magic = undefined,
            .knight_moves = gen_knight_moves(),
            .king_moves = gen_king_moves(),
            .lut_mem = undefined,
        };

        var cursor: usize = 0;
        cursor = gen_magic(bishop_starter, true, cursor, &out.bishop_magic, &out.lut_mem);
        cursor = gen_magic(rook_starter, false, cursor, &out.rook_magic, &out.lut_mem);

        if (cursor != out.lut_mem.len) {
            unreachable;
        }

        return out;
    }
};

const LUTs = extern struct {
    bishop_magic: [NUMSQ]MagicInfo,
    rook_magic: [NUMSQ]MagicInfo,
    knight_moves: [NUMSQ]u64,
    king_moves: [NUMSQ]u64,
    lut_mem: [lut_init.get_magic_sz()]u64,
};

export const g: LUTs = lut_init.gen_LUTs();

comptime {
    //@compileLog(std.fmt.comptimePrint("lut_mem size = {}\n", .{g.lut_mem.len}));
}
