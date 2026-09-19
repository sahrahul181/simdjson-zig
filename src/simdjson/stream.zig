const std = @import("std");
const error_types = @import("error.zig");
const SimdJsonError = error_types.SimdJsonError;
const Diagnostic = error_types.Diagnostic;
const common = @import("common.zig");
const stage1 = @import("stage1.zig");
const Stage1Indexer = stage1.Stage1Indexer;
const SIMDJSON_PADDING = stage1.SIMDJSON_PADDING;
const stage2 = @import("stage2.zig");
const Stage2Parser = stage2.Stage2Parser;
const dom = @import("dom.zig");
const Document = dom.Document;
const ondemand = @import("ondemand.zig");
const Value = ondemand.Value;
const OnDemandDocument = ondemand.OnDemandDocument;

pub const StreamOptions = struct {
    /// Usable window capacity in bytes (excluding SIMDJSON_PADDING).
    /// Default is 1 MB.
    window_capacity: usize = 1024 * 1024,
    /// Maximum capacity allowed when auto_grow is enabled.
    max_capacity: usize = 64 * 1024 * 1024,
    /// Automatically grow window capacity if a single document exceeds it.
    auto_grow: bool = false,
};

inline fn isTruncationError(err: SimdJsonError) bool {
    return switch (err) {
        error.IncompleteArrayOrObject,
        error.UnclosedString,
        error.Empty,
        error.TapeError,
        error.NumberError,
        error.TAtomError,
        error.FAtomError,
        error.NAtomError,
        error.StringError => true,
        else => false,
    };
}

inline fn readFromReader(reader: anytype, dest: []u8) !usize {
    const T = @TypeOf(reader);
    if (comptime @typeInfo(T) == .pointer) {
        const Child = @typeInfo(T).pointer.child;
        if (comptime @hasDecl(Child, "readSliceShort")) {
            return reader.readSliceShort(dest);
        } else if (comptime @hasDecl(Child, "read")) {
            return reader.read(dest);
        }
    } else {
        if (comptime @hasDecl(T, "readSliceShort")) {
            return reader.readSliceShort(dest);
        } else if (comptime @hasDecl(T, "read")) {
            return reader.read(dest);
        }
    }
    return reader.readSliceShort(dest);
}

