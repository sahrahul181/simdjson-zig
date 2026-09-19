//! Ultra-fast compile-time reflection-driven JSON serialization and deserialization (serde).
//! Provides bidirectional conversion between native Zig types (structs, enums, unions,
//! optionals, slices, arrays, primitives) and JSON with zero-copy fast-paths.

const std = @import("std");
const dom = @import("dom.zig");
const common = @import("common.zig");
const stage1 = @import("stage1.zig");
const stage2 = @import("stage2.zig");

const Element = dom.Element;
const Object = dom.Object;
const Array = dom.Array;
const Document = dom.Document;
const Stage1Indexer = stage1.Stage1Indexer;
const Stage2Parser = stage2.Stage2Parser;
const SIMDJSON_PADDING = stage1.SIMDJSON_PADDING;

pub const SerdeError = error{
    IncorrectType,
    MissingRequiredField,
    UnknownField,
    ArrayLengthMismatch,
    InvalidEnumValue,
    InvalidUnionTag,
    NumberOutOfRange,
    BufferTooSmall,
};

pub const ParseOptions = struct {
    /// If true, unknown fields in JSON objects are ignored.
    /// If false, encountering an unrecognized key returns error.UnknownField.
    ignore_unknown_fields: bool = true,

    /// If true, strings without escape characters borrow directly from the input buffer.
    /// Note: the input buffer must outlive the parsed struct if zero-copy is used.
    zero_copy_strings: bool = false,
};

pub const StringifyOptions = struct {
    /// If true, optional fields containing `null` are serialized as `"field": null`.
    /// If false (default), optional fields with `null` are omitted from the object.
    emit_null_optional_fields: bool = false,

    /// If true (default), enums are serialized as their `@tagName` string.
    /// If false, enums are serialized as their integer value.
    enum_as_string: bool = true,
};

/// Container for deserialized value backed by an ArenaAllocator.
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

// =============================================================================
// DESERIALIZATION (JSON -> ZIG)
// =============================================================================

/// Deserializes a raw JSON slice directly into a `Parsed(T)` container.
/// Memory allocated for child slices/strings is owned by the returned `Parsed(T)` arena.
pub fn parseFromSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    json: []const u8,
    options: ParseOptions,
) !Parsed(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();

    const val = if (json.len <= 2048) blk: {
        var stack_padded: [2048 + SIMDJSON_PADDING]u8 = undefined;
        var stack_indexes: [2048 + 3]u32 = undefined;
        var stack_tape: [2048 * 2 + 16]u64 = undefined;

        @memcpy(stack_padded[0..json.len], json);
        @memset(stack_padded[json.len .. json.len + SIMDJSON_PADDING], ' ');

        const structurals = try Stage1Indexer.indexPadded(&stack_padded, json.len, &stack_indexes);
        const tape_len = try Stage2Parser.parse(&stack_padded, &stack_indexes, structurals, &stack_tape);

        const doc = Document.init(&stack_padded, stack_tape[0..tape_len]);
        break :blk try parseFromElementInternal(T, arena_allocator, doc.root(), options, json);
    } else blk: {
        const padded = try allocator.alloc(u8, json.len + SIMDJSON_PADDING);
        defer allocator.free(padded);
        @memcpy(padded[0..json.len], json);
        @memset(padded[json.len..], ' ');

        const indexes = try allocator.alloc(u32, json.len + 3);
        defer allocator.free(indexes);
        const structurals = try Stage1Indexer.indexPadded(padded, json.len, indexes);

        const tape_buf = try allocator.alloc(u64, structurals * 2 + 16);
        defer allocator.free(tape_buf);
        const tape_len = try Stage2Parser.parse(padded, indexes, structurals, tape_buf);

        const doc = Document.init(padded, tape_buf[0..tape_len]);
        break :blk try parseFromElementInternal(T, arena_allocator, doc.root(), options, json);
    };

    return Parsed(T){
        .arena = arena,
        .value = val,
    };
}

