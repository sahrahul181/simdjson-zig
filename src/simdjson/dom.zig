const std = @import("std");
const error_types = @import("error.zig");
const SimdJsonError = error_types.SimdJsonError;
const Diagnostic = error_types.Diagnostic;
const tape_mod = @import("tape.zig");
const TapeTag = tape_mod.TapeTag;
const TapeEntry = tape_mod.TapeEntry;
const common = @import("common.zig");

pub const Type = enum {
    object,
    array,
    string,
    int64,
    uint64,
    double,
    bool,
    null,
};

pub const FormatOptions = struct {
    indent: usize = 2,
};

inline fn writeIndent(writer: anytype, count: usize) !void {
    const spaces = "                                                                ";
    var remaining = count;
    while (remaining > 0) {
        const chunk = @min(remaining, spaces.len);
        try writer.writeAll(spaces[0..chunk]);
        remaining -= chunk;
    }
}

pub const Document = struct {
    buf: []const u8,
    tape: []const u64,

    pub inline fn init(buf: []const u8, tape: []const u64) Document {
        return .{
            .buf = buf,
            .tape = tape,
        };
    }

    pub inline fn root(self: Document) Element {
        return Element{
            .doc = self,
            .tape_idx = 1,
        };
    }

    /// Parse a JSON document and populate diagnostic on error.
    pub fn parseWithDiagnostic(
        buf: []const u8,
        indexes: []const u32,
        structurals_count: usize,
        tape_buf: []u64,
        diag: *Diagnostic,
    ) SimdJsonError!Document {
        const Stage2Parser = @import("stage2.zig").Stage2Parser;
        const tape_len = try Stage2Parser.parseWithDiagnostic(buf, indexes, structurals_count, tape_buf, diag);
        return Document.init(buf, tape_buf[0..tape_len]);
    }

    /// Serializes the entire document back into minified JSON format.
    pub fn writeJson(self: Document, writer: anytype) !void {
        try self.root().writeJson(writer);
    }

    /// Serializes the entire document to a newly allocated JSON string.
    pub fn stringifyAlloc(self: Document, allocator: std.mem.Allocator) ![]const u8 {
        return self.root().stringifyAlloc(allocator);
    }

    /// Deserializes the root DOM element into native Zig type `T`.
    pub fn to(self: Document, comptime T: type, allocator: std.mem.Allocator) !T {
        return self.root().to(T, allocator);
    }

    /// Deserializes the root DOM element into native Zig type `T` with options.
    pub fn toWithOptions(self: Document, comptime T: type, allocator: std.mem.Allocator, options: anytype) !T {
        return self.root().toWithOptions(T, allocator, options);
    }

    /// Pretty-prints the entire document with indentation.
    pub fn formatJson(self: Document, writer: anytype, options: FormatOptions) !void {
        try self.root().formatJson(writer, options);
    }

    /// Pretty-prints the entire document to a newly allocated JSON string.
    pub fn formatAlloc(self: Document, allocator: std.mem.Allocator, options: FormatOptions) ![]const u8 {
        return self.root().formatAlloc(allocator, options);
    }

    /// Navigates the document using an RFC 6901 JSON Pointer (e.g. "/statuses/0/user/id").
    pub inline fn atPointer(self: Document, pointer: []const u8) !Element {
        return self.root().atPointer(pointer);
    }

    /// Evaluates an RFC 9535 JSONPath query on this document, returning a slice of matching Elements.
    /// Caller owns the returned slice and must free it with `allocator.free(slice)`.
    pub fn jsonPath(self: Document, allocator: std.mem.Allocator, query_str: []const u8) ![]Element {
        return self.root().jsonPath(allocator, query_str);
    }

    /// Evaluates an RFC 9535 JSONPath query on this document, returning the first match, or null.
    pub fn jsonPathFirst(self: Document, allocator: std.mem.Allocator, query_str: []const u8) !?Element {
        return self.root().jsonPathFirst(allocator, query_str);
    }

    /// Converts this immutable Document into a mutable DOM tree.
    pub fn toMutable(self: Document, allocator: std.mem.Allocator) !@import("mut_dom.zig").MutDocument {
        return @import("mut_dom.zig").MutDocument.from(allocator, self);
    }

    /// Applies an RFC 6902 JSON Patch to this Document, returning a modified MutDocument.
    pub fn applyPatch(self: Document, allocator: std.mem.Allocator, patch_input: anytype) !@import("mut_dom.zig").MutDocument {
        var mut_doc = try self.toMutable(allocator);
        try mut_doc.applyPatch(patch_input);
        return mut_doc;
    }

    /// Applies an RFC 7396 JSON Merge Patch to this Document, returning a modified MutDocument.
    pub fn applyMergePatch(self: Document, allocator: std.mem.Allocator, patch_input: anytype) !@import("mut_dom.zig").MutDocument {
        var mut_doc = try self.toMutable(allocator);
        try mut_doc.applyMergePatch(patch_input);
        return mut_doc;
    }
};