/// Sliding-window streaming parser for arbitrary std.Io.Reader streams.
/// Parses multi-gigabyte NDJSON / multi-document files with a constant, fixed-size memory footprint.
pub fn ChunkedDocumentStream(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        reader: ReaderType,
        allocator: ?std.mem.Allocator = null,
        options: StreamOptions,

        window_buf: []u8,
        indexes_buf: []u32,
        tape_buf: []u64,

        capacity: usize,
        buf_len: usize = 0,
        indexed_len: usize = 0,
        doc_start_byte: usize = 0,
        cur_struct: usize = 0,
        structurals_count: usize = 0,
        eof: bool = false,

        // Global stream tracking for rich diagnostics
        global_line_offset: usize = 0,
        global_byte_offset: usize = 0,

        /// Initializes a chunked document streamer with dynamic window buffers allocated once.
        pub fn init(
            allocator: std.mem.Allocator,
            reader: ReaderType,
            options: StreamOptions,
        ) !Self {
            const cap = options.window_capacity;
            const window_buf = try allocator.alloc(u8, cap + SIMDJSON_PADDING);
            errdefer allocator.free(window_buf);

            const indexes_buf = try allocator.alloc(u32, cap + 3);
            errdefer allocator.free(indexes_buf);

            const tape_buf = try allocator.alloc(u64, cap + 16);
            errdefer allocator.free(tape_buf);

            return Self{
                .reader = reader,
                .allocator = allocator,
                .options = options,
                .window_buf = window_buf,
                .indexes_buf = indexes_buf,
                .tape_buf = tape_buf,
                .capacity = cap,
            };
        }

        /// Initializes a chunked document streamer with caller-provided static or stack buffers.
        /// Guaranteed STRICTLY ZERO heap allocations.
        pub fn initFixed(
            reader: ReaderType,
            window_buf: []u8,
            indexes_buf: []u32,
            tape_buf: []u64,
        ) !Self {
            if (window_buf.len <= SIMDJSON_PADDING) return error.Capacity;
            const cap = window_buf.len - SIMDJSON_PADDING;
            if (indexes_buf.len < cap + 3) return error.Capacity;
            if (tape_buf.len < 4) return error.Capacity;

            return Self{
                .reader = reader,
                .allocator = null,
                .options = .{ .window_capacity = cap, .auto_grow = false },
                .window_buf = window_buf,
                .indexes_buf = indexes_buf,
                .tape_buf = tape_buf,
                .capacity = cap,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.allocator) |alloc| {
                alloc.free(self.window_buf);
                alloc.free(self.indexes_buf);
                alloc.free(self.tape_buf);
            }
            self.* = undefined;
        }

        fn growWindow(self: *Self) !void {
            const alloc = self.allocator orelse return error.Capacity;
            const new_cap = self.capacity * 2;
            if (new_cap > self.options.max_capacity) {
                std.debug.print("\n[DEBUG] growWindow capacity exceeded: new_cap={d} > max={d}\n", .{ new_cap, self.options.max_capacity });
                return error.Capacity;
            }

            const new_window = try alloc.alloc(u8, new_cap + SIMDJSON_PADDING);
            @memcpy(new_window[0..self.buf_len], self.window_buf[0..self.buf_len]);
            alloc.free(self.window_buf);
            self.window_buf = new_window;

            const new_indexes = try alloc.alloc(u32, new_cap + 3);
            alloc.free(self.indexes_buf);
            self.indexes_buf = new_indexes;

            const new_tape = try alloc.alloc(u64, new_cap + 16);
            alloc.free(self.tape_buf);
            self.tape_buf = new_tape;

            self.capacity = new_cap;
        }

        fn refillWindow(self: *Self) !bool {
            if (self.doc_start_byte > 0) {
                const consumed_slice = self.window_buf[0..self.doc_start_byte];
                self.global_line_offset += std.mem.count(u8, consumed_slice, "\n");
                self.global_byte_offset += self.doc_start_byte;

                const unconsumed = self.buf_len - self.doc_start_byte;
                if (unconsumed > 0) {
                    std.mem.copyForwards(u8, self.window_buf[0..unconsumed], self.window_buf[self.doc_start_byte .. self.buf_len]);
                }
                self.buf_len = unconsumed;
                self.doc_start_byte = 0;
            }

            while (self.buf_len < self.capacity and !self.eof) {
                const read_slice = self.window_buf[self.buf_len .. self.capacity];
                const n = try readFromReader(self.reader, read_slice);
                if (n == 0) {
                    self.eof = true;
                    break;
                }
                self.buf_len += n;
            }

            if (self.buf_len == 0) {
                self.structurals_count = 0;
                self.cur_struct = 0;
                return false;
            }

            // For streams with newlines (NDJSON / JSON lines), safe-trim Stage 1 to the last newline
            // so arbitrary chunk reads don't fail with UnclosedString on a split trailing line.
            var index_len = self.buf_len;
            if (!self.eof and index_len > 0) {
                if (std.mem.lastIndexOfScalar(u8, self.window_buf[0..index_len], '\n')) |last_nl| {
                    if (last_nl > 0 and last_nl < index_len - 1) {
                        index_len = last_nl + 1;
                    }
                }
            }

            self.indexed_len = index_len;
            var saved_pad: [SIMDJSON_PADDING]u8 = undefined;
            const pad_to_save = @min(SIMDJSON_PADDING, self.buf_len - index_len);
            @memcpy(saved_pad[0..pad_to_save], self.window_buf[index_len .. index_len + pad_to_save]);
            @memset(self.window_buf[index_len .. index_len + SIMDJSON_PADDING], ' ');

            const index_res = Stage1Indexer.indexPadded(
                self.window_buf,
                index_len,
                self.indexes_buf,
            );

            // Restore original bytes immediately so window_buf is not corrupted
            @memcpy(self.window_buf[index_len .. index_len + pad_to_save], saved_pad[0..pad_to_save]);

            if (index_res) |cnt| {
                self.structurals_count = cnt;
                self.cur_struct = 0;
                return true;
            } else |err| {
                if (err == error.Empty) {
                    if (self.eof) {
                        self.structurals_count = 0;
                        self.cur_struct = 0;
                        return false;
                    }
                    // Only whitespace was read so far, reset and keep reading
                    self.buf_len = 0;
                    return self.refillWindow();
                }

                if (!self.eof and isTruncationError(err)) {
                    if (self.buf_len >= self.capacity) {
                        if (self.options.auto_grow and self.allocator != null) {
                            try self.growWindow();
                            return self.refillWindow();
                        }
                        return error.Capacity;
                    }
                }
                return err;
            }
        }

        /// Yields the next DOM Document from the stream, sliding the window forward as necessary.
        /// Returns null when the stream is exhausted.
        pub fn next(self: *Self) !?Document {
            while (true) {
                if (self.cur_struct >= self.structurals_count) {
                    if (self.eof) return null;
                    const has_more = try self.refillWindow();
                    if (!has_more) return null;
                    if (self.structurals_count == 0) {
                        if (self.eof) return null;
                        continue;
                    }
                }

                // Skip commas and whitespace between top-level values
                while (self.cur_struct < self.structurals_count) {
                    const b = self.window_buf[self.indexes_buf[self.cur_struct]];
                    if (b == ',' or b == '\n' or b == '\r' or b == '\t' or b == ' ') {
                        self.cur_struct += 1;
                    } else {
                        break;
                    }
                }

                if (self.cur_struct >= self.structurals_count) {
                    self.doc_start_byte = self.indexed_len;
                    continue;
                }

                self.doc_start_byte = self.indexes_buf[self.cur_struct];

                var cur = self.cur_struct;
                const res = Stage2Parser.parseSingle(
                    self.window_buf[0..self.indexed_len],
                    self.indexes_buf,
                    self.structurals_count,
                    &cur,
                    self.tape_buf,
                );

                if (res) |opt_len| {
                    if (opt_len) |tape_len| {
                        self.cur_struct = cur;
                        if (cur < self.structurals_count) {
                            self.doc_start_byte = self.indexes_buf[cur];
                        } else {
                            self.doc_start_byte = self.indexed_len;
                        }
                        return Document.init(self.window_buf[0..self.indexed_len], self.tape_buf[0..tape_len]);
                    } else {
                        self.doc_start_byte = self.indexed_len;
                        self.cur_struct = self.structurals_count;
                        continue;
                    }
                } else |err| {
                    if (!self.eof and isTruncationError(err)) {
                        if (self.doc_start_byte == 0 and self.buf_len >= self.capacity) {
                            if (self.options.auto_grow and self.allocator != null) {
                                try self.growWindow();
                                continue;
                            }
                            return error.Capacity;
                        }
                        const refilled = try self.refillWindow();
                        if (!refilled) return err;
                        continue;
                    }
                    return err;
                }
            }
        }

        /// Computes exact global line and column diagnostics pointing into the source stream.
        pub fn getDiagnostic(self: *const Self, err: SimdJsonError) Diagnostic {
            const local_pos = if (self.cur_struct < self.structurals_count)
                self.indexes_buf[self.cur_struct]
            else if (self.structurals_count > 0)
                self.indexes_buf[self.structurals_count - 1]
            else
                0;

            var diag = Diagnostic.compute(self.window_buf[0..self.buf_len], local_pos, err);
            diag.line += self.global_line_offset;
            diag.byte_offset += self.global_byte_offset;
            return diag;
        }
    };
}

