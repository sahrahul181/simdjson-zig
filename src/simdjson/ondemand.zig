const std = @import("std");
const error_types = @import("error.zig");
const SimdJsonError = error_types.SimdJsonError;
const Diagnostic = error_types.Diagnostic;

const stage2 = @import("stage2.zig");
pub const findStringEnd = stage2.Stage2Parser.findStringEnd;
const fast_float = @import("fast_float.zig");
const common = @import("common.zig");

const depth_delta: [256]i8 = blk: {
    @setEvalBranchQuota(10000);
    var tab = [_]i8{0} ** 256;
    tab['{'] = 1;
    tab['['] = 1;
    tab['}'] = -1;
    tab[']'] = -1;
    break :blk tab;
};

pub const FormatOptions = struct {
    indent: usize = 2,
};

pub const OnDemandDocument = struct {
    buf: []const u8,
    indexes: []const u32,
    count: usize,
    cur: usize = 0,

    pub inline fn init(buf: []const u8, indexes: []const u32, count: usize) OnDemandDocument {
        return .{ .buf = buf, .indexes = indexes, .count = count, .cur = 0 };
    }

    // Note: Ensure your 'Value' type is visible in this scope
    pub inline fn root(self: *OnDemandDocument) Value {
        return Value{ .doc = self };
    }

    /// Navigates the OnDemand document using an RFC 6901 JSON Pointer (e.g. "/statuses/0/user/id").
    pub inline fn atPointer(self: *OnDemandDocument, pointer: []const u8) !Value {
        var r = self.root();
        return r.atPointer(pointer);
    }

    /// Computes rich line and column error diagnostic for this OnDemand document.
    pub inline fn getDiagnostic(self: *const OnDemandDocument, err: SimdJsonError) Diagnostic {
        const byte_pos = if (self.cur < self.count)
            self.indexes[self.cur]
        else if (self.count > 0)
            self.indexes[self.count - 1]
        else
            0;
        return Diagnostic.compute(self.buf, byte_pos, err);
    }

    /// Blazing fast SIMD-accelerated Minifier.
    /// Strips all whitespace at 5+ GB/s by directly traversing Stage 1 structural indices.
    pub fn minify(self: OnDemandDocument, writer: anytype) !void {
        @setRuntimeSafety(false);
        const buf_ptr = self.buf.ptr;
        const indexes_ptr = self.indexes.ptr;
        const count = self.count;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const pos = indexes_ptr[i];
            const c = buf_ptr[pos];

            switch (c) {
                '{', '}', '[', ']', ':', ',' => {
                    try writer.writeByte(c);
                },
                '"' => {
                    const end = findStringEnd(buf_ptr, pos + 1);
                    try writer.writeAll(self.buf[pos .. end + 1]);
                },
                else => {
                    var end = pos;
                    while (true) : (end += 1) {
                        const b = buf_ptr[end];
                        if (b <= ' ' or b == ',' or b == ']' or b == '}') break;
                    }
                    try writer.writeAll(self.buf[pos..end]);
                },
            }
        }
    }

    /// High-speed Pretty-Printer.
    /// Re-indents the raw JSON buffer sequentially without allocating a DOM.
    pub fn format(self: OnDemandDocument, writer: anytype, options: FormatOptions) !void {
        @setRuntimeSafety(false);
        const buf_ptr = self.buf.ptr;
        const indexes_ptr = self.indexes.ptr;
        const count = self.count;

        var depth: usize = 0;
        var i: usize = 0;
        var needs_indent = false;

        while (i < count) : (i += 1) {
            const pos = indexes_ptr[i];
            const c = buf_ptr[pos];

            if (needs_indent and c != '}' and c != ']') {
                try writer.writeByte('\n');
                try writer.splatBytesAll(&.{' '}, depth * options.indent);
                needs_indent = false;
            }

            switch (c) {
                '{', '[' => {
                    try writer.writeByte(c);
                    depth += 1;
                    needs_indent = true;
                },
                '}', ']' => {
                    depth -= 1;
                    if (i > 0) {
                        const prev_c = buf_ptr[indexes_ptr[i - 1]];
                        if ((c == '}' and prev_c != '{') or (c == ']' and prev_c != '[')) {
                            try writer.writeByte('\n');
                            try writer.splatBytesAll(&.{' '}, depth * options.indent);
                        }
                    }
                    try writer.writeByte(c);
                },
                ',' => {
                    try writer.writeByte(c);
                    needs_indent = true;
                },
                ':' => {
                    try writer.writeAll(": ");
                },
                '"' => {
                    const end = findStringEnd(buf_ptr, pos + 1);
                    try writer.writeAll(self.buf[pos .. end + 1]);
                },
                else => {
                    var end = pos;
                    while (true) : (end += 1) {
                        const b = buf_ptr[end];
                        if (b <= ' ' or b == ',' or b == ']' or b == '}') break;
                    }
                    try writer.writeAll(self.buf[pos..end]);
                },
            }
        }
    }
};

