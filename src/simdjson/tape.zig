const std = @import("std");

pub const TapeTag = enum(u8) {
    ROOT = 'r',
    START_ARRAY = '[',
    START_OBJECT = '{',
    END_ARRAY = ']',
    END_OBJECT = '}',
    STRING = '"',
    INT64 = 'l',
    UINT64 = 'u',
    DOUBLE = 'd',
    TRUE = 't',
    FALSE = 'f',
    NULL = 'n',

    pub inline fn char(self: TapeTag) u8 {
        return @intFromEnum(self);
    }
};

pub const TapeWriter = struct {
    tape: [*]u64, // Raw pointer eliminates slice bounds checking overhead
    idx: usize = 0,

    pub fn init(tape_buf: []u64) TapeWriter {
        return .{
            .tape = tape_buf.ptr,
            .idx = 0,
        };
    }

    pub inline fn append(self: *TapeWriter, val: u64, tag: TapeTag) void {
        const entry = (val & 0x00FF_FFFF_FFFF_FFFF) | (@as(u64, tag.char()) << 56);
        self.tape[self.idx] = entry;
        self.idx += 1;
    }

    pub inline fn append2(self: *TapeWriter, val: u64, val2: u64, tag: TapeTag) void {
        const entry = (val & 0x00FF_FFFF_FFFF_FFFF) | (@as(u64, tag.char()) << 56);
        self.tape[self.idx] = entry;
        self.tape[self.idx + 1] = val2;
        self.idx += 2;
    }

    // Add this specialized bypass for primitives
    pub inline fn appendPrimitive(self: *TapeWriter, val2: u64, tag: TapeTag) void {
        self.tape[self.idx] = @as(u64, tag.char()) << 56;
        self.tape[self.idx + 1] = val2;
        self.idx += 2;
    }

    pub inline fn appendInt64(self: *TapeWriter, value: i64) void {
        self.appendPrimitive(@as(u64, @bitCast(value)), .INT64);
    }

    pub inline fn appendUint64(self: *TapeWriter, value: u64) void {
        self.appendPrimitive(value, .UINT64);
    }

    pub inline fn appendDouble(self: *TapeWriter, value: f64) void {
        self.appendPrimitive(@as(u64, @bitCast(value)), .DOUBLE);
    }

    pub inline fn skip(self: *TapeWriter) usize {
        const current = self.idx;
        self.idx += 1;
        return current;
    }

    pub inline fn writeAt(self: *TapeWriter, target_idx: usize, val: u64, tag: TapeTag) void {
        const entry = (val & 0x00FF_FFFF_FFFF_FFFF) | (@as(u64, tag.char()) << 56);
        self.tape[target_idx] = entry;
    }

    pub inline fn currentIdx(self: TapeWriter) usize {
        return self.idx;
    }
};

pub const TapeEntry = struct {
    tag: TapeTag,
    payload: u64,

    pub inline fn decode(raw: u64) TapeEntry {
        return .{
            .tag = @enumFromInt(@as(u8, @truncate(raw >> 56))),
            .payload = raw & 0x00FF_FFFF_FFFF_FFFF,
        };
    }
};

test "TapeTag: char conversions for all variants" {
    try std.testing.expectEqual(@as(u8, 'r'), TapeTag.ROOT.char());
    try std.testing.expectEqual(@as(u8, '['), TapeTag.START_ARRAY.char());
    try std.testing.expectEqual(@as(u8, '{'), TapeTag.START_OBJECT.char());
    try std.testing.expectEqual(@as(u8, ']'), TapeTag.END_ARRAY.char());
    try std.testing.expectEqual(@as(u8, '}'), TapeTag.END_OBJECT.char());
    try std.testing.expectEqual(@as(u8, '"'), TapeTag.STRING.char());
    try std.testing.expectEqual(@as(u8, 'l'), TapeTag.INT64.char());
    try std.testing.expectEqual(@as(u8, 'u'), TapeTag.UINT64.char());
    try std.testing.expectEqual(@as(u8, 'd'), TapeTag.DOUBLE.char());
    try std.testing.expectEqual(@as(u8, 't'), TapeTag.TRUE.char());
    try std.testing.expectEqual(@as(u8, 'f'), TapeTag.FALSE.char());
    try std.testing.expectEqual(@as(u8, 'n'), TapeTag.NULL.char());
}

