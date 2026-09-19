const std = @import("std");
const error_types = @import("error.zig");
const SimdJsonError = error_types.SimdJsonError;
const dom = @import("dom.zig");
const Element = dom.Element;
const Document = dom.Document;
const FormatOptions = dom.FormatOptions;
const common = @import("common.zig");

pub const MutType = enum {
    object,
    array,
    string,
    int64,
    uint64,
    double,
    bool,
    null,
};

pub const MutValue = union(MutType) {
    object: MutObject,
    array: MutArray,
    string: []const u8,
    int64: i64,
    uint64: u64,
    double: f64,
    bool: bool,
    null: void,
};

inline fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    var i: usize = 0;
    var start: usize = 0;

    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' or c == '\\' or c < 0x20) {
            if (i > start) {
                try writer.writeAll(s[start..i]);
            }
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x08 => try writer.writeAll("\\b"),
                0x0C => try writer.writeAll("\\f"),
                else => try writer.print("\\u{x:0>4}", .{c}),
            }
            start = i + 1;
        }
    }
    if (i > start) {
        try writer.writeAll(s[start..i]);
    }
    try writer.writeByte('"');
}

inline fn writeIndent(writer: anytype, count: usize) !void {
    const spaces = "                                                                ";
    var remaining = count;
    while (remaining > 0) {
        const chunk = @min(remaining, spaces.len);
        try writer.writeAll(spaces[0..chunk]);
        remaining -= chunk;
    }
}

pub const MutField = struct {
    key: []const u8,
    value: MutElement,
};