/// Convenience factory for ChunkedDocumentStream with dynamic allocation.
pub fn chunkedDocumentStream(
    allocator: std.mem.Allocator,
    reader: anytype,
    options: StreamOptions,
) !ChunkedDocumentStream(@TypeOf(reader)) {
    return ChunkedDocumentStream(@TypeOf(reader)).init(allocator, reader, options);
}

/// Convenience factory for ChunkedDocumentStream with fixed zero-allocation buffers.
pub fn fixedChunkedDocumentStream(
    reader: anytype,
    window_buf: []u8,
    indexes_buf: []u32,
    tape_buf: []u64,
) !ChunkedDocumentStream(@TypeOf(reader)) {
    return ChunkedDocumentStream(@TypeOf(reader)).initFixed(reader, window_buf, indexes_buf, tape_buf);
}

test "ChunkedDocumentStream empty and whitespace-only stream" {
    // 1. Completely empty stream
    var empty_reader = std.Io.Reader.fixed("");
    var stream1 = try chunkedDocumentStream(std.testing.allocator, &empty_reader, .{ .window_capacity = 128 });
    defer stream1.deinit();
    try std.testing.expect((try stream1.next()) == null);

    // 2. Whitespace-only stream
    var ws_reader = std.Io.Reader.fixed("   \t\r\n   \n\n   ");
    var stream2 = try chunkedDocumentStream(std.testing.allocator, &ws_reader, .{ .window_capacity = 128 });
    defer stream2.deinit();
    try std.testing.expect((try stream2.next()) == null);
}