/// Deserializes a raw JSON slice into `T` using the provided allocator.
/// Caller is responsible for memory freeing.
pub fn parseFromSliceLeaky(
    comptime T: type,
    allocator: std.mem.Allocator,
    json: []const u8,
    options: ParseOptions,
) !T {
    if (json.len <= 2048) {
        var stack_padded: [2048 + SIMDJSON_PADDING]u8 = undefined;
        var stack_indexes: [2048 + 3]u32 = undefined;
        var stack_tape: [2048 * 2 + 16]u64 = undefined;

        @memcpy(stack_padded[0..json.len], json);
        @memset(stack_padded[json.len .. json.len + SIMDJSON_PADDING], ' ');

        const structurals = try Stage1Indexer.indexPadded(&stack_padded, json.len, &stack_indexes);
        const tape_len = try Stage2Parser.parse(&stack_padded, &stack_indexes, structurals, &stack_tape);

        const doc = Document.init(&stack_padded, stack_tape[0..tape_len]);
        return parseFromElementInternal(T, allocator, doc.root(), options, json);
    } else {
        const padded = try allocator.alloc(u8, json.len + SIMDJSON_PADDING);
        defer allocator.free(padded);
        @memcpy(padded[0..json.len], json);
        @memset(padded[json.len..], ' ');

        const indexes = try allocator.alloc(u32, json.len + 3);
        defer allocator.free(indexes);
        const structurals = try Stage1Indexer.indexPadded(padded, json.len, indexes);

        const tape_buf = try allocator.alloc(u64, structurals * 2 + 16);
        defer allocator.free(tape_buf);
        const tape_len = try Stage2Parser.parse(padded, indexes, structurals, tape_buf);

        const doc = Document.init(padded, tape_buf[0..tape_len]);
        return parseFromElementInternal(T, allocator, doc.root(), options, json);
    }
}

/// Deserializes a DOM `Element` into native Zig type `T`.
pub fn parseFromElement(
    comptime T: type,
    allocator: std.mem.Allocator,
    element: Element,
    options: ParseOptions,
) !T {
    return parseFromElementInternal(T, allocator, element, options, null);
}