pub const MutObject = struct {
    fields: std.ArrayListUnmanaged(MutField) = .empty,

    pub inline fn get(self: *const MutObject, key: []const u8) ?*MutElement {
        for (self.fields.items) |*f| {
            if (std.mem.eql(u8, f.key, key)) return &f.value;
        }
        return null;
    }

    pub inline fn has(self: *const MutObject, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn set(self: *MutObject, allocator: std.mem.Allocator, key: []const u8, val: anytype) !void {
        const new_el = try MutElement.fromValue(allocator, val);
        for (self.fields.items) |*f| {
            if (std.mem.eql(u8, f.key, key)) {
                f.value = new_el;
                return;
            }
        }
        const key_copy = try allocator.dupe(u8, key);
        try self.fields.append(allocator, .{ .key = key_copy, .value = new_el });
    }

    pub fn remove(self: *MutObject, key: []const u8) bool {
        for (self.fields.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.key, key)) {
                _ = self.fields.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub inline fn count(self: *const MutObject) usize {
        return self.fields.items.len;
    }

    pub inline fn iterator(self: *const MutObject) []const MutField {
        return self.fields.items;
    }
};

pub const MutArray = struct {
    items: std.ArrayListUnmanaged(MutElement) = .empty,

    pub inline fn len(self: *const MutArray) usize {
        return self.items.items.len;
    }

    pub inline fn at(self: *const MutArray, index: usize) ?*MutElement {
        if (index < self.items.items.len) {
            return &self.items.items[index];
        }
        return null;
    }

    pub fn append(self: *MutArray, allocator: std.mem.Allocator, val: anytype) !void {
        const el = try MutElement.fromValue(allocator, val);
        try self.items.append(allocator, el);
    }

    pub fn insert(self: *MutArray, allocator: std.mem.Allocator, index: usize, val: anytype) !void {
        if (index > self.items.items.len) return error.IndexOutOfBounds;
        const el = try MutElement.fromValue(allocator, val);
        try self.items.insert(allocator, index, el);
    }

    pub fn removeAt(self: *MutArray, index: usize) bool {
        if (index < self.items.items.len) {
            _ = self.items.orderedRemove(index);
            return true;
        }
        return false;
    }

    pub inline fn iterator(self: *const MutArray) []const MutElement {
        return self.items.items;
    }
};

pub const MutElement = struct {
    allocator: std.mem.Allocator,
    value: MutValue,

    pub fn fromValue(allocator: std.mem.Allocator, val: anytype) !MutElement {
        const T = @TypeOf(val);
        if (T == MutElement) {
            return val;
        } else if (T == *MutElement) {
            return val.*;
        } else if (T == MutObject) {
            return MutElement{ .allocator = allocator, .value = .{ .object = val } };
        } else if (T == MutArray) {
            return MutElement{ .allocator = allocator, .value = .{ .array = val } };
        } else if (T == []const u8 or T == []u8 or T == [:0]const u8 or T == [:0]u8) {
            const s = try allocator.dupe(u8, val);
            return MutElement{ .allocator = allocator, .value = .{ .string = s } };
        } else if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice and @typeInfo(T).pointer.child == u8) {
            const s = try allocator.dupe(u8, val);
            return MutElement{ .allocator = allocator, .value = .{ .string = s } };
        } else if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one and @typeInfo(@typeInfo(T).pointer.child) == .array and @typeInfo(@typeInfo(T).pointer.child).array.child == u8) {
            const s = try allocator.dupe(u8, val);
            return MutElement{ .allocator = allocator, .value = .{ .string = s } };
        } else if (T == comptime_int) {
            if (val > std.math.maxInt(i64)) {
                return MutElement{ .allocator = allocator, .value = .{ .uint64 = @as(u64, val) } };
            } else {
                return MutElement{ .allocator = allocator, .value = .{ .int64 = @as(i64, val) } };
            }
        } else if (T == comptime_float) {
            return MutElement{ .allocator = allocator, .value = .{ .double = @as(f64, val) } };
        } else if (T == bool) {
            return MutElement{ .allocator = allocator, .value = .{ .bool = val } };
        } else if (T == f32 or T == f64) {
            return MutElement{ .allocator = allocator, .value = .{ .double = @floatCast(val) } };
        } else if (@typeInfo(T) == .int) {
            if (@typeInfo(T).int.signedness == .signed) {
                return MutElement{ .allocator = allocator, .value = .{ .int64 = @intCast(val) } };
            } else {
                return MutElement{ .allocator = allocator, .value = .{ .uint64 = @intCast(val) } };
            }
        } else if (T == @TypeOf(null) or T == void) {
            return MutElement{ .allocator = allocator, .value = .{ .null = {} } };
        } else if (T == Element) {
            return fromElement(allocator, val);
        } else {
            @compileError("Unsupported value type for MutElement: " ++ @typeName(T));
        }
    }

    pub fn fromElement(allocator: std.mem.Allocator, el: Element) !MutElement {
        switch (el.tag()) {
            .START_OBJECT => {
                const obj = try el.asObject();
                var mut_obj = MutObject{};
                var it = obj.iterator();
                while (it.next()) |f| {
                    const key_copy = try allocator.dupe(u8, f.key);
                    const val_mut = try fromElement(allocator, f.value);
                    try mut_obj.fields.append(allocator, .{ .key = key_copy, .value = val_mut });
                }
                return MutElement{ .allocator = allocator, .value = .{ .object = mut_obj } };
            },
            .START_ARRAY => {
                const arr = try el.asArray();
                var mut_arr = MutArray{};
                var it = arr.iterator();
                while (it.next()) |item| {
                    const val_mut = try fromElement(allocator, item);
                    try mut_arr.items.append(allocator, val_mut);
                }
                return MutElement{ .allocator = allocator, .value = .{ .array = mut_arr } };
            },
            .STRING => {
                const s = try el.asString();
                const s_copy = try allocator.dupe(u8, s);
                return MutElement{ .allocator = allocator, .value = .{ .string = s_copy } };
            },
            .INT64 => {
                return MutElement{ .allocator = allocator, .value = .{ .int64 = try el.asInt() } };
            },
            .UINT64 => {
                return MutElement{ .allocator = allocator, .value = .{ .uint64 = try el.asUint() } };
            },
            .DOUBLE => {
                return MutElement{ .allocator = allocator, .value = .{ .double = try el.asDouble() } };
            },
            .TRUE => {
                return MutElement{ .allocator = allocator, .value = .{ .bool = true } };
            },
            .FALSE => {
                return MutElement{ .allocator = allocator, .value = .{ .bool = false } };
            },
            .NULL => {
                return MutElement{ .allocator = allocator, .value = .{ .null = {} } };
            },
            .ROOT => {
                const root_el = Element{ .doc = el.doc, .tape_idx = 1 };
                return fromElement(allocator, root_el);
            },
            else => return error.TapeError,
        }
    }

    pub inline fn getType(self: *const MutElement) MutType {
        return self.value;
    }

    pub inline fn isNull(self: *const MutElement) bool {
        return self.value == .null;
    }

    pub inline fn asObject(self: *MutElement) !*MutObject {
        return switch (self.value) {
            .object => |*obj| obj,
            else => error.IncorrectType,
        };
    }

    pub inline fn asArray(self: *MutElement) !*MutArray {
        return switch (self.value) {
            .array => |*arr| arr,
            else => error.IncorrectType,
        };
    }

    pub inline fn asString(self: *const MutElement) ![]const u8 {
        return switch (self.value) {
            .string => |s| s,
            else => error.IncorrectType,
        };
    }

    pub inline fn asInt(self: *const MutElement) !i64 {
        return switch (self.value) {
            .int64 => |v| v,
            .uint64 => |v| if (v > std.math.maxInt(i64)) error.NumberOutOfRange else @as(i64, @intCast(v)),
            else => error.IncorrectType,
        };
    }

    pub inline fn asUint(self: *const MutElement) !u64 {
        return switch (self.value) {
            .uint64 => |v| v,
            .int64 => |v| if (v < 0) error.NumberOutOfRange else @as(u64, @intCast(v)),
            else => error.IncorrectType,
        };
    }

    pub inline fn asDouble(self: *const MutElement) !f64 {
        return switch (self.value) {
            .double => |v| v,
            .int64 => |v| @as(f64, @floatFromInt(v)),
            .uint64 => |v| @as(f64, @floatFromInt(v)),
            else => error.IncorrectType,
        };
    }

    pub inline fn asBool(self: *const MutElement) !bool {
        return switch (self.value) {
            .bool => |v| v,
            else => error.IncorrectType,
        };
    }

    // --- In-Memory Object Mutators ---

    pub fn set(self: *MutElement, key: []const u8, val: anytype) !void {
        const obj = try self.asObject();
        try obj.set(self.allocator, key, val);
    }

    pub fn get(self: *MutElement, key: []const u8) ?*MutElement {
        const obj = self.asObject() catch return null;
        return obj.get(key);
    }

    pub fn remove(self: *MutElement, key: []const u8) bool {
        const obj = self.asObject() catch return false;
        return obj.remove(key);
    }

    pub fn has(self: *const MutElement, key: []const u8) bool {
        return switch (self.value) {
            .object => |*obj| obj.has(key),
            else => false,
        };
    }

    // --- In-Memory Array Mutators ---

    pub fn append(self: *MutElement, val: anytype) !void {
        const arr = try self.asArray();
        try arr.append(self.allocator, val);
    }

    pub fn insert(self: *MutElement, index: usize, val: anytype) !void {
        const arr = try self.asArray();
        try arr.insert(self.allocator, index, val);
    }

    pub fn removeAt(self: *MutElement, index: usize) bool {
        const arr = self.asArray() catch return false;
        return arr.removeAt(index);
    }

    pub fn at(self: *MutElement, index: usize) ?*MutElement {
        const arr = self.asArray() catch return null;
        return arr.at(index);
    }

    pub fn len(self: *const MutElement) usize {
        return switch (self.value) {
            .array => |*arr| arr.len(),
            .object => |*obj| obj.count(),
            else => 0,
        };
    }

    // --- Serialization ---

    pub fn writeJson(self: *const MutElement, writer: anytype) anyerror!void {
        switch (self.value) {
            .object => |*obj| {
                try writer.writeByte('{');
                var first = true;
                for (obj.fields.items) |f| {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try writeJsonString(writer, f.key);
                    try writer.writeByte(':');
                    try f.value.writeJson(writer);
                }
                try writer.writeByte('}');
            },
            .array => |*arr| {
                try writer.writeByte('[');
                var first = true;
                for (arr.items.items) |item| {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try item.writeJson(writer);
                }
                try writer.writeByte(']');
            },
            .string => |s| {
                try writeJsonString(writer, s);
            },
            .int64 => |val| {
                try writer.print("{d}", .{val});
            },
            .uint64 => |val| {
                try writer.print("{d}", .{val});
            },
            .double => |val| {
                try writer.print("{d}", .{val});
            },
            .bool => |val| {
                try writer.writeAll(if (val) "true" else "false");
            },
            .null => {
                try writer.writeAll("null");
            },
        }
    }

    pub fn stringifyAlloc(self: *const MutElement, allocator: std.mem.Allocator) ![]const u8 {
        var alloc_writer = std.Io.Writer.Allocating.init(allocator);
        defer alloc_writer.deinit();

        try self.writeJson(&alloc_writer.writer);
        return try alloc_writer.toOwnedSlice();
    }

    pub fn formatJson(self: *const MutElement, writer: anytype, options: FormatOptions) anyerror!void {
        try self.formatJsonInternal(writer, options, 0);
    }

    fn formatJsonInternal(self: *const MutElement, writer: anytype, options: FormatOptions, depth: usize) anyerror!void {
        switch (self.value) {
            .object => |*obj| {
                if (obj.fields.items.len == 0) {
                    try writer.writeAll("{}");
                    return;
                }
                try writer.writeAll("{\n");
                for (obj.fields.items, 0..) |f, i| {
                    try writeIndent(writer, (depth + 1) * options.indent);
                    try writeJsonString(writer, f.key);
                    try writer.writeAll(": ");
                    try f.value.formatJsonInternal(writer, options, depth + 1);
                    if (i + 1 < obj.fields.items.len) {
                        try writer.writeByte(',');
                    }
                    try writer.writeByte('\n');
                }
                try writeIndent(writer, depth * options.indent);
                try writer.writeByte('}');
            },
            .array => |*arr| {
                if (arr.items.items.len == 0) {
                    try writer.writeAll("[]");
                    return;
                }
                try writer.writeAll("[\n");
                for (arr.items.items, 0..) |item, i| {
                    try writeIndent(writer, (depth + 1) * options.indent);
                    try item.formatJsonInternal(writer, options, depth + 1);
                    if (i + 1 < arr.items.items.len) {
                        try writer.writeByte(',');
                    }
                    try writer.writeByte('\n');
                }
                try writeIndent(writer, depth * options.indent);
                try writer.writeByte(']');
            },
            else => {
                try self.writeJson(writer);
            },
        }
    }

    pub fn formatAlloc(self: *const MutElement, allocator: std.mem.Allocator, options: FormatOptions) ![]const u8 {
        var alloc_writer = std.Io.Writer.Allocating.init(allocator);
        defer alloc_writer.deinit();

        try self.formatJson(&alloc_writer.writer, options);
        return try alloc_writer.toOwnedSlice();
    }

    // --- RFC 6901 JSON Pointer ---

    pub fn atPointer(self: *MutElement, pointer: []const u8) !*MutElement {
        var it = try common.JsonPointerIterator.init(pointer);
        var current: *MutElement = self;
        var token_buf: [512]u8 = undefined;

        while (it.next()) |raw_token| {
            const token = try common.unescapePointerToken(raw_token, &token_buf);

            switch (current.value) {
                .object => |*obj| {
                    current = obj.get(token) orelse return error.NoSuchField;
                },
                .array => |*arr| {
                    const idx = try common.parseArrayIndex(token);
                    current = arr.at(idx) orelse return error.IndexOutOfBounds;
                },
                else => return error.IncorrectType,
            }
        }
        return current;
    }

    pub fn setPointer(self: *MutElement, pointer: []const u8, val: anytype) !void {
        if (pointer.len == 0) {
            const new_el = try MutElement.fromValue(self.allocator, val);
            self.* = new_el;
            return;
        }

        const last_slash = std.mem.lastIndexOfScalar(u8, pointer, '/') orelse return error.InvalidJsonPointer;
        const parent_ptr = pointer[0..last_slash];
        const raw_token = pointer[last_slash + 1 ..];

        const parent = try self.atPointer(parent_ptr);
        var token_buf: [512]u8 = undefined;
        const token = try common.unescapePointerToken(raw_token, &token_buf);

        switch (parent.value) {
            .object => |*obj| {
                try obj.set(self.allocator, token, val);
            },
            .array => |*arr| {
                if (std.mem.eql(u8, token, "-")) {
                    try arr.append(self.allocator, val);
                } else {
                    const idx = try common.parseArrayIndex(token);
                    if (idx == arr.len()) {
                        try arr.append(self.allocator, val);
                    } else if (idx < arr.len()) {
                        arr.items.items[idx] = try MutElement.fromValue(self.allocator, val);
                    } else {
                        return error.IndexOutOfBounds;
                    }
                }
            },
            else => return error.IncorrectType,
        }
    }

    pub fn removePointer(self: *MutElement, pointer: []const u8) !bool {
        if (pointer.len == 0) return false;

        const last_slash = std.mem.lastIndexOfScalar(u8, pointer, '/') orelse return error.InvalidJsonPointer;
        const parent_ptr = pointer[0..last_slash];
        const raw_token = pointer[last_slash + 1 ..];

        const parent = try self.atPointer(parent_ptr);
        var token_buf: [512]u8 = undefined;
        const token = try common.unescapePointerToken(raw_token, &token_buf);

        switch (parent.value) {
            .object => |*obj| {
                return obj.remove(token);
            },
            .array => |*arr| {
                const idx = try common.parseArrayIndex(token);
                return arr.removeAt(idx);
            },
            else => return error.IncorrectType,
        }
    }
};