pub const Element = struct {
    doc: Document,
    tape_idx: usize,

    pub inline fn raw(self: Element) u64 {
        @setRuntimeSafety(false);
        return self.doc.tape.ptr[self.tape_idx];
    }

    pub inline fn entry(self: Element) TapeEntry {
        return TapeEntry.decode(self.raw());
    }

    pub inline fn tag(self: Element) TapeTag {
        return self.entry().tag;
    }

    pub inline fn getType(self: Element) Type {
        return switch (self.tag()) {
            .START_OBJECT => .object,
            .START_ARRAY => .array,
            .STRING => .string,
            .INT64 => .int64,
            .UINT64 => .uint64,
            .DOUBLE => .double,
            .TRUE, .FALSE => .bool,
            .NULL => .null,
            else => .null,
        };
    }

    pub inline fn isNull(self: Element) bool {
        return self.tag() == .NULL;
    }

    pub inline fn asBool(self: Element) !bool {
        return switch (self.tag()) {
            .TRUE => true,
            .FALSE => false,
            else => error.IncorrectType,
        };
    }

    pub inline fn asInt(self: Element) !i64 {
        @setRuntimeSafety(false);
        const t = self.tag();
        if (t == .INT64) {
            return @as(i64, @bitCast(self.doc.tape.ptr[self.tape_idx + 1]));
        } else if (t == .UINT64) {
            const raw_val = self.doc.tape.ptr[self.tape_idx + 1];
            if (raw_val > std.math.maxInt(i64)) return error.NumberOutOfRange;
            return @as(i64, @intCast(raw_val));
        }
        return error.IncorrectType;
    }

    pub inline fn asUint(self: Element) !u64 {
        @setRuntimeSafety(false);
        const t = self.tag();
        if (t == .UINT64) {
            return self.doc.tape.ptr[self.tape_idx + 1];
        } else if (t == .INT64) {
            const raw_val: i64 = @bitCast(self.doc.tape.ptr[self.tape_idx + 1]);
            if (raw_val < 0) return error.NumberOutOfRange;
            return @as(u64, @intCast(raw_val));
        }
        return error.IncorrectType;
    }

    pub inline fn asDouble(self: Element) !f64 {
        @setRuntimeSafety(false);
        const t = self.tag();
        if (t == .DOUBLE) {
            return @as(f64, @bitCast(self.doc.tape.ptr[self.tape_idx + 1]));
        } else if (t == .INT64) {
            return @as(f64, @floatFromInt(try self.asInt()));
        } else if (t == .UINT64) {
            return @as(f64, @floatFromInt(try self.asUint()));
        }
        return error.IncorrectType;
    }

    /// Returns the raw, zero-copy string slice exactly as it appears in the buffer.
    pub inline fn asString(self: Element) ![]const u8 {
        @setRuntimeSafety(false);
        if (self.tag() != .STRING) return error.IncorrectType;
        const e = self.entry();
        const str_len: usize = @intCast(e.payload);
        const str_offset: usize = @intCast(self.doc.tape.ptr[self.tape_idx + 1]);
        return self.doc.buf.ptr[str_offset .. str_offset + str_len];
    }

    /// Extremely fast SIMD-friendly check if the string needs unescaping.
    pub inline fn hasEscapes(self: Element) !bool {
        const raw_str = try self.asString();
        return std.mem.indexOfScalar(u8, raw_str, '\\') != null;
    }

    /// Unescapes the string into a user-provided buffer.
    /// Returns the active slice of the buffer.
    /// Note: `dest_buf` only ever needs to be as large as the raw string length.
    pub fn writeUnescaped(self: Element, dest_buf: []u8) ![]const u8 {
        const raw_str = try self.asString();
        return common.unescapeString(raw_str, dest_buf);
    }

    /// Helper for applications that prefer an allocator
    pub fn asUnescapedAlloc(self: Element, allocator: std.mem.Allocator) ![]const u8 {
        const raw_str = try self.asString();
        return common.unescapeStringAlloc(raw_str, allocator);
    }

    pub inline fn asObject(self: Element) !Object {
        if (self.tag() != .START_OBJECT) return error.IncorrectType;
        return Object{ .el = self };
    }

    pub inline fn asArray(self: Element) !Array {
        if (self.tag() != .START_ARRAY) return error.IncorrectType;
        return Array{ .el = self };
    }

    pub inline fn next(self: Element) Element {
        const t = self.tag();
        if (t == .START_OBJECT or t == .START_ARRAY) {
            const end_tape_idx: usize = @intCast(self.entry().payload);
            return Element{ .doc = self.doc, .tape_idx = end_tape_idx + 1 };
        } else if (t == .INT64 or t == .UINT64 or t == .DOUBLE or t == .STRING) {
            return Element{ .doc = self.doc, .tape_idx = self.tape_idx + 2 };
        } else {
            return Element{ .doc = self.doc, .tape_idx = self.tape_idx + 1 };
        }
    }

    /// Recursively serializes this DOM Element into minified JSON format.
    pub fn writeJson(self: Element, writer: anytype) anyerror!void {
        switch (self.tag()) {
            .START_OBJECT => {
                try writer.writeByte('{');
                const obj = try self.asObject();
                var it = obj.iterator();
                var first = true;
                while (it.next()) |field| {
                    if (!first) {
                        try writer.writeByte(',');
                    }
                    first = false;
                    try writer.writeByte('"');
                    try writer.writeAll(field.key);
                    try writer.writeAll("\":");
                    try field.value.writeJson(writer);
                }
                try writer.writeByte('}');
            },
            .START_ARRAY => {
                try writer.writeByte('[');
                const arr = try self.asArray();
                var it = arr.iterator();
                var first = true;
                while (it.next()) |item| {
                    if (!first) {
                        try writer.writeByte(',');
                    }
                    first = false;
                    try item.writeJson(writer);
                }
                try writer.writeByte(']');
            },
            .STRING => {
                const s = try self.asString();
                try writer.writeByte('"');
                try writer.writeAll(s);
                try writer.writeByte('"');
            },
            .INT64 => {
                const val = try self.asInt();
                try writer.print("{d}", .{val});
            },
            .UINT64 => {
                const val = try self.asUint();
                try writer.print("{d}", .{val});
            },
            .DOUBLE => {
                const val = try self.asDouble();
                try writer.print("{d}", .{val});
            },
            .TRUE => {
                try writer.writeAll("true");
            },
            .FALSE => {
                try writer.writeAll("false");
            },
            .NULL => {
                try writer.writeAll("null");
            },
            .ROOT => {
                const actual_root = Element{ .doc = self.doc, .tape_idx = 1 };
                try actual_root.writeJson(writer);
            },
            else => return error.TapeError,
        }
    }

    /// Serializes this DOM Element to a newly allocated JSON string.
    /// Caller owns the returned slice and must free it with `allocator.free(slice)`.
    pub fn stringifyAlloc(self: Element, allocator: std.mem.Allocator) ![]const u8 {
        var alloc_writer = std.Io.Writer.Allocating.init(allocator);
        defer alloc_writer.deinit();

        try self.writeJson(&alloc_writer.writer);
        return try alloc_writer.toOwnedSlice();
    }

    /// Deserializes this DOM Element into native Zig type `T`.
    pub fn to(self: Element, comptime T: type, allocator: std.mem.Allocator) !T {
        const serde = @import("serde.zig");
        return serde.parseFromElement(T, allocator, self, .{});
    }

    /// Deserializes this DOM Element into native Zig type `T` with options.
    pub fn toWithOptions(self: Element, comptime T: type, allocator: std.mem.Allocator, options: anytype) !T {
        const serde = @import("serde.zig");
        return serde.parseFromElement(T, allocator, self, options);
    }


    /// Pretty-prints this DOM Element into writer with formatting options.
    pub fn formatJson(self: Element, writer: anytype, options: FormatOptions) !void {
        try self.formatJsonInternal(writer, options, 0);
    }

    fn formatJsonInternal(self: Element, writer: anytype, options: FormatOptions, depth: usize) anyerror!void {
        switch (self.tag()) {
            .START_OBJECT => {
                const obj = try self.asObject();
                var it = obj.iterator();
                const first_field = it.next() orelse {
                    try writer.writeAll("{}");
                    return;
                };

                try writer.writeAll("{\n");
                var field_opt: ?ObjectField = first_field;
                while (field_opt) |field| {
                    try writeIndent(writer, (depth + 1) * options.indent);
                    try writer.writeByte('"');
                    try writer.writeAll(field.key);
                    try writer.writeAll("\": ");
                    try field.value.formatJsonInternal(writer, options, depth + 1);

                    field_opt = it.next();
                    if (field_opt != null) {
                        try writer.writeByte(',');
                    }
                    try writer.writeByte('\n');
                }
                try writeIndent(writer, depth * options.indent);
                try writer.writeByte('}');
            },
            .START_ARRAY => {
                const arr = try self.asArray();
                var it = arr.iterator();
                const first_item = it.next() orelse {
                    try writer.writeAll("[]");
                    return;
                };

                try writer.writeAll("[\n");
                var item_opt: ?Element = first_item;
                while (item_opt) |item| {
                    try writeIndent(writer, (depth + 1) * options.indent);
                    try item.formatJsonInternal(writer, options, depth + 1);

                    item_opt = it.next();
                    if (item_opt != null) {
                        try writer.writeByte(',');
                    }
                    try writer.writeByte('\n');
                }
                try writeIndent(writer, depth * options.indent);
                try writer.writeByte(']');
            },
            .ROOT => {
                const actual_root = Element{ .doc = self.doc, .tape_idx = 1 };
                try actual_root.formatJsonInternal(writer, options, depth);
            },
            else => {
                try self.writeJson(writer);
            },
        }
    }

    /// Pretty-prints this DOM Element to a newly allocated JSON string.
    /// Caller owns the returned slice and must free it with `allocator.free(slice)`.
    pub fn formatAlloc(self: Element, allocator: std.mem.Allocator, options: FormatOptions) ![]const u8 {
        var alloc_writer = std.Io.Writer.Allocating.init(allocator);
        defer alloc_writer.deinit();

        try self.formatJson(&alloc_writer.writer, options);
        return try alloc_writer.toOwnedSlice();
    }

    /// Navigates this DOM sub-tree using an RFC 6901 JSON Pointer (e.g. "/statuses/0/user/id").
    /// Supports ~0 (~) and ~1 (/) escape decoding in path tokens.
    pub fn atPointer(self: Element, pointer: []const u8) !Element {
        var it = try common.JsonPointerIterator.init(pointer);
        var current = self;
        var token_buf: [512]u8 = undefined;
        var key_buf: [512]u8 = undefined;

        while (it.next()) |raw_token| {
            const token = try common.unescapePointerToken(raw_token, &token_buf);

            switch (current.tag()) {
                .START_OBJECT => {
                    const obj = try current.asObject();
                    var obj_it = obj.iterator();
                    var matched: ?Element = null;

                    while (obj_it.next()) |field| {
                        var field_key = field.key;
                        if (std.mem.indexOfScalar(u8, field.key, '\\') != null) {
                            field_key = common.unescapeString(field.key, &key_buf) catch field.key;
                        }
                        if (std.mem.eql(u8, field_key, token)) {
                            matched = field.value;
                            break;
                        }
                    }

                    if (matched) |m| {
                        current = m;
                    } else {
                        return error.NoSuchField;
                    }
                },
                .START_ARRAY => {
                    const arr = try current.asArray();
                    const target_idx = try common.parseArrayIndex(token);
                    if (arr.at(target_idx)) |el| {
                        current = el;
                    } else {
                        return error.IndexOutOfBounds;
                    }
                },
                .ROOT => {
                    const actual_root = Element{ .doc = current.doc, .tape_idx = 1 };
                    return actual_root.atPointer(pointer);
                },
                else => return error.IncorrectType,
            }
        }

        return current;
    }

    /// Evaluates an RFC 9535 JSONPath query starting from this element.
    /// Caller owns the returned slice and must free it with `allocator.free(slice)`.
    pub fn jsonPath(self: Element, allocator: std.mem.Allocator, query_str: []const u8) ![]Element {
        return @import("jsonpath.zig").query(self, allocator, query_str);
    }

    /// Evaluates an RFC 9535 JSONPath query starting from this element, returning the first match, or null.
    pub fn jsonPathFirst(self: Element, allocator: std.mem.Allocator, query_str: []const u8) !?Element {
        return @import("jsonpath.zig").queryFirst(self, allocator, query_str);
    }

    /// Converts this immutable Element and its sub-tree into a mutable DOM element.
    pub fn toMutable(self: Element, allocator: std.mem.Allocator) !@import("mut_dom.zig").MutElement {
        return @import("mut_dom.zig").MutElement.fromElement(allocator, self);
    }
};