fn parseFromElementInternal(
    comptime T: type,
    allocator: std.mem.Allocator,
    element: Element,
    options: ParseOptions,
    source_buf: ?[]const u8,
) !T {
    const info = @typeInfo(T);

    switch (info) {
        .void => {
            return {};
        },

        .optional => |opt_info| {
            if (element.isNull()) {
                return null;
            }
            return try parseFromElementInternal(opt_info.child, allocator, element, options, source_buf);
        },

        .bool => {
            return try element.asBool();
        },

        .int => |int_info| {
            if (int_info.signedness == .signed) {
                const val = try element.asInt();
                return std.math.cast(T, val) orelse error.NumberOutOfRange;
            } else {
                const val = try element.asUint();
                return std.math.cast(T, val) orelse error.NumberOutOfRange;
            }
        },

        .float => {
            const val = try element.asDouble();
            return @floatCast(val);
        },

        .pointer => |ptr_info| {
            if (ptr_info.size == .slice) {
                if (ptr_info.child == u8) {
                    // String slice
                    const raw_str = try element.asString();
                    const has_esc = std.mem.indexOfScalar(u8, raw_str, '\\') != null;

                    if (has_esc) {
                        return try common.unescapeStringAlloc(raw_str, allocator);
                    } else if (options.zero_copy_strings) {
                        if (source_buf) |src| {
                            const offset = @intFromPtr(raw_str.ptr) - @intFromPtr(element.doc.buf.ptr);
                            return src[offset .. offset + raw_str.len];
                        }
                        return raw_str;
                    } else {
                        return try allocator.dupe(u8, raw_str);
                    }
                } else {
                    // Slice of elements: `[]Child`
                    const arr = try element.asArray();
                    const count = arr.len();
                    const slice = try allocator.alloc(ptr_info.child, count);
                    errdefer allocator.free(slice);

                    var it = arr.iterator();
                    var idx: usize = 0;
                    while (it.next()) |item| : (idx += 1) {
                        slice[idx] = try parseFromElementInternal(ptr_info.child, allocator, item, options, source_buf);
                    }
                    return slice;
                }
            } else {
                @compileError("Only slices are supported for pointer deserialization in simdjson serde: " ++ @typeName(T));
            }
        },

        .array => |arr_info| {
            if (arr_info.child == u8) {
                if (element.asString()) |raw_str| {
                    if (raw_str.len != arr_info.len) {
                        return error.ArrayLengthMismatch;
                    }
                    var result: T = undefined;
                    const has_esc = std.mem.indexOfScalar(u8, raw_str, '\\') != null;
                    if (has_esc) {
                        _ = try common.unescapeString(raw_str, &result);
                    } else {
                        @memcpy(&result, raw_str);
                    }
                    return result;
                } else |_| {}
            }
            const arr = try element.asArray();
            if (arr.len() != arr_info.len) {
                return error.ArrayLengthMismatch;
            }
            var result: T = undefined;
            var it = arr.iterator();
            var idx: usize = 0;
            while (it.next()) |item| : (idx += 1) {
                result[idx] = try parseFromElementInternal(arr_info.child, allocator, item, options, source_buf);
            }
            return result;
        },

        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                const arr = try element.asArray();
                if (arr.len() != struct_info.fields.len) {
                    return error.ArrayLengthMismatch;
                }
                var result: T = undefined;
                var it = arr.iterator();
                inline for (struct_info.fields) |field| {
                    if (it.next()) |item| {
                        @field(result, field.name) = try parseFromElementInternal(field.type, allocator, item, options, source_buf);
                    } else {
                        return error.ArrayLengthMismatch;
                    }
                }
                return result;
            }

            const obj = try element.asObject();
            var result: T = undefined;

            inline for (struct_info.fields) |field| {
                if (obj.get(field.name)) |field_el| {
                    @field(result, field.name) = try parseFromElementInternal(field.type, allocator, field_el, options, source_buf);
                } else {
                    // Key not present in JSON object
                    if (field.default_value_ptr) |default_ptr| {
                        const ptr: *const field.type = @ptrCast(@alignCast(default_ptr));
                        @field(result, field.name) = ptr.*;
                    } else if (@typeInfo(field.type) == .optional) {
                        @field(result, field.name) = null;
                    } else {
                        return error.MissingRequiredField;
                    }
                }
            }

            if (!options.ignore_unknown_fields) {
                var it = obj.iterator();
                var key_buf: [512]u8 = undefined;
                while (it.next()) |f| {
                    const unescaped_key = if (std.mem.indexOfScalar(u8, f.key, '\\') != null)
                        common.unescapeString(f.key, &key_buf) catch f.key
                    else
                        f.key;

                    var recognized = false;
                    inline for (struct_info.fields) |field| {
                        if (std.mem.eql(u8, field.name, unescaped_key)) {
                            recognized = true;
                            break;
                        }
                    }
                    if (!recognized) {
                        return error.UnknownField;
                    }
                }
            }

            return result;
        },

        .@"enum" => |enum_info| {
            // Check if string matches tag name
            if (element.asString()) |str| {
                inline for (enum_info.fields) |field| {
                    if (std.mem.eql(u8, field.name, str)) {
                        return @enumFromInt(field.value);
                    }
                }
                return error.InvalidEnumValue;
            } else |_| {
                // Also support integer enum deserialization
                const int_val = try element.asInt();
                inline for (enum_info.fields) |field| {
                    if (field.value == int_val) {
                        return @enumFromInt(field.value);
                    }
                }
                return error.InvalidEnumValue;
            }
        },

        .@"union" => |union_info| {
            if (union_info.tag_type) |_| {
                const obj = try element.asObject();
                inline for (union_info.fields) |u_field| {
                    if (obj.get(u_field.name)) |field_el| {
                        const payload = try parseFromElementInternal(u_field.type, allocator, field_el, options, source_buf);
                        return @unionInit(T, u_field.name, payload);
                    }
                }
                return error.InvalidUnionTag;
            } else {
                @compileError("Untagged unions are not supported for JSON deserialization: " ++ @typeName(T));
            }
        },

        else => {
            @compileError("Unsupported type for simdjson deserialization: " ++ @typeName(T));
        },
    }
}

// =============================================================================
// SERIALIZATION (ZIG -> JSON)
// =============================================================================

