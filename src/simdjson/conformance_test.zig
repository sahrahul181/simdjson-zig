const std = @import("std");
const simdjson = @import("../root.zig");
const conformance = @import("conformance_cases.zig");

test "JSONTestSuite official conformance test suite (318 tests)" {
    const allocator = std.testing.allocator;

    var y_passed: usize = 0;
    var y_failed: usize = 0;
    var n_passed: usize = 0;
    var n_failed: usize = 0;
    var i_accepted: usize = 0;
    var i_rejected: usize = 0;

    for (conformance.cases) |tc| {

        // Prepare padded buffer
        const padded = try allocator.alloc(u8, tc.data.len + simdjson.SIMDJSON_PADDING);
        defer allocator.free(padded);
        @memcpy(padded[0..tc.data.len], tc.data);
        @memset(padded[tc.data.len..], ' ');

        const indexes = try allocator.alloc(u32, tc.data.len + 3);
        defer allocator.free(indexes);

        const parse_result = blk: {
            const structurals = simdjson.Stage1Indexer.indexPaddedOptions(
                .{ .validate_utf8 = true },
                padded,
                tc.data.len,
                indexes,
            ) catch break :blk false;

            const tape_buf = try allocator.alloc(u64, structurals * 2 + 16);
            defer allocator.free(tape_buf);

            _ = simdjson.Stage2Parser.parseOptions(
                .{ .validate_strings = true },
                padded,
                indexes,
                structurals,
                tape_buf,
            ) catch break :blk false;
            break :blk true;
        };

        switch (tc.expected) {
            .must_pass => {
                if (parse_result) {
                    y_passed += 1;
                } else {
                    y_failed += 1;
                    std.debug.print("\nFAIL: y_ test falsely rejected: {s}\n", .{tc.name});
                }
            },
            .must_fail => {
                if (!parse_result) {
                    n_passed += 1;
                } else {
                    n_failed += 1;
                    std.debug.print("\nFAIL: n_ test falsely accepted: {s}\n", .{tc.name});
                }
            },
            .indeterminate => {
                if (parse_result) {
                    i_accepted += 1;
                } else {
                    i_rejected += 1;
                }
            },
        }
    }

    std.debug.print("\n=======================================================\n", .{});
    std.debug.print("          JSONTestSuite Conformance Results\n", .{});
    std.debug.print("=======================================================\n", .{});
    std.debug.print("  y_ (Must Pass) : {d} passed, {d} failed (total: {d})\n", .{ y_passed, y_failed, y_passed + y_failed });
    std.debug.print("  n_ (Must Fail) : {d} passed, {d} failed (total: {d})\n", .{ n_passed, n_failed, n_passed + n_failed });
    std.debug.print("  i_ (Implementation-defined): {d} accepted, {d} rejected (total: {d})\n", .{ i_accepted, i_rejected, i_accepted + i_rejected });
    std.debug.print("-------------------------------------------------------\n", .{});
    std.debug.print("  Total Test Files Evaluated: {d}\n", .{conformance.cases.len});
    std.debug.print("=======================================================\n", .{});

    try std.testing.expectEqual(@as(usize, 0), y_failed);
    try std.testing.expectEqual(@as(usize, 0), n_failed);
}
