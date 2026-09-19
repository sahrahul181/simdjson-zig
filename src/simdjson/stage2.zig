const std = @import("std");
const builtin = @import("builtin");
const error_types = @import("error.zig");
const SimdJsonError = error_types.SimdJsonError;
const Diagnostic = error_types.Diagnostic;
const tape = @import("tape.zig");
const TapeTag = tape.TapeTag;
const TapeWriter = tape.TapeWriter;
const TapeEntry = tape.TapeEntry;
const fast_float = @import("fast_float.zig");

pub const Stage2Parser = struct {
    const MAX_DEPTH = 1024;

    const Container = struct {
        tape_idx: usize,
        is_array: bool,
    };

    const ScanVecLen = if (builtin.cpu.arch == .aarch64)
        16
    else if (builtin.cpu.arch == .x86_64 and builtin.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx512bw)))
        64
    else
        32;

    const ScanVec = @Vector(ScanVecLen, u8);
    const ScanMask = std.meta.Int(.unsigned, ScanVecLen);

    pub inline fn findStringEnd(buf_ptr: [*]const u8, start_pos: usize) usize {
        var p = start_pos;
        while (true) {
            const chunk = @as(*align(1) const ScanVec, @ptrCast(buf_ptr + p)).*;
            const quote_bits: ScanMask = @bitCast(chunk == @as(ScanVec, @splat('"')));
            const bs_bits: ScanMask = @bitCast(chunk == @as(ScanVec, @splat('\\')));

            if (((bs_bits -% 1) & quote_bits) != 0) {
                return p + @ctz(quote_bits);
            }

            if (bs_bits != 0) {
                p += @ctz(bs_bits) + 2;
                continue;
            }
            p += ScanVecLen;
        }
    }

    /// INLINED HOT PATH: Unbounded branchless integer accumulation
    pub inline fn parseNumber(
        buf_ptr: [*]const u8,
        pos: usize,
        writer: *TapeWriter,
    ) SimdJsonError!void {
        var p = pos;
        const is_neg = buf_ptr[p] == '-';
        if (is_neg) p += 1;

        const start_digits = p;
        var val: u64 = 0;

        while (true) : (p += 1) {
            const digit = buf_ptr[p] -% '0';
            if (digit <= 9) {
                val = val *% 10 +% digit;
            } else {
                break;
            }
        }

        // Post-loop validation
        if (p == start_digits) return error.NumberError;
        if (p > start_digits + 1 and buf_ptr[start_digits] == '0') return error.NumberError;

        const c = buf_ptr[p];
        if (c != '.' and (c | 0x20) != 'e') {
            if (is_neg) {
                writer.appendInt64(-@as(i64, @intCast(val)));
            } else {
                writer.appendUint64(val);
            }
            return;
        }

        return parseFloatCold(buf_ptr, pos, writer);
    }

    /// COLD PATH: High-speed Lemire IEEE-754 decimal float parser
    fn parseFloatCold(
        buf_ptr: [*]const u8,
        pos: usize,
        writer: *TapeWriter,
    ) SimdJsonError!void {
        const res = fast_float.parseNumber(buf_ptr, pos, std.math.maxInt(usize)) catch return error.NumberError;
        const end = pos + res.bytes_consumed;
        const term = buf_ptr[end];
        if (term != ',' and term != '}' and term != ']' and term > ' ') {
            return error.NumberError;
        }
        writer.appendDouble(res.val);
    }

    pub inline fn parsePrimitive(
        buf_ptr: [*]const u8,
        indexes_ptr: [*]const u32,
        cur_struct: usize,
        writer: *TapeWriter,
    ) SimdJsonError!usize {
        const pos = indexes_ptr[cur_struct];
        const c = buf_ptr[pos];

        switch (c) {
            '"' => {
                const str_end = findStringEnd(buf_ptr, pos + 1);
                writer.append2(str_end - (pos + 1), pos + 1, .STRING);
                return cur_struct + 1;
            },
            't' => {
                const val = @as(*align(1) const u32, @ptrCast(buf_ptr + pos)).*;
                if (val != 0x65757274) return error.TAtomError;
                writer.append(0, .TRUE);
                return cur_struct + 1;
            },
            'f' => {
                const val = @as(*align(1) const u32, @ptrCast(buf_ptr + pos)).*;
                if (val != 0x736c6166 or buf_ptr[pos + 4] != 'e') return error.FAtomError;
                writer.append(0, .FALSE);
                return cur_struct + 1;
            },
            'n' => {
                const val = @as(*align(1) const u32, @ptrCast(buf_ptr + pos)).*;
                if (val != 0x6c6c756e) return error.NAtomError;
                writer.append(0, .NULL);
                return cur_struct + 1;
            },
            '-', '0'...'9' => {
                try parseNumber(buf_ptr, pos, writer);
                return cur_struct + 1;
            },
            else => return error.TapeError,
        }
    }

    /// Parse a single JSON document from a stream starting at `cur_struct_ptr.*`.
    /// Returns the tape length for this document and advances `cur_struct_ptr.*` to the next document in the stream.
    /// Returns null when the stream reaches EOF.
    pub inline fn parseSingle(
        buf: []const u8,
        indexes: []const u32,
        structurals_count: usize,
        cur_struct_ptr: *usize,
        tape_buf: []u64,
    ) SimdJsonError!?usize {
        @setRuntimeSafety(false);

        var cur_struct: usize = cur_struct_ptr.*;
        errdefer cur_struct_ptr.* = cur_struct;
        if (cur_struct >= structurals_count) return null;
        if (tape_buf.len < 4) return error.Capacity;

        var writer = TapeWriter.init(tape_buf);
        const root_tape_idx = writer.skip();

        var container_stack: [MAX_DEPTH]Container = undefined;
        var depth: usize = 0;
        var in_array = false;

        const buf_ptr = buf.ptr;
        const indexes_ptr = indexes.ptr;

        while (cur_struct < structurals_count) {
            const pos = indexes_ptr[cur_struct];
            const c = buf_ptr[pos];

            if (depth == 0) {
                if (c == '{') {
                    container_stack[0] = .{ .tape_idx = writer.skip(), .is_array = false };
                    in_array = false;
                    depth = 1;
                    cur_struct += 1;
                    continue;
                } else if (c == '[') {
                    container_stack[0] = .{ .tape_idx = writer.skip(), .is_array = true };
                    in_array = true;
                    depth = 1;
                    cur_struct += 1;
                    continue;
                } else {
                    cur_struct = try parsePrimitive(buf_ptr, indexes_ptr, cur_struct, &writer);
                    break;
                }
            }

            if (!in_array) {
                if (c == '}') {
                    const cont = container_stack[depth - 1];
                    if (writer.idx > cont.tape_idx + 1) return error.TrailingComma;
                    const end_tape = writer.idx;
                    writer.append(cont.tape_idx, .END_OBJECT);
                    writer.writeAt(cont.tape_idx, end_tape, .START_OBJECT);
                    depth -= 1;
                    cur_struct += 1;
                    if (depth == 0) break;
                    in_array = container_stack[depth - 1].is_array;
                } else {
                    if (c != '"') return error.TapeError;
                    const str_end = findStringEnd(buf_ptr, pos + 1);
                    writer.append2(str_end - (pos + 1), pos + 1, .STRING);

                    cur_struct += 2; // Rapid jump past string and colon
                    const val_pos = indexes_ptr[cur_struct];
                    const vc = buf_ptr[val_pos];

                    if (vc == '{') {
                        if (depth >= MAX_DEPTH) return error.DepthError;
                        container_stack[depth] = .{ .tape_idx = writer.skip(), .is_array = false };
                        in_array = false;
                        depth += 1;
                        cur_struct += 1;
                        continue;
                    } else if (vc == '[') {
                        if (depth >= MAX_DEPTH) return error.DepthError;
                        container_stack[depth] = .{ .tape_idx = writer.skip(), .is_array = true };
                        in_array = true;
                        depth += 1;
                        cur_struct += 1;
                        continue;
                    } else {
                        cur_struct = try parsePrimitive(buf_ptr, indexes_ptr, cur_struct, &writer);
                    }
                }
            } else {
                if (c == ']') {
                    const cont = container_stack[depth - 1];
                    if (writer.idx > cont.tape_idx + 1) return error.TrailingComma;
                    const end_tape = writer.idx;
                    writer.append(cont.tape_idx, .END_ARRAY);
                    writer.writeAt(cont.tape_idx, end_tape, .START_ARRAY);
                    depth -= 1;
                    cur_struct += 1;
                    if (depth == 0) break;
                    in_array = container_stack[depth - 1].is_array;
                } else if (c == '{') {
                    if (depth >= MAX_DEPTH) return error.DepthError;
                    container_stack[depth] = .{ .tape_idx = writer.skip(), .is_array = false };
                    in_array = false;
                    depth += 1;
                    cur_struct += 1;
                    continue;
                } else if (c == '[') {
                    if (depth >= MAX_DEPTH) return error.DepthError;
                    container_stack[depth] = .{ .tape_idx = writer.skip(), .is_array = true };
                    in_array = true;
                    depth += 1;
                    cur_struct += 1;
                    continue;
                } else {
                    cur_struct = try parsePrimitive(buf_ptr, indexes_ptr, cur_struct, &writer);
                }
            }

            while (depth > 0) {
                if (cur_struct >= structurals_count) return error.IncompleteArrayOrObject;
                const delim = buf_ptr[indexes_ptr[cur_struct]];

                if (delim == ',') {
                    cur_struct += 1;
                    break;
                } else if (!in_array and delim == '}') {
                    const cont = container_stack[depth - 1];
                    const end_tape = writer.idx;
                    writer.append(cont.tape_idx, .END_OBJECT);
                    writer.writeAt(cont.tape_idx, end_tape, .START_OBJECT);
                    depth -= 1;
                    cur_struct += 1;
                    if (depth == 0) break;
                    in_array = container_stack[depth - 1].is_array;
                } else if (in_array and delim == ']') {
                    const cont = container_stack[depth - 1];
                    const end_tape = writer.idx;
                    writer.append(cont.tape_idx, .END_ARRAY);
                    writer.writeAt(cont.tape_idx, end_tape, .START_ARRAY);
                    depth -= 1;
                    cur_struct += 1;
                    if (depth == 0) break;
                    in_array = container_stack[depth - 1].is_array;
                } else {
                    return error.TapeError;
                }
            }

            if (depth == 0) break;
        }

        if (depth != 0) return error.IncompleteArrayOrObject;

        writer.writeAt(root_tape_idx, writer.idx, .ROOT);
        writer.append(0, .ROOT);

        cur_struct_ptr.* = cur_struct;
        return writer.idx;
    }

    /// Parse a JSON document from its Stage 1 structural indices into a 64-bit DOM Tape.
    /// Performs ZERO heap allocations and ZERO string copies.
    pub fn parse(
        buf: []const u8,
        indexes: []const u32,
        structurals_count: usize,
        tape_buf: []u64,
    ) SimdJsonError!usize {
        var cur: usize = 0;
        const len = (try parseSingle(buf, indexes, structurals_count, &cur, tape_buf)) orelse return error.Empty;
        return len;
    }

    /// Parse a JSON document and, if any error occurs, compute rich line and column diagnostics
    /// pointing directly to the offending character in the input source buffer.
    pub fn parseWithDiagnostic(
        buf: []const u8,
        indexes: []const u32,
        structurals_count: usize,
        tape_buf: []u64,
        diag: *Diagnostic,
    ) SimdJsonError!usize {
        var cur: usize = 0;
        const res = parseSingle(buf, indexes, structurals_count, &cur, tape_buf);
        if (res) |len_opt| {
            if (len_opt) |len| return len;
            diag.* = Diagnostic.compute(buf, buf.len, error.Empty);
            return error.Empty;
        } else |err| {
            const byte_pos = if (cur < structurals_count)
                indexes[cur]
            else if (structurals_count > 0)
                indexes[structurals_count - 1]
            else
                0;
            diag.* = Diagnostic.compute(buf, byte_pos, err);
            return err;
        }
    }

};
// [Tests remain unchanged]

