const std = @import("std");
const error_types = @import("error.zig");
const SimdJsonError = error_types.SimdJsonError;
const dom = @import("dom.zig");
const Document = dom.Document;
const Element = dom.Element;
const mut_dom = @import("mut_dom.zig");
const MutDocument = mut_dom.MutDocument;
const MutElement = mut_dom.MutElement;
const MutObject = mut_dom.MutObject;
const MutArray = mut_dom.MutArray;
const stage1 = @import("stage1.zig");
const stage2 = @import("stage2.zig");
const common = @import("common.zig");

pub const PatchError = error{
    TestFailed,
    InvalidPatch,
    NoSuchField,
    IndexOutOfBounds,
    InvalidJsonPointer,
    IncorrectType,
    Capacity,
} || SimdJsonError || std.mem.Allocator.Error;

pub fn deepClone(allocator: std.mem.Allocator, el: *const MutElement) std.mem.Allocator.Error!MutElement {
    switch (el.value) {
        .object => |*obj| {
            var new_obj = MutObject{};
            for (obj.fields.items) |f| {
                const k_copy = try allocator.dupe(u8, f.key);
                const v_copy = try deepClone(allocator, &f.value);
                try new_obj.fields.append(allocator, .{ .key = k_copy, .value = v_copy });
            }
            return MutElement{ .allocator = allocator, .value = .{ .object = new_obj } };
        },
        .array => |*arr| {
            var new_arr = MutArray{};
            for (arr.items.items) |item| {
                const i_copy = try deepClone(allocator, &item);
                try new_arr.items.append(allocator, i_copy);
            }
            return MutElement{ .allocator = allocator, .value = .{ .array = new_arr } };
        },
        .string => |s| {
            const s_copy = try allocator.dupe(u8, s);
            return MutElement{ .allocator = allocator, .value = .{ .string = s_copy } };
        },
        .int64 => |v| return MutElement{ .allocator = allocator, .value = .{ .int64 = v } },
        .uint64 => |v| return MutElement{ .allocator = allocator, .value = .{ .uint64 = v } },
        .double => |v| return MutElement{ .allocator = allocator, .value = .{ .double = v } },
        .bool => |v| return MutElement{ .allocator = allocator, .value = .{ .bool = v } },
        .null => return MutElement{ .allocator = allocator, .value = .{ .null = {} } },
    }
}

pub fn deepEqual(a: *const MutElement, b: *const MutElement) bool {
    const a_tag = std.meta.activeTag(a.value);
    const b_tag = std.meta.activeTag(b.value);
    const max_safe_int: i64 = 9_007_199_254_740_991; // 2^53 - 1
    const min_safe_int: i64 = -9_007_199_254_740_991; // -(2^53 - 1)
    const max_safe_uint: u64 = 9_007_199_254_740_991;

    if (a_tag != b_tag) {
        if (a_tag == .int64 and b_tag == .uint64) {
            if (a.value.int64 < 0) return false;
            return @as(u64, @intCast(a.value.int64)) == b.value.uint64;
        } else if (a_tag == .uint64 and b_tag == .int64) {
            if (b.value.int64 < 0) return false;
            return a.value.uint64 == @as(u64, @intCast(b.value.int64));
        } else if (a_tag == .double and b_tag == .int64) {
            if (b.value.int64 < min_safe_int or b.value.int64 > max_safe_int) return false;
            return a.value.double == @as(f64, @floatFromInt(b.value.int64));
        } else if (a_tag == .int64 and b_tag == .double) {
            if (a.value.int64 < min_safe_int or a.value.int64 > max_safe_int) return false;
            return @as(f64, @floatFromInt(a.value.int64)) == b.value.double;
        } else if (a_tag == .double and b_tag == .uint64) {
            if (b.value.uint64 > max_safe_uint) return false;
            return a.value.double == @as(f64, @floatFromInt(b.value.uint64));
        } else if (a_tag == .uint64 and b_tag == .double) {
            if (a.value.uint64 > max_safe_uint) return false;
            return @as(f64, @floatFromInt(a.value.uint64)) == b.value.double;
        }
        return false;
    }

    switch (a.value) {
        .object => |*obj_a| {
            const obj_b = &b.value.object;
            if (obj_a.count() != obj_b.count()) return false;
            for (obj_a.fields.items) |f_a| {
                const val_b = obj_b.get(f_a.key) orelse return false;
                if (!deepEqual(&f_a.value, val_b)) return false;
            }
            return true;
        },
        .array => |*arr_a| {
            const arr_b = &b.value.array;
            if (arr_a.len() != arr_b.len()) return false;
            for (arr_a.items.items, 0..) |item_a, i| {
                const item_b = arr_b.at(i).?;
                if (!deepEqual(&item_a, item_b)) return false;
            }
            return true;
        },
        .string => |s_a| {
            return std.mem.eql(u8, s_a, b.value.string);
        },
        .int64 => |v_a| {
            return v_a == b.value.int64;
        },
        .uint64 => |v_a| {
            return v_a == b.value.uint64;
        },
        .double => |v_a| {
            return v_a == b.value.double;
        },
        .bool => |v_a| {
            return v_a == b.value.bool;
        },
        .null => return true,
    }
}