/// High-level mutable JSON document tree owning all allocated nodes through an ArenaAllocator.
pub const MutDocument = struct {
    arena: *std.heap.ArenaAllocator,
    root_element: MutElement,

    /// Creates an empty mutable document with a root object `{}`.
    pub fn init(parent_allocator: std.mem.Allocator) !MutDocument {
        const arena_ptr = try parent_allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(parent_allocator);
        const alloc = arena_ptr.allocator();
        return MutDocument{
            .arena = arena_ptr,
            .root_element = MutElement{
                .allocator = alloc,
                .value = .{ .object = MutObject{} },
            },
        };
    }

    /// Creates an empty mutable document with a root array `[]`.
    pub fn initArray(parent_allocator: std.mem.Allocator) !MutDocument {
        const arena_ptr = try parent_allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(parent_allocator);
        const alloc = arena_ptr.allocator();
        return MutDocument{
            .arena = arena_ptr,
            .root_element = MutElement{
                .allocator = alloc,
                .value = .{ .array = MutArray{} },
            },
        };
    }

    /// Converts an immutable tape Document into a mutable document tree.
    pub fn from(parent_allocator: std.mem.Allocator, doc: Document) !MutDocument {
        const arena_ptr = try parent_allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(parent_allocator);
        const alloc = arena_ptr.allocator();
        const root_mut = MutElement.fromElement(alloc, doc.root()) catch |err| {
            arena_ptr.deinit();
            parent_allocator.destroy(arena_ptr);
            return err;
        };
        return MutDocument{
            .arena = arena_ptr,
            .root_element = root_mut,
        };
    }

    pub fn deinit(self: *MutDocument) void {
        const parent = self.arena.child_allocator;
        self.arena.deinit();
        parent.destroy(self.arena);
        self.* = undefined;
    }

    pub inline fn root(self: *MutDocument) *MutElement {
        return &self.root_element;
    }

    pub inline fn writeJson(self: *const MutDocument, writer: anytype) !void {
        try self.root_element.writeJson(writer);
    }

    pub inline fn stringifyAlloc(self: *const MutDocument, allocator: std.mem.Allocator) ![]const u8 {
        return self.root_element.stringifyAlloc(allocator);
    }

    pub inline fn formatJson(self: *const MutDocument, writer: anytype, options: FormatOptions) !void {
        try self.root_element.formatJson(writer, options);
    }

    pub inline fn formatAlloc(self: *const MutDocument, allocator: std.mem.Allocator, options: FormatOptions) ![]const u8 {
        return self.root_element.formatAlloc(allocator, options);
    }

    pub inline fn atPointer(self: *MutDocument, pointer: []const u8) !*MutElement {
        return self.root_element.atPointer(pointer);
    }

    pub inline fn setPointer(self: *MutDocument, pointer: []const u8, val: anytype) !void {
        return self.root_element.setPointer(pointer, val);
    }

    pub inline fn removePointer(self: *MutDocument, pointer: []const u8) !bool {
        return self.root_element.removePointer(pointer);
    }

    /// Applies an RFC 6902 JSON Patch document atomically to this MutDocument.
    pub inline fn applyPatch(self: *MutDocument, patch_input: anytype) !void {
        return @import("patch.zig").applyPatch(self, patch_input);
    }

    /// Applies an RFC 7396 JSON Merge Patch document to this MutDocument.
    pub inline fn applyMergePatch(self: *MutDocument, patch_input: anytype) !void {
        return @import("patch.zig").applyMergePatch(self, patch_input);
    }
};

