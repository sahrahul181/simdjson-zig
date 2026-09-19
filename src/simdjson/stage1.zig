const std = @import("std");
const error_types = @import("error.zig");
const SimdJsonError = error_types.SimdJsonError;
const Diagnostic = error_types.Diagnostic;
const common = @import("common.zig");
const Vec64u8 = common.Vec64u8;
const Vec64bool = common.Vec64bool;
const StringScanner = common.StringScanner;
const scanBlock64 = common.scanBlock64;
const Utf8Validator = @import("utf8.zig").Utf8Validator;

pub const SIMDJSON_PADDING: usize = 64;

inline fn writeBitsStepped(out: [*]u32, idx: u32, bits: u64) usize {
    if (bits == 0) return 0;
    const cnt: usize = @popCount(bits);
    var b = bits;

    out[0] = idx + @as(u32, @ctz(b));
    b &= b -% 1;
    out[1] = idx + @as(u32, @ctz(b));
    b &= b -% 1;
    out[2] = idx + @as(u32, @ctz(b));
    b &= b -% 1;
    out[3] = idx + @as(u32, @ctz(b));
    b &= b -% 1;

    if (cnt > 4) {
        out[4] = idx + @as(u32, @ctz(b));
        b &= b -% 1;
        out[5] = idx + @as(u32, @ctz(b));
        b &= b -% 1;
        out[6] = idx + @as(u32, @ctz(b));
        b &= b -% 1;
        out[7] = idx + @as(u32, @ctz(b));
        b &= b -% 1;
        if (cnt > 8) {
            var i: usize = 8;
            while (i < cnt) : (i += 1) {
                out[i] = idx + @as(u32, @ctz(b));
                b &= b -% 1;
            }
        }
    }
    return cnt;
}

inline fn writeBitsSafe(out: [*]u32, idx: u32, bits: u64) usize {
    if (bits == 0) return 0;
    const cnt: usize = @popCount(bits);
    var b = bits;
    var i: usize = 0;
    while (i < cnt) : (i += 1) {
        out[i] = idx + @as(u32, @ctz(b));
        b &= b -% 1;
    }
    return cnt;
}