test "Stage2Parser basic object and primitives1" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const json = "{\"name\": \"simdjson\", \"version\": 2, \"pi\": 3.14, \"fast\": true, \"null_val\": null}";

    var indexes: [128]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    var tape_buf: [256]u64 = undefined;
    const tape_len = try Stage2Parser.parse(json, &indexes, count, &tape_buf);
    try std.testing.expect(tape_len > 0);
}

test "Stage2Parser basic object and primitives" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const json = "{\"name\": \"simdjson\", \"version\": 2, \"pi\": 3.14, \"fast\": true, \"null_val\": null}";

    var indexes: [128]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);
    try std.testing.expect(count > 0);

    var tape_buf: [256]u64 = undefined;
    const tape_len = try Stage2Parser.parse(json, &indexes, count, &tape_buf);
    try std.testing.expect(tape_len > 0);

    // Verify root is ROOT tag
    const root_entry = TapeEntry.decode(tape_buf[0]);
    try std.testing.expectEqual(TapeTag.ROOT, root_entry.tag);

    // Verify first element is START_OBJECT
    const obj_entry = TapeEntry.decode(tape_buf[1]);
    try std.testing.expectEqual(TapeTag.START_OBJECT, obj_entry.tag);
}

test "Stage2Parser arrays and nested structures" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const json = "[10, 20, [30, 40], {\"nested\": true}]";

    var indexes: [128]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);
    try std.testing.expect(count > 0);

    var tape_buf: [256]u64 = undefined;
    const tape_len = try Stage2Parser.parse(json, &indexes, count, &tape_buf);
    try std.testing.expect(tape_len > 0);

    // Root entry
    const root = TapeEntry.decode(tape_buf[0]);
    try std.testing.expectEqual(TapeTag.ROOT, root.tag);

    // Outer array
    const arr = TapeEntry.decode(tape_buf[1]);
    try std.testing.expectEqual(TapeTag.START_ARRAY, arr.tag);
}