test "MutElement type accessors, conversions, and range errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var num_el = try MutElement.fromValue(alloc, @as(i64, -50));
    try std.testing.expectEqual(@as(i64, -50), try num_el.asInt());
    try std.testing.expectError(error.NumberOutOfRange, num_el.asUint());
    try std.testing.expectEqual(@as(f64, -50.0), try num_el.asDouble());
    try std.testing.expectError(error.IncorrectType, num_el.asString());
    try std.testing.expectError(error.IncorrectType, num_el.asBool());
    try std.testing.expectError(error.IncorrectType, num_el.asObject());
    try std.testing.expectError(error.IncorrectType, num_el.asArray());

    var u64_el = try MutElement.fromValue(alloc, std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), try u64_el.asUint());
    try std.testing.expectError(error.NumberOutOfRange, u64_el.asInt());

    const str_el = try MutElement.fromValue(alloc, "hello world");
    try std.testing.expectEqualStrings("hello world", try str_el.asString());
    try std.testing.expectError(error.IncorrectType, str_el.asInt());

    const null_el = try MutElement.fromValue(alloc, null);
    try std.testing.expect(null_el.isNull());
    try std.testing.expectEqual(MutType.null, null_el.getType());
}

test "MutObject operations: overwrite, remove, count" {
    var doc = try MutDocument.init(std.testing.allocator);
    defer doc.deinit();
    const alloc = doc.arena.allocator();

    var obj = try doc.root().asObject();

    try obj.set(alloc, "k1", @as(i64, 100));
    try obj.set(alloc, "k2", "val2");
    try std.testing.expectEqual(@as(usize, 2), obj.count());
    try std.testing.expect(obj.has("k1"));
    try std.testing.expect(!obj.has("k3"));

    // Overwrite existing key
    try obj.set(alloc, "k1", @as(i64, 200));
    try std.testing.expectEqual(@as(usize, 2), obj.count());
    try std.testing.expectEqual(@as(i64, 200), try (obj.get("k1").?).asInt());

    // Remove non-existent key
    try std.testing.expect(!obj.remove("nonexistent"));

    // Remove existing key
    try std.testing.expect(obj.remove("k2"));
    try std.testing.expectEqual(@as(usize, 1), obj.count());
    try std.testing.expect(obj.get("k2") == null);
}

