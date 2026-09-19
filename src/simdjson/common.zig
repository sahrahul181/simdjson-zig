const std = @import("std");
const builtin = @import("builtin");

/// Vector types for SIMD operations
pub const Vec64u8 = @Vector(64, u8);
pub const Vec64bool = @Vector(64, bool);
pub const Vec32u8 = @Vector(32, u8);
pub const Vec32bool = @Vector(32, bool);
pub const Vec16u8 = @Vector(16, u8);
pub const Vec16bool = @Vector(16, bool);

/// Structural & Whitespace lookup tables
pub const ws_tbl_16 = [_]u8{ ' ', 100, 100, 100, 17, 100, 113, 2, 100, '\t', '\n', 112, 100, '\r', 100, 100 };
pub const ws_tbl_32: Vec32u8 = ws_tbl_16 ** 2;
pub const ws_tbl_64: Vec64u8 = ws_tbl_16 ** 4;
pub const ws_vec_16: Vec16u8 = ws_tbl_16;

pub const op_tbl_16 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, ':', '{', ',', '}', 0, 0 };
pub const op_tbl_32: Vec32u8 = op_tbl_16 ** 2;
pub const op_tbl_64: Vec64u8 = op_tbl_16 ** 4;
pub const op_vec_16: Vec16u8 = op_tbl_16;

const all_ones_clmul: @Vector(2, u64) = .{ ~@as(u64, 0), ~@as(u64, 0) };

// -----------------------------------------------------------------------------
// COMPTIME ARCHITECTURE ISOLATION
// Hides incompatible inline assembly constraints from the compiler.
// -----------------------------------------------------------------------------

const x86_64_asm = if (builtin.cpu.arch == .x86_64) struct {
    pub inline fn pshufb256(tbl: Vec32u8, indices: Vec32u8) Vec32u8 {
        return asm ("vpshufb %[indices], %[tbl], %[out]"
            : [out] "=x" (-> Vec32u8),
            : [tbl] "x" (tbl),
              [indices] "x" (indices),
        );
    }
    pub inline fn pshufb512(tbl: Vec64u8, indices: Vec64u8) Vec64u8 {
        return asm ("vpshufb %[indices], %[tbl], %[out]"
            : [out] "=v" (-> Vec64u8),
            : [tbl] "v" (tbl),
              [indices] "v" (indices),
        );
    }
    pub inline fn pclmul(val: @Vector(2, u64), ones: @Vector(2, u64)) u64 {
        const res = asm ("vpclmulqdq $0x00, %[all_ones], %[val], %[out]"
            : [out] "=x" (-> @Vector(2, u64)),
            : [val] "x" (val),
              [all_ones] "x" (ones),
        );
        return res[0];
    }
} else struct {};

const aarch64_asm = if (builtin.cpu.arch == .aarch64) struct {
    pub inline fn neon_lookup(tbl: Vec16u8, indices: Vec16u8) Vec16u8 {
        return asm ("tbl %[out].16b, {%[tbl].16b}, %[indices].16b"
            : [out] "=w" (-> Vec16u8),
            : [tbl] "w" (tbl),
              [indices] "w" (indices),
        );
    }
    pub inline fn pmull(val: @Vector(2, u64), ones: @Vector(2, u64)) u64 {
        const res = asm ("pmull %[out].1q, %[val].1d, %[ones].1d"
            : [out] "=w" (-> @Vector(2, u64)),
            : [val] "w" (val),
              [ones] "w" (ones),
        );
        return res[0];
    }
    pub inline fn addp(x: Vec16u8, y: Vec16u8) Vec16u8 {
        return asm ("addp %[out].16b, %[x].16b, %[y].16b"
            : [out] "=w" (-> Vec16u8),
            : [x] "w" (x),
              [y] "w" (y),
        );
    }
} else struct {};

pub const bitmask_neon_16: Vec16u8 = .{ 1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128 };

/// Highly optimized ARM NEON 4-vector bitmask reduction (Daniel Lemire algorithm).
/// Compresses 64 bytes of boolean vector masks into a 64-bit scalar integer in 4 addp instructions.
pub inline fn neonToBitmask64(b0: Vec16bool, b1: Vec16bool, b2: Vec16bool, b3: Vec16bool) u64 {
    const a = @select(u8, b0, bitmask_neon_16, @as(Vec16u8, @splat(0)));
    const b = @select(u8, b1, bitmask_neon_16, @as(Vec16u8, @splat(0)));
    const c = @select(u8, b2, bitmask_neon_16, @as(Vec16u8, @splat(0)));
    const d = @select(u8, b3, bitmask_neon_16, @as(Vec16u8, @splat(0)));

    const p1 = aarch64_asm.addp(a, b);
    const p2 = aarch64_asm.addp(c, d);
    const p3 = aarch64_asm.addp(p1, p2);
    const p4 = aarch64_asm.addp(p3, p3);

    const u64_pair: @Vector(2, u64) = @bitCast(p4);
    return u64_pair[0];
}

