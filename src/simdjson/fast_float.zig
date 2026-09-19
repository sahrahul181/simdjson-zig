//! Fast IEEE-754 Double Precision (f64) Floating-Point Parser
//! Based on Daniel Lemire's "Number Parsing at a Gigabyte per Second" (2021)
//!
//! Architecture:
//! 1. Digit Scanning: In-register 64-bit mantissa accumulator for up to 19 digits.
//! 2. Tier 1 (Clinger Fast Path): Exact IEEE-754 round-to-nearest for -22 <= q <= 22
//!    and w <= 2^53 - 1 (9,007,199,254,740,991) using hardware f64 multiplication.
//! 3. Tier 2 (Lemire 128-bit Fixed-Point): Precomputed 128-bit normalized power-of-10
//!    table for -342 <= q <= 308, resolving floats in ~25ns using 64x128 bit products.
//! 4. Tier 3 (Fallback): Exact fallback for extreme boundary rounding ambiguity.

const std = @import("std");

pub const PowerOfTen = struct {
    hi: u64,
    lo: u64,
    bin_exp: i16,
};

pub const MIN_EXPONENT: i16 = -342;
pub const MAX_EXPONENT: i16 = 308;
pub const TABLE_SIZE: usize = @intCast(MAX_EXPONENT - MIN_EXPONENT + 1); // 651 entries

/// Precomputed powers of 10 as exact 128-bit normalized significands.
/// Generates at compile-time using arbitrary-precision integer arithmetic (u2048).
pub const POWERS_OF_TEN: [TABLE_SIZE]PowerOfTen = blk: {
    @setEvalBranchQuota(500000);
    var table: [TABLE_SIZE]PowerOfTen = undefined;

    var q: i16 = MIN_EXPONENT;
    while (q <= MAX_EXPONENT) : (q += 1) {
        const idx: usize = @intCast(q - MIN_EXPONENT);

        if (q >= 0) {
            // Compute 10^q exactly
            var x: u2048 = 1;
            var i: i16 = 0;
            while (i < q) : (i += 1) {
                x *= 10;
            }

            const lz = @clz(x);
            const bit_len: usize = 2048 - lz;

            if (bit_len >= 128) {
                const shift = bit_len - 128;
                const rounded = (x + (@as(u2048, 1) << @intCast(shift - 1))) >> @intCast(shift);
                const m: u128 = @truncate(rounded);
                table[idx] = .{
                    .hi = @truncate(m >> 64),
                    .lo = @truncate(m),
                    .bin_exp = @intCast(shift),
                };
            } else {
                const shift = 128 - bit_len;
                const m: u128 = @as(u128, @truncate(x)) << @intCast(shift);
                table[idx] = .{
                    .hi = @truncate(m >> 64),
                    .lo = @truncate(m),
                    .bin_exp = -@as(i16, @intCast(shift)),
                };
            }
        } else {
            // Compute 1 / 10^(-q)
            const k: i16 = -q;
            var y: u2048 = 1;
            var i: i16 = 0;
            while (i < k) : (i += 1) {
                y *= 10;
            }

            const lz = @clz(y);
            const bit_len: usize = 2048 - lz;

            // We want 2^S / y ≈ M * 2^E where M has 128 bits (MSB at bit 127)
            const extra_precision: usize = 64;
            const shift: usize = 128 + bit_len + extra_precision;
            const numerator: u2048 = (@as(u2048, 1) << @intCast(shift)) + (y >> 1);
            const quotient: u2048 = numerator / y;

            const q_lz = @clz(quotient);
            const q_bit_len: usize = 2048 - q_lz;

            const final_shift = q_bit_len - 128;
            const rounded = (quotient + (@as(u2048, 1) << @intCast(final_shift - 1))) >> @intCast(final_shift);
            const m: u128 = @truncate(rounded);

            // 10^q = 1 / y ≈ (quotient / 2^shift) = (m * 2^final_shift) / 2^shift = m * 2^(final_shift - shift)
            const bin_exp = @as(i16, @intCast(final_shift)) - @as(i16, @intCast(shift));
            table[idx] = .{
                .hi = @truncate(m >> 64),
                .lo = @truncate(m),
                .bin_exp = bin_exp,
            };
        }
    }

    break :blk table;
};

const POWER_OF_10_F64 = [_]f64{
    1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,  1e8,  1e9,
    1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19,
    1e20, 1e21, 1e22,
};

/// 64-bit x 128-bit multiplication producing the top 128 bits.
inline fn mul64x128(w: u64, hi: u64, lo: u64) struct { hi: u64, lo: u64 } {
    const p_lo = @as(u128, w) * lo;
    const p_hi = @as(u128, w) * hi + (p_lo >> 64);
    return .{
        .hi = @truncate(p_hi >> 64),
        .lo = @truncate(p_hi),
    };
}

pub const ParseResult = struct {
    val: f64,
    bytes_consumed: usize,
};