test "MutArray operations: insert boundaries, removeAt, out-of-bounds" {
    var doc = try MutDocument.initArray(std.testing.allocator);
    defer doc.deinit();
    const alloc = doc.arena.allocator();

    var arr = try doc.root().asArray();

    try arr.append(alloc, @as(i64, 10));
    try arr.append(alloc, @as(i64, 30));

    // Insert in middle (index 1)
    try arr.insert(alloc, 1, @as(i64, 20));
    try std.testing.expectEqual(@as(usize, 3), arr.len());
    try std.testing.expectEqual(@as(i64, 20), try (arr.at(1).?).asInt());

    // Insert at front (index 0)
    try arr.insert(alloc, 0, @as(i64, 0));
    try std.testing.expectEqual(@as(usize, 4), arr.len());
    try std.testing.expectEqual(@as(i64, 0), try (arr.at(0).?).asInt());

    // Insert out of bounds (index > len)
    try std.testing.expectError(error.IndexOutOfBounds, arr.insert(alloc, 10, @as(i64, 999)));

    // removeAt out of bounds
    try std.testing.expect(!arr.removeAt(10));

    // Valid removeAt
    try std.testing.expect(arr.removeAt(0));
    try std.testing.expectEqual(@as(usize, 3), arr.len());
    try std.testing.expectEqual(@as(i64, 10), try (arr.at(0).?).asInt());
}

test "MutDocument pointer edge cases: append '-', replace root, and invalid pointers" {
    var doc = try MutDocument.initArray(std.testing.allocator);
    defer doc.deinit();
    const alloc = doc.arena.allocator();

    const arr = try doc.root().asArray();
    try arr.append(alloc, "first");

    // Append using "/-"
    try doc.setPointer("/-", "second");
    try doc.setPointer("/-", "third");

    const item1 = try doc.atPointer("/1");
    try std.testing.expectEqualStrings("second", try item1.asString());

    const item2 = try doc.atPointer("/2");
    try std.testing.expectEqualStrings("third", try item2.asString());

    // Replace root directly via ""
    try doc.setPointer("", @as(i64, 999));
    try std.testing.expectEqual(@as(i64, 999), try (try doc.atPointer("")).asInt());

    // Invalid pointer syntax
    try std.testing.expectError(error.InvalidJsonPointer, doc.setPointer("no_slash", 1));
    try std.testing.expectError(error.InvalidJsonPointer, doc.removePointer("no_slash"));
}