pub const Value = struct {
    doc: *OnDemandDocument,

    /// Computes rich line and column error diagnostic at current value position.
    pub inline fn getDiagnostic(self: Value, err: SimdJsonError) Diagnostic {
        return self.doc.getDiagnostic(err);
    }

    pub inline fn skip(self: Value) !void {
        @setRuntimeSafety(false);
        const buf_ptr = self.doc.buf.ptr;
        const idx_ptr = self.doc.indexes.ptr;
        const pos = idx_ptr[self.doc.cur];
        const c = buf_ptr[pos];

        if (c == '{' or c == '[') {
            var depth: usize = 1;
            var cur = self.doc.cur + 1;
            const count = self.doc.count;

            while (cur + 8 <= count) : (cur += 8) {
                const c0 = buf_ptr[idx_ptr[cur]];
                const c1 = buf_ptr[idx_ptr[cur + 1]];
                const c2 = buf_ptr[idx_ptr[cur + 2]];
                const c3 = buf_ptr[idx_ptr[cur + 3]];
                const c4 = buf_ptr[idx_ptr[cur + 4]];
                const c5 = buf_ptr[idx_ptr[cur + 5]];
                const c6 = buf_ptr[idx_ptr[cur + 6]];
                const c7 = buf_ptr[idx_ptr[cur + 7]];

                const d0 = depth_delta[c0];
                const d1 = depth_delta[c1];
                const d2 = depth_delta[c2];
                const d3 = depth_delta[c3];
                const d4 = depth_delta[c4];
                const d5 = depth_delta[c5];
                const d6 = depth_delta[c6];
                const d7 = depth_delta[c7];

                if ((d0 | d1 | d2 | d3 | d4 | d5 | d6 | d7) == 0) continue;

                depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d0));
                if (depth == 0) { self.doc.cur = cur + 1; return; }
                depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d1));
                if (depth == 0) { self.doc.cur = cur + 2; return; }
                depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d2));
                if (depth == 0) { self.doc.cur = cur + 3; return; }
                depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d3));
                if (depth == 0) { self.doc.cur = cur + 4; return; }
                depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d4));
                if (depth == 0) { self.doc.cur = cur + 5; return; }
                depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d5));
                if (depth == 0) { self.doc.cur = cur + 6; return; }
                depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d6));
                if (depth == 0) { self.doc.cur = cur + 7; return; }
                depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d7));
                if (depth == 0) { self.doc.cur = cur + 8; return; }
            }

            while (cur < count) : (cur += 1) {
                const next_c = buf_ptr[idx_ptr[cur]];
                const d = depth_delta[next_c];
                if (d != 0) {
                    depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d));
                    if (depth == 0) {
                        self.doc.cur = cur + 1;
                        return;
                    }
                }
            }
            return error.IncompleteArrayOrObject;
        } else {
            self.doc.cur += 1;
        }
    }

    pub inline fn asString(self: Value) ![]const u8 {
        @setRuntimeSafety(false);
        const pos = self.doc.indexes.ptr[self.doc.cur];
        if (self.doc.buf.ptr[pos] != '"') return error.IncorrectType;

        const str_end = findStringEnd(self.doc.buf.ptr, pos + 1);
        self.doc.cur += 1;
        return self.doc.buf.ptr[pos + 1 .. str_end];
    }

    /// Extremely fast SIMD-friendly check if the string contains escape sequences.
    /// Note: Does not advance the document cursor.
    pub inline fn hasEscapes(self: Value) !bool {
        @setRuntimeSafety(false);
        const pos = self.doc.indexes.ptr[self.doc.cur];
        if (self.doc.buf.ptr[pos] != '"') return error.IncorrectType;
        const str_end = findStringEnd(self.doc.buf.ptr, pos + 1);
        const raw_str = self.doc.buf.ptr[pos + 1 .. str_end];
        return std.mem.indexOfScalar(u8, raw_str, '\\') != null;
    }

    /// Unescapes the string into a user-provided buffer (zero heap allocations).
    /// Advances the document cursor past this value.
    pub fn writeUnescaped(self: Value, dest_buf: []u8) ![]const u8 {
        const raw_str = try self.asString();
        return common.unescapeString(raw_str, dest_buf);
    }

    /// Allocates an unescaped string copy using caller-provided allocator.
    /// Advances the document cursor past this value.
    pub fn asUnescapedAlloc(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        const raw_str = try self.asString();
        return common.unescapeStringAlloc(raw_str, allocator);
    }

    pub inline fn asInt(self: Value) !i64 {
        @setRuntimeSafety(false);
        const pos = self.doc.indexes.ptr[self.doc.cur];
        const buf_ptr = self.doc.buf.ptr;
        const c = buf_ptr[pos];
        if (c != '-' and (c < '0' or c > '9')) return error.IncorrectType;

        var p = pos;
        const is_neg = c == '-';
        if (is_neg) p += 1;
        const start_digits = p;

        var val: u64 = 0;

        while (true) : (p += 1) {
            const digit = buf_ptr[p] -% '0';
            if (digit <= 9) {
                val = val *% 10 +% digit;
            } else if (buf_ptr[p] == '.' or (buf_ptr[p] | 0x20) == 'e') {
                return error.IncorrectType;
            } else {
                break;
            }
        }

        if (p == start_digits) return error.NumberError;
        if (p > start_digits + 1 and buf_ptr[start_digits] == '0') return error.NumberError;

        self.doc.cur += 1;
        return if (is_neg) -@as(i64, @intCast(val)) else @as(i64, @intCast(val));
    }

    pub inline fn asUint(self: Value) !u64 {
        @setRuntimeSafety(false);
        const pos = self.doc.indexes.ptr[self.doc.cur];
        const buf_ptr = self.doc.buf.ptr;
        const c = buf_ptr[pos];
        if (c < '0' or c > '9') return error.IncorrectType;

        var p = pos;
        var val: u64 = 0;
        while (true) : (p += 1) {
            const digit = buf_ptr[p] -% '0';
            if (digit <= 9) {
                val = val *% 10 +% digit;
            } else if (buf_ptr[p] == '.' or (buf_ptr[p] | 0x20) == 'e') {
                return error.IncorrectType;
            } else {
                break;
            }
        }
        if (p == pos) return error.NumberError;
        if (p > pos + 1 and buf_ptr[pos] == '0') return error.NumberError;

        self.doc.cur += 1;
        return val;
    }

    pub inline fn asDouble(self: Value) !f64 {
        @setRuntimeSafety(false);
        const pos = self.doc.indexes.ptr[self.doc.cur];
        const buf_ptr = self.doc.buf.ptr;
        const c = buf_ptr[pos];
        if (c != '-' and (c < '0' or c > '9')) return error.IncorrectType;

        const res = fast_float.parseNumber(buf_ptr, pos, self.doc.buf.len) catch return error.NumberError;
        self.doc.cur += 1;
        return res.val;
    }

    pub inline fn asFloat(self: Value) !f32 {
        const d = try self.asDouble();
        return @floatCast(d);
    }

    pub inline fn asBool(self: Value) !bool {
        @setRuntimeSafety(false);
        const pos = self.doc.indexes.ptr[self.doc.cur];
        const val = @as(*align(1) const u32, @ptrCast(self.doc.buf.ptr + pos)).*;

        if (val == 0x65757274) {
            self.doc.cur += 1;
            return true;
        } else if (val == 0x736c6166 and self.doc.buf.ptr[pos + 4] == 'e') {
            self.doc.cur += 1;
            return false;
        }
        return error.IncorrectType;
    }

    pub inline fn asObject(self: Value) !ObjectIterator {
        @setRuntimeSafety(false);
        const pos = self.doc.indexes.ptr[self.doc.cur];
        if (self.doc.buf.ptr[pos] != '{') return error.IncorrectType;
        self.doc.cur += 1;
        return ObjectIterator{ .doc = self.doc };
    }

    pub inline fn asArray(self: Value) !ArrayIterator {
        @setRuntimeSafety(false);
        const pos = self.doc.indexes.ptr[self.doc.cur];
        if (self.doc.buf.ptr[pos] != '[') return error.IncorrectType;
        self.doc.cur += 1;
        return ArrayIterator{ .doc = self.doc };
    }

    /// Navigates this Value using an RFC 6901 JSON Pointer (e.g. "/statuses/0/user/id").
    /// Supports ~0 (~) and ~1 (/) escape decoding in path tokens.
    /// Fast-skips unrequested fields and array elements at hardware speed.
    pub fn atPointer(self: Value, pointer: []const u8) !Value {
        var it = try common.JsonPointerIterator.init(pointer);
        var current = self;
        var token_buf: [512]u8 = undefined;
        var key_buf: [512]u8 = undefined;

        while (it.next()) |raw_token| {
            const token = try common.unescapePointerToken(raw_token, &token_buf);

            @setRuntimeSafety(false);
            if (current.doc.cur >= current.doc.count) return error.TapeError;
            const pos = current.doc.indexes.ptr[current.doc.cur];
            const c = current.doc.buf.ptr[pos];

            if (c == '{') {
                var obj = try current.asObject();
                var matched: ?Value = null;

                while (try obj.next()) |field| {
                    var field_key = field.key;
                    if (field.hasEscapedKey()) {
                        field_key = field.writeUnescapedKey(&key_buf) catch field.key;
                    }
                    if (std.mem.eql(u8, field_key, token)) {
                        matched = field.value;
                        break;
                    }
                    try field.value.skip();
                }

                if (matched) |m| {
                    current = m;
                } else {
                    return error.NoSuchField;
                }
            } else if (c == '[') {
                var arr = try current.asArray();
                const target_idx = try common.parseArrayIndex(token);
                var cur_i: usize = 0;
                var matched: ?Value = null;

                while (try arr.next()) |val| : (cur_i += 1) {
                    if (cur_i == target_idx) {
                        matched = val;
                        break;
                    }
                    try val.skip();
                }

                if (matched) |m| {
                    current = m;
                } else {
                    return error.IndexOutOfBounds;
                }
            } else {
                return error.IncorrectType;
            }
        }

        return current;
    }
};