pub const Object = struct {
    el: Element,

    pub inline fn get(self: Object, key: []const u8) ?Element {
        var it = self.iterator();
        var key_buf: [512]u8 = undefined;
        while (it.next()) |field| {
            if (std.mem.eql(u8, field.key, key)) return field.value;
            if (std.mem.indexOfScalar(u8, field.key, '\\') != null) {
                const unescaped = common.unescapeString(field.key, &key_buf) catch field.key;
                if (std.mem.eql(u8, unescaped, key)) return field.value;
            }
        }
        return null;
    }

    pub inline fn iterator(self: Object) ObjectIterator {
        const end_tape_idx: usize = @intCast(self.el.entry().payload);
        return ObjectIterator{
            .doc = self.el.doc,
            .cur_idx = self.el.tape_idx + 1,
            .end_idx = end_tape_idx,
        };
    }

    pub inline fn writeJson(self: Object, writer: anytype) !void {
        try self.el.writeJson(writer);
    }
    pub inline fn stringifyAlloc(self: Object, allocator: std.mem.Allocator) ![]const u8 {
        return self.el.stringifyAlloc(allocator);
    }
    pub inline fn formatJson(self: Object, writer: anytype, options: FormatOptions) !void {
        try self.el.formatJson(writer, options);
    }
    pub inline fn formatAlloc(self: Object, allocator: std.mem.Allocator, options: FormatOptions) ![]const u8 {
        return self.el.formatAlloc(allocator, options);
    }
    pub inline fn atPointer(self: Object, pointer: []const u8) !Element {
        return self.el.atPointer(pointer);
    }
    pub inline fn jsonPath(self: Object, allocator: std.mem.Allocator, query_str: []const u8) ![]Element {
        return self.el.jsonPath(allocator, query_str);
    }
    pub inline fn jsonPathFirst(self: Object, allocator: std.mem.Allocator, query_str: []const u8) !?Element {
        return self.el.jsonPathFirst(allocator, query_str);
    }
};