// -----------------------------------------------------------------------------
// CORE PARSER LOGIC
// -----------------------------------------------------------------------------

/// Perform a cumulative bitwise XOR, flipping bits each time a 1 is encountered.
pub inline fn prefixXor(bitmask: u64) u64 {
    if (comptime builtin.cpu.arch == .x86_64 and builtin.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.pclmul))) {
        return x86_64_asm.pclmul(.{ bitmask, 0 }, all_ones_clmul);
    } else if (comptime builtin.cpu.arch == .aarch64 and builtin.cpu.features.isEnabled(@intFromEnum(std.Target.aarch64.Feature.aes))) {
        return aarch64_asm.pmull(.{ bitmask, 0 }, all_ones_clmul);
    } else {
        var m = bitmask;
        m ^= m << 1;
        m ^= m << 2;
        m ^= m << 4;
        m ^= m << 8;
        m ^= m << 16;
        m ^= m << 32;
        return m;
    }
}

pub inline fn nextEscapeAndTerminalCode(potential_escape: u64) u64 {
    const ODD_BITS: u64 = 0xAAAAAAAAAAAAAAAA;
    const maybe_escaped = potential_escape << 1;
    const maybe_escaped_and_odd = maybe_escaped | ODD_BITS;
    const even_series = maybe_escaped_and_odd -% potential_escape;
    return even_series ^ ODD_BITS;
}

pub const EscapeScanner = struct {
    next_is_escaped: u64 = 0,

    pub const Result = struct { escaped: u64, escape: u64 };

    pub inline fn next(self: *EscapeScanner, backslash: u64) Result {
        if (backslash == 0) {
            const escaped = self.next_is_escaped;
            self.next_is_escaped = 0;
            return .{ .escaped = escaped, .escape = 0 };
        }
        const escape_and_terminal = nextEscapeAndTerminalCode(backslash & ~self.next_is_escaped);
        const escaped = escape_and_terminal ^ (backslash | self.next_is_escaped);
        const escape = escape_and_terminal & backslash;
        self.next_is_escaped = escape >> 63;
        return .{ .escaped = escaped, .escape = escape };
    }
};

pub const StringBlock = struct {
    escaped: u64,
    quote: u64,
    in_string: u64,

    pub inline fn stringTail(self: StringBlock) u64 {
        return self.in_string ^ self.quote;
    }
    pub inline fn stringContent(self: StringBlock) u64 {
        return self.in_string & ~self.quote;
    }
};

pub const StringScanner = struct {
    escape_scanner: EscapeScanner = .{},
    prev_in_string: u64 = 0,

    pub inline fn next(self: *StringScanner, chunk: Vec64u8) StringBlock {
        if (comptime builtin.cpu.arch == .aarch64 and builtin.cpu.features.isEnabled(@intFromEnum(std.Target.aarch64.Feature.neon))) {
            const chunks: [4]Vec16u8 = @bitCast(chunk);
            const q0 = chunks[0] == @as(Vec16u8, @splat('"'));
            const q1 = chunks[1] == @as(Vec16u8, @splat('"'));
            const q2 = chunks[2] == @as(Vec16u8, @splat('"'));
            const q3 = chunks[3] == @as(Vec16u8, @splat('"'));
            const raw_quote = neonToBitmask64(q0, q1, q2, q3);

            const bs0 = chunks[0] == @as(Vec16u8, @splat('\\'));
            const bs1 = chunks[1] == @as(Vec16u8, @splat('\\'));
            const bs2 = chunks[2] == @as(Vec16u8, @splat('\\'));
            const bs3 = chunks[3] == @as(Vec16u8, @splat('\\'));
            const backslash = neonToBitmask64(bs0, bs1, bs2, bs3);

            return self.nextFromMasks(raw_quote, backslash);
        } else {
            return self.nextFromMasks(@bitCast(chunk == @as(Vec64u8, @splat('"'))), @bitCast(chunk == @as(Vec64u8, @splat('\\'))));
        }
    }

    pub inline fn nextFromMasks(self: *StringScanner, raw_quote: u64, backslash: u64) StringBlock {
        var real_quote = raw_quote;
        var escaped: u64 = 0;
        if (backslash != 0 or self.escape_scanner.next_is_escaped != 0) {
            const esc_res = self.escape_scanner.next(backslash);
            escaped = esc_res.escaped;
            real_quote &= ~escaped;
        }

        const in_string = prefixXor(real_quote) ^ self.prev_in_string;
        self.prev_in_string = @as(u64, @bitCast(@as(i64, @bitCast(in_string)) >> 63));

        return .{ .escaped = escaped, .quote = real_quote, .in_string = in_string };
    }

    pub inline fn isUnclosed(self: StringScanner) bool {
        return self.prev_in_string != 0;
    }
};