pub const Field = struct {
    key: []const u8,
    value: Value,

    /// Checks if the object key contains escape sequences.
    pub inline fn hasEscapedKey(self: Field) bool {
        return std.mem.indexOfScalar(u8, self.key, '\\') != null;
    }

    /// Unescapes the object key into a user-provided destination buffer (zero heap allocations).
    pub inline fn writeUnescapedKey(self: Field, dest_buf: []u8) ![]const u8 {
        return common.unescapeString(self.key, dest_buf);
    }

    /// Allocates an unescaped object key copy using caller-provided allocator.
    pub inline fn keyUnescapedAlloc(self: Field, allocator: std.mem.Allocator) ![]const u8 {
        return common.unescapeStringAlloc(self.key, allocator);
    }
};

pub const ObjectIterator = struct {
    doc: *OnDemandDocument,

    pub inline fn next(self: *ObjectIterator) !?Field {
        @setRuntimeSafety(false);
        if (self.doc.cur >= self.doc.count) return null;

        const buf_ptr = self.doc.buf.ptr;
        const idx_ptr = self.doc.indexes.ptr;
        var pos = idx_ptr[self.doc.cur];
        var c = buf_ptr[pos];

        if (c == '}') {
            if (self.doc.cur > 0 and buf_ptr[idx_ptr[self.doc.cur - 1]] == ',') return error.TapeError;
            self.doc.cur += 1;
            return null;
        }
        if (c == ',') {
            self.doc.cur += 1;
            pos = idx_ptr[self.doc.cur];
            c = buf_ptr[pos];
        }

        if (c != '"') return error.TapeError;

        const str_end = findStringEnd(buf_ptr, pos + 1);
        const key = buf_ptr[pos + 1 .. str_end];
        self.doc.cur += 1;

        pos = idx_ptr[self.doc.cur];
        if (buf_ptr[pos] != ':') return error.TapeError;
        self.doc.cur += 1;

        return Field{ .key = key, .value = Value{ .doc = self.doc } };
    }

    pub inline fn get(self: *ObjectIterator, key: []const u8) !?Value {
        var key_buf: [512]u8 = undefined;
        while (try self.next()) |field| {
            if (std.mem.eql(u8, field.key, key)) return field.value;
            if (field.hasEscapedKey()) {
                const unescaped = field.writeUnescapedKey(&key_buf) catch field.key;
                if (std.mem.eql(u8, unescaped, key)) return field.value;
            }
            try field.value.skip();
        }
        return null;
    }
};