pub const ObjectField = struct {
    key: []const u8,
    value: Element,
};

pub const ObjectIterator = struct {
    doc: Document,
    cur_idx: usize,
    end_idx: usize,

    pub inline fn next(self: *ObjectIterator) ?ObjectField {
        if (self.cur_idx >= self.end_idx) return null;

        const key_el = Element{ .doc = self.doc, .tape_idx = self.cur_idx };
        const key_str = key_el.asString() catch return null;

        const val_el = Element{ .doc = self.doc, .tape_idx = self.cur_idx + 2 };
        const next_el = val_el.next();
        self.cur_idx = next_el.tape_idx;

        return .{
            .key = key_str,
            .value = val_el,
        };
    }
};

pub const Array = struct {
    el: Element,

    pub inline fn len(self: Array) usize {
        var it = self.iterator();
        var c: usize = 0;
        while (it.next()) |_| : (c += 1) {}
        return c;
    }

    pub inline fn at(self: Array, target_index: usize) ?Element {
        var it = self.iterator();
        var i: usize = 0;
        while (it.next()) |val| : (i += 1) {
            if (i == target_index) return val;
        }
        return null;
    }

    pub inline fn iterator(self: Array) ArrayIterator {
        const end_tape_idx: usize = @intCast(self.el.entry().payload);
        return ArrayIterator{
            .doc = self.el.doc,
            .cur_idx = self.el.tape_idx + 1,
            .end_idx = end_tape_idx,
        };
    }

    pub inline fn writeJson(self: Array, writer: anytype) !void {
        try self.el.writeJson(writer);
    }
    pub inline fn stringifyAlloc(self: Array, allocator: std.mem.Allocator) ![]const u8 {
        return self.el.stringifyAlloc(allocator);
    }
    pub inline fn formatJson(self: Array, writer: anytype, options: FormatOptions) !void {
        try self.el.formatJson(writer, options);
    }
    pub inline fn formatAlloc(self: Array, allocator: std.mem.Allocator, options: FormatOptions) ![]const u8 {
        return self.el.formatAlloc(allocator, options);
    }
    pub inline fn atPointer(self: Array, pointer: []const u8) !Element {
        return self.el.atPointer(pointer);
    }
    pub inline fn jsonPath(self: Array, allocator: std.mem.Allocator, query_str: []const u8) ![]Element {
        return self.el.jsonPath(allocator, query_str);
    }
    pub inline fn jsonPathFirst(self: Array, allocator: std.mem.Allocator, query_str: []const u8) !?Element {
        return self.el.jsonPathFirst(allocator, query_str);
    }
};