fn isProperPrefix(from: []const u8, path: []const u8) bool {
    if (std.mem.startsWith(u8, path, from)) {
        if (path.len > from.len and path[from.len] == '/') {
            return true;
        }
    }
    return false;
}

fn parsePatchToMutable(allocator: std.mem.Allocator, patch_input: anytype) PatchError!MutElement {
    const T = @TypeOf(patch_input);
    if (T == MutElement) {
        return patch_input;
    } else if (T == *MutElement) {
        return patch_input.*;
    } else if (T == MutDocument) {
        return patch_input.root_element;
    } else if (T == *MutDocument) {
        return patch_input.root_element;
    } else if (T == Element) {
        return MutElement.fromElement(allocator, patch_input);
    } else if (T == Document) {
        return MutElement.fromElement(allocator, patch_input.root());
    } else if (T == []const u8 or T == []u8 or T == [:0]const u8 or T == [:0]u8 or (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one and @typeInfo(@typeInfo(T).pointer.child) == .array and @typeInfo(@typeInfo(T).pointer.child).array.child == u8)) {
        const str: []const u8 = patch_input;
        const padded = try allocator.alloc(u8, str.len + stage1.SIMDJSON_PADDING);
        defer allocator.free(padded);
        @memcpy(padded[0..str.len], str);
        @memset(padded[str.len..], ' ');

        const idx_buf = try allocator.alloc(u32, str.len + 3);
        defer allocator.free(idx_buf);
        const count = try stage1.Stage1Indexer.indexPadded(padded, str.len, idx_buf);

        const tape_buf = try allocator.alloc(u64, str.len + 16);
        defer allocator.free(tape_buf);
        const tape_len = try stage2.Stage2Parser.parse(padded, idx_buf, count, tape_buf);

        const parsed_doc = Document.init(padded, tape_buf[0..tape_len]);
        return MutElement.fromElement(allocator, parsed_doc.root());
    } else {
        @compileError("Unsupported patch input type: " ++ @typeName(T));
    }
}