pub const Stage1Indexer = struct {
    pub const Options = struct { validate_utf8: bool = false };

    pub fn indexPadded(buf: []const u8, len: usize, out_indexes: []u32) SimdJsonError!usize {
        return indexPaddedOptions(.{ .validate_utf8 = false }, buf, len, out_indexes);
    }

    pub fn indexPaddedOptions(
        comptime options: Options,
        buf: []const u8,
        len: usize,
        out_indexes: []u32,
    ) SimdJsonError!usize {
        if (len == 0) return error.Empty;
        if (out_indexes.len < len + 3) return error.Capacity;

        var string_scanner = StringScanner{};
        var prev_scalar: u64 = 0;
        var unescaped_error: u64 = 0;
        var out_count: usize = 0;
        var i: usize = 0;
        const out_ptr = out_indexes.ptr;

        var prev_structurals: u64 = 0;
        var prev_idx: u32 = 0;
        var has_non_ascii: bool = false;

        // Cache splatted vector for control character comparison
        const ctrl_char_vec: Vec64u8 = @splat(0x1F);

        // Process 128 bytes per loop iteration
        while (i + 128 <= len) : (i += 128) {
            // 1. PREFETCH NEXT DATA:
            // Tell the CPU to load the data 256 bytes ahead into the L1 cache right now.
            // (The CPU will silently ignore this if it goes slightly out of bounds).
            @prefetch(buf.ptr + i + 256, .{ .rw = .read, .locality = 3, .cache = .data });

            const chunk0: Vec64u8 = buf[i..][0..64].*;
            const chunk1: Vec64u8 = buf[i + 64 ..][0..64].*;

            if (comptime options.validate_utf8) {
                if (!has_non_ascii and !Utf8Validator.isAscii128(chunk0, chunk1)) {
                    has_non_ascii = true;
                }
            }

            const string_block0 = string_scanner.next(chunk0);
            const masks0 = scanBlock64(chunk0);

            const string_block1 = string_scanner.next(chunk1);
            const masks1 = scanBlock64(chunk1);

            out_count += writeBitsStepped(out_ptr + out_count, prev_idx, prev_structurals);

            const nonquote_scalar0 = ~(masks0.op | masks0.whitespace | string_block0.quote);
            const follows0 = (nonquote_scalar0 << 1) | prev_scalar;
            prev_scalar = nonquote_scalar0 >> 63;
            const structural0 = (masks0.op | ~(masks0.whitespace | follows0)) & ~string_block0.stringTail();

            const nonquote_scalar1 = ~(masks1.op | masks1.whitespace | string_block1.quote);
            const follows1 = (nonquote_scalar1 << 1) | prev_scalar;
            prev_scalar = nonquote_scalar1 >> 63;
            const structural1 = (masks1.op | ~(masks1.whitespace | follows1)) & ~string_block1.stringTail();

            // 2. BRANCHLESS CONTROL CHECK:
            // Always execute. The CPU's vector units can calculate `chunk <= 0x1F` faster
            // than the branch predictor can evaluate an `if` statement.
            const c0: u64 = common.checkControlChars(chunk0, ctrl_char_vec);
            const c1: u64 = common.checkControlChars(chunk1, ctrl_char_vec);
            unescaped_error |= (c0 & string_block0.in_string) | (c1 & string_block1.in_string);

            out_count += writeBitsStepped(out_ptr + out_count, @as(u32, @intCast(i)), structural0);

            prev_structurals = structural1;
            prev_idx = @as(u32, @intCast(i + 64));
        }

        // Handle remaining 64-byte chunks
        while (i < len) : (i += 64) {
            const chunk: Vec64u8 = buf[i..][0..64].*;

            if (comptime options.validate_utf8) {
                if (!has_non_ascii and !Utf8Validator.isAscii64(chunk)) has_non_ascii = true;
            }

            const string_block = string_scanner.next(chunk);
            const masks = scanBlock64(chunk);

            out_count += writeBitsStepped(out_ptr + out_count, prev_idx, prev_structurals);

            // Branchless control check here too
            const c: u64 = common.checkControlChars(chunk, ctrl_char_vec);
            unescaped_error |= (c & string_block.in_string);

            const nonquote_scalar = ~(masks.op | masks.whitespace | string_block.quote);
            const follows = (nonquote_scalar << 1) | prev_scalar;
            prev_scalar = nonquote_scalar >> 63;
            var structural = (masks.op | ~(masks.whitespace | follows)) & ~string_block.stringTail();

            if (i + 64 > len) {
                const valid_bits = len - i;
                const mask = if (valid_bits >= 64) ~@as(u64, 0) else (@as(u64, 1) << @as(u6, @intCast(valid_bits))) - 1;
                structural &= mask;
            }

            prev_structurals = structural;
            prev_idx = @as(u32, @intCast(i));
        }

        out_count += writeBitsSafe(out_ptr + out_count, prev_idx, prev_structurals);

        if (string_scanner.isUnclosed()) return error.UnclosedString;
        if (unescaped_error != 0) return error.UnescapedChars;
        if (comptime options.validate_utf8) {
            if (has_non_ascii and !Utf8Validator.validate(buf[0..len])) return error.Utf8Error;
        }
        if (out_count == 0) return error.Empty;

        out_indexes[out_count] = @as(u32, @intCast(len));
        out_indexes[out_count + 1] = @as(u32, @intCast(len));
        out_indexes[out_count + 2] = 0;

        return out_count;
    }

    pub fn indexAlloc(
        allocator: std.mem.Allocator,
        input: []const u8,
        out_indexes: []u32,
    ) (SimdJsonError || std.mem.Allocator.Error)!usize {
        return indexAllocOptions(.{ .validate_utf8 = false }, allocator, input, out_indexes);
    }

    pub fn indexAllocOptions(
        comptime options: Options,
        allocator: std.mem.Allocator,
        input: []const u8,
        out_indexes: []u32,
    ) (SimdJsonError || std.mem.Allocator.Error)!usize {
        if (input.len == 0) return error.Empty;
        // NOTE: Memory allocation and `memcpy` costs time!
        // For absolute maximum throughput, users should use `indexPadded` with pre-padded buffers.
        const padded = try allocator.alloc(u8, input.len + SIMDJSON_PADDING);
        defer allocator.free(padded);

        @memcpy(padded[0..input.len], input);
        @memset(padded[input.len..], ' ');

        return try indexPaddedOptions(options, padded, input.len, out_indexes);
    }

    /// Computes rich line/column diagnostic for a Stage 1 error.
    /// Runs lazily upon error, keeping the SIMD scan loop at zero overhead.
    pub fn getDiagnostic(buf: []const u8, err: SimdJsonError) Diagnostic {
        var byte_offset: usize = 0;
        if (err == error.UnclosedString) {
            // Find the unclosed string quote
            var p = buf.len;
            while (p > 0) {
                p -= 1;
                if (buf[p] == '"') {
                    var bs_count: usize = 0;
                    var b = p;
                    while (b > 0) {
                        b -= 1;
                        if (buf[b] == '\\') bs_count += 1 else break;
                    }
                    if (bs_count % 2 == 0) {
                        byte_offset = p;
                        break;
                    }
                }
            }
        } else if (err == error.UnescapedChars) {
            // Find first control character <= 0x1F inside a string
            var in_str = false;
            var escaped = false;
            for (buf, 0..) |c, idx| {
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (c == '\\' and in_str) {
                    escaped = true;
                    continue;
                }
                if (c == '"') {
                    in_str = !in_str;
                    continue;
                }
                if (in_str and c <= 0x1F) {
                    byte_offset = idx;
                    break;
                }
            }
        } else if (err == error.Utf8Error) {
            byte_offset = 0;
            var i: usize = 0;
            while (i < buf.len) {
                const cp_len = std.unicode.utf8ByteSequenceLength(buf[i]) catch {
                    byte_offset = i;
                    break;
                };
                if (i + cp_len > buf.len) {
                    byte_offset = i;
                    break;
                }
                _ = std.unicode.utf8Decode(buf[i .. i + cp_len]) catch {
                    byte_offset = i;
                    break;
                };
                i += cp_len;
            }
        }
        return Diagnostic.compute(buf, byte_offset, err);
    }

    /// Index structural characters and populate diagnostic on error.
    pub fn indexPaddedWithDiagnostic(
        buf: []const u8,
        len: usize,
        out_indexes: []u32,
        diag: *Diagnostic,
    ) SimdJsonError!usize {
        const res = indexPadded(buf, len, out_indexes);
        if (res) |count| {
            return count;
        } else |err| {
            diag.* = getDiagnostic(buf[0..len], err);
            return err;
        }
    }

    /// Index structural characters with allocation and populate diagnostic on error.
    pub fn indexAllocWithDiagnostic(
        allocator: std.mem.Allocator,
        input: []const u8,
        out_indexes: []u32,
        diag: *Diagnostic,
    ) (SimdJsonError || std.mem.Allocator.Error)!usize {
        const res = indexAlloc(allocator, input, out_indexes);
        if (res) |count| {
            return count;
        } else |err| {
            if (err == error.OutOfMemory) return err;
            diag.* = getDiagnostic(input, @as(SimdJsonError, @errorCast(err)));
            return err;
        }
    }
};