pub const ArrayIterator = struct {
    doc: Document,
    cur_idx: usize,
    end_idx: usize,

    pub inline fn next(self: *ArrayIterator) ?Element {
        if (self.cur_idx >= self.end_idx) return null;

        const val_el = Element{ .doc = self.doc, .tape_idx = self.cur_idx };
        const next_el = val_el.next();
        self.cur_idx = next_el.tape_idx;
        return val_el;
    }
};

/// Streaming parser for NDJSON / JSON Lines and multi-document streams.
/// Parses one document at a time reusing the preallocated tape buffer with zero heap allocations.
pub const DocumentStream = struct {
    buf: []const u8,
    indexes: []const u32,
    count: usize,
    cur: usize = 0,
    tape_buf: []u64,

    pub inline fn init(buf: []const u8, indexes: []const u32, count: usize, tape_buf: []u64) DocumentStream {
        return .{
            .buf = buf,
            .indexes = indexes,
            .count = count,
            .cur = 0,
            .tape_buf = tape_buf,
        };
    }

    pub inline fn next(self: *DocumentStream) !?Document {
        const Stage2Parser = @import("stage2.zig").Stage2Parser;
        if (self.cur >= self.count) return null;
        const tape_len = (try Stage2Parser.parseSingle(self.buf, self.indexes, self.count, &self.cur, self.tape_buf)) orelse return null;
        return Document.init(self.buf, self.tape_buf[0..tape_len]);
    }

    /// Computes rich line and column error diagnostic for current document stream position.
    pub inline fn getDiagnostic(self: *const DocumentStream, err: SimdJsonError) Diagnostic {
        const byte_pos = if (self.cur < self.count)
            self.indexes[self.cur]
        else if (self.count > 0)
            self.indexes[self.count - 1]
        else
            0;
        return Diagnostic.compute(self.buf, byte_pos, err);
    }
};