test "ChunkedDocumentStream stream with primitives and delimiter variations" {
    const stream_text =
        \\42
        \\"hello"
        \\true
        \\null
        \\{"key": "val"},
        \\{"second": 100}
    ;
    var reader = std.Io.Reader.fixed(stream_text);
    var stream = try chunkedDocumentStream(std.testing.allocator, &reader, .{ .window_capacity = 128 });
    defer stream.deinit();

    // 1. Number 42
    const doc1 = (try stream.next()).?;
    try std.testing.expectEqual(@as(i64, 42), try doc1.root().asInt());

    // 2. String "hello"
    const doc2 = (try stream.next()).?;
    try std.testing.expectEqualStrings("hello", try doc2.root().asString());

    // 3. Boolean true
    const doc3 = (try stream.next()).?;
    try std.testing.expectEqual(true, try doc3.root().asBool());

    // 4. Null
    const doc4 = (try stream.next()).?;
    try std.testing.expect(doc4.root().isNull());

    // 5. Object {"key": "val"}
    const doc5 = (try stream.next()).?;
    const obj5 = try doc5.root().asObject();
    try std.testing.expectEqualStrings("val", try (obj5.get("key").?).asString());

    // 6. Object {"second": 100}
    const doc6 = (try stream.next()).?;
    const obj6 = try doc6.root().asObject();
    try std.testing.expectEqual(@as(i64, 100), try (obj6.get("second").?).asInt());

    // End of stream
    try std.testing.expect((try stream.next()) == null);
}

test "ChunkedDocumentStream syntax error diagnostics and fixed buffer capacity overflow" {
    // 1. Syntax error midway through stream
    const invalid_stream =
        \\{"id": 1}
        \\{"broken": }
        \\{"id": 3}
    ;
    var reader1 = std.Io.Reader.fixed(invalid_stream);
    var stream1 = try chunkedDocumentStream(std.testing.allocator, &reader1, .{ .window_capacity = 128 });
    defer stream1.deinit();

    const first = try stream1.next();
    try std.testing.expect(first != null);

    const res = stream1.next();
    try std.testing.expectError(error.TapeError, res);
    const diag = stream1.getDiagnostic(error.TapeError);
    try std.testing.expectEqual(@as(usize, 2), diag.line);

    // 2. Fixed buffer capacity overflow
    const large_doc = "{\"large_key_exceeding_tiny_fixed_buffer\": \"some long string contents here\"}";
    var reader2 = std.Io.Reader.fixed(large_doc);

    var window_buf: [32 + SIMDJSON_PADDING]u8 = undefined;
    var indexes_buf: [64]u32 = undefined;
    var tape_buf: [64]u64 = undefined;

    var stream2 = try fixedChunkedDocumentStream(&reader2, &window_buf, &indexes_buf, &tape_buf);
    defer stream2.deinit();

    try std.testing.expectError(error.Capacity, stream2.next());
}