test "basic structural indexing" {
    const json = "{\"a\": 1, \"b\": true, \"c\": null, \"d\": [1, 2]}";
    var indexes: [128]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    const expected = [_]u32{ 0, 1, 4, 6, 7, 9, 12, 14, 18, 20, 23, 25, 29, 31, 34, 36, 37, 38, 40, 41, 42 };
    try std.testing.expectEqual(expected.len, count);
    for (expected, 0..) |exp, idx| {
        try std.testing.expectEqual(exp, indexes[idx]);
    }

    // Check sentinels
    try std.testing.expectEqual(@as(u32, @intCast(json.len)), indexes[count]);
    try std.testing.expectEqual(@as(u32, @intCast(json.len)), indexes[count + 1]);
    try std.testing.expectEqual(@as(u32, 0), indexes[count + 2]);
}

test "operators inside strings are ignored" {
    const json = "{\"key:with,symbols\": \"value:with[more],symbols\"}";
    var indexes: [128]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    const expected = [_]u32{ 0, 1, 19, 21, 47 };
    try std.testing.expectEqual(expected.len, count);
    for (expected, 0..) |exp, idx| {
        try std.testing.expectEqual(exp, indexes[idx]);
    }
}

test "escaped quotes and backslashes" {
    const json = "{\"msg\": \"hello \\\"world\\\" :)\"}";
    var indexes: [128]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    const expected = [_]u32{ 0, 1, 6, 8, 28 };
    try std.testing.expectEqual(expected.len, count);
    for (expected, 0..) |exp, idx| {
        try std.testing.expectEqual(exp, indexes[idx]);
    }
}

test "cross-block escape handling" {
    var padded_buf: [256]u8 = undefined;
    @memset(&padded_buf, ' ');

    const prefix = "{\"msg\": \"";
    @memcpy(padded_buf[0..prefix.len], prefix);
    @memset(padded_buf[prefix.len..63], 'a');
    padded_buf[63] = '\\';

    padded_buf[64] = '"';
    padded_buf[65] = 'e';
    padded_buf[66] = 'n';
    padded_buf[67] = 'd';
    padded_buf[68] = '"';
    padded_buf[69] = '}';
    const doc_len: usize = 70;

    var indexes: [128]u32 = undefined;
    const count = try Stage1Indexer.indexPadded(&padded_buf, doc_len, &indexes);

    const expected = [_]u32{ 0, 1, 6, 8, 69 };
    try std.testing.expectEqual(expected.len, count);
    for (expected, 0..) |exp, idx| {
        try std.testing.expectEqual(exp, indexes[idx]);
    }
}