/// Serializes any native Zig value into a preallocated destination buffer with zero heap allocations.
/// Returns the slice of `dest_buf` containing the minified JSON string.
pub fn stringify(
    value: anytype,
    dest_buf: []u8,
    options: StringifyOptions,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(dest_buf);
    try stringifyWriter(value, &writer, options);
    return dest_buf[0..writer.end];
}

/// Serializes any native Zig value into a newly allocated string buffer.
/// Caller owns the returned slice and must free it with `allocator`.
pub fn stringifyAlloc(
    allocator: std.mem.Allocator,
    value: anytype,
    options: StringifyOptions,
) ![]u8 {
    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    try stringifyWriter(value, &alloc_writer.writer, options);

    return try alloc_writer.toOwnedSlice();
}

/// Serializes any native Zig value directly into an `std.Io.Writer`.
pub fn stringifyWriter(
    value: anytype,
    writer: anytype,
    options: StringifyOptions,
) anyerror!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .null => {
            try writer.writeAll("null");
        },

        .void => {
            try writer.writeAll("null");
        },

        .bool => {
            try writer.writeAll(if (value) "true" else "false");
        },

        .int => {
            try writer.print("{d}", .{value});
        },

        .float => {
            if (std.math.isNan(value) or std.math.isInf(value)) {
                try writer.writeAll("null");
            } else {
                try writer.print("{d}", .{value});
            }
        },

        .optional => {
            if (value) |val| {
                try stringifyWriter(val, writer, options);
            } else {
                try writer.writeAll("null");
            }
        },

        .pointer => |ptr_info| {
            if (ptr_info.size == .slice) {
                if (ptr_info.child == u8) {
                    try writeEscapedString(value, writer);
                } else {
                    try writer.writeByte('[');
                    for (value, 0..) |item, i| {
                        if (i > 0) try writer.writeByte(',');
                        try stringifyWriter(item, writer, options);
                    }
                    try writer.writeByte(']');
                }
            } else if (ptr_info.size == .one) {
                try stringifyWriter(value.*, writer, options);
            } else {
                @compileError("Unsupported pointer type for serialization: " ++ @typeName(T));
            }
        },

        .array => |arr_info| {
            if (arr_info.child == u8) {
                try writeEscapedString(&value, writer);
            } else {
                try writer.writeByte('[');
                for (value, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(',');
                    try stringifyWriter(item, writer, options);
                }
                try writer.writeByte(']');
            }
        },

        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                try writer.writeByte('[');
                inline for (struct_info.fields, 0..) |field, i| {
                    if (i > 0) try writer.writeByte(',');
                    try stringifyWriter(@field(value, field.name), writer, options);
                }
                try writer.writeByte(']');
                return;
            }

            try writer.writeByte('{');
            var first = true;

            inline for (struct_info.fields) |field| {
                const field_val = @field(value, field.name);
                var skip = false;

                if (@typeInfo(field.type) == .optional) {
                    if (field_val == null and !options.emit_null_optional_fields) {
                        skip = true;
                    }
                }

                if (!skip) {
                    if (!first) try writer.writeByte(',');
                    first = false;

                    try writeEscapedString(field.name, writer);
                    try writer.writeByte(':');
                    try stringifyWriter(field_val, writer, options);
                }
            }

            try writer.writeByte('}');
        },

        .@"enum" => {
            if (options.enum_as_string) {
                try writeEscapedString(@tagName(value), writer);
            } else {
                try writer.print("{d}", .{@intFromEnum(value)});
            }
        },

        .@"union" => |union_info| {
            if (union_info.tag_type) |_| {
                const tag = std.meta.activeTag(value);
                try writer.writeByte('{');
                try writeEscapedString(@tagName(tag), writer);
                try writer.writeByte(':');

                inline for (union_info.fields) |u_field| {
                    if (tag == @field(std.meta.Tag(T), u_field.name)) {
                        try stringifyWriter(@field(value, u_field.name), writer, options);
                        break;
                    }
                }

                try writer.writeByte('}');
            } else {
                @compileError("Untagged unions cannot be serialized to JSON: " ++ @typeName(T));
            }
        },

        else => {
            @compileError("Unsupported type for JSON serialization: " ++ @typeName(T));
        },
    }
}