pub const BlockMasks = struct {
    whitespace: u64,
    op: u64,
    quote: u64,
    backslash: u64,
};

pub inline fn scanBlock32(c: Vec32u8) struct { ws: u32, op: u32, q: u32, bs: u32 } {
    const q: u32 = @bitCast(c == @as(Vec32u8, @splat('"')));
    const bs: u32 = @bitCast(c == @as(Vec32u8, @splat('\\')));

    if (comptime builtin.cpu.arch == .x86_64 and builtin.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx2))) {
        return .{
            .ws = @bitCast(c == x86_64_asm.pshufb256(ws_tbl_32, c)),
            .op = @bitCast((c | @as(Vec32u8, @splat(0x20))) == x86_64_asm.pshufb256(op_tbl_32, c)),
            .q = q,
            .bs = bs,
        };
    } else {
        unreachable;
    }
}

pub inline fn scanBlock16Neon(c: Vec16u8) struct { ws: u16, op: u16, q: u16, bs: u16 } {
    const q: u16 = @bitCast(c == @as(Vec16u8, @splat('"')));
    const bs: u16 = @bitCast(c == @as(Vec16u8, @splat('\\')));

    if (comptime builtin.cpu.arch == .aarch64 and builtin.cpu.features.isEnabled(@intFromEnum(std.Target.aarch64.Feature.neon))) {
        const low4 = c & @as(Vec16u8, @splat(0x0F));
        return .{
            .ws = @bitCast(c == aarch64_asm.neon_lookup(ws_vec_16, low4)),
            .op = @bitCast((c | @as(Vec16u8, @splat(0x20))) == aarch64_asm.neon_lookup(op_vec_16, low4)),
            .q = q,
            .bs = bs,
        };
    } else {
        unreachable;
    }
}