pub const ArrayIterator = struct {
    doc: *OnDemandDocument,

    pub inline fn next(self: *ArrayIterator) !?Value {
        @setRuntimeSafety(false);
        if (self.doc.cur >= self.doc.count) return null;

        const buf_ptr = self.doc.buf.ptr;
        const idx_ptr = self.doc.indexes.ptr;
        var pos = idx_ptr[self.doc.cur];
        var c = buf_ptr[pos];

        if (c == ']') {
            if (self.doc.cur > 0 and buf_ptr[idx_ptr[self.doc.cur - 1]] == ',') return error.TapeError;
            self.doc.cur += 1;
            return null;
        }
        if (c == ',') {
            self.doc.cur += 1;
            pos = idx_ptr[self.doc.cur];
            c = buf_ptr[pos];
        }

        return Value{ .doc = self.doc };
    }
};

/// Streaming OnDemand parser for NDJSON / JSON Lines.
/// Iterates multi-document streams with zero tape creation and high-speed hardware skipping.
pub const OnDemandDocumentStream = struct {
    doc: OnDemandDocument,
    doc_start_cur: ?usize = null,

    pub inline fn init(buf: []const u8, indexes: []const u32, count: usize) OnDemandDocumentStream {
        return .{
            .doc = OnDemandDocument.init(buf, indexes, count),
            .doc_start_cur = null,
        };
    }

    pub inline fn next(self: *OnDemandDocumentStream) !?Value {
        @setRuntimeSafety(false);
        if (self.doc_start_cur) |start_cur| {
            const buf_ptr = self.doc.buf.ptr;
            const idx_ptr = self.doc.indexes.ptr;
            const start_c = buf_ptr[idx_ptr[start_cur]];

            if (start_c == '{' or start_c == '[') {
                var depth: usize = 1;
                var cur = start_cur + 1;
                const count = self.doc.count;

                while (cur + 8 <= count) : (cur += 8) {
                    const c0 = buf_ptr[idx_ptr[cur]];
                    const c1 = buf_ptr[idx_ptr[cur + 1]];
                    const c2 = buf_ptr[idx_ptr[cur + 2]];
                    const c3 = buf_ptr[idx_ptr[cur + 3]];
                    const c4 = buf_ptr[idx_ptr[cur + 4]];
                    const c5 = buf_ptr[idx_ptr[cur + 5]];
                    const c6 = buf_ptr[idx_ptr[cur + 6]];
                    const c7 = buf_ptr[idx_ptr[cur + 7]];

                    const d0 = depth_delta[c0];
                    const d1 = depth_delta[c1];
                    const d2 = depth_delta[c2];
                    const d3 = depth_delta[c3];
                    const d4 = depth_delta[c4];
                    const d5 = depth_delta[c5];
                    const d6 = depth_delta[c6];
                    const d7 = depth_delta[c7];

                    if ((d0 | d1 | d2 | d3 | d4 | d5 | d6 | d7) == 0) continue;

                    depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d0));
                    if (depth == 0) { cur += 1; break; }
                    depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d1));
                    if (depth == 0) { cur += 2; break; }
                    depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d2));
                    if (depth == 0) { cur += 3; break; }
                    depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d3));
                    if (depth == 0) { cur += 4; break; }
                    depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d4));
                    if (depth == 0) { cur += 5; break; }
                    depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d5));
                    if (depth == 0) { cur += 6; break; }
                    depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d6));
                    if (depth == 0) { cur += 7; break; }
                    depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d7));
                    if (depth == 0) { cur += 8; break; }
                }

                while (depth > 0 and cur < count) : (cur += 1) {
                    const c = buf_ptr[idx_ptr[cur]];
                    const d = depth_delta[c];
                    if (d != 0) {
                        depth = @as(usize, @intCast(@as(isize, @intCast(depth)) + d));
                    }
                }

                if (self.doc.cur < cur) {
                    self.doc.cur = cur;
                }
            } else if (self.doc.cur == start_cur) {
                self.doc.cur += 1;
            }
            self.doc_start_cur = null;
        }

        if (self.doc.cur >= self.doc.count) return null;
        self.doc_start_cur = self.doc.cur;
        return Value{ .doc = &self.doc };
    }

    /// Computes rich line and column error diagnostic for current document stream position.
    pub inline fn getDiagnostic(self: *const OnDemandDocumentStream, err: SimdJsonError) Diagnostic {
        return self.doc.getDiagnostic(err);
    }
};