// ... keep existing tests ...

test "DOM Document query tests" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const Stage2Parser = @import("stage2.zig").Stage2Parser;

    const json =
        \\{
        \\  "project": "simdjson-zig",
        \\  "stars": 1500,
        \\  "rating": 4.95,
        \\  "active": true,
        \\  "tags": ["parser", "simd", "zero-copy"],
        \\  "maintainer": {
        \\    "name": "developer",
        \\    "verified": true
        \\  }
        \\}
    ;

    var indexes: [256]u32 = undefined;
    const structurals = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    var tape_buf: [512]u64 = undefined;
    const tape_len = try Stage2Parser.parse(json, &indexes, structurals, &tape_buf);

    const doc = Document.init(json, tape_buf[0..tape_len]);
    const root = doc.root();
    try std.testing.expectEqual(Type.object, root.getType());

    const obj = try root.asObject();

    // Query string field (zero-copy)
    const project = obj.get("project").?;
    try std.testing.expectEqualStrings("simdjson-zig", try project.asString());

    // Query integer field
    const stars = obj.get("stars").?;
    try std.testing.expectEqual(@as(i64, 1500), try stars.asInt());

    // Query double field
    const rating = obj.get("rating").?;
    try std.testing.expectApproxEqAbs(@as(f64, 4.95), try rating.asDouble(), 1e-4);

    // Query boolean field
    const active = obj.get("active").?;
    try std.testing.expectEqual(true, try active.asBool());

    // Query array field
    const tags_el = obj.get("tags").?;
    const tags_arr = try tags_el.asArray();
    const tag0 = tags_arr.at(0).?;
    try std.testing.expectEqualStrings("parser", try tag0.asString());
    const tag2 = tags_arr.at(2).?;
    try std.testing.expectEqualStrings("zero-copy", try tag2.asString());
    try std.testing.expect(tags_arr.at(3) == null);

    // Query nested object field
    const maintainer = try (obj.get("maintainer").?).asObject();
    const name = maintainer.get("name").?;
    try std.testing.expectEqualStrings("developer", try name.asString());
    const verified = maintainer.get("verified").?;
    try std.testing.expectEqual(true, try verified.asBool());
}