pub inline fn scanBlock64(chunk: Vec64u8) BlockMasks {
    if (comptime builtin.cpu.arch == .x86_64 and builtin.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx512bw))) {
        return .{
            .whitespace = @bitCast(chunk == x86_64_asm.pshufb512(ws_tbl_64, chunk)),
            .op = @bitCast((chunk | @as(Vec64u8, @splat(0x20))) == x86_64_asm.pshufb512(op_tbl_64, chunk)),
            .quote = @bitCast(chunk == @as(Vec64u8, @splat('"'))),
            .backslash = @bitCast(chunk == @as(Vec64u8, @splat('\\'))),
        };
    } else if (comptime builtin.cpu.arch == .x86_64 and builtin.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx2))) {
        const lo = scanBlock32(@as([2]Vec32u8, @bitCast(chunk))[0]);
        const hi = scanBlock32(@as([2]Vec32u8, @bitCast(chunk))[1]);
        return .{
            .whitespace = @as(u64, lo.ws) | (@as(u64, hi.ws) << 32),
            .op = @as(u64, lo.op) | (@as(u64, hi.op) << 32),
            .quote = @as(u64, lo.q) | (@as(u64, hi.q) << 32),
            .backslash = @as(u64, lo.bs) | (@as(u64, hi.bs) << 32),
        };
    } else if (comptime builtin.cpu.arch == .aarch64 and builtin.cpu.features.isEnabled(@intFromEnum(std.Target.aarch64.Feature.neon))) {
        const chunks: [4]Vec16u8 = @bitCast(chunk);

        // Quotes
        const q0 = chunks[0] == @as(Vec16u8, @splat('"'));
        const q1 = chunks[1] == @as(Vec16u8, @splat('"'));
        const q2 = chunks[2] == @as(Vec16u8, @splat('"'));
        const q3 = chunks[3] == @as(Vec16u8, @splat('"'));

        // Backslashes
        const bs0 = chunks[0] == @as(Vec16u8, @splat('\\'));
        const bs1 = chunks[1] == @as(Vec16u8, @splat('\\'));
        const bs2 = chunks[2] == @as(Vec16u8, @splat('\\'));
        const bs3 = chunks[3] == @as(Vec16u8, @splat('\\'));

        // Whitespace lookup
        const low4_0 = chunks[0] & @as(Vec16u8, @splat(0x0F));
        const low4_1 = chunks[1] & @as(Vec16u8, @splat(0x0F));
        const low4_2 = chunks[2] & @as(Vec16u8, @splat(0x0F));
        const low4_3 = chunks[3] & @as(Vec16u8, @splat(0x0F));

        const ws0 = chunks[0] == aarch64_asm.neon_lookup(ws_vec_16, low4_0);
        const ws1 = chunks[1] == aarch64_asm.neon_lookup(ws_vec_16, low4_1);
        const ws2 = chunks[2] == aarch64_asm.neon_lookup(ws_vec_16, low4_2);
        const ws3 = chunks[3] == aarch64_asm.neon_lookup(ws_vec_16, low4_3);

        // Operator lookup
        const op0 = (chunks[0] | @as(Vec16u8, @splat(0x20))) == aarch64_asm.neon_lookup(op_vec_16, low4_0);
        const op1 = (chunks[1] | @as(Vec16u8, @splat(0x20))) == aarch64_asm.neon_lookup(op_vec_16, low4_1);
        const op2 = (chunks[2] | @as(Vec16u8, @splat(0x20))) == aarch64_asm.neon_lookup(op_vec_16, low4_2);
        const op3 = (chunks[3] | @as(Vec16u8, @splat(0x20))) == aarch64_asm.neon_lookup(op_vec_16, low4_3);

        return .{
            .whitespace = neonToBitmask64(ws0, ws1, ws2, ws3),
            .op = neonToBitmask64(op0, op1, op2, op3),
            .quote = neonToBitmask64(q0, q1, q2, q3),
            .backslash = neonToBitmask64(bs0, bs1, bs2, bs3),
        };
    } else {
        const ws_mask: u64 = @bitCast((chunk == @as(Vec64u8, @splat(' '))) | (chunk == @as(Vec64u8, @splat('\t'))) |
            (chunk == @as(Vec64u8, @splat('\n'))) | (chunk == @as(Vec64u8, @splat('\r'))));
        const op_mask: u64 = @bitCast((chunk == @as(Vec64u8, @splat('{'))) | (chunk == @as(Vec64u8, @splat('}'))) |
            (chunk == @as(Vec64u8, @splat('['))) | (chunk == @as(Vec64u8, @splat(']'))) |
            (chunk == @as(Vec64u8, @splat(':'))) | (chunk == @as(Vec64u8, @splat(','))));

        return .{
            .whitespace = ws_mask,
            .op = op_mask,
            .quote = @bitCast(chunk == @as(Vec64u8, @splat('"'))),
            .backslash = @bitCast(chunk == @as(Vec64u8, @splat('\\'))),
        };
    }
}

/// Vectorized branchless check for ASCII control characters <= 0x1F inside string blocks.
/// Employs single-instruction vpcmpub on AVX-512, vpmovmskb on AVX2, or neonToBitmask64 on ARM64.
pub inline fn checkControlChars(chunk: Vec64u8, ctrl_vec: Vec64u8) u64 {
    if (comptime builtin.cpu.arch == .aarch64 and builtin.cpu.features.isEnabled(@intFromEnum(std.Target.aarch64.Feature.neon))) {
        const chunks: [4]Vec16u8 = @bitCast(chunk);
        const c0 = chunks[0] <= @as(Vec16u8, @splat(0x1F));
        const c1 = chunks[1] <= @as(Vec16u8, @splat(0x1F));
        const c2 = chunks[2] <= @as(Vec16u8, @splat(0x1F));
        const c3 = chunks[3] <= @as(Vec16u8, @splat(0x1F));
        return neonToBitmask64(c0, c1, c2, c3);
    } else {
        return @bitCast(chunk <= ctrl_vec);
    }
}

const hex_lut: [256]u8 = blk: {
    var tab: [256]u8 = [_]u8{255} ** 256;
    for ("0123456789", 0..) |c, i| tab[c] = @intCast(i);
    for ("abcdef", 10..) |c, i| tab[c] = @intCast(i);
    for ("ABCDEF", 10..) |c, i| tab[c] = @intCast(i);
    break :blk tab;
};

