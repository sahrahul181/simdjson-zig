const std = @import("std");

pub const SimdJsonError = error{ Capacity, MemAlloc, TapeError, DepthError, StringError, TAtomError, FAtomError, NAtomError, NumberError, BigIntError, Utf8Error, Uninitialized, Empty, UnescapedChars, UnclosedString, UnsupportedArchitecture, IncorrectType, NumberOutOfRange, IndexOutOfBounds, NoSuchField, IoError, InvalidJsonPointer, InvalidUriFragment, UnexpectedError, ParserInUse, OutOfOrderIteration, InsufficientPadding, IncompleteArrayOrObject, ScalarDocumentAsValue, OutOfBounds, TrailingContent, OutOfCapacity, TrailingComma };

pub fn errorMessage(err: SimdJsonError) []const u8 {
    return switch (err) {
        error.Capacity => "This parser can't support a document that big",
        error.MemAlloc => "Error allocating memory, most likely out of memory",
        error.TapeError => "Something went wrong, generic tape error",
        error.DepthError => "Your document exceeds the depth limitation",
        error.StringError => "Problem while parsing a string",
        error.TAtomError => "Problem while parsing 'true' atom",
        error.FAtomError => "Problem while parsing 'false' atom",
        error.NAtomError => "Problem while parsing 'null' atom",
        error.NumberError => "Problem while parsing a number",
        error.BigIntError => "The integer value exceeds 64 bits",
        error.Utf8Error => "The input is not valid UTF-8",
        error.Uninitialized => "Unknown error or uninitialized document",
        error.Empty => "No structural element found",
        error.UnescapedChars => "Found unescaped characters in a string",
        error.UnclosedString => "Missing quote at the end of string",
        error.UnsupportedArchitecture => "Unsupported architecture",
        error.IncorrectType => "JSON element has a different type than user expected",
        error.NumberOutOfRange => "JSON number does not fit in range",
        error.IndexOutOfBounds => "JSON array index too large",
        error.NoSuchField => "JSON field not found in object",
        error.IoError => "Error reading file",
        error.InvalidJsonPointer => "Invalid JSON pointer syntax",
        error.InvalidUriFragment => "Invalid URI fragment",
        error.UnexpectedError => "Indicative of a bug in parser",
        error.ParserInUse => "Parser is already in use",
        error.OutOfOrderIteration => "Tried to iterate out of order",
        error.InsufficientPadding => "The JSON doesn't have enough padding for safe SIMD parsing",
        error.IncompleteArrayOrObject => "The document ends early without closing array or object",
        error.ScalarDocumentAsValue => "A scalar document is treated as a container value",
        error.OutOfBounds => "Attempted to access location outside of document",
        error.TrailingContent => "Unexpected trailing content after JSON root element",
        error.OutOfCapacity => "The capacity was exceeded",
        error.TrailingComma => "Found illegal trailing comma",
    };
}

/// Rich Line/Column Error Diagnostic for SIMD JSON parsing.
/// Zero heap allocations, zero cost on the happy path.
pub const Diagnostic = struct {
    line: usize,
    column: usize,
    byte_offset: usize,
    err: SimdJsonError,
    line_slice: []const u8,
    custom_msg: ?[]const u8 = null,

    /// Computes exact 1-based line and column, byte offset, and line snippet from input buffer.
    pub fn compute(buf: []const u8, byte_offset: usize, err: SimdJsonError) Diagnostic {
        const offset = @min(byte_offset, buf.len);

        // Count 1-based line number and find start of current line
        var line: usize = 1;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < offset) : (i += 1) {
            if (buf[i] == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }

        // Find end of current line (stop before \r, \n, or EOF)
        var line_end = offset;
        while (line_end < buf.len) : (line_end += 1) {
            if (buf[line_end] == '\n' or buf[line_end] == '\r') break;
        }

        // 1-based column
        const column = (offset - line_start) + 1;

        return .{
            .line = line,
            .column = column,
            .byte_offset = offset,
            .err = err,
            .line_slice = buf[line_start..line_end],
            .custom_msg = null,
        };
    }

    /// Returns human-readable error description
    pub fn message(self: Diagnostic) []const u8 {
        return self.custom_msg orelse errorMessage(self.err);
    }

    /// Formats a compiler-grade diagnostic snippet with visual caret pointing to the exact column:
    ///
    /// JSON parse error: Problem while parsing a number (line 3, column 11, byte 45)
    ///    |
    ///  3 |   "val": 12.34.56,
    ///    |          ^
    pub fn format(self: Diagnostic, writer: anytype) !void {
        const msg = self.message();
        try writer.print("JSON parse error: {s} (line {d}, column {d}, byte {d})\n", .{
            msg,
            self.line,
            self.column,
            self.byte_offset,
        });

        // Compute gutter width for line numbers (e.g. "   3 | ")
        var line_digits: usize = 1;
        var temp_line = self.line;
        while (temp_line >= 10) : (temp_line /= 10) {
            line_digits += 1;
        }
        const gutter_width = @max(line_digits, 2);

        // Empty gutter line: "   |"
        var g: usize = 0;
        while (g < gutter_width + 1) : (g += 1) try writer.writeByte(' ');
        try writer.writeAll("|\n");

        // Line content: "  3 | <line_slice>"
        var num_spaces = (gutter_width + 1) - (line_digits + 1);
        while (num_spaces > 0) : (num_spaces -= 1) try writer.writeByte(' ');
        try writer.print("{d} | {s}\n", .{ self.line, self.line_slice });

        // Caret line: "    |      ^"
        g = 0;
        while (g < gutter_width + 1) : (g += 1) try writer.writeByte(' ');
        try writer.writeAll("| ");

        const col_spaces = if (self.column > 1) self.column - 1 else 0;
        var c: usize = 0;
        while (c < col_spaces) : (c += 1) {
            if (c < self.line_slice.len and self.line_slice[c] == '\t') {
                try writer.writeByte('\t');
            } else {
                try writer.writeByte(' ');
            }
        }
        try writer.writeAll("^\n");
    }

    pub const BufferWriter = struct {
        buffer: []u8,
        pos: usize = 0,

        pub const Error = error{NoSpaceLeft};

        pub fn writeByte(self: *BufferWriter, byte: u8) Error!void {
            if (self.pos >= self.buffer.len) return error.NoSpaceLeft;
            self.buffer[self.pos] = byte;
            self.pos += 1;
        }

        pub fn writeAll(self: *BufferWriter, bytes: []const u8) Error!void {
            if (self.pos + bytes.len > self.buffer.len) return error.NoSpaceLeft;
            @memcpy(self.buffer[self.pos..][0..bytes.len], bytes);
            self.pos += bytes.len;
        }

        pub fn print(self: *BufferWriter, comptime fmt: []const u8, args: anytype) Error!void {
            const printed = std.fmt.bufPrint(self.buffer[self.pos..], fmt, args) catch return error.NoSpaceLeft;
            self.pos += printed.len;
        }

        pub fn getWritten(self: *BufferWriter) []const u8 {
            return self.buffer[0..self.pos];
        }
    };

    /// Formats into a caller-provided buffer (zero heap allocation).
    /// Returns the written slice of out_buf.
    pub fn formatToString(self: Diagnostic, out_buf: []u8) []const u8 {
        var writer = BufferWriter{ .buffer = out_buf };
        self.format(&writer) catch return out_buf[0..0];
        return writer.getWritten();
    }

    /// Convenience printer for debugging and CLI reporting.
    pub fn print(self: Diagnostic) void {
        var buf: [1024]u8 = undefined;
        const msg = self.formatToString(&buf);
        std.debug.print("{s}", .{msg});
    }
};