test "Stage2Parser root primitives: string, int, float, bool, null" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const test_cases = [_]struct { json: []const u8, expected_tag: TapeTag }{
        .{ .json = "\"standalone string\"", .expected_tag = .STRING },
        .{ .json = "987654", .expected_tag = .UINT64 },
        .{ .json = "-42", .expected_tag = .INT64 },
        .{ .json = "2.71828", .expected_tag = .DOUBLE },
        .{ .json = "true", .expected_tag = .TRUE },
        .{ .json = "false", .expected_tag = .FALSE },
        .{ .json = "null", .expected_tag = .NULL },
    };

    for (test_cases) |tc| {
        var indexes: [64]u32 = undefined;
        const count = try Stage1Indexer.indexAlloc(std.testing.allocator, tc.json, &indexes);
        var tape_buf: [64]u64 = undefined;
        const tape_len = try Stage2Parser.parse(tc.json, &indexes, count, &tape_buf);
        try std.testing.expect(tape_len >= 3);

        const root_start = TapeEntry.decode(tape_buf[0]);
        try std.testing.expectEqual(TapeTag.ROOT, root_start.tag);

        const elem = TapeEntry.decode(tape_buf[1]);
        try std.testing.expectEqual(tc.expected_tag, elem.tag);

        const root_end = TapeEntry.decode(tape_buf[tape_len - 1]);
        try std.testing.expectEqual(TapeTag.ROOT, root_end.tag);
    }
}