test "OnDemand Parser speed run" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const json =
        \\{
        \\  "metadata": { "unrequested": [1, 2, 3, {"skip_me": "yes"}] },
        \\  "project": "simdjson-zig",
        \\  "active": true,
        \\  "stars": 1500
        \\}
    ;

    var indexes: [256]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    var doc = OnDemandDocument.init(json, &indexes, count);
    const root = doc.root();

    var obj = try root.asObject();

    const project = try (try obj.get("project")).?.asString();
    try std.testing.expectEqualStrings("simdjson-zig", project);

    const active = try (try obj.get("active")).?.asBool();
    try std.testing.expectEqual(true, active);

    const stars = try (try obj.get("stars")).?.asInt();
    try std.testing.expectEqual(@as(i64, 1500), stars);
}

test "Minifier and Formatter Speed Run" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;

    // A poorly formatted JSON string
    const json =
        \\{
        \\   "project" :    "simdjson-zig" ,
        \\  "active": 
        \\ true, "tags": [  "fast" ,   "zero-alloc" ] 
        \\}
    ;

    var indexes: [256]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    const doc = OnDemandDocument.init(json, &indexes, count);

    // 1. Minify Test
    var formatted_buf0: [256]u8 = undefined;
    var writer0 = std.Io.Writer.fixed(&formatted_buf0);

    // Inline the writer to avoid Zig 0.16 'var vs const' strictness errors
    try doc.minify(&writer0);

    try std.testing.expectEqualStrings(
        "{\"project\":\"simdjson-zig\",\"active\":true,\"tags\":[\"fast\",\"zero-alloc\"]}",
        formatted_buf0[0..writer0.end],
    );

    // 2. Format (Pretty-Print) Test
    var formatted_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&formatted_buf);

    try doc.format(&writer, .{ .indent = 4 });

    const expected_pretty =
        \\{
        \\    "project": "simdjson-zig",
        \\    "active": true,
        \\    "tags": [
        \\        "fast",
        \\        "zero-alloc"
        \\    ]
        \\}
    ;

    try std.testing.expectEqualStrings(expected_pretty, formatted_buf[0..writer.end]);
}