test "Diagnostic compute and formatting" {
    const json =
        \\{
        \\  "name": "simdjson",
        \\  "version": 12.34.56,
        \\  "active": true
        \\}
    ;

    // Offset of the '1' in '12.34.56'
    const target = "12.34.56";
    const byte_offset = std.mem.indexOf(u8, json, target).?;

    const diag = Diagnostic.compute(json, byte_offset, error.NumberError);
    try std.testing.expectEqual(@as(usize, 3), diag.line);
    try std.testing.expectEqual(@as(usize, 14), diag.column);
    try std.testing.expectEqual(byte_offset, diag.byte_offset);
    try std.testing.expectEqualStrings("  \"version\": 12.34.56,", diag.line_slice);
    try std.testing.expectEqual(error.NumberError, diag.err);

    var out_buf: [512]u8 = undefined;
    const formatted = diag.formatToString(&out_buf);
    try std.testing.expect(formatted.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "(line 3, column 14, byte") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "3 |   \"version\": 12.34.56,") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "^") != null);
}

test "Diagnostic compute: line 1 col 1, CRLF, and out of bounds" {
    // 1. First byte of buffer
    const d0 = Diagnostic.compute("{\"a\": 1}", 0, error.TapeError);
    try std.testing.expectEqual(@as(usize, 1), d0.line);
    try std.testing.expectEqual(@as(usize, 1), d0.column);
    try std.testing.expectEqual(@as(usize, 0), d0.byte_offset);
    try std.testing.expectEqualStrings("{\"a\": 1}", d0.line_slice);

    // 2. CRLF handling across lines
    const crlf_json = "{\r\n  \"key\":\r\n  [1, 2]\r\n}";
    const offset_arr = std.mem.indexOf(u8, crlf_json, "[").?;
    const d_crlf = Diagnostic.compute(crlf_json, offset_arr, error.IncompleteArrayOrObject);
    try std.testing.expectEqual(@as(usize, 3), d_crlf.line);
    try std.testing.expectEqual(@as(usize, 3), d_crlf.column);
    try std.testing.expectEqualStrings("  [1, 2]", d_crlf.line_slice);

    // 3. Offset beyond buffer length clamped safely
    const d_oob = Diagnostic.compute("short", 999, error.TapeError);
    try std.testing.expectEqual(@as(usize, 1), d_oob.line);
    try std.testing.expectEqual(@as(usize, 6), d_oob.column);
    try std.testing.expectEqual(@as(usize, 5), d_oob.byte_offset);

    // 4. Empty buffer
    const d_empty = Diagnostic.compute("", 0, error.Empty);
    try std.testing.expectEqual(@as(usize, 1), d_empty.line);
    try std.testing.expectEqual(@as(usize, 1), d_empty.column);
    try std.testing.expectEqualStrings("", d_empty.line_slice);
}

test "errorMessage: descriptive strings for all major errors" {
    try std.testing.expect(errorMessage(error.UnclosedString).len > 0);
    try std.testing.expect(errorMessage(error.UnescapedChars).len > 0);
    try std.testing.expect(errorMessage(error.TrailingComma).len > 0);
    try std.testing.expect(errorMessage(error.IncompleteArrayOrObject).len > 0);
    try std.testing.expect(errorMessage(error.Capacity).len > 0);
    try std.testing.expect(errorMessage(error.NumberOutOfRange).len > 0);
    try std.testing.expect(errorMessage(error.TapeError).len > 0);
    try std.testing.expect(errorMessage(error.Empty).len > 0);
}