test "DOM Element type conversions, mismatch errors, and range bounds" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const Stage2Parser = @import("stage2.zig").Stage2Parser;

    const json = "{\"neg\": -100, \"large_u64\": 18446744073709551615, \"str\": \"test\", \"b\": false, \"nil\": null, \"flt\": 1.5}";
    var indexes: [256]u32 = undefined;
    const structurals = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);
    var tape_buf: [256]u64 = undefined;
    const tape_len = try Stage2Parser.parse(json, &indexes, structurals, &tape_buf);

    const doc = Document.init(json, tape_buf[0..tape_len]);
    const obj = try doc.root().asObject();

    const neg_el = obj.get("neg").?;
    try std.testing.expectEqual(@as(i64, -100), try neg_el.asInt());
    try std.testing.expectError(error.NumberOutOfRange, neg_el.asUint());
    try std.testing.expectEqual(@as(f64, -100.0), try neg_el.asDouble());
    try std.testing.expectError(error.IncorrectType, neg_el.asString());
    try std.testing.expectError(error.IncorrectType, neg_el.asBool());
    try std.testing.expectError(error.IncorrectType, neg_el.asObject());
    try std.testing.expectError(error.IncorrectType, neg_el.asArray());

    const large_u64 = obj.get("large_u64").?;
    try std.testing.expectEqual(std.math.maxInt(u64), try large_u64.asUint());
    try std.testing.expectError(error.NumberOutOfRange, large_u64.asInt());

    const str_el = obj.get("str").?;
    try std.testing.expectEqualStrings("test", try str_el.asString());
    try std.testing.expectError(error.IncorrectType, str_el.asInt());
    try std.testing.expectError(error.IncorrectType, str_el.asDouble());
    try std.testing.expect(!str_el.isNull());

    const nil_el = obj.get("nil").?;
    try std.testing.expect(nil_el.isNull());
    try std.testing.expectEqual(Type.null, nil_el.getType());

    const flt_el = obj.get("flt").?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), try flt_el.asDouble(), 1e-4);
    try std.testing.expectError(error.IncorrectType, flt_el.asInt());
}