/// Branchless inline hex decoder using a 256-byte LUT
pub inline fn decodeHex4(hex: []const u8) !u32 {
    var res: u32 = 0;
    comptime var i = 0;
    inline while (i < 4) : (i += 1) {
        const val = hex_lut[hex[i]];
        if (val == 255) return error.StringError;
        res = (res << 4) | val;
    }
    return res;
}

fn makeSingleBsMask(comptime p: usize) [16]u8 {
    var mask: [16]u8 = [_]u8{0x80} ** 16;
    var dst: usize = 0;
    for (0..16) |src| {
        if (src == p) continue;
        mask[dst] = @intCast(src);
        dst += 1;
    }
    return mask;
}

const single_bs_table: [15]Vec16u8 = blk: {
    var tab: [15]Vec16u8 = undefined;
    for (0..15) |i| {
        tab[i] = makeSingleBsMask(i);
    }
    break :blk tab;
};

fn makeDoubleBsMask(comptime p1: usize, comptime p2: usize) [16]u8 {
    var mask: [16]u8 = [_]u8{0x80} ** 16;
    var dst: usize = 0;
    for (0..16) |src| {
        if (src == p1 or src == p2) continue;
        mask[dst] = @intCast(src);
        dst += 1;
    }
    return mask;
}

const double_bs_table: [256]Vec16u8 = blk: {
    @setEvalBranchQuota(10000);
    var tab: [256]Vec16u8 = [_]Vec16u8{@splat(0x80)} ** 256;
    for (0..14) |p1| {
        for ((p1 + 2)..15) |p2| {
            tab[p1 * 16 + p2] = makeDoubleBsMask(p1, p2);
        }
    }
    break :blk tab;
};

inline fn vpshufb_16(a: Vec16u8, m: Vec16u8) Vec16u8 {
    if (builtin.cpu.arch == .x86_64) {
        return asm (
            \\vpshufb %xmm1, %xmm0, %xmm0
            : [ret] "={xmm0}" (-> Vec16u8),
            : [a] "{xmm0}" (a),
              [m] "{xmm1}" (m),
        );
    } else if (builtin.cpu.arch == .aarch64) {
        return asm (
            \\tbl %[ret].16b, {%[a].16b}, %[m].16b
            : [ret] "=w" (-> Vec16u8),
            : [a] "w" (a),
              [m] "w" (m),
        );
    } else {
        var res: [16]u8 = undefined;
        const a_arr: [16]u8 = a;
        const m_arr: [16]u8 = m;
        for (0..16) |i| {
            const idx = m_arr[i];
            if (idx < 16) {
                res[i] = a_arr[idx];
            } else {
                res[i] = 0;
            }
        }
        return res;
    }
}