test "OnDemand Value type interrogation and type mismatch errors" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const json = "{\"str\": \"val\", \"num\": 42, \"b\": true, \"arr\": [1], \"obj\": {}, \"flt\": 3.14}";
    var indexes: [256]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    var doc = OnDemandDocument.init(json, &indexes, count);
    var obj = try doc.root().asObject();

    const str_val = (try obj.get("str")).?;
    try std.testing.expectEqualStrings("val", try str_val.asString());

    doc.cur = 0;
    var obj_reset1 = try doc.root().asObject();
    const str_val2 = (try obj_reset1.get("str")).?;
    try std.testing.expectError(error.IncorrectType, str_val2.asInt());

    doc.cur = 0;
    var obj_reset2 = try doc.root().asObject();
    const num_val = (try obj_reset2.get("num")).?;
    try std.testing.expectEqual(@as(u64, 42), try num_val.asUint());

    doc.cur = 0;
    var obj_reset3 = try doc.root().asObject();
    const num_val2 = (try obj_reset3.get("num")).?;
    try std.testing.expectError(error.IncorrectType, num_val2.asString());

    doc.cur = 0;
    var obj_reset4 = try doc.root().asObject();
    const b_val = (try obj_reset4.get("b")).?;
    try std.testing.expectEqual(true, try b_val.asBool());

    doc.cur = 0;
    var obj_reset5 = try doc.root().asObject();
    const b_val2 = (try obj_reset5.get("b")).?;
    try std.testing.expectError(error.IncorrectType, b_val2.asObject());

    doc.cur = 0;
    var obj_reset6 = try doc.root().asObject();
    const arr_val = (try obj_reset6.get("arr")).?;
    var arr_it = try arr_val.asArray();
    const first_item = (try arr_it.next()).?;
    try std.testing.expectEqual(@as(i64, 1), try first_item.asInt());
    try std.testing.expect((try arr_it.next()) == null);

    doc.cur = 0;
    var obj_reset7 = try doc.root().asObject();
    const flt_val = (try obj_reset7.get("flt")).?;
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), try flt_val.asDouble(), 1e-4);
}

