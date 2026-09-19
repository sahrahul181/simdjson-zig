const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const Vec64u8 = common.Vec64u8;
const Vec32u8 = common.Vec32u8;
const Vec16u8 = common.Vec16u8;

pub const validate = Utf8Validator.validate;

pub const Utf8Validator = struct {
    has_non_ascii: bool = false,

    /// Highly optimized ASCII check. Bitcasting a boolean vector to an integer
    /// forces LLVM to emit a highly efficient `vpmovmskb` (AVX2) or `kmovq` (AVX-512)
    /// instruction on x86, or native `umax`/`umaxv` on ARM64 NEON.
    pub inline fn isAscii64(chunk: Vec64u8) bool {
        if (comptime builtin.cpu.arch == .aarch64 and builtin.cpu.features.isEnabled(@intFromEnum(std.Target.aarch64.Feature.neon))) {
            const chunks: [4]Vec16u8 = @bitCast(chunk);
            const max01 = @max(chunks[0], chunks[1]);
            const max23 = @max(chunks[2], chunks[3]);
            const max_all = @max(max01, max23);
            return @reduce(.Max, max_all) < 0x80;
        } else {
            const i8_chunk: @Vector(64, i8) = @bitCast(chunk);
            const is_neg = i8_chunk < @as(@Vector(64, i8), @splat(0));
            const mask: u64 = @bitCast(is_neg);
            return mask == 0;
        }
    }

    /// Fast SIMD check across two 64-byte chunks (128 bytes total).
    /// Bitwise ORing the chunks before checking halves the number of register tests.
    pub inline fn isAscii128(chunk0: Vec64u8, chunk1: Vec64u8) bool {
        return isAscii64(chunk0 | chunk1);
    }

    /// Validates the full slice for UTF-8 compliance using a Hybrid SIMD-Scalar loop.
    /// It devours ASCII in 128-byte/64-byte chunks. If it hits Unicode, it falls back
    /// to scalar processing just for those multi-byte sequences, and immediately
    /// jumps back to SIMD speeds when ASCII resumes.
    pub fn validate(buf: []const u8) bool {
        var i: usize = 0;

        while (i < buf.len) {
            // 1. 128-byte Ultra-Fast Path
            while (i + 128 <= buf.len) {
                const chunk0: Vec64u8 = buf[i .. i + 64][0..64].*;
                const chunk1: Vec64u8 = buf[i + 64 .. i + 128][0..64].*;
                if (isAscii128(chunk0, chunk1)) {
                    i += 128;
                } else {
                    break;
                }
            }

            // 2. 64-byte Fast Path (to pinpoint the exact non-ASCII block)
            while (i + 64 <= buf.len) {
                const chunk: Vec64u8 = buf[i .. i + 64][0..64].*;
                if (isAscii64(chunk)) {
                    i += 64;
                } else {
                    break; // Block contains non-ASCII, drop to scalar
                }
            }

            // 3. Scalar fallback for exact Unicode sequences
            while (i < buf.len) {
                // Peek ahead: if we hit a clean 64-byte ASCII runway, break the
                // scalar loop and jump back to the SIMD fast paths.
                if (i + 64 <= buf.len) {
                    const next_chunk: Vec64u8 = buf[i .. i + 64][0..64].*;
                    if (isAscii64(next_chunk)) {
                        break;
                    }
                }

                const byte = buf[i];

                // If it's just scalar ASCII, step one byte.
                if (byte < 0x80) {
                    i += 1;
                    continue;
                }

                // Decode and validate the exact multi-byte Unicode sequence
                const n = std.unicode.utf8ByteSequenceLength(byte) catch return false;
                if (i + n > buf.len) return false; // Truncated buffer

                if (!std.unicode.utf8ValidateSlice(buf[i .. i + n])) return false;
                i += n; // Step completely over the unicode character
            }
        }

        return true;
    }
};

test "Utf8Validator ASCII detection" {
    const ascii_text = "Purely ASCII JSON brackets: {\"key\": [1, 2, 3]}!";
    var block: [64]u8 = undefined;
    @memcpy(block[0..ascii_text.len], ascii_text);
    @memset(block[ascii_text.len..], ' ');

    const vec: Vec64u8 = block;
    try std.testing.expect(Utf8Validator.isAscii64(vec));

    // Introduce non-ASCII UTF-8 byte (0xC3 0xA9 = 'é')
    block[10] = 0xC3;
    const non_ascii_vec: Vec64u8 = block;
    try std.testing.expect(!Utf8Validator.isAscii64(non_ascii_vec));
}

test "Utf8Validator edge cases" {
    // Valid multi-byte UTF-8
    try std.testing.expect(Utf8Validator.validate("Hello, 世界! 🚀"));

    // Invalid overlong encoding (0xC0 0x80)
    const overlong = [_]u8{ 'a', 0xC0, 0x80, 'b' };
    try std.testing.expect(!Utf8Validator.validate(&overlong));

    // Invalid surrogate (0xED 0xA0 0x80)
    const surrogate = [_]u8{ 'a', 0xED, 0xA0, 0x80, 'b' };
    try std.testing.expect(!Utf8Validator.validate(&surrogate));

    // Invalid codepoint (> U+10FFFF: 0xF5 0x80 0x80 0x80)
    const too_large = [_]u8{ 0xF5, 0x80, 0x80, 0x80 };
    try std.testing.expect(!Utf8Validator.validate(&too_large));
}

test "Utf8Validator failure scenarios: truncated, orphan continuation, invalid bytes" {
    // 1. Truncated 2-byte sequence (ends prematurely)
    const truncated_2 = [_]u8{ 'a', 0xC3 };
    try std.testing.expect(!Utf8Validator.validate(&truncated_2));

    // 2. Truncated 3-byte sequence
    const truncated_3 = [_]u8{ 'a', 0xE2, 0x82 };
    try std.testing.expect(!Utf8Validator.validate(&truncated_3));

    // 3. Truncated 4-byte sequence
    const truncated_4 = [_]u8{ 'a', 0xF0, 0x9F, 0x98 };
    try std.testing.expect(!Utf8Validator.validate(&truncated_4));

    // 4. Orphan continuation byte without start byte
    const orphan = [_]u8{ 'a', 0x80, 'b' };
    try std.testing.expect(!Utf8Validator.validate(&orphan));

    const orphan_max = [_]u8{ 'a', 0xBF, 'b' };
    try std.testing.expect(!Utf8Validator.validate(&orphan_max));

    // 5. Illegal bytes 0xFE and 0xFF
    const illegal_fe = [_]u8{ 'a', 0xFE, 'b' };
    try std.testing.expect(!Utf8Validator.validate(&illegal_fe));

    const illegal_ff = [_]u8{ 'a', 0xFF, 'b' };
    try std.testing.expect(!Utf8Validator.validate(&illegal_ff));

    // 6. Empty slice
    try std.testing.expect(Utf8Validator.validate(""));

    // 7. Large purely ASCII buffer across multi-64-byte chunks
    var large_ascii: [256]u8 = [_]u8{'a'} ** 256;
    try std.testing.expect(Utf8Validator.validate(&large_ascii));

    // Break in chunk 3 (byte index 140)
    large_ascii[140] = 0xFF;
    try std.testing.expect(!Utf8Validator.validate(&large_ascii));
}