/// Unescapes a JSON string slice into a user-provided destination buffer.
/// Returns the unescaped slice.
/// Uses a multi-tier SIMD kernel (32-byte fast scan + 16-byte vpshufb compression for \" and \\).
pub fn unescapeString(raw_str: []const u8, dest_buf: []u8) ![]const u8 {
    // Fast path: SIMD-accelerated check. If no backslashes, return original slice directly (true zero-copy).
    if (std.mem.indexOfScalar(u8, raw_str, '\\') == null) {
        return raw_str;
    }

    if (dest_buf.len < raw_str.len) return error.Capacity;

    var src_i: usize = 0;
    var dst_i: usize = 0;
    const src_ptr = raw_str.ptr;
    const dest_ptr = dest_buf.ptr;

    @setRuntimeSafety(false);

    // Fast 32-byte block scan
    while (src_i + 32 <= raw_str.len) {
        const chunk32 = @as(*align(1) const Vec32u8, @ptrCast(src_ptr + src_i)).*;
        const bs32: u32 = @bitCast(chunk32 == @as(Vec32u8, @splat('\\')));
        if (bs32 == 0) {
            @as(*align(1) Vec32u8, @ptrCast(dest_ptr + dst_i)).* = chunk32;
            src_i += 32;
            dst_i += 32;
            continue;
        }

        // Fast 16-byte lane shuffle compression
        var lane_fell_back = false;
        var lane: usize = 0;
        while (lane < 2) : (lane += 1) {
            if (src_i + 16 > raw_str.len) break;
            const chunk16 = @as(*align(1) const Vec16u8, @ptrCast(src_ptr + src_i)).*;
            const bs16: u16 = @bitCast(chunk16 == @as(Vec16u8, @splat('\\')));

            if (bs16 == 0) {
                @as(*align(1) Vec16u8, @ptrCast(dest_ptr + dst_i)).* = chunk16;
                src_i += 16;
                dst_i += 16;
                continue;
            }

            const pop = @popCount(bs16);
            if (pop == 1) {
                const p: usize = @ctz(bs16);
                if (p < 15) {
                    const esc = src_ptr[src_i + p + 1];
                    if (esc == '"' or esc == '\\' or esc == '/') {
                        const mask = single_bs_table[p];
                        const out_vec = vpshufb_16(chunk16, mask);
                        @as(*align(1) Vec16u8, @ptrCast(dest_ptr + dst_i)).* = out_vec;
                        src_i += 16;
                        dst_i += 15;
                        continue;
                    }
                }
            } else if (pop == 2) {
                const p1: usize = @ctz(bs16);
                const p2: usize = @ctz(bs16 & (bs16 - 1));
                if (p1 < 14 and p2 < 15 and p2 >= p1 + 2) {
                    const esc1 = src_ptr[src_i + p1 + 1];
                    const esc2 = src_ptr[src_i + p2 + 1];
                    if ((esc1 == '"' or esc1 == '\\' or esc1 == '/') and (esc2 == '"' or esc2 == '\\' or esc2 == '/')) {
                        const mask = double_bs_table[p1 * 16 + p2];
                        const out_vec = vpshufb_16(chunk16, mask);
                        @as(*align(1) Vec16u8, @ptrCast(dest_ptr + dst_i)).* = out_vec;
                        src_i += 16;
                        dst_i += 14;
                        continue;
                    }
                }
            }

            // Scalar fallback for this 16-byte block
            const first_bs = @ctz(bs16);
            if (first_bs > 0) {
                @memcpy(dest_ptr[dst_i .. dst_i + first_bs], src_ptr[src_i .. src_i + first_bs]);
                src_i += first_bs;
                dst_i += first_bs;
            }
            lane_fell_back = true;
            break;
        }

        // Process scalar escape if we stopped at backslash
        if (lane_fell_back and src_i < raw_str.len and src_ptr[src_i] == '\\') {
            src_i += 1;
            if (src_i >= raw_str.len) return error.StringError;
            const esc = src_ptr[src_i];
            src_i += 1;
            switch (esc) {
                '"' => { dest_buf[dst_i] = '"'; dst_i += 1; },
                '\\' => { dest_buf[dst_i] = '\\'; dst_i += 1; },
                '/' => { dest_buf[dst_i] = '/'; dst_i += 1; },
                'b' => { dest_buf[dst_i] = '\x08'; dst_i += 1; },
                'f' => { dest_buf[dst_i] = '\x0C'; dst_i += 1; },
                'n' => { dest_buf[dst_i] = '\n'; dst_i += 1; },
                'r' => { dest_buf[dst_i] = '\r'; dst_i += 1; },
                't' => { dest_buf[dst_i] = '\t'; dst_i += 1; },
                'u' => {
                    if (src_i + 4 > raw_str.len) return error.StringError;
                    var cp = try decodeHex4(raw_str[src_i .. src_i + 4]);
                    src_i += 4;
                    if (cp >= 0xD800 and cp <= 0xDBFF) {
                        if (src_i + 6 > raw_str.len or raw_str[src_i] != '\\' or raw_str[src_i + 1] != 'u') {
                            return error.StringError;
                        }
                        const low_cp = try decodeHex4(raw_str[src_i + 2 .. src_i + 6]);
                        if (low_cp < 0xDC00 or low_cp > 0xDFFF) return error.StringError;
                        src_i += 6;
                        cp = 0x10000 + (((cp & 0x03FF) << 10) | (low_cp & 0x03FF));
                    }
                    const written = std.unicode.utf8Encode(@intCast(cp), dest_buf[dst_i..]) catch return error.StringError;
                    dst_i += written;
                },
                else => return error.StringError,
            }
        }
    }

    // Scalar tail loop
    while (src_i < raw_str.len) {
        const c = src_ptr[src_i];
        if (c != '\\') {
            dest_buf[dst_i] = c;
            src_i += 1;
            dst_i += 1;
            continue;
        }

        src_i += 1;
        if (src_i >= raw_str.len) return error.StringError;
        const esc = src_ptr[src_i];
        src_i += 1;
        switch (esc) {
            '"' => { dest_buf[dst_i] = '"'; dst_i += 1; },
            '\\' => { dest_buf[dst_i] = '\\'; dst_i += 1; },
            '/' => { dest_buf[dst_i] = '/'; dst_i += 1; },
            'b' => { dest_buf[dst_i] = '\x08'; dst_i += 1; },
            'f' => { dest_buf[dst_i] = '\x0C'; dst_i += 1; },
            'n' => { dest_buf[dst_i] = '\n'; dst_i += 1; },
            'r' => { dest_buf[dst_i] = '\r'; dst_i += 1; },
            't' => { dest_buf[dst_i] = '\t'; dst_i += 1; },
            'u' => {
                if (src_i + 4 > raw_str.len) return error.StringError;
                var cp = try decodeHex4(raw_str[src_i .. src_i + 4]);
                src_i += 4;
                if (cp >= 0xD800 and cp <= 0xDBFF) {
                    if (src_i + 6 > raw_str.len or raw_str[src_i] != '\\' or raw_str[src_i + 1] != 'u') {
                        return error.StringError;
                    }
                    const low_cp = try decodeHex4(raw_str[src_i + 2 .. src_i + 6]);
                    if (low_cp < 0xDC00 or low_cp > 0xDFFF) return error.StringError;
                    src_i += 6;
                    cp = 0x10000 + (((cp & 0x03FF) << 10) | (low_cp & 0x03FF));
                }
                const written = std.unicode.utf8Encode(@intCast(cp), dest_buf[dst_i..]) catch return error.StringError;
                dst_i += written;
            },
            else => return error.StringError,
        }
    }

    return dest_buf[0..dst_i];
}