test "Stage2Parser empty containers and nested empties" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const empties = [_][]const u8{
        "{}",
        "[]",
        "[{}, []]",
        "{\"a\": {}, \"b\": []}",
    };

    for (empties) |json| {
        var indexes: [64]u32 = undefined;
        const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);
        var tape_buf: [64]u64 = undefined;
        const tape_len = try Stage2Parser.parse(json, &indexes, count, &tape_buf);
        try std.testing.expect(tape_len >= 4);
    }
}

test "Stage2Parser failure scenarios: trailing comma, incomplete, mismatched delimiters" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    
    // Trailing comma in array
    {
        const json = "[1, 2,]";
        var indexes: [64]u32 = undefined;
        const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);
        var tape_buf: [64]u64 = undefined;
        try std.testing.expectError(error.TrailingComma, Stage2Parser.parse(json, &indexes, count, &tape_buf));
    }

    // Trailing comma in object
    {
        const json = "{\"x\": 1,}";
        var indexes: [64]u32 = undefined;
        const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);
        var tape_buf: [64]u64 = undefined;
        try std.testing.expectError(error.TrailingComma, Stage2Parser.parse(json, &indexes, count, &tape_buf));
    }

    // Incomplete array
    {
        const json = "[1, 2";
        var indexes: [64]u32 = undefined;
        const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);
        var tape_buf: [64]u64 = undefined;
        try std.testing.expectError(error.IncompleteArrayOrObject, Stage2Parser.parse(json, &indexes, count, &tape_buf));
    }

    // Incomplete object
    {
        const json = "{\"key\": \"val\"";
        var indexes: [64]u32 = undefined;
        const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);
        var tape_buf: [64]u64 = undefined;
        try std.testing.expectError(error.IncompleteArrayOrObject, Stage2Parser.parse(json, &indexes, count, &tape_buf));
    }

    // Mismatched delimiters
    {
        const json = "{\"key\": 1]";
        var indexes: [64]u32 = undefined;
        const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);
        var tape_buf: [64]u64 = undefined;
        try std.testing.expectError(error.TapeError, Stage2Parser.parse(json, &indexes, count, &tape_buf));
    }

    // Capacity error (tape too small)
    {
        const json = "{\"a\": 1}";
        var indexes: [64]u32 = undefined;
        const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);
        var tiny_tape: [2]u64 = undefined;
        try std.testing.expectError(error.Capacity, Stage2Parser.parse(json, &indexes, count, &tiny_tape));
    }
}

test "Stage2Parser parseWithDiagnostic captures error context" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const json = "{\n  \"valid\": 1,\n  \"broken\": ,\n}";
    var indexes: [64]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);
    var tape_buf: [64]u64 = undefined;
    var diag: Diagnostic = undefined;

    const res = Stage2Parser.parseWithDiagnostic(json, &indexes, count, &tape_buf, &diag);
    try std.testing.expectError(error.TapeError, res);
    try std.testing.expectEqual(@as(usize, 3), diag.line);
}