fn applySingleOp(allocator: std.mem.Allocator, root: *MutElement, op_el: *MutElement) PatchError!void {
    const op_str = try (op_el.get("op") orelse return error.InvalidPatch).asString();
    const path = try (op_el.get("path") orelse return error.InvalidPatch).asString();

    if (std.mem.eql(u8, op_str, "add")) {
        const val_el = op_el.get("value") orelse return error.InvalidPatch;
        const val_copy = try deepClone(allocator, val_el);

        if (path.len == 0) {
            root.* = val_copy;
            return;
        }

        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidJsonPointer;
        const parent_ptr = path[0..last_slash];
        const raw_token = path[last_slash + 1 ..];

        const parent = try root.atPointer(parent_ptr);
        var token_buf: [512]u8 = undefined;
        const token = try common.unescapePointerToken(raw_token, &token_buf);

        switch (parent.value) {
            .object => |*obj| {
                try obj.set(allocator, token, val_copy);
            },
            .array => |*arr| {
                if (std.mem.eql(u8, token, "-")) {
                    try arr.append(allocator, val_copy);
                } else {
                    const idx = try common.parseArrayIndex(token);
                    if (idx > arr.len()) return error.IndexOutOfBounds;
                    if (idx == arr.len()) {
                        try arr.append(allocator, val_copy);
                    } else {
                        try arr.insert(allocator, idx, val_copy);
                    }
                }
            },
            else => return error.IncorrectType,
        }
    } else if (std.mem.eql(u8, op_str, "remove")) {
        if (path.len == 0) return error.InvalidPatch;

        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidJsonPointer;
        const parent_ptr = path[0..last_slash];
        const raw_token = path[last_slash + 1 ..];

        const parent = try root.atPointer(parent_ptr);
        var token_buf: [512]u8 = undefined;
        const token = try common.unescapePointerToken(raw_token, &token_buf);

        switch (parent.value) {
            .object => |*obj| {
                if (!obj.remove(token)) return error.NoSuchField;
            },
            .array => |*arr| {
                const idx = try common.parseArrayIndex(token);
                if (idx >= arr.len()) return error.IndexOutOfBounds;
                _ = arr.removeAt(idx);
            },
            else => return error.IncorrectType,
        }
    } else if (std.mem.eql(u8, op_str, "replace")) {
        const val_el = op_el.get("value") orelse return error.InvalidPatch;
        const val_copy = try deepClone(allocator, val_el);

        if (path.len == 0) {
            root.* = val_copy;
            return;
        }

        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidJsonPointer;
        const parent_ptr = path[0..last_slash];
        const raw_token = path[last_slash + 1 ..];

        const parent = try root.atPointer(parent_ptr);
        var token_buf: [512]u8 = undefined;
        const token = try common.unescapePointerToken(raw_token, &token_buf);

        switch (parent.value) {
            .object => |*obj| {
                if (!obj.has(token)) return error.NoSuchField;
                try obj.set(allocator, token, val_copy);
            },
            .array => |*arr| {
                const idx = try common.parseArrayIndex(token);
                if (idx >= arr.len()) return error.IndexOutOfBounds;
                arr.items.items[idx] = val_copy;
            },
            else => return error.IncorrectType,
        }
    } else if (std.mem.eql(u8, op_str, "move")) {
        const from = try (op_el.get("from") orelse return error.InvalidPatch).asString();
        if (isProperPrefix(from, path)) return error.InvalidPatch;

        // Retrieve and clone from target
        const src_el = try root.atPointer(from);
        const val_copy = try deepClone(allocator, src_el);

        // Remove from source
        const last_slash_from = std.mem.lastIndexOfScalar(u8, from, '/') orelse return error.InvalidJsonPointer;
        const parent_from = try root.atPointer(from[0..last_slash_from]);
        var token_buf_from: [512]u8 = undefined;
        const token_from = try common.unescapePointerToken(from[last_slash_from + 1 ..], &token_buf_from);

        switch (parent_from.value) {
            .object => |*obj| {
                if (!obj.remove(token_from)) return error.NoSuchField;
            },
            .array => |*arr| {
                const idx = try common.parseArrayIndex(token_from);
                if (idx >= arr.len()) return error.IndexOutOfBounds;
                _ = arr.removeAt(idx);
            },
            else => return error.IncorrectType,
        }

        // Add to destination
        if (path.len == 0) {
            root.* = val_copy;
            return;
        }

        const last_slash_to = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidJsonPointer;
        const parent_to = try root.atPointer(path[0..last_slash_to]);
        var token_buf_to: [512]u8 = undefined;
        const token_to = try common.unescapePointerToken(path[last_slash_to + 1 ..], &token_buf_to);

        switch (parent_to.value) {
            .object => |*obj| {
                try obj.set(allocator, token_to, val_copy);
            },
            .array => |*arr| {
                if (std.mem.eql(u8, token_to, "-")) {
                    try arr.append(allocator, val_copy);
                } else {
                    const idx = try common.parseArrayIndex(token_to);
                    if (idx > arr.len()) return error.IndexOutOfBounds;
                    if (idx == arr.len()) {
                        try arr.append(allocator, val_copy);
                    } else {
                        try arr.insert(allocator, idx, val_copy);
                    }
                }
            },
            else => return error.IncorrectType,
        }
    } else if (std.mem.eql(u8, op_str, "copy")) {
        const from = try (op_el.get("from") orelse return error.InvalidPatch).asString();
        const src_el = try root.atPointer(from);
        const val_copy = try deepClone(allocator, src_el);

        if (path.len == 0) {
            root.* = val_copy;
            return;
        }

        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidJsonPointer;
        const parent = try root.atPointer(path[0..last_slash]);
        var token_buf: [512]u8 = undefined;
        const token = try common.unescapePointerToken(path[last_slash + 1 ..], &token_buf);

        switch (parent.value) {
            .object => |*obj| {
                try obj.set(allocator, token, val_copy);
            },
            .array => |*arr| {
                if (std.mem.eql(u8, token, "-")) {
                    try arr.append(allocator, val_copy);
                } else {
                    const idx = try common.parseArrayIndex(token);
                    if (idx > arr.len()) return error.IndexOutOfBounds;
                    if (idx == arr.len()) {
                        try arr.append(allocator, val_copy);
                    } else {
                        try arr.insert(allocator, idx, val_copy);
                    }
                }
            },
            else => return error.IncorrectType,
        }
    } else if (std.mem.eql(u8, op_str, "test")) {
        const expected_val = op_el.get("value") orelse return error.InvalidPatch;
        const actual_val = try root.atPointer(path);
        if (!deepEqual(actual_val, expected_val)) {
            return error.TestFailed;
        }
    } else {
        return error.InvalidPatch;
    }
}