/// Allocates an unescaped string copy.
pub fn unescapeStringAlloc(raw_str: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw_str, '\\') == null) {
        return try allocator.dupe(u8, raw_str);
    }

    const dest_buf = try allocator.alloc(u8, raw_str.len);
    errdefer allocator.free(dest_buf);

    const final_slice = try unescapeString(raw_str, dest_buf);

    if (allocator.resize(dest_buf, final_slice.len)) {
        return dest_buf[0..final_slice.len];
    }
    const res = try allocator.dupe(u8, final_slice);
    allocator.free(dest_buf);
    return res;
}

/// Decodes RFC 6901 JSON Pointer token escapes: ~1 -> / and ~0 -> ~
/// If no ~ escape is present, returns raw token directly with zero copies.
pub fn unescapePointerToken(raw: []const u8, buf: []u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '~') == null) {
        return raw;
    }
    if (buf.len < raw.len) return error.Capacity;

    var src: usize = 0;
    var dst: usize = 0;
    while (src < raw.len) {
        const c = raw[src];
        if (c == '~') {
            src += 1;
            if (src >= raw.len) return error.InvalidJsonPointer;
            const next_c = raw[src];
            if (next_c == '0') {
                buf[dst] = '~';
                dst += 1;
            } else if (next_c == '1') {
                buf[dst] = '/';
                dst += 1;
            } else {
                return error.InvalidJsonPointer;
            }
            src += 1;
        } else {
            buf[dst] = c;
            dst += 1;
            src += 1;
        }
    }
    return buf[0..dst];
}

/// Parses an RFC 6901 array index token (unsigned integer with no leading zeros).
pub fn parseArrayIndex(token: []const u8) !usize {
    if (token.len == 0) return error.IndexOutOfBounds;
    if (token.len > 1 and token[0] == '0') return error.IndexOutOfBounds;
    var val: usize = 0;
    for (token) |c| {
        if (c < '0' or c > '9') return error.IndexOutOfBounds;
        const d = c - '0';
        val = std.math.mul(usize, val, 10) catch return error.IndexOutOfBounds;
        val = std.math.add(usize, val, d) catch return error.IndexOutOfBounds;
    }
    return val;
}

/// Tokenizer for RFC 6901 JSON Pointers.
pub const JsonPointerIterator = struct {
    pointer: []const u8,
    pos: usize,

    pub fn init(pointer: []const u8) !JsonPointerIterator {
        if (pointer.len == 0) {
            return .{ .pointer = pointer, .pos = 0 };
        }
        if (pointer[0] != '/') {
            return error.InvalidJsonPointer;
        }
        return .{ .pointer = pointer, .pos = 1 };
    }

    pub fn next(self: *JsonPointerIterator) ?[]const u8 {
        if (self.pos == 0 or self.pos > self.pointer.len) return null;

        const start = self.pos;
        if (std.mem.indexOfScalarPos(u8, self.pointer, start, '/')) |next_slash| {
            self.pos = next_slash + 1;
            return self.pointer[start..next_slash];
        } else {
            self.pos = self.pointer.len + 1;
            return self.pointer[start..];
        }
    }
};