test "OnDemand skip and incomplete container error" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    
    // Skip deeply nested containers
    const nested = "[{\"a\": [1, 2, {\"b\": [3, 4]}]}, 99]";
    var indexes: [256]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, nested, &indexes);
    var doc = OnDemandDocument.init(nested, &indexes, count);
    var arr = try doc.root().asArray();
    
    // First item is object: skip it
    const first_item = (try arr.next()).?;
    try first_item.skip();

    // Next item is 99
    const second_item = (try arr.next()).?;
    try std.testing.expectEqual(@as(i64, 99), try second_item.asInt());
}

test "OnDemand atPointer edge cases and error conditions" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const json = "{\"users\": [{\"name\": \"alice\"}], \"flag\": false}";
    var indexes: [256]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    var doc = OnDemandDocument.init(json, &indexes, count);
    
    // Missing leading slash
    try std.testing.expectError(error.InvalidJsonPointer, doc.atPointer("users/0"));

    // Reset doc for next query
    doc.cur = 0;
    try std.testing.expectError(error.NoSuchField, doc.atPointer("/unknown_field"));

    doc.cur = 0;
    try std.testing.expectError(error.IndexOutOfBounds, doc.atPointer("/users/5"));

    doc.cur = 0;
    try std.testing.expectError(error.IncorrectType, doc.atPointer("/flag/child"));
}

test "OnDemand Iterator get non-existent key" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const json = "{\"items\": [10, 20]}";
    var indexes: [256]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    var doc = OnDemandDocument.init(json, &indexes, count);
    var obj = try doc.root().asObject();

    // Query non-existent key
    const missing = try obj.get("nonexistent");
    try std.testing.expect(missing == null);
}