/// Ultra-fast string escaping:
/// Checks if string is clean (pure printable ASCII, no quotes, no backslashes).
/// If clean, emits opening quote, raw slice, and closing quote in a single stream.
/// If escape characters are present, safely encodes JSON escape sequences.
pub fn writeEscapedString(str: []const u8, writer: anytype) !void {
    try writer.writeByte('"');

    var needs_escape = false;
    for (str) |c| {
        if (c < 0x20 or c == '"' or c == '\\') {
            needs_escape = true;
            break;
        }
    }

    if (!needs_escape) {
        // Fast path: pure unescaped string
        try writer.writeAll(str);
    } else {
        // Safe escape path
        var start: usize = 0;
        for (str, 0..) |c, i| {
            const esc: ?[]const u8 = switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                0x08 => "\\b",
                0x0C => "\\f",
                else => if (c < 0x20) null else continue,
            };

            if (i > start) {
                try writer.writeAll(str[start..i]);
            }

            if (esc) |s| {
                try writer.writeAll(s);
            } else {
                // Control char < 0x20 formatted as \u00XX
                try writer.print("\\u00{x:0>2}", .{c});
            }
            start = i + 1;
        }

        if (start < str.len) {
            try writer.writeAll(str[start..]);
        }
    }

    try writer.writeByte('"');
}

// =============================================================================
// TESTS
// =============================================================================

const Status = enum {
    active,
    inactive,
    pending,
};

const Role = union(enum) {
    admin: u32,
    guest: []const u8,
};

const User = struct {
    id: i64,
    username: []const u8,
    email: ?[]const u8 = null,
    status: Status = .active,
    tags: []const []const u8 = &.{},
    scores: [3]f64 = .{ 0.0, 0.0, 0.0 },
    verified: bool = false,
};

test "serde: basic struct serialization and deserialization" {
    const u = User{
        .id = 101,
        .username = "alice",
        .email = "alice@example.com",
        .status = .active,
        .tags = &.{ "zig", "simd" },
        .scores = .{ 95.5, 88.0, 100.0 },
        .verified = true,
    };

    var buf: [512]u8 = undefined;
    const json = try stringify(u, &buf, .{});

    var parsed = try parseFromSlice(User, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 101), parsed.value.id);
    try std.testing.expectEqualStrings("alice", parsed.value.username);
    try std.testing.expectEqualStrings("alice@example.com", parsed.value.email.?);
    try std.testing.expectEqual(Status.active, parsed.value.status);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tags.len);
    try std.testing.expectEqualStrings("zig", parsed.value.tags[0]);
    try std.testing.expectEqualStrings("simd", parsed.value.tags[1]);
    try std.testing.expectEqual(@as(f64, 95.5), parsed.value.scores[0]);
    try std.testing.expectEqual(@as(f64, 88.0), parsed.value.scores[1]);
    try std.testing.expectEqual(@as(f64, 100.0), parsed.value.scores[2]);
    try std.testing.expectEqual(true, parsed.value.verified);
}

test "serde: default values and omitted optional fields" {
    const json =
        \\{
        \\  "id": 999,
        \\  "username": "bob",
        \\  "extra_unrecognized_key": "will be ignored by default"
        \\}
    ;

    var parsed = try parseFromSlice(User, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 999), parsed.value.id);
    try std.testing.expectEqualStrings("bob", parsed.value.username);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.email);
    try std.testing.expectEqual(Status.active, parsed.value.status); // Default value
    try std.testing.expectEqual(false, parsed.value.verified); // Default value
}

test "serde: strict mode rejects unknown fields" {
    const json =
        \\{
        \\  "id": 123,
        \\  "username": "charlie",
        \\  "unknown_property": 42
        \\}
    ;

    const result = parseFromSlice(User, std.testing.allocator, json, .{ .ignore_unknown_fields = false });
    try std.testing.expectError(error.UnknownField, result);
}