test "TapeEntry: decode 56-bit payload and tag" {
    // 1. Basic decode
    const raw1 = (@as(u64, 'r') << 56) | 12345;
    const entry1 = TapeEntry.decode(raw1);
    try std.testing.expectEqual(TapeTag.ROOT, entry1.tag);
    try std.testing.expectEqual(@as(u64, 12345), entry1.payload);

    // 2. Max 56-bit payload boundary
    const max_payload: u64 = 0x00FF_FFFF_FFFF_FFFF;
    const raw2 = (@as(u64, '{') << 56) | max_payload;
    const entry2 = TapeEntry.decode(raw2);
    try std.testing.expectEqual(TapeTag.START_OBJECT, entry2.tag);
    try std.testing.expectEqual(max_payload, entry2.payload);

    // 3. Overflow payload bits are masked off
    const overflow_payload = 0xFF00_0000_0000_1234;
    const raw3 = (@as(u64, '"') << 56) | (overflow_payload & max_payload);
    const entry3 = TapeEntry.decode(raw3);
    try std.testing.expectEqual(TapeTag.STRING, entry3.tag);
    try std.testing.expectEqual(@as(u64, 0x1234), entry3.payload);
}

test "TapeWriter: append, appendPrimitive, writeAt, and skip" {
    var buffer: [32]u64 = [_]u64{0} ** 32;
    var writer = TapeWriter.init(&buffer);

    try std.testing.expectEqual(@as(usize, 0), writer.currentIdx());

    // append ROOT
    writer.append(10, .ROOT);
    try std.testing.expectEqual(@as(usize, 1), writer.currentIdx());
    const e0 = TapeEntry.decode(buffer[0]);
    try std.testing.expectEqual(TapeTag.ROOT, e0.tag);
    try std.testing.expectEqual(@as(u64, 10), e0.payload);

    // append2 STRING: payload 5, offset 100
    writer.append2(5, 100, .STRING);
    try std.testing.expectEqual(@as(usize, 3), writer.currentIdx());
    const e1 = TapeEntry.decode(buffer[1]);
    try std.testing.expectEqual(TapeTag.STRING, e1.tag);
    try std.testing.expectEqual(@as(u64, 5), e1.payload);
    try std.testing.expectEqual(@as(u64, 100), buffer[2]);

    // appendInt64: negative integer
    writer.appendInt64(-42);
    try std.testing.expectEqual(@as(usize, 5), writer.currentIdx());
    const e3 = TapeEntry.decode(buffer[3]);
    try std.testing.expectEqual(TapeTag.INT64, e3.tag);
    try std.testing.expectEqual(@as(i64, -42), @as(i64, @bitCast(buffer[4])));

    // appendUint64
    writer.appendUint64(18446744073709551615);
    try std.testing.expectEqual(@as(usize, 7), writer.currentIdx());
    const e5 = TapeEntry.decode(buffer[5]);
    try std.testing.expectEqual(TapeTag.UINT64, e5.tag);
    try std.testing.expectEqual(@as(u64, 18446744073709551615), buffer[6]);

    // appendDouble
    writer.appendDouble(3.14159265);
    try std.testing.expectEqual(@as(usize, 9), writer.currentIdx());
    const e7 = TapeEntry.decode(buffer[7]);
    try std.testing.expectEqual(TapeTag.DOUBLE, e7.tag);
    try std.testing.expectEqual(@as(f64, 3.14159265), @as(f64, @bitCast(buffer[8])));

    // skip & writeAt
    const placeholder = writer.skip();
    try std.testing.expectEqual(@as(usize, 9), placeholder);
    try std.testing.expectEqual(@as(usize, 10), writer.currentIdx());

    writer.writeAt(placeholder, 999, .START_ARRAY);
    const patched = TapeEntry.decode(buffer[placeholder]);
    try std.testing.expectEqual(TapeTag.START_ARRAY, patched.tag);
    try std.testing.expectEqual(@as(u64, 999), patched.payload);
}