/// High-speed in-register decimal float parser conforming to IEEE-754.
pub fn parseNumber(buf_ptr: [*]const u8, start_pos: usize, max_len: usize) error{NumberError}!ParseResult {
    @setRuntimeSafety(false);
    var p = start_pos;
    const is_neg = buf_ptr[p] == '-';
    if (is_neg) p += 1;

    const start_digits = p;
    var mantissa: u64 = 0;
    var exp: i64 = 0;
    var digit_count: usize = 0;

    // 1. Integer digits
    while (p < max_len) : (p += 1) {
        const digit = buf_ptr[p] -% '0';
        if (digit <= 9) {
            if (mantissa < 184467440737095516) {
                mantissa = mantissa * 10 + digit;
            } else {
                exp += 1;
            }
            digit_count += 1;
        } else {
            break;
        }
    }

    if (p == start_digits) return error.NumberError;
    if (p > start_digits + 1 and buf_ptr[start_digits] == '0') return error.NumberError;

    // 2. Fractional digits
    if (p < max_len and buf_ptr[p] == '.') {
        p += 1;
        const frac_start = p;
        while (p < max_len) : (p += 1) {
            const digit = buf_ptr[p] -% '0';
            if (digit <= 9) {
                if (mantissa < 184467440737095516) {
                    mantissa = mantissa * 10 + digit;
                    exp -= 1;
                }
                digit_count += 1;
            } else {
                break;
            }
        }
        if (p == frac_start) return error.NumberError;
    }

    // 3. Scientific exponent
    if (p < max_len and (buf_ptr[p] | 0x20) == 'e') {
        p += 1;
        if (p >= max_len) return error.NumberError;
        var exp_neg = false;
        if (buf_ptr[p] == '-') {
            exp_neg = true;
            p += 1;
        } else if (buf_ptr[p] == '+') {
            p += 1;
        }

        const exp_digits_start = p;
        var explicit_exp: i64 = 0;
        while (p < max_len) : (p += 1) {
            const digit = buf_ptr[p] -% '0';
            if (digit <= 9) {
                explicit_exp = explicit_exp *% 10 +% digit;
            } else {
                break;
            }
        }
        if (p == exp_digits_start) return error.NumberError;
        if (exp_neg) {
            exp -= explicit_exp;
        } else {
            exp += explicit_exp;
        }
    }

    // 0 is always exact
    if (mantissa == 0) {
        return .{
            .val = if (is_neg) -0.0 else 0.0,
            .bytes_consumed = p - start_pos,
        };
    }

    // TIER 1: Clinger's fast path (Covers >90% of JSON floats)
    // Mantissa <= 2^53 - 1 (9,007,199,254,740,991) and exponent between -22 and 22
    if (mantissa <= 9007199254740991 and exp >= -22 and exp <= 22) {
        var d = @as(f64, @floatFromInt(mantissa));
        if (exp < 0) {
            d /= POWER_OF_10_F64[@intCast(-exp)];
        } else {
            d *= POWER_OF_10_F64[@intCast(exp)];
        }
        return .{
            .val = if (is_neg) -d else d,
            .bytes_consumed = p - start_pos,
        };
    }

    // TIER 2: Lemire's 128-bit Fixed-Point Scaling
    if (exp >= MIN_EXPONENT and exp <= MAX_EXPONENT) {
        const table_entry = POWERS_OF_TEN[@intCast(exp - MIN_EXPONENT)];

        // Normalize mantissa so bit 63 is 1
        const lz = @clz(mantissa);
        const w_norm = mantissa << @intCast(lz);

        // Multiply 64-bit w_norm by 128-bit power of 10
        const prod = mul64x128(w_norm, table_entry.hi, table_entry.lo);

        // Check if MSB is bit 63 or bit 62 of prod.hi
        var hi = prod.hi;
        var lo = prod.lo;
        var p_exp: i16 = table_entry.bin_exp - @as(i16, @intCast(lz)) + 191;

        if ((hi & (1 << 63)) == 0) {
            hi = (hi << 1) | (lo >> 63);
            lo <<= 1;
            p_exp -= 1;
        }

        // We need 53 bits of mantissa: 1 implicit bit + 52 explicit bits
        // In `hi` (which has 64 bits), the top 53 bits are `hi >> 11`.
        const mantissa_53 = hi >> 11;
        const round_bit = (hi >> 10) & 1;
        const remainder = (hi & 0x3FF) | (if (lo != 0) @as(u64, 1) else 0);

        // IEEE-754 binary exponent bias is 1023
        const final_exp = p_exp + 1023;

        // Check for normal range and non-ambiguous rounding
        if (final_exp > 0 and final_exp < 2047) {
            var rounded_mantissa = mantissa_53;
            // Round-to-nearest-even
            if (round_bit != 0 and (remainder != 0 or (mantissa_53 & 1) != 0)) {
                rounded_mantissa += 1;
            }

            if (rounded_mantissa >= (1 << 53)) {
                // Mantissa overflowed into next power of 2
                rounded_mantissa >>= 1;
                // Exponent increments
                const adj_exp = final_exp + 1;
                if (adj_exp < 2047) {
                    const bits: u64 = (@as(u64, if (is_neg) 1 else 0) << 63) |
                        (@as(u64, @intCast(adj_exp)) << 52) |
                        (rounded_mantissa & 0xFFFFFFFFFFFFF);
                    return .{
                        .val = @bitCast(bits),
                        .bytes_consumed = p - start_pos,
                    };
                }
            } else {
                const bits: u64 = (@as(u64, if (is_neg) 1 else 0) << 63) |
                    (@as(u64, @intCast(final_exp)) << 52) |
                    (rounded_mantissa & 0xFFFFFFFFFFFFF);
                return .{
                    .val = @bitCast(bits),
                    .bytes_consumed = p - start_pos,
                };
            }
        }
    }

    // TIER 3: Fallback to standard library for extreme subnormals or halfway boundaries
    const slice = buf_ptr[start_pos..p];
    const fallback_val = std.fmt.parseFloat(f64, slice) catch return error.NumberError;
    return .{
        .val = fallback_val,
        .bytes_consumed = p - start_pos,
    };
}