test "DOM atPointer edge cases and error handling" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const Stage2Parser = @import("stage2.zig").Stage2Parser;

    const json = "{\"users\": [{\"name\": \"alice\"}, {\"name\": \"bob\"}], \"leaf\": 42}";
    var indexes: [256]u32 = undefined;
    const structurals = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);
    var tape_buf: [256]u64 = undefined;
    const tape_len = try Stage2Parser.parse(json, &indexes, structurals, &tape_buf);

    const doc = Document.init(json, tape_buf[0..tape_len]);

    // Root pointer
    const root = try doc.atPointer("");
    try std.testing.expectEqual(Type.object, root.getType());

    // Valid nested pointer
    const bob_name = try doc.atPointer("/users/1/name");
    try std.testing.expectEqualStrings("bob", try bob_name.asString());

    // Invalid pointer syntax (missing leading slash)
    try std.testing.expectError(error.InvalidJsonPointer, doc.atPointer("users/0"));

    // NoSuchField error
    try std.testing.expectError(error.NoSuchField, doc.atPointer("/nonexistent"));
    try std.testing.expectError(error.NoSuchField, doc.atPointer("/users/0/nonexistent"));

    // IndexOutOfBounds error
    try std.testing.expectError(error.IndexOutOfBounds, doc.atPointer("/users/5"));

    // Invalid array index token returns IndexOutOfBounds
    try std.testing.expectError(error.IndexOutOfBounds, doc.atPointer("/users/abc"));

    // IncorrectType error (navigating into a leaf primitive)
    try std.testing.expectError(error.IncorrectType, doc.atPointer("/leaf/subfield"));
}

test "DOM DocumentStream multi-document and error diagnostics" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;

    const ndjson =
        \\{"id": 1}
        \\{"id": 2}
        \\{"id": 3}
    ;

    var indexes: [256]u32 = undefined;
    const structurals = try Stage1Indexer.indexAlloc(std.testing.allocator, ndjson, &indexes);
    var tape_buf: [256]u64 = undefined;

    var stream = DocumentStream.init(ndjson, &indexes, structurals, &tape_buf);

    var count: usize = 0;
    while (try stream.next()) |doc| {
        const obj = try doc.root().asObject();
        count += 1;
        try std.testing.expectEqual(@as(i64, @intCast(count)), try (obj.get("id").?).asInt());
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect((try stream.next()) == null);
}