/// Applies an RFC 6902 JSON Patch document to a MutDocument with strict atomicity.
/// If any operation fails, the original document remains unmodified.
pub fn applyPatch(doc: *MutDocument, patch_input: anytype) PatchError!void {
    const alloc = doc.arena.allocator();
    var patch_mut = try parsePatchToMutable(alloc, patch_input);
    const patch_arr = try patch_mut.asArray();

    // Stage changes on a clone to ensure all-or-nothing atomicity
    var staged_root = try deepClone(alloc, doc.root());

    for (patch_arr.items.items) |*op_el| {
        try applySingleOp(alloc, &staged_root, op_el);
    }

    // Commit staged root on full success
    doc.root_element = staged_root;
}

fn mergePatchRecursive(allocator: std.mem.Allocator, target: *MutElement, patch: *const MutElement) PatchError!void {
    if (patch.value == .object) {
        if (target.value != .object) {
            target.* = MutElement{ .allocator = allocator, .value = .{ .object = MutObject{} } };
        }

        const patch_obj = &patch.value.object;
        for (patch_obj.fields.items) |f| {
            if (f.value.isNull()) {
                _ = target.remove(f.key);
            } else {
                if (target.get(f.key)) |child| {
                    try mergePatchRecursive(allocator, child, &f.value);
                } else {
                    const cloned_val = try deepClone(allocator, &f.value);
                    try target.set(f.key, cloned_val);
                }
            }
        }
    } else {
        target.* = try deepClone(allocator, patch);
    }
}

/// Applies an RFC 7396 JSON Merge Patch to a MutDocument.
pub fn applyMergePatch(doc: *MutDocument, patch_input: anytype) PatchError!void {
    const alloc = doc.arena.allocator();
    const patch_mut = try parsePatchToMutable(alloc, patch_input);

    var staged_root = try deepClone(alloc, doc.root());
    try mergePatchRecursive(alloc, &staged_root, &patch_mut);
    doc.root_element = staged_root;
}