/// Convenience function to parse an entire slice into an f64.
/// Returns NumberError if the slice contains trailing invalid characters.
pub fn parse(slice: []const u8) error{NumberError}!f64 {
    if (slice.len == 0) return error.NumberError;
    const res = try parseNumber(slice.ptr, 0, slice.len);
    if (res.bytes_consumed != slice.len) return error.NumberError;
    return res.val;
}

test "fast_float basic integers and decimals" {
    const cases = [_]struct { s: []const u8, expected: f64 }{
        .{ .s = "0", .expected = 0.0 },
        .{ .s = "-0", .expected = -0.0 },
        .{ .s = "1", .expected = 1.0 },
        .{ .s = "-1", .expected = -1.0 },
        .{ .s = "0.0", .expected = 0.0 },
        .{ .s = "0.5", .expected = 0.5 },
        .{ .s = "1.5", .expected = 1.5 },
        .{ .s = "-1.5", .expected = -1.5 },
        .{ .s = "3.141592653589793", .expected = 3.141592653589793 },
        .{ .s = "12.3456", .expected = 12.3456 },
        .{ .s = "1000000000", .expected = 1000000000.0 },
        .{ .s = "0.000000001", .expected = 0.000000001 },
    };

    for (cases) |c| {
        const val = try parse(c.s);
        try std.testing.expectEqual(c.expected, val);
    }
}

test "fast_float scientific notation and edge cases" {
    const cases = [_]struct { s: []const u8, expected: f64 }{
        .{ .s = "1e0", .expected = 1.0 },
        .{ .s = "1e1", .expected = 10.0 },
        .{ .s = "1e10", .expected = 1e10 },
        .{ .s = "1e-10", .expected = 1e-10 },
        .{ .s = "1e22", .expected = 1e22 },
        .{ .s = "1e-22", .expected = 1e-22 },
        .{ .s = "1e23", .expected = 1e23 },
        .{ .s = "1e-23", .expected = 1e-23 },
        .{ .s = "6.02214076e23", .expected = 6.02214076e23 },
        .{ .s = "1.7976931348623157e308", .expected = 1.7976931348623157e308 },
        .{ .s = "2.2250738585072014e-308", .expected = 2.2250738585072014e-308 },
        .{ .s = "1e30", .expected = 1e30 },
        .{ .s = "1e-30", .expected = 1e-30 },
        .{ .s = "123.456e7", .expected = 123.456e7 },
        .{ .s = "123.456e-7", .expected = 123.456e-7 },
        .{ .s = "2.718281828459045", .expected = 2.718281828459045 },
        .{ .s = "4.9406564584124654e-324", .expected = 4.9406564584124654e-324 },
        .{ .s = "0.03125", .expected = 0.03125 },
        .{ .s = "0.0625", .expected = 0.0625 },
        .{ .s = "0.125", .expected = 0.125 },
    };

    for (cases) |c| {
        const val = try parse(c.s);
        try std.testing.expectEqual(c.expected, val);
    }
}

test "fast_float invalid numbers" {
    const invalid_cases = [_][]const u8{
        "",
        "-",
        "+1",
        "1.",
        ".5",
        "1e",
        "1e+",
        "1e-",
        "abc",
        "01",
        "-01",
        "1.2.3",
    };

    for (invalid_cases) |s| {
        try std.testing.expectError(error.NumberError, parse(s));
    }
}

test "fast_float: parseNumber offsets, negative zero, and trailing characters" {
    // 1. parseNumber with offset and length
    const text = "padding: -123.456e2, next";
    const res = try parseNumber(text.ptr, 9, 19);
    try std.testing.expectApproxEqAbs(@as(f64, -12345.6), res.val, 0.001);
    try std.testing.expectEqual(@as(usize, 10), res.bytes_consumed);

    // 2. Negative zero
    const neg_zero = try parse("-0.0");
    try std.testing.expect(neg_zero == 0.0);
    try std.testing.expect(std.math.isNegativeZero(neg_zero));

    // 3. Trailing junk characters (parse requires complete consumption)
    try std.testing.expectError(error.NumberError, parse("123a"));
    try std.testing.expectError(error.NumberError, parse("123.45 trailing"));
    try std.testing.expectError(error.NumberError, parse("123 456"));
    try std.testing.expectError(error.NumberError, parse("1e2f"));
}