test "unclosed string error" {
    const json = "{\"msg\": \"hello world";
    var indexes: [128]u32 = undefined;
    try std.testing.expectError(error.UnclosedString, Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes));
}

test "unescaped control character error" {
    const json = "{\"msg\": \"hello\x01world\"}";
    var indexes: [128]u32 = undefined;
    try std.testing.expectError(error.UnescapedChars, Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes));
}

test "empty document error" {
    const json = "   ";
    var indexes: [128]u32 = undefined;
    try std.testing.expectError(error.Empty, Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes));
}

test "valid utf8 indexing" {
    const json = "{\"greeting\": \"こんにちは世界! 🌍\"}";
    var indexes: [128]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);
    try std.testing.expect(count > 0);
}

test "invalid utf8 error" {
    const json = "{\"msg\": \"bad \xC0\x80 text\"}";
    var indexes: [128]u32 = undefined;
    try std.testing.expectError(error.Utf8Error, Stage1Indexer.indexAllocOptions(.{ .validate_utf8 = true }, std.testing.allocator, json, &indexes));
}

test "stage1 capacity error when buffer too small" {
    const json = "{\"key\": [1, 2, 3, 4, 5]}";
    // out_indexes buffer smaller than json.len + 3
    var small_indexes: [10]u32 = undefined;
    try std.testing.expectError(error.Capacity, Stage1Indexer.indexAlloc(std.testing.allocator, json, &small_indexes));
}

test "stage1 empty string or whitespace-only documents" {
    var indexes: [128]u32 = undefined;
    try std.testing.expectError(error.Empty, Stage1Indexer.indexAlloc(std.testing.allocator, "", &indexes));
    try std.testing.expectError(error.Empty, Stage1Indexer.indexAlloc(std.testing.allocator, "   \t\r\n   ", &indexes));
}

test "stage1 primitive documents" {
    var indexes: [128]u32 = undefined;
    
    // Number primitive
    const count_num = try Stage1Indexer.indexAlloc(std.testing.allocator, "12345", &indexes);
    try std.testing.expectEqual(@as(usize, 1), count_num);
    try std.testing.expectEqual(@as(u32, 0), indexes[0]);

    // Boolean primitive
    const count_bool = try Stage1Indexer.indexAlloc(std.testing.allocator, "true", &indexes);
    try std.testing.expectEqual(@as(usize, 1), count_bool);
    try std.testing.expectEqual(@as(u32, 0), indexes[0]);

    // Null primitive
    const count_null = try Stage1Indexer.indexAlloc(std.testing.allocator, "null", &indexes);
    try std.testing.expectEqual(@as(usize, 1), count_null);
    try std.testing.expectEqual(@as(u32, 0), indexes[0]);

    // String primitive
    const count_str = try Stage1Indexer.indexAlloc(std.testing.allocator, "\"hello\"", &indexes);
    try std.testing.expectEqual(@as(usize, 1), count_str);
    try std.testing.expectEqual(@as(u32, 0), indexes[0]);
}

test "stage1 even vs odd backslashes across 64-byte block boundary" {
    // Even backslashes (\\) do NOT escape the quote
    var padded_buf: [256]u8 = undefined;
    @memset(&padded_buf, ' ');

    const prefix = "{\"msg\": \"";
    @memcpy(padded_buf[0..prefix.len], prefix);
    @memset(padded_buf[prefix.len..62], 'a');
    padded_buf[62] = '\\';
    padded_buf[63] = '\\'; // Even number of backslashes before block boundary
    padded_buf[64] = '"';  // Quote is NOT escaped!
    padded_buf[65] = '}';
    const doc_len: usize = 66;

    var indexes: [128]u32 = undefined;
    const count = try Stage1Indexer.indexPadded(&padded_buf, doc_len, &indexes);
    // Structural characters: '{' (0), '"' (1), ':' (6), '"' (8), '}' (65)
    // The quote at 64 closes the string, so '}' at 65 is an operator outside string!
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqual(@as(u32, 65), indexes[4]);
}

test "stage1 deeply nested brackets" {
    var deep_json: [200]u8 = undefined;
    const depth = 50;
    for (0..depth) |i| {
        deep_json[i] = '[';
    }
    deep_json[depth] = '1';
    for (0..depth) |i| {
        deep_json[depth + 1 + i] = ']';
    }
    const total_len = depth * 2 + 1;

    var indexes: [256]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, deep_json[0..total_len], &indexes);
    // 50 '[' + '1' + 50 ']' = 101 structurals
    try std.testing.expectEqual(@as(usize, 101), count);
}