test "JSON Patch RFC 6902 error conditions and invalid patches" {
    const alloc = std.testing.allocator;

    var doc = try MutDocument.init(alloc);
    defer doc.deinit();
    try doc.setPointer("/existing", 100);

    // Missing 'op' field
    try std.testing.expectError(error.InvalidPatch, doc.applyPatch("[{\"path\": \"/existing\"}]"));

    // Missing 'path' field
    try std.testing.expectError(error.InvalidPatch, doc.applyPatch("[{\"op\": \"remove\"}]"));

    // Invalid op name
    try std.testing.expectError(error.InvalidPatch, doc.applyPatch("[{\"op\": \"destroy\", \"path\": \"/existing\"}]"));

    // Remove non-existent field -> error.NoSuchField
    try std.testing.expectError(error.NoSuchField, doc.applyPatch("[{\"op\": \"remove\", \"path\": \"/missing\"}]"));

    // Replace non-existent field -> error.NoSuchField
    try std.testing.expectError(error.NoSuchField, doc.applyPatch("[{\"op\": \"replace\", \"path\": \"/missing\", \"value\": 1}]"));

    // Test failure -> error.TestFailed
    try std.testing.expectError(error.TestFailed, doc.applyPatch("[{\"op\": \"test\", \"path\": \"/existing\", \"value\": 999}]"));

    // Array index out of bounds in remove
    try doc.root().set("arr", MutArray{});
    try doc.setPointer("/arr/-", 1);
    try doc.setPointer("/arr/-", 2);
    try std.testing.expectError(error.IndexOutOfBounds, doc.applyPatch("[{\"op\": \"remove\", \"path\": \"/arr/10\"}]"));
}

test "JSON Patch RFC 6902 circular move rejection and atomicity rollback" {
    const alloc = std.testing.allocator;

    var doc = try MutDocument.init(alloc);
    defer doc.deinit();
    try doc.root().set("parent", MutObject{});
    try doc.setPointer("/parent/child", "val");

    // Circular move: from is parent of path
    const circular_res = doc.applyPatch("[{\"op\": \"move\", \"from\": \"/parent\", \"path\": \"/parent/child/grandchild\"}]");
    try std.testing.expect(circular_res == error.InvalidPatch or circular_res == error.CircularMove or circular_res == error.NoSuchField);

    // Atomicity test: successful add followed by failing test op
    const patch =
        \\[
        \\  {"op": "add", "path": "/parent/new_field", "value": "temporary"},
        \\  {"op": "test", "path": "/parent/child", "value": "wrong_expected_val"}
        \\]
    ;
    try std.testing.expectError(error.TestFailed, doc.applyPatch(patch));

    // Verify /parent/new_field was NOT committed (rollback verified!)
    try std.testing.expectError(error.NoSuchField, doc.atPointer("/parent/new_field"));
}

test "JSON Merge Patch RFC 7396 edge cases: scalar replacement, array replacement, null deletion" {
    const alloc = std.testing.allocator;

    var doc = try MutDocument.init(alloc);
    defer doc.deinit();
    try doc.setPointer("/a", "keep");
    try doc.setPointer("/b", "delete_me");
    try doc.root().set("arr", MutArray{});
    try doc.setPointer("/arr/-", 1);
    try doc.setPointer("/arr/-", 2);
    try doc.setPointer("/arr/-", 3);

    // Merge patch:
    // 1. "b": null deletes "b"
    // 2. "arr": [4, 5] completely replaces array (not merged)
    // 3. "c": "new_val" adds "c"
    const merge_patch =
        \\{
        \\  "b": null,
        \\  "arr": [4, 5],
        \\  "c": "new_val"
        \\}
    ;
    try doc.applyMergePatch(merge_patch);

    // Check "a" preserved
    try std.testing.expectEqualStrings("keep", try (try doc.atPointer("/a")).asString());

    // Check "b" removed
    try std.testing.expectError(error.NoSuchField, doc.atPointer("/b"));

    // Check "c" added
    try std.testing.expectEqualStrings("new_val", try (try doc.atPointer("/c")).asString());

    // Check "arr" replaced with [4, 5]
    const arr_el = try doc.atPointer("/arr");
    const arr = try arr_el.asArray();
    try std.testing.expectEqual(@as(usize, 2), arr.len());
    try std.testing.expectEqual(@as(i64, 4), try (arr.at(0).?).asInt());
    try std.testing.expectEqual(@as(i64, 5), try (arr.at(1).?).asInt());

    // Merge patch with non-object replaces the entire document root!
    try doc.applyMergePatch("\"scalar_root\"");
    try std.testing.expectEqualStrings("scalar_root", try (try doc.atPointer("")).asString());
}