test "decodeHex4: valid and invalid characters" {
    try std.testing.expectEqual(@as(u32, 0x0000), try decodeHex4("0000"));
    try std.testing.expectEqual(@as(u32, 0x1234), try decodeHex4("1234"));
    try std.testing.expectEqual(@as(u32, 0xABCD), try decodeHex4("ABCD"));
    try std.testing.expectEqual(@as(u32, 0xabcd), try decodeHex4("abcd"));
    try std.testing.expectEqual(@as(u32, 0xFFFF), try decodeHex4("FFFF"));

    // Invalid hex digits
    try std.testing.expectError(error.StringError, decodeHex4("123G"));
    try std.testing.expectError(error.StringError, decodeHex4("Z000"));
    try std.testing.expectError(error.StringError, decodeHex4("00-0"));
}

test "unescapeString: zero-copy fast path and standard escapes" {
    var dest: [128]u8 = undefined;

    // 1. True zero-copy: pointer identity preserved
    const clean = "hello world this has no backslashes";
    const res_clean = try unescapeString(clean, &dest);
    try std.testing.expectEqual(clean.ptr, res_clean.ptr);

    // 2. All standard escape characters
    const escaped = "quote: \\\", slash: \\\\, fwd: \\/, bs: \\b, ff: \\f, nl: \\n, cr: \\r, tab: \\t";
    const expected = "quote: \", slash: \\, fwd: /, bs: \x08, ff: \x0C, nl: \n, cr: \r, tab: \t";
    const res_escaped = try unescapeString(escaped, &dest);
    try std.testing.expectEqualStrings(expected, res_escaped);

    // 3. Unicode escape and surrogate pairs
    const unicode_src = "A\\u0042C \\u00E9 \\uD83D\\uDE00!";
    const res_uni = try unescapeString(unicode_src, &dest);
    try std.testing.expectEqualStrings("ABC \xc3\xa9 \xf0\x9f\x98\x80!", res_uni);
}

test "unescapeString: failure scenarios" {
    var dest: [32]u8 = undefined;

    // 1. Destination capacity error
    const long_escaped = "1234567890123456789012345678901234567890\\n";
    try std.testing.expectError(error.Capacity, unescapeString(long_escaped, &dest));

    // 2. Trailing backslash at end of input
    var dest2: [64]u8 = undefined;
    try std.testing.expectError(error.StringError, unescapeString("invalid trailing \\", &dest2));

    // 3. Invalid unicode hex sequence
    try std.testing.expectError(error.StringError, unescapeString("bad hex \\u123Z", &dest2));

    // 4. Truncated unicode sequence
    try std.testing.expectError(error.StringError, unescapeString("truncated \\u12", &dest2));

    // 5. Unpaired surrogate (high surrogate without low surrogate)
    try std.testing.expectError(error.StringError, unescapeString("unpaired \\uD83D without low", &dest2));
}

test "parseArrayIndex: standard and edge cases" {
    try std.testing.expectEqual(@as(usize, 0), try parseArrayIndex("0"));
    try std.testing.expectEqual(@as(usize, 42), try parseArrayIndex("42"));
    try std.testing.expectEqual(@as(usize, 9999), try parseArrayIndex("9999"));

    // Invalid non-digits
    try std.testing.expectError(error.IndexOutOfBounds, parseArrayIndex(""));
    try std.testing.expectError(error.IndexOutOfBounds, parseArrayIndex("-1"));
    try std.testing.expectError(error.IndexOutOfBounds, parseArrayIndex("12a"));
    try std.testing.expectError(error.IndexOutOfBounds, parseArrayIndex("abc"));
}

test "JsonPointerIterator: parsing and validation" {
    // 1. Missing leading slash
    try std.testing.expectError(error.InvalidJsonPointer, JsonPointerIterator.init("foo/bar"));

    // 2. Empty string pointer (root)
    var it_root = try JsonPointerIterator.init("");
    try std.testing.expect(it_root.next() == null);

    // 3. Single slash (empty key "/")
    var it_slash = try JsonPointerIterator.init("/");
    try std.testing.expectEqualStrings("", it_slash.next().?);
    try std.testing.expect(it_slash.next() == null);

    // 4. Multiple segments
    var it_multi = try JsonPointerIterator.init("/users/0/profile/name");
    try std.testing.expectEqualStrings("users", it_multi.next().?);
    try std.testing.expectEqualStrings("0", it_multi.next().?);
    try std.testing.expectEqualStrings("profile", it_multi.next().?);
    try std.testing.expectEqualStrings("name", it_multi.next().?);
    try std.testing.expect(it_multi.next() == null);
}