test "serde: tagged union serialization and deserialization" {
    const r1 = Role{ .admin = 42 };
    const r2 = Role{ .guest = "anonymous" };

    var buf: [128]u8 = undefined;

    const json1 = try stringify(r1, &buf, .{});
    try std.testing.expectEqualStrings("{\"admin\":42}", json1);

    var parsed1 = try parseFromSlice(Role, std.testing.allocator, json1, .{});
    defer parsed1.deinit();
    try std.testing.expectEqual(@as(u32, 42), parsed1.value.admin);

    const json2 = try stringify(r2, &buf, .{});
    try std.testing.expectEqualStrings("{\"guest\":\"anonymous\"}", json2);

    var parsed2 = try parseFromSlice(Role, std.testing.allocator, json2, .{});
    defer parsed2.deinit();
    try std.testing.expectEqualStrings("anonymous", parsed2.value.guest);
}

test "serde: string unescaping during deserialization" {
    const json =
        \\{
        \\  "id": 1,
        \\  "username": "line1\nline2\ttab\"quote\\slash\/emoji:\uD83D\uDE00"
        \\}
    ;

    var parsed = try parseFromSlice(User, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const expected = "line1\nline2\ttab\"quote\\slash/emoji:😀";
    try std.testing.expectEqualStrings(expected, parsed.value.username);
}

test "serde: zero-copy strings borrow directly from input json slice" {
    const json = "{\"id\":42,\"username\":\"direct_borrow\",\"tags\":[\"fast\",\"zero\"]}";
    var parsed = try parseFromSlice(User, std.testing.allocator, json, .{ .zero_copy_strings = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("direct_borrow", parsed.value.username);
    // Verify string pointers point directly inside the json slice
    const json_start = @intFromPtr(json.ptr);
    const json_end = json_start + json.len;
    const str_ptr = @intFromPtr(parsed.value.username.ptr);
    try std.testing.expect(str_ptr >= json_start and str_ptr < json_end);

    const tag0_ptr = @intFromPtr(parsed.value.tags[0].ptr);
    try std.testing.expect(tag0_ptr >= json_start and tag0_ptr < json_end);
}

test "serde: [N]u8 fixed-size byte array roundtrip" {
    const HashObj = struct {
        hash: [5]u8,
    };
    const obj = HashObj{ .hash = "abcde".* };

    var buf: [64]u8 = undefined;
    const json = try stringify(obj, &buf, .{});
    try std.testing.expectEqualStrings("{\"hash\":\"abcde\"}", json);

    var parsed = try parseFromSlice(HashObj, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("abcde", &parsed.value.hash);

    // Also support parsing from numeric JSON array [97, 98, 99, 100, 101]
    const json_arr = "{\"hash\":[97,98,99,100,101]}";
    var parsed_arr = try parseFromSlice(HashObj, std.testing.allocator, json_arr, .{});
    defer parsed_arr.deinit();
    try std.testing.expectEqualStrings("abcde", &parsed_arr.value.hash);
}

test "serde: tuple serialization and deserialization" {
    const TupleType = struct { i64, []const u8, bool };
    const tuple_val: TupleType = .{ 42, "hello", true };

    var buf: [64]u8 = undefined;
    const json = try stringify(tuple_val, &buf, .{});
    try std.testing.expectEqualStrings("[42,\"hello\",true]", json);

    var parsed = try parseFromSlice(TupleType, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), parsed.value[0]);
    try std.testing.expectEqualStrings("hello", parsed.value[1]);
    try std.testing.expectEqual(true, parsed.value[2]);
}

test "serde: void handling" {
    const VoidStruct = struct {
        empty: void,
        num: u32,
    };
    const vs = VoidStruct{ .empty = {}, .num = 7 };

    var buf: [64]u8 = undefined;
    const json = try stringify(vs, &buf, .{});
    try std.testing.expectEqualStrings("{\"empty\":null,\"num\":7}", json);

    var parsed = try parseFromSlice(VoidStruct, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 7), parsed.value.num);
}

test "serde: strict mode recognizes escaped keys" {
    const Simple = struct {
        user_name: []const u8,
    };
    const json = "{\"user\\u005fname\":\"escaped_key_match\"}";

    var parsed = try parseFromSlice(Simple, std.testing.allocator, json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("escaped_key_match", parsed.value.user_name);
}

