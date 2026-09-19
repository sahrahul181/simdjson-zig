//! Root module for simdjson-zig.
//! Zero-allocation, AVX2-accelerated SIMD JSON parsing engine for Zig 0.16.0+.

const std = @import("std");

// Submodules
pub const error_types = @import("simdjson/error.zig");
pub const SimdJsonError = error_types.SimdJsonError;
pub const errorMessage = error_types.errorMessage;
pub const Diagnostic = error_types.Diagnostic;

pub const common = @import("simdjson/common.zig");
pub const stage1 = @import("simdjson/stage1.zig");
pub const tape = @import("simdjson/tape.zig");
pub const stage2 = @import("simdjson/stage2.zig");
pub const dom = @import("simdjson/dom.zig");
pub const utf8 = @import("simdjson/utf8.zig");
pub const ondemand = @import("simdjson/ondemand.zig");
pub const fast_float = @import("simdjson/fast_float.zig");

// Stage 1 & 2 Parsers
pub const Stage1Indexer = stage1.Stage1Indexer;
pub const SIMDJSON_PADDING = stage1.SIMDJSON_PADDING;
pub const Stage2Parser = stage2.Stage2Parser;

// DOM Tree & Navigation
pub const Document = dom.Document;
pub const DocumentStream = dom.DocumentStream;
pub const Element = dom.Element;
pub const Object = dom.Object;
pub const Array = dom.Array;
pub const FormatOptions = dom.FormatOptions;

// OnDemand Parser
pub const OnDemandDocument = ondemand.OnDemandDocument;
pub const OnDemandDocumentStream = ondemand.OnDemandDocumentStream;
pub const Value = ondemand.Value;
pub const Field = ondemand.Field;

// Vectorized Unescaping
pub const unescapeString = common.unescapeString;

// Chunked Streaming
pub const stream = @import("simdjson/stream.zig");
pub const StreamOptions = stream.StreamOptions;
pub const ChunkedDocumentStream = stream.ChunkedDocumentStream;
pub const chunkedDocumentStream = stream.chunkedDocumentStream;
pub const fixedChunkedDocumentStream = stream.fixedChunkedDocumentStream;

// Mutable DOM
pub const mut_dom = @import("simdjson/mut_dom.zig");
pub const MutDocument = mut_dom.MutDocument;
pub const MutElement = mut_dom.MutElement;
pub const MutObject = mut_dom.MutObject;
pub const MutArray = mut_dom.MutArray;
pub const MutType = mut_dom.MutType;
pub const MutValue = mut_dom.MutValue;
pub const MutField = mut_dom.MutField;

// RFC 6902 JSON Patch & RFC 7396 Merge Patch
pub const patch = @import("simdjson/patch.zig");
pub const applyPatch = patch.applyPatch;
pub const applyMergePatch = patch.applyMergePatch;
pub const deepEqual = patch.deepEqual;
pub const deepClone = patch.deepClone;
pub const PatchError = patch.PatchError;

// RFC 9535 JSONPath
pub const jsonpath = @import("simdjson/jsonpath.zig");
pub const JsonPath = jsonpath.JsonPath;
pub const JsonPathError = jsonpath.JsonPathError;

// Compile-time reflection serialization & deserialization (Serde)
pub const serde = @import("simdjson/serde.zig");
pub const parseFromSlice = serde.parseFromSlice;
pub const parseFromSliceLeaky = serde.parseFromSliceLeaky;
pub const parseFromElement = serde.parseFromElement;
pub const Parsed = serde.Parsed;
pub const ParseOptions = serde.ParseOptions;
pub const stringify = serde.stringify;
pub const stringifyAlloc = serde.stringifyAlloc;
pub const stringifyWriter = serde.stringifyWriter;
pub const StringifyOptions = serde.StringifyOptions;
pub const SerdeError = serde.SerdeError;

// Backward-compatibility alias
pub const simdjson = @This();

test {
    _ = @import("simdjson/stage1.zig");
    _ = @import("simdjson/stage2.zig");
    _ = @import("simdjson/tape.zig");
    _ = @import("simdjson/dom.zig");
    _ = @import("simdjson/utf8.zig");
    _ = @import("simdjson/common.zig");
    _ = @import("simdjson/error.zig");
    _ = @import("simdjson/ondemand.zig");
    _ = @import("simdjson/fast_float.zig");
    _ = @import("simdjson/stream.zig");
    _ = @import("simdjson/mut_dom.zig");
    _ = @import("simdjson/patch.zig");
    _ = @import("simdjson/jsonpath.zig");
    _ = @import("simdjson/serde.zig");
}




test "stage 1 parity test on twitter.json" {
    const raw_data = @embedFile("data/twitter.json");
    const allocator = std.testing.allocator;

    const padded_buf = try allocator.alloc(u8, raw_data.len + simdjson.SIMDJSON_PADDING);
    defer allocator.free(padded_buf);
    @memcpy(padded_buf[0..raw_data.len], raw_data);
    @memset(padded_buf[raw_data.len..], ' ');

    const indexes = try allocator.alloc(u32, raw_data.len + 3);
    defer allocator.free(indexes);

    const count = try Stage1Indexer.indexPadded(padded_buf, raw_data.len, indexes);

    // Exact count matching official simdjson C++: 55,263 structural indices
    try std.testing.expectEqual(@as(usize, 55263), count);

    // First and last indices check
    try std.testing.expectEqual(@as(u32, 0), indexes[0]); // '{'
    try std.testing.expectEqual(@as(u32, 4), indexes[1]); // '"'
    try std.testing.expectEqual(@as(u32, 14), indexes[2]); // ':'
    try std.testing.expectEqual(@as(u32, 16), indexes[3]); // '['
    try std.testing.expectEqual(@as(u32, 631513), indexes[count - 1]); // '}'

    // Verify sentinels
    try std.testing.expectEqual(@as(u32, @intCast(raw_data.len)), indexes[count]);
    try std.testing.expectEqual(@as(u32, @intCast(raw_data.len)), indexes[count + 1]);
    try std.testing.expectEqual(@as(u32, 0), indexes[count + 2]);
}

test "stage 1 parity test on citm_catalog.json" {
    const raw_data = @embedFile("data/citm_catalog.json");
    const allocator = std.testing.allocator;

    const padded_buf = try allocator.alloc(u8, raw_data.len + simdjson.SIMDJSON_PADDING);
    defer allocator.free(padded_buf);
    @memcpy(padded_buf[0..raw_data.len], raw_data);
    @memset(padded_buf[raw_data.len..], ' ');

    const indexes = try allocator.alloc(u32, raw_data.len + 3);
    defer allocator.free(indexes);

    const count = try Stage1Indexer.indexPadded(padded_buf, raw_data.len, indexes);

    // Exact count matching official simdjson C++: 135,990 structural indices
    try std.testing.expectEqual(@as(usize, 135990), count);

    // Verify sentinels
    try std.testing.expectEqual(@as(u32, @intCast(raw_data.len)), indexes[count]);
    try std.testing.expectEqual(@as(u32, @intCast(raw_data.len)), indexes[count + 1]);
    try std.testing.expectEqual(@as(u32, 0), indexes[count + 2]);
}

test "stage 1 + stage 2 end-to-end on twitter.json" {
    const raw_data = @embedFile("data/twitter.json");
    const allocator = std.testing.allocator;

    const padded_buf = try allocator.alloc(u8, raw_data.len + simdjson.SIMDJSON_PADDING);
    defer allocator.free(padded_buf);
    @memcpy(padded_buf[0..raw_data.len], raw_data);
    @memset(padded_buf[raw_data.len..], ' ');

    const indexes = try allocator.alloc(u32, raw_data.len + 3);
    defer allocator.free(indexes);

    // Stage 1: Index structurals
    const structurals = try Stage1Indexer.indexPadded(padded_buf, raw_data.len, indexes);
    try std.testing.expectEqual(@as(usize, 55263), structurals);

    // Stage 2: Parse tape (zero-copy, zero-alloc)
    const tape_buf = try allocator.alloc(u64, structurals * 2 + 4);
    defer allocator.free(tape_buf);

    const tape_len = try simdjson.Stage2Parser.parse(padded_buf, indexes, structurals, tape_buf);
    try std.testing.expect(tape_len > 0);

    // Query via zero-allocation DOM
    const doc = simdjson.Document.init(padded_buf, tape_buf[0..tape_len]);
    const root = doc.root();
    const root_obj = try root.asObject();

    const statuses_el = root_obj.get("statuses").?;
    const statuses_arr = try statuses_el.asArray();

    // First tweet
    const first_tweet = try (statuses_arr.at(0).?).asObject();
    const tweet_id = (first_tweet.get("id").?).asInt() catch null;
    try std.testing.expect(tweet_id != null);

    const text = try (first_tweet.get("text").?).asString();
    try std.testing.expect(text.len > 0);

    const user = try (first_tweet.get("user").?).asObject();
    const screen_name = try (user.get("screen_name").?).asString();
    try std.testing.expect(screen_name.len > 0);
}

test "NDJSON streaming with DocumentStream" {
    const ndjson =
        \\{"id": 1, "user": "alice", "active": true}
        \\{"id": 2, "user": "bob", "active": false}
        \\{"id": 3, "user": "charlie", "tags": [10, 20]}
    ;

    var indexes: [256]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, ndjson, &indexes);
    try std.testing.expect(count > 0);

    var tape_buf: [256]u64 = undefined;
    var doc_stream = simdjson.DocumentStream.init(ndjson, &indexes, count, &tape_buf);

    // Doc 1
    const doc1 = (try doc_stream.next()).?;
    const obj1 = try doc1.root().asObject();
    try std.testing.expectEqual(@as(i64, 1), try (obj1.get("id").?).asInt());
    try std.testing.expectEqualStrings("alice", try (obj1.get("user").?).asString());
    try std.testing.expectEqual(true, try (obj1.get("active").?).asBool());

    // Doc 2
    const doc2 = (try doc_stream.next()).?;
    const obj2 = try doc2.root().asObject();
    try std.testing.expectEqual(@as(i64, 2), try (obj2.get("id").?).asInt());
    try std.testing.expectEqualStrings("bob", try (obj2.get("user").?).asString());
    try std.testing.expectEqual(false, try (obj2.get("active").?).asBool());

    // Doc 3
    const doc3 = (try doc_stream.next()).?;
    const obj3 = try doc3.root().asObject();
    try std.testing.expectEqual(@as(i64, 3), try (obj3.get("id").?).asInt());
    try std.testing.expectEqualStrings("charlie", try (obj3.get("user").?).asString());
    const tags = try (obj3.get("tags").?).asArray();
    try std.testing.expectEqual(@as(i64, 10), try (tags.at(0).?).asInt());
    try std.testing.expectEqual(@as(i64, 20), try (tags.at(1).?).asInt());

    // End of stream
    try std.testing.expect((try doc_stream.next()) == null);
}

test "NDJSON streaming with OnDemandDocumentStream" {
    const ndjson =
        \\{"id": 100, "name": "service_a", "metrics": {"cpu": 45}}
        \\{"id": 101, "name": "service_b", "metrics": {"cpu": 82}}
        \\{"id": 102, "name": "service_c", "metrics": {"cpu": 12}}
    ;

    var indexes: [256]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, ndjson, &indexes);
    try std.testing.expect(count > 0);

    var od_stream = simdjson.OnDemandDocumentStream.init(ndjson, &indexes, count);

    var parsed_ids: [3]i64 = undefined;
    var i: usize = 0;

    while (try od_stream.next()) |doc_val| : (i += 1) {
        var obj = try doc_val.asObject();
        const id = try (try obj.get("id")).?.asInt();
        parsed_ids[i] = id;
        // next() automatically skips unparsed fields like "name" and "metrics"!
    }

    try std.testing.expectEqual(@as(usize, 3), i);
    try std.testing.expectEqual(@as(i64, 100), parsed_ids[0]);
    try std.testing.expectEqual(@as(i64, 101), parsed_ids[1]);
    try std.testing.expectEqual(@as(i64, 102), parsed_ids[2]);
}

test "Line and Column Error Diagnostics with Stage 2 syntax errors" {
    const invalid_json =
        \\{
        \\  "name": "simdjson",
        \\  "rating": 12.34.56,
        \\  "active": true
        \\}
    ;

    var indexes: [128]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, invalid_json, &indexes);

    var tape_buf: [256]u64 = undefined;
    var diag: simdjson.Diagnostic = undefined;
    const err = simdjson.Stage2Parser.parseWithDiagnostic(invalid_json, &indexes, count, &tape_buf, &diag);
    try std.testing.expectError(error.NumberError, err);

    try std.testing.expectEqual(@as(usize, 3), diag.line);
    try std.testing.expectEqual(@as(usize, 13), diag.column);
    try std.testing.expectEqualStrings("  \"rating\": 12.34.56,", diag.line_slice);
    try std.testing.expectEqual(error.NumberError, diag.err);

    var formatted_buf: [512]u8 = undefined;
    const output = diag.formatToString(&formatted_buf);
    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "JSON parse error: Problem while parsing a number (line 3, column 13, byte") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "3 |   \"rating\": 12.34.56,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "^") != null);
}

test "Line and Column Error Diagnostics with trailing comma" {
    const invalid_json =
        \\{
        \\  "items": [
        \\    10,
        \\    20,
        \\  ]
        \\}
    ;

    var indexes: [128]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, invalid_json, &indexes);

    var tape_buf: [256]u64 = undefined;
    var diag: simdjson.Diagnostic = undefined;
    const err = simdjson.Stage2Parser.parseWithDiagnostic(invalid_json, &indexes, count, &tape_buf, &diag);
    try std.testing.expectError(error.TrailingComma, err);

    try std.testing.expectEqual(@as(usize, 5), diag.line);
    try std.testing.expectEqual(@as(usize, 3), diag.column);
    try std.testing.expectEqual(error.TrailingComma, diag.err);
}

test "Line and Column Error Diagnostics with Stage 1 unclosed string" {
    const invalid_json =
        \\{
        \\  "title": "unclosed string literal
        \\}
    ;

    const padded = try std.testing.allocator.alloc(u8, invalid_json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..invalid_json.len], invalid_json);
    @memset(padded[invalid_json.len..], ' ');

    var indexes: [128]u32 = undefined;
    var diag: simdjson.Diagnostic = undefined;
    const err = Stage1Indexer.indexPaddedWithDiagnostic(padded, invalid_json.len, &indexes, &diag);
    try std.testing.expectError(error.UnclosedString, err);

    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expectEqual(@as(usize, 12), diag.column);
    try std.testing.expectEqual(error.UnclosedString, diag.err);
}

test "Line and Column Error Diagnostics with OnDemand parser" {
    const json =
        \\{
        \\  "user": "alice",
        \\  "age": "twenty"
        \\}
    ;

    var indexes: [128]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    var doc = simdjson.OnDemandDocument.init(json, &indexes, count);
    var root = try doc.root().asObject();

    _ = try (try root.get("user")).?.asString();

    const age_val = (try root.get("age")).?;
    // Trying to parse a string as an integer fails with error.IncorrectType
    const age_err = age_val.asInt();
    try std.testing.expectError(error.IncorrectType, age_err);

    const diag = age_val.getDiagnostic(error.IncorrectType);
    try std.testing.expectEqual(@as(usize, 3), diag.line);
    try std.testing.expectEqual(@as(usize, 10), diag.column);
    try std.testing.expectEqual(error.IncorrectType, diag.err);
}

test "Lemire fast_float in Stage 2 DOM tape parser" {
    const json =
        \\{
        \\  "pi": 3.141592653589793,
        \\  "e": 2.718281828459045,
        \\  "avogadro": 6.02214076e23,
        \\  "planck": 6.62607015e-34,
        \\  "max_double": 1.7976931348623157e308,
        \\  "min_subnormal": 4.9406564584124654e-324,
        \\  "negative_val": -123.456e-7,
        \\  "zero": 0.0
        \\}
    ;

    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var indexes: [512]u32 = undefined;
    const structurals = try Stage1Indexer.indexPadded(padded, json.len, &indexes);

    var tape_buf: [512]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &indexes, structurals, &tape_buf);

    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);
    const obj = try doc.root().asObject();

    try std.testing.expectEqual(@as(f64, 3.141592653589793), try obj.get("pi").?.asDouble());
    try std.testing.expectEqual(@as(f64, 2.718281828459045), try obj.get("e").?.asDouble());
    try std.testing.expectEqual(@as(f64, 6.02214076e23), try obj.get("avogadro").?.asDouble());
    try std.testing.expectEqual(@as(f64, 6.62607015e-34), try obj.get("planck").?.asDouble());
    try std.testing.expectEqual(@as(f64, 1.7976931348623157e308), try obj.get("max_double").?.asDouble());
    try std.testing.expectEqual(@as(f64, 4.9406564584124654e-324), try obj.get("min_subnormal").?.asDouble());
    try std.testing.expectEqual(@as(f64, -123.456e-7), try obj.get("negative_val").?.asDouble());
    try std.testing.expectEqual(@as(f64, 0.0), try obj.get("zero").?.asDouble());
}

test "Lemire fast_float in OnDemand Value.asDouble and Value.asFloat" {
    const json =
        \\{
        \\  "price": 19.99,
        \\  "rating": 4.5,
        \\  "scientific": 1.23456e10,
        \\  "temperature": -40.0
        \\}
    ;

    var indexes: [128]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    var doc = simdjson.OnDemandDocument.init(json, &indexes, count);
    var root = try doc.root().asObject();

    const price = try (try root.get("price")).?.asDouble();
    try std.testing.expectEqual(@as(f64, 19.99), price);

    const rating = try (try root.get("rating")).?.asFloat();
    try std.testing.expectEqual(@as(f32, 4.5), rating);

    const scientific = try (try root.get("scientific")).?.asDouble();
    try std.testing.expectEqual(@as(f64, 1.23456e10), scientific);

    const temp = try (try root.get("temperature")).?.asDouble();
    try std.testing.expectEqual(@as(f64, -40.0), temp);
}

test "OnDemand string unescaping: standard, unicode, and surrogate pair emojis" {
    const json =
        \\{
        \\  "plain": "hello world",
        \\  "escapes": "line1\nline2\ttab\"quote\\slash\/bell\bform\ffeed\rcarriage",
        \\  "unicode": "\u0048\u0065\u006c\u006c\u006f \u0057\u006f\u0072\u006c\u0064",
        \\  "emoji_smile": "\uD83D\uDE00",
        \\  "emoji_rocket": "Blastoff! \uD83D\uDE80",
        \\  "cjk": "\u4E16\u754C"
        \\}
    ;

    var indexes: [512]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    var doc = simdjson.OnDemandDocument.init(json, &indexes, count);
    var root = try doc.root().asObject();

    var unescape_buf: [256]u8 = undefined;

    // 1. Plain string (no escapes)
    {
        var val = (try root.get("plain")).?;
        try std.testing.expectEqual(false, try val.hasEscapes());
        const plain_res = try val.writeUnescaped(&unescape_buf);
        try std.testing.expectEqualStrings("hello world", plain_res);
    }

    // 2. Standard escapes via writeUnescaped
    {
        var val = (try root.get("escapes")).?;
        try std.testing.expectEqual(true, try val.hasEscapes());
        const esc_res = try val.writeUnescaped(&unescape_buf);
        const expected = "line1\nline2\ttab\"quote\\slash/bell\x08form\x0Cfeed\rcarriage";
        try std.testing.expectEqualStrings(expected, esc_res);
    }

    // 3. Unicode ASCII escapes via asUnescapedAlloc
    {
        var val = (try root.get("unicode")).?;
        try std.testing.expectEqual(true, try val.hasEscapes());
        const allocated = try val.asUnescapedAlloc(std.testing.allocator);
        defer std.testing.allocator.free(allocated);
        try std.testing.expectEqualStrings("Hello World", allocated);
    }

    // 4. UTF-16 Surrogate pair emoji (\uD83D\uDE00 -> 😀)
    {
        var val = (try root.get("emoji_smile")).?;
        try std.testing.expectEqual(true, try val.hasEscapes());
        const emoji_res = try val.writeUnescaped(&unescape_buf);
        try std.testing.expectEqualStrings("😀", emoji_res);
    }

    // 5. Mixed text with surrogate pair emoji via asUnescapedAlloc
    {
        var val = (try root.get("emoji_rocket")).?;
        const allocated = try val.asUnescapedAlloc(std.testing.allocator);
        defer std.testing.allocator.free(allocated);
        try std.testing.expectEqualStrings("Blastoff! 🚀", allocated);
    }

    // 6. CJK 3-byte UTF-8 character (\u4E16\u754C -> 世界)
    {
        var val = (try root.get("cjk")).?;
        const cjk_res = try val.writeUnescaped(&unescape_buf);
        try std.testing.expectEqualStrings("世界", cjk_res);
    }
}

test "OnDemand Field key unescaping" {
    const json =
        \\{
        \\  "plain_key": 1,
        \\  "escaped\nkey": 2,
        \\  "\u0075\u0073\u0065\u0072": 3,
        \\  "\uD83D\uDD25_fire": 4
        \\}
    ;

    var indexes: [512]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    var doc = simdjson.OnDemandDocument.init(json, &indexes, count);
    var root = try doc.root().asObject();

    var key_buf: [128]u8 = undefined;

    // Field 1: plain
    const f1 = (try root.next()).?;
    try std.testing.expectEqual(false, f1.hasEscapedKey());
    try std.testing.expectEqualStrings("plain_key", f1.key);
    _ = try f1.value.asInt();

    // Field 2: escaped \n
    const f2 = (try root.next()).?;
    try std.testing.expectEqual(true, f2.hasEscapedKey());
    const unesc_key2 = try f2.writeUnescapedKey(&key_buf);
    try std.testing.expectEqualStrings("escaped\nkey", unesc_key2);
    _ = try f2.value.asInt();

    // Field 3: unicode key
    const f3 = (try root.next()).?;
    try std.testing.expectEqual(true, f3.hasEscapedKey());
    const alloc_key3 = try f3.keyUnescapedAlloc(std.testing.allocator);
    defer std.testing.allocator.free(alloc_key3);
    try std.testing.expectEqualStrings("user", alloc_key3);
    _ = try f3.value.asInt();

    // Field 4: surrogate emoji key (\uD83D\uDD25 -> 🔥)
    const f4 = (try root.next()).?;
    const unesc_key4 = try f4.writeUnescapedKey(&key_buf);
    try std.testing.expectEqualStrings("🔥_fire", unesc_key4);
    _ = try f4.value.asInt();
}

test "DOM Element unescaping parity for surrogate pairs and escapes" {
    const json =
        \\{
        \\  "greeting": "Hello \uD83D\uDC4B \uD83C\uDF0D!\nNew line."
        \\}
    ;

    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var indexes: [128]u32 = undefined;
    const structurals = try Stage1Indexer.indexPadded(padded, json.len, &indexes);

    var tape_buf: [128]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &indexes, structurals, &tape_buf);

    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);
    const obj = try doc.root().asObject();
    const el = obj.get("greeting").?;

    try std.testing.expectEqual(true, try el.hasEscapes());

    var dest_buf: [128]u8 = undefined;
    const unesc = try el.writeUnescaped(&dest_buf);
    try std.testing.expectEqualStrings("Hello 👋 🌍!\nNew line.", unesc);

    const alloc_unesc = try el.asUnescapedAlloc(std.testing.allocator);
    defer std.testing.allocator.free(alloc_unesc);
}

test "SIMD Vectorized String Unescaping Kernel: vpshufb shuffle and multi-tier escapes" {
    var buf: [512]u8 = undefined;

    // 1. Single 16-byte block with single \" escape (exercises single_bs_table)
    {
        const input = "12345\\\"789012345";
        const res = try simdjson.unescapeString(input, &buf);
        try std.testing.expectEqualStrings("12345\"789012345", res);
    }

    // 2. Single 16-byte block with single \\ escape (exercises single_bs_table)
    {
        const input = "abcdef\\\\ghijklmn";
        const res = try simdjson.unescapeString(input, &buf);
        try std.testing.expectEqualStrings("abcdef\\ghijklmn", res);
    }

    // 3. Single 16-byte block with two \" escapes (exercises double_bs_table)
    {
        const input = "ab\\\"cdef\\\"ghijkl";
        const res = try simdjson.unescapeString(input, &buf);
        try std.testing.expectEqualStrings("ab\"cdef\"ghijkl", res);
    }

    // 4. Multi-chunk (64+ bytes) with 32-byte plain scan + 16-byte vpshufb compression
    {
        const input =
            "This is a thirty-two byte string" ++
            "hello \\\"world!\\\" ok" ++
            "plain padding!!" ++
            "and \\\\ more \\\"stuff";
        const res = try simdjson.unescapeString(input, &buf);
        const expected = "This is a thirty-two byte stringhello \"world!\" okplain padding!!and \\ more \"stuff";
        try std.testing.expectEqualStrings(expected, res);
    }

    // 5. Complex interleaved escapes: SIMD drop-backslash + scalar control characters + Unicode
    {
        const input = "path: \\\"C:\\\\Program Files\\\\App\\\"\\nstatus: \\u004F\\u004B\\t\\uD83D\\uDE80";
        const res = try simdjson.unescapeString(input, &buf);
        const expected = "path: \"C:\\Program Files\\App\"\nstatus: OK\t🚀";
        try std.testing.expectEqualStrings(expected, res);
    }
}

test "DOM Tree Serializer: writeJson and stringifyAlloc on primitives, arrays, and objects" {
    const json =
        \\{
        \\  "name": "simdjson-zig",
        \\  "version": 2,
        \\  "active": true,
        \\  "owner": null,
        \\  "ratio": 1.25,
        \\  "tags": ["fast", "zero-alloc", 42]
        \\}
    ;

    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var indexes: [256]u32 = undefined;
    const structurals = try Stage1Indexer.indexPadded(padded, json.len, &indexes);

    var tape_buf: [256]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &indexes, structurals, &tape_buf);

    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);
    const root_el = doc.root();

    // 1. Test writeJson into a fixed buffer writer
    var out_buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    try root_el.writeJson(&writer);

    const expected_minified = "{\"name\":\"simdjson-zig\",\"version\":2,\"active\":true,\"owner\":null,\"ratio\":1.25,\"tags\":[\"fast\",\"zero-alloc\",42]}";
    try std.testing.expectEqualStrings(expected_minified, out_buf[0..writer.end]);

    // 2. Test stringifyAlloc
    const allocated_json = try root_el.stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(allocated_json);
    try std.testing.expectEqualStrings(expected_minified, allocated_json);

    // 3. Test document-level stringifyAlloc
    const doc_json = try doc.stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(doc_json);
    try std.testing.expectEqualStrings(expected_minified, doc_json);
}

test "DOM Tree Serializer: sub-element serialization" {
    const json =
        \\{
        \\  "user": {
        \\    "id": 101,
        \\    "roles": ["admin", "developer"]
        \\  }
        \\}
    ;

    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var indexes: [128]u32 = undefined;
    const structurals = try Stage1Indexer.indexPadded(padded, json.len, &indexes);

    var tape_buf: [128]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &indexes, structurals, &tape_buf);

    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);
    const obj = try doc.root().asObject();

    // Sub-object serialization
    const user_el = obj.get("user").?;
    const user_json = try user_el.stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(user_json);
    try std.testing.expectEqualStrings("{\"id\":101,\"roles\":[\"admin\",\"developer\"]}", user_json);

    // Sub-array serialization
    const user_obj = try user_el.asObject();
    const roles_el = user_obj.get("roles").?;
    const roles_json = try roles_el.stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(roles_json);
    try std.testing.expectEqualStrings("[\"admin\",\"developer\"]", roles_json);

    // Primitive element serialization
    const id_el = user_obj.get("id").?;
    const id_json = try id_el.stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(id_json);
    try std.testing.expectEqualStrings("101", id_json);
}

test "DOM Tree Serializer: formatJson and formatAlloc pretty printing" {
    const json = "{\"a\":1,\"b\":[true,false],\"c\":{}}";

    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var indexes: [128]u32 = undefined;
    const structurals = try Stage1Indexer.indexPadded(padded, json.len, &indexes);

    var tape_buf: [128]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &indexes, structurals, &tape_buf);

    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);

    const formatted = try doc.formatAlloc(std.testing.allocator, .{ .indent = 2 });
    defer std.testing.allocator.free(formatted);

    const expected_formatted =
        \\{
        \\  "a": 1,
        \\  "b": [
        \\    true,
        \\    false
        \\  ],
        \\  "c": {}
        \\}
    ;

    try std.testing.expectEqualStrings(expected_formatted, formatted);
}

test "JSON Pointer (RFC 6901) DOM Document and Element navigation" {
    // Canonical RFC 6901 Section 5 example
    const json =
        \\{
        \\  "foo": ["bar", "baz"],
        \\  "": 0,
        \\  "a/b": 1,
        \\  "c%d": 2,
        \\  "e^f": 3,
        \\  "g|h": 4,
        \\  "i\\j": 5,
        \\  "k\"l": 6,
        \\  " ": 7,
        \\  "m~n": 8,
        \\  "statuses": [
        \\    {
        \\      "user": {
        \\        "id": 998877
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var indexes: [256]u32 = undefined;
    const structurals = try Stage1Indexer.indexPadded(padded, json.len, &indexes);

    var tape_buf: [256]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &indexes, structurals, &tape_buf);

    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);

    // 1. Root pointer ""
    const root_el = try doc.atPointer("");
    try std.testing.expectEqual(simdjson.dom.Type.object, root_el.getType());

    // 2. "/foo" -> ["bar", "baz"]
    const foo_el = try doc.atPointer("/foo");
    try std.testing.expectEqual(simdjson.dom.Type.array, foo_el.getType());

    // 3. "/foo/0" -> "bar"
    const foo0 = try doc.atPointer("/foo/0");
    try std.testing.expectEqualStrings("bar", try foo0.asString());

    // 4. "/foo/1" -> "baz"
    const foo1 = try doc.atPointer("/foo/1");
    try std.testing.expectEqualStrings("baz", try foo1.asString());

    // 5. "/" -> 0 (empty string key)
    const empty_key = try doc.atPointer("/");
    try std.testing.expectEqual(@as(i64, 0), try empty_key.asInt());

    // 6. "/a~1b" -> 1 (unescaping ~1 to /)
    const slash_key = try doc.atPointer("/a~1b");
    try std.testing.expectEqual(@as(i64, 1), try slash_key.asInt());

    // 7. "/c%d" -> 2
    const pct_key = try doc.atPointer("/c%d");
    try std.testing.expectEqual(@as(i64, 2), try pct_key.asInt());

    // 8. "/e^f" -> 3
    const caret_key = try doc.atPointer("/e^f");
    try std.testing.expectEqual(@as(i64, 3), try caret_key.asInt());

    // 9. "/g|h" -> 4
    const pipe_key = try doc.atPointer("/g|h");
    try std.testing.expectEqual(@as(i64, 4), try pipe_key.asInt());

    // 10. "/ " -> 7
    const space_key = try doc.atPointer("/ ");
    try std.testing.expectEqual(@as(i64, 7), try space_key.asInt());

    // 11. "/m~0n" -> 8 (unescaping ~0 to ~)
    const tilde_key = try doc.atPointer("/m~0n");
    try std.testing.expectEqual(@as(i64, 8), try tilde_key.asInt());

    // 12. Deep path navigation: "/statuses/0/user/id" -> 998877
    const user_id = try doc.atPointer("/statuses/0/user/id");
    try std.testing.expectEqual(@as(i64, 998877), try user_id.asInt());

    // 13. Sub-element navigation
    const status_obj = try doc.atPointer("/statuses/0");
    const sub_user_id = try status_obj.atPointer("/user/id");
    try std.testing.expectEqual(@as(i64, 998877), try sub_user_id.asInt());

    // 14. Errors: missing field, out of bounds, invalid pointer
    try std.testing.expectError(error.NoSuchField, doc.atPointer("/nonexistent"));
    try std.testing.expectError(error.IndexOutOfBounds, doc.atPointer("/foo/99"));
    try std.testing.expectError(error.IndexOutOfBounds, doc.atPointer("/foo/-1"));
    try std.testing.expectError(error.IndexOutOfBounds, doc.atPointer("/foo/01")); // leading zero
    try std.testing.expectError(error.InvalidJsonPointer, doc.atPointer("no_leading_slash"));
    try std.testing.expectError(error.InvalidJsonPointer, doc.atPointer("/m~2n")); // invalid escape
    try std.testing.expectError(error.IncorrectType, doc.atPointer("/statuses/0/user/id/cannot_subindex_scalar"));
}

test "JSON Pointer (RFC 6901) OnDemand Document and Value navigation" {
    const json =
        \\{
        \\  "app": "simdjson",
        \\  "a/b": 42,
        \\  "m~n": 84,
        \\  "statuses": [
        \\    {
        \\      "unrequested_blob": { "skip_fast": [1, 2, 3] },
        \\      "user": {
        \\        "name": "alice",
        \\        "id": 123456
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var indexes: [512]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(std.testing.allocator, json, &indexes);

    // 1. Direct path navigation on OnDemandDocument
    {
        var doc = simdjson.OnDemandDocument.init(json, &indexes, count);
        const id_val = try doc.atPointer("/statuses/0/user/id");
        try std.testing.expectEqual(@as(i64, 123456), try id_val.asInt());
    }

    // 2. Direct path navigation with ~1 (/) and ~0 (~) escapes
    {
        var doc = simdjson.OnDemandDocument.init(json, &indexes, count);
        const slash_val = try doc.atPointer("/a~1b");
        try std.testing.expectEqual(@as(i64, 42), try slash_val.asInt());
    }

    {
        var doc = simdjson.OnDemandDocument.init(json, &indexes, count);
        const tilde_val = try doc.atPointer("/m~0n");
        try std.testing.expectEqual(@as(i64, 84), try tilde_val.asInt());
    }

    // 3. String value extraction via pointer
    {
        var doc = simdjson.OnDemandDocument.init(json, &indexes, count);
        const name_val = try doc.atPointer("/statuses/0/user/name");
        try std.testing.expectEqualStrings("alice", try name_val.asString());
    }

    // 4. Sub-value navigation on Value
    {
        var doc = simdjson.OnDemandDocument.init(json, &indexes, count);
        var user_val = try doc.atPointer("/statuses/0/user");
        const id_val = try user_val.atPointer("/id");
        try std.testing.expectEqual(@as(i64, 123456), try id_val.asInt());
    }

    // 5. Errors: missing field, out of bounds, invalid pointer
    {
        var doc = simdjson.OnDemandDocument.init(json, &indexes, count);
        try std.testing.expectError(error.NoSuchField, doc.atPointer("/nonexistent"));
    }
    {
        var doc = simdjson.OnDemandDocument.init(json, &indexes, count);
        try std.testing.expectError(error.IndexOutOfBounds, doc.atPointer("/statuses/5"));
    }
    {
        var doc = simdjson.OnDemandDocument.init(json, &indexes, count);
        try std.testing.expectError(error.InvalidJsonPointer, doc.atPointer("invalid_pointer"));
    }
}

test "ChunkedDocumentStream: tiny sliding window sliding across document and chunk boundaries" {
    // Multi-document stream with 5 JSON objects separated by newlines
    const ndjson =
        \\{"id": 101, "name": "alpha", "active": true}
        \\{"id": 102, "name": "beta", "active": false}
        \\{"id": 103, "name": "gamma", "active": true, "values": [10, 20, 30]}
        \\{"id": 104, "name": "delta", "active": false}
        \\{"id": 105, "name": "epsilon", "active": true}
    ;

    var reader = std.Io.Reader.fixed(ndjson);

    // Use a 96-byte window. Since objects are 40-70 bytes long,
    // 5 objects (250+ bytes) force multiple sliding-window refills across boundaries!
    var chunk_stream1 = try simdjson.chunkedDocumentStream(
        std.testing.allocator,
        &reader,
        .{ .window_capacity = 96 },
    );
    defer chunk_stream1.deinit();

    var count: usize = 0;
    const expected_ids = [_]i64{ 101, 102, 103, 104, 105 };

    while (try chunk_stream1.next()) |doc| {
        const root_obj = try doc.root().asObject();
        const id_el = root_obj.get("id").?;
        try std.testing.expectEqual(expected_ids[count], try id_el.asInt());
        count += 1;
    }

    try std.testing.expectEqual(5, count);
}

test "ChunkedDocumentStream: fixed buffer mode with zero heap allocations" {
    const ndjson =
        \\{"metric": "cpu", "value": 85.5}
        \\{"metric": "mem", "value": 42.0}
        \\{"metric": "disk", "value": 12.3}
    ;

    var reader = std.Io.Reader.fixed(ndjson);

    // Fixed stack buffers: zero heap allocations
    var window_buf: [128 + simdjson.SIMDJSON_PADDING]u8 = undefined;
    var indexes_buf: [128 + 3]u32 = undefined;
    var tape_buf: [128 + 16]u64 = undefined;

    var chunk_stream2 = try simdjson.fixedChunkedDocumentStream(
        &reader,
        &window_buf,
        &indexes_buf,
        &tape_buf,
    );
    defer chunk_stream2.deinit();

    var count: usize = 0;
    while (try chunk_stream2.next()) |doc| {
        const root_obj = try doc.root().asObject();
        _ = root_obj.get("metric").?;
        count += 1;
    }

    try std.testing.expectEqual(3, count);
}

test "ChunkedDocumentStream: global line and column diagnostics across chunk boundaries" {
    const ndjson =
        \\{"id": 1}
        \\{"id": 2}
        \\{"id": 3}
        \\{"id": 4}
        \\{"id": 5, "broken": [invalid}
    ;

    var reader = std.Io.Reader.fixed(ndjson);

    // 48-byte window to force several slide cycles before hitting line 5
    var chunk_stream3 = try simdjson.chunkedDocumentStream(
        std.testing.allocator,
        &reader,
        .{ .window_capacity = 48 },
    );
    defer chunk_stream3.deinit();

    // First 4 documents parse cleanly
    try std.testing.expect((try chunk_stream3.next()) != null);
    try std.testing.expect((try chunk_stream3.next()) != null);
    try std.testing.expect((try chunk_stream3.next()) != null);
    try std.testing.expect((try chunk_stream3.next()) != null);

    // Fifth document fails with syntax error
    const err = chunk_stream3.next();
    try std.testing.expectError(error.TapeError, err);

    // Global diagnostic accurately reports Line 5!
    const diag = chunk_stream3.getDiagnostic(error.TapeError);
    try std.testing.expectEqual(5, diag.line);
}

test "ChunkedDocumentStream: auto-grow on large documents exceeding initial window" {
    const ndjson =
        \\{"small": 1}
        \\{"large": "This is a longer payload that exceeds the initial 32 byte window capacity easily"}
        \\{"small": 2}
    ;

    var reader = std.Io.Reader.fixed(ndjson);

    // Start with a 32-byte window but enable auto_grow
    var chunk_stream4 = try simdjson.chunkedDocumentStream(
        std.testing.allocator,
        &reader,
        .{ .window_capacity = 32, .auto_grow = true, .max_capacity = 1024 },
    );
    defer chunk_stream4.deinit();

    // Document 1
    const doc1 = (try chunk_stream4.next()).?;
    try std.testing.expectEqual(@as(i64, 1), try (try doc1.root().asObject()).get("small").?.asInt());

    // Document 2 triggers auto-grow
    const doc2 = (try chunk_stream4.next()).?;
    try std.testing.expect((try doc2.root().asObject()).get("large") != null);

    // Document 3
    const doc3 = (try chunk_stream4.next()).?;
    try std.testing.expectEqual(@as(i64, 2), try (try doc3.root().asObject()).get("small").?.asInt());

    try std.testing.expectEqual(null, try chunk_stream4.next());
}

test "DOM Tree Mutator: construct from scratch and mutate (set, append, remove)" {
    var doc = try simdjson.MutDocument.init(std.testing.allocator);
    defer doc.deinit();

    const root = doc.root();

    // 1. Primitive fields
    try root.set("project", "simdjson-zig");
    try root.set("version", 2);
    try root.set("ratio", 3.14);
    try root.set("active", true);
    try root.set("deleted_flag", false);
    try root.set("extra", null);

    try std.testing.expectEqualStrings("simdjson-zig", try root.get("project").?.asString());
    try std.testing.expectEqual(@as(i64, 2), try root.get("version").?.asInt());
    try std.testing.expectEqual(@as(f64, 3.14), try root.get("ratio").?.asDouble());
    try std.testing.expectEqual(true, try root.get("active").?.asBool());
    try std.testing.expectEqual(true, root.get("extra").?.isNull());

    // 2. Overwriting existing field
    try root.set("version", 3);
    try std.testing.expectEqual(@as(i64, 3), try root.get("version").?.asInt());

    // 3. Removing field
    try std.testing.expectEqual(true, root.remove("deleted_flag"));
    try std.testing.expectEqual(false, root.remove("deleted_flag")); // Already gone
    try std.testing.expectEqual(false, root.has("deleted_flag"));

    // 4. Array field and mutations
    try root.set("tags", simdjson.MutArray{});
    var tags = root.get("tags").?;
    try tags.append("fast");
    try tags.append("zero-copy");
    try tags.append("simd");
    try std.testing.expectEqual(@as(usize, 3), tags.len());

    // Insert and removeAt
    try tags.insert(1, "vectorized");
    try std.testing.expectEqual(@as(usize, 4), tags.len());
    try std.testing.expectEqualStrings("vectorized", try tags.at(1).?.asString());

    try std.testing.expectEqual(true, tags.removeAt(1));
    try std.testing.expectEqual(@as(usize, 3), tags.len());
    try std.testing.expectEqualStrings("zero-copy", try tags.at(1).?.asString());

    // 5. Round-trip serialization
    const json_out = try doc.stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json_out);

    try std.testing.expect(std.mem.indexOf(u8, json_out, "\"project\":\"simdjson-zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_out, "\"version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_out, "[\"fast\",\"zero-copy\",\"simd\"]") != null);
}

test "DOM Tree Mutator: convert from immutable tape DOM and mutate in-memory" {
    const json =
        \\{
        \\  "name": "original",
        \\  "status": "pending",
        \\  "count": 10,
        \\  "list": [1, 2, 3]
        \\}
    ;

    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var indexes: [128]u32 = undefined;
    const structurals = try Stage1Indexer.indexPadded(padded, json.len, &indexes);

    var tape_buf: [128]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &indexes, structurals, &tape_buf);

    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);

    // Convert immutable DOM to Mutable DOM
    var mut_doc = try doc.toMutable(std.testing.allocator);
    defer mut_doc.deinit();

    const root = mut_doc.root();

    // Verify initial values
    try std.testing.expectEqualStrings("original", try root.get("name").?.asString());
    try std.testing.expectEqual(@as(i64, 10), try root.get("count").?.asInt());

    // Mutate existing fields
    try root.set("name", "updated");
    try root.set("status", "completed");
    try root.set("count", 99);

    // Remove field
    try std.testing.expect(root.remove("status"));

    // Append to existing array
    var list = root.get("list").?;
    try list.append(4);
    try list.append(5);
    try std.testing.expectEqual(@as(usize, 5), list.len());

    // Serialize back and re-parse with Stage 1 + Stage 2 to verify 100% valid JSON
    const modified_json = try mut_doc.stringifyAlloc(std.testing.allocator);
    defer std.testing.allocator.free(modified_json);

    const mod_padded = try std.testing.allocator.alloc(u8, modified_json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(mod_padded);
    @memcpy(mod_padded[0..modified_json.len], modified_json);
    @memset(mod_padded[modified_json.len..], ' ');

    var mod_indexes: [128]u32 = undefined;
    const mod_structs = try Stage1Indexer.indexPadded(mod_padded, modified_json.len, &mod_indexes);

    var mod_tape: [128]u64 = undefined;
    const mod_tape_len = try simdjson.Stage2Parser.parse(mod_padded, &mod_indexes, mod_structs, &mod_tape);

    const re_doc = simdjson.Document.init(mod_padded, mod_tape[0..mod_tape_len]);
    const re_root = try re_doc.root().asObject();

    try std.testing.expectEqualStrings("updated", try re_root.get("name").?.asString());
    try std.testing.expectEqual(@as(i64, 99), try re_root.get("count").?.asInt());
    try std.testing.expectEqual(null, re_root.get("status"));
    const re_list = try re_root.get("list").?.asArray();
    try std.testing.expectEqual(@as(usize, 5), re_list.len());
    try std.testing.expectEqual(@as(i64, 1), try re_list.at(0).?.asInt());
    try std.testing.expectEqual(@as(i64, 5), try re_list.at(4).?.asInt());
}

test "DOM Tree Mutator: RFC 6901 pointer mutation (atPointer, setPointer, removePointer)" {
    var doc = try simdjson.MutDocument.init(std.testing.allocator);
    defer doc.deinit();

    const root = doc.root();
    try root.set("user", simdjson.MutObject{});
    try root.set("scores", simdjson.MutArray{});

    // 1. setPointer into nested object
    try doc.setPointer("/user/name", "Alice");
    try doc.setPointer("/user/level", 42);

    const name_el = try doc.atPointer("/user/name");
    try std.testing.expectEqualStrings("Alice", try name_el.asString());

    const level_el = try doc.atPointer("/user/level");
    try std.testing.expectEqual(@as(i64, 42), try level_el.asInt());

    // 2. setPointer appending to array with "-"
    try doc.setPointer("/scores/-", 100);
    try doc.setPointer("/scores/-", 200);
    try doc.setPointer("/scores/-", 300);

    const s0 = try doc.atPointer("/scores/0");
    try std.testing.expectEqual(@as(i64, 100), try s0.asInt());
    const s2 = try doc.atPointer("/scores/2");
    try std.testing.expectEqual(@as(i64, 300), try s2.asInt());

    // 3. setPointer overwriting an array index
    try doc.setPointer("/scores/1", 250);
    const s1 = try doc.atPointer("/scores/1");
    try std.testing.expectEqual(@as(i64, 250), try s1.asInt());

    // 4. removePointer on object and array
    try std.testing.expectEqual(true, try doc.removePointer("/user/level"));
    try std.testing.expectError(error.NoSuchField, doc.atPointer("/user/level"));

    try std.testing.expectEqual(true, try doc.removePointer("/scores/0"));
    const new_s0 = try doc.atPointer("/scores/0");
    try std.testing.expectEqual(@as(i64, 250), try new_s0.asInt()); // 250 shifted to index 0
}

test "JSON Patch (RFC 6902): all operations (add, remove, replace, move, copy, test)" {
    var doc = try simdjson.MutDocument.init(std.testing.allocator);
    defer doc.deinit();

    // Initial doc: {"foo": "bar", "numbers": [1, 2, 3]}
    try doc.root().set("foo", "bar");
    try doc.root().set("numbers", simdjson.MutArray{});
    var nums = doc.root().get("numbers").?;
    try nums.append(1);
    try nums.append(2);
    try nums.append(3);

    // 1. "add" member to object, append to array, and insert into array
    const patch1 =
        \\[
        \\  { "op": "add", "path": "/baz", "value": "qux" },
        \\  { "op": "add", "path": "/numbers/-", "value": 4 },
        \\  { "op": "add", "path": "/numbers/1", "value": 99 }
        \\]
    ;
    try doc.applyPatch(patch1);

    try std.testing.expectEqualStrings("qux", try (try doc.atPointer("/baz")).asString());
    // numbers was [1, 2, 3] -> after add 99 at 1 -> [1, 99, 2, 3] -> after add 4 at - -> [1, 99, 2, 3, 4]
    try std.testing.expectEqual(@as(i64, 99), try (try doc.atPointer("/numbers/1")).asInt());
    try std.testing.expectEqual(@as(i64, 2), try (try doc.atPointer("/numbers/2")).asInt());
    try std.testing.expectEqual(@as(i64, 4), try (try doc.atPointer("/numbers/4")).asInt());

    // 2. "test" success
    const patch2 =
        \\[
        \\  { "op": "test", "path": "/baz", "value": "qux" },
        \\  { "op": "test", "path": "/numbers/0", "value": 1 }
        \\]
    ;
    try doc.applyPatch(patch2);

    // 3. "replace" object member and array element
    const patch3 =
        \\[
        \\  { "op": "replace", "path": "/baz", "value": "updated_baz" },
        \\  { "op": "replace", "path": "/numbers/0", "value": 100 }
        \\]
    ;
    try doc.applyPatch(patch3);
    try std.testing.expectEqualStrings("updated_baz", try (try doc.atPointer("/baz")).asString());
    try std.testing.expectEqual(@as(i64, 100), try (try doc.atPointer("/numbers/0")).asInt());

    // 4. "copy" property to new location
    const patch4 =
        \\[
        \\  { "op": "copy", "from": "/baz", "path": "/baz_copy" }
        \\]
    ;
    try doc.applyPatch(patch4);
    try std.testing.expectEqualStrings("updated_baz", try (try doc.atPointer("/baz_copy")).asString());

    // 5. "move" property to new location
    const patch5 =
        \\[
        \\  { "op": "move", "from": "/baz_copy", "path": "/baz_moved" }
        \\]
    ;
    try doc.applyPatch(patch5);
    try std.testing.expectEqualStrings("updated_baz", try (try doc.atPointer("/baz_moved")).asString());
    try std.testing.expectError(error.NoSuchField, doc.atPointer("/baz_copy"));

    // 6. "remove" property and array element
    const patch6 =
        \\[
        \\  { "op": "remove", "path": "/baz_moved" },
        \\  { "op": "remove", "path": "/numbers/1" }
        \\]
    ;
    try doc.applyPatch(patch6);
    try std.testing.expectError(error.NoSuchField, doc.atPointer("/baz_moved"));
    // 99 removed from index 1, so index 1 is now 2
    try std.testing.expectEqual(@as(i64, 2), try (try doc.atPointer("/numbers/1")).asInt());
}

test "JSON Patch (RFC 6902): atomicity rollback on test failure" {
    var doc = try simdjson.MutDocument.init(std.testing.allocator);
    defer doc.deinit();

    try doc.root().set("title", "simdjson");
    try doc.root().set("version", 1);

    // Multi-operation patch where the 3rd operation fails "test"
    const patch_fail =
        \\[
        \\  { "op": "add", "path": "/staged_field", "value": "should_be_reverted" },
        \\  { "op": "replace", "path": "/version", "value": 2 },
        \\  { "op": "test", "path": "/title", "value": "WRONG_TITLE" }
        \\]
    ;

    const res = doc.applyPatch(patch_fail);
    try std.testing.expectError(error.TestFailed, res);

    // Verify 100% rollback: neither staged_field nor version were modified!
    try std.testing.expectEqualStrings("simdjson", try (try doc.atPointer("/title")).asString());
    try std.testing.expectEqual(@as(i64, 1), try (try doc.atPointer("/version")).asInt());
    try std.testing.expectError(error.NoSuchField, doc.atPointer("/staged_field"));
}

test "JSON Merge Patch (RFC 7396): recursive merge, removal via null, array replacement" {
    var doc = try simdjson.MutDocument.init(std.testing.allocator);
    defer doc.deinit();

    // Target from RFC 7396 Section 3
    const initial_json =
        \\{
        \\  "title": "Goodbye!",
        \\  "author": {
        \\    "givenName": "John",
        \\    "familyName": "Doe"
        \\  },
        \\  "tags": ["example", "sample"],
        \\  "content": "This will be unchanged"
        \\}
    ;

    // Parse initial JSON into MutDocument
    var mut_doc = blk: {
        const padded = try std.testing.allocator.alloc(u8, initial_json.len + simdjson.SIMDJSON_PADDING);
        defer std.testing.allocator.free(padded);
        @memcpy(padded[0..initial_json.len], initial_json);
        @memset(padded[initial_json.len..], ' ');

        var idx: [512]u32 = undefined;
        const cnt = try Stage1Indexer.indexPadded(padded, initial_json.len, &idx);

        var tape_buf: [512]u64 = undefined;
        const tape_len = try simdjson.Stage2Parser.parse(padded, &idx, cnt, &tape_buf);

        const d = simdjson.Document.init(padded, tape_buf[0..tape_len]);
        break :blk try d.toMutable(std.testing.allocator);
    };
    defer mut_doc.deinit();

    // RFC 7396 Patch from Section 3:
    // - "title": "Hello!" (replace)
    // - "author": {"familyName": null} (delete familyName)
    // - "phoneNumber": "+01-555-1234" (add)
    // - "tags": ["example"] (replace entire array)
    const patch_json =
        \\{
        \\  "title": "Hello!",
        \\  "phoneNumber": "+01-555-1234",
        \\  "author": {
        \\    "familyName": null
        \\  },
        \\  "tags": ["example"]
        \\}
    ;

    try mut_doc.applyMergePatch(patch_json);

    // 1. title updated
    try std.testing.expectEqualStrings("Hello!", try (try mut_doc.atPointer("/title")).asString());

    // 2. phoneNumber added
    try std.testing.expectEqualStrings("+01-555-1234", try (try mut_doc.atPointer("/phoneNumber")).asString());

    // 3. author.givenName retained, author.familyName removed
    try std.testing.expectEqualStrings("John", try (try mut_doc.atPointer("/author/givenName")).asString());
    try std.testing.expectError(error.NoSuchField, mut_doc.atPointer("/author/familyName"));

    // 4. tags replaced with single element ["example"]
    const tags_arr = try (try mut_doc.atPointer("/tags")).asArray();
    try std.testing.expectEqual(@as(usize, 1), tags_arr.len());
    try std.testing.expectEqualStrings("example", try (try mut_doc.atPointer("/tags/0")).asString());

    // 5. content untouched
    try std.testing.expectEqualStrings("This will be unchanged", try (try mut_doc.atPointer("/content")).asString());
}

test "JSON Patch & Merge Patch direct on immutable Document" {
    const json = "{\"count\": 1, \"user\": {\"name\": \"Alice\"}}";

    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var idx: [128]u32 = undefined;
    const cnt = try Stage1Indexer.indexPadded(padded, json.len, &idx);

    var tape_buf: [128]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &idx, cnt, &tape_buf);

    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);

    // 1. applyPatch direct on Document
    var patched_doc = try doc.applyPatch(std.testing.allocator, "[{\"op\": \"replace\", \"path\": \"/count\", \"value\": 42}]");
    defer patched_doc.deinit();
    try std.testing.expectEqual(@as(i64, 42), try (try patched_doc.atPointer("/count")).asInt());

    // 2. applyMergePatch direct on Document
    var merged_doc = try doc.applyMergePatch(std.testing.allocator, "{\"user\": {\"role\": \"admin\"}}");
    defer merged_doc.deinit();
    try std.testing.expectEqualStrings("Alice", try (try merged_doc.atPointer("/user/name")).asString());
    try std.testing.expectEqualStrings("admin", try (try merged_doc.atPointer("/user/role")).asString());
}

test "Object.get and OnDemand ObjectIterator.get with escaped keys" {
    const json = "{\"user\\nname\": 1, \"quote\\\"key\": 2, \"normal\": 3}";
    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var idx: [128]u32 = undefined;
    const cnt = try Stage1Indexer.indexPadded(padded, json.len, &idx);

    // 1. DOM Object.get
    var tape_buf: [128]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &idx, cnt, &tape_buf);
    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);
    const obj = try doc.root().asObject();

    try std.testing.expectEqual(@as(i64, 1), try (obj.get("user\nname").?).asInt());
    try std.testing.expectEqual(@as(i64, 2), try (obj.get("quote\"key").?).asInt());
    try std.testing.expectEqual(@as(i64, 3), try (obj.get("normal").?).asInt());

    // 2. OnDemand ObjectIterator.get
    var od_doc = simdjson.OnDemandDocument.init(padded, &idx, cnt);
    var od_obj = try od_doc.root().asObject();
    try std.testing.expectEqual(@as(i64, 1), try (try od_obj.get("user\nname")).?.asInt());

    // Re-query from fresh iterator
    var od_doc2 = simdjson.OnDemandDocument.init(padded, &idx, cnt);
    var od_obj2 = try od_doc2.root().asObject();
    try std.testing.expectEqual(@as(i64, 2), try (try od_obj2.get("quote\"key")).?.asInt());
}

test "JSON Patch deepEqual: precision safety for double vs int64/uint64 (2^53 - 1 limit)" {
    const el_float = try simdjson.MutElement.fromValue(std.testing.allocator, @as(f64, 42.0));
    const el_int = try simdjson.MutElement.fromValue(std.testing.allocator, @as(i64, 42));
    try std.testing.expect(simdjson.deepEqual(&el_float, &el_int));
    try std.testing.expect(simdjson.deepEqual(&el_int, &el_float));

    // Safe integer limit: 2^53 - 1 = 9_007_199_254_740_991
    const safe_max: i64 = 9_007_199_254_740_991;
    const el_safe_f = try simdjson.MutElement.fromValue(std.testing.allocator, @as(f64, 9007199254740991.0));
    const el_safe_i = try simdjson.MutElement.fromValue(std.testing.allocator, safe_max);
    try std.testing.expect(simdjson.deepEqual(&el_safe_f, &el_safe_i));

    // Beyond safe integer limit: 9_007_199_254_740_993 rounds to 9_007_199_254_740_992.0 in f64
    // Without bounds check, deepEqual would falsely return true.
    const el_rounded_f = try simdjson.MutElement.fromValue(std.testing.allocator, @as(f64, 9007199254740992.0));
    const el_unsafe_i = try simdjson.MutElement.fromValue(std.testing.allocator, @as(i64, 9_007_199_254_740_993));
    try std.testing.expect(!simdjson.deepEqual(&el_rounded_f, &el_unsafe_i));
    try std.testing.expect(!simdjson.deepEqual(&el_unsafe_i, &el_rounded_f));

    // uint64 beyond 2^53 - 1
    const el_unsafe_u = try simdjson.MutElement.fromValue(std.testing.allocator, @as(u64, 9_007_199_254_740_993));
    try std.testing.expect(!simdjson.deepEqual(&el_rounded_f, &el_unsafe_u));
    try std.testing.expect(!simdjson.deepEqual(&el_unsafe_u, &el_rounded_f));
}

test "JSONPath (RFC 9535): Bookstore canonical queries (wildcards, children, recursive descent)" {
    const json =
        \\{
        \\  "store": {
        \\    "book": [
        \\      {
        \\        "category": "reference",
        \\        "author": "Nigel Rees",
        \\        "title": "Sayings of the Century",
        \\        "price": 8.95
        \\      },
        \\      {
        \\        "category": "fiction",
        \\        "author": "Evelyn Waugh",
        \\        "title": "Sword of Honour",
        \\        "price": 12.99
        \\      },
        \\      {
        \\        "category": "fiction",
        \\        "author": "Herman Melville",
        \\        "title": "Moby Dick",
        \\        "isbn": "0-553-21311-3",
        \\        "price": 8.99
        \\      },
        \\      {
        \\        "category": "fiction",
        \\        "author": "J. R. R. Tolkien",
        \\        "title": "The Lord of the Rings",
        \\        "isbn": "0-395-19395-8",
        \\        "price": 22.99
        \\      }
        \\    ],
        \\    "bicycle": {
        \\      "color": "red",
        \\      "price": 19.95
        \\    }
        \\  }
        \\}
    ;

    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var indexes: [1024]u32 = undefined;
    const structurals = try Stage1Indexer.indexPadded(padded, json.len, &indexes);

    var tape_buf: [512]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &indexes, structurals, &tape_buf);
    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);

    // 1. Wildcard query: $.store.book[*].author
    const authors = try doc.jsonPath(std.testing.allocator, "$.store.book[*].author");
    defer std.testing.allocator.free(authors);
    try std.testing.expectEqual(@as(usize, 4), authors.len);
    try std.testing.expectEqualStrings("Nigel Rees", try authors[0].asString());
    try std.testing.expectEqualStrings("Evelyn Waugh", try authors[1].asString());
    try std.testing.expectEqualStrings("Herman Melville", try authors[2].asString());
    try std.testing.expectEqualStrings("J. R. R. Tolkien", try authors[3].asString());

    // 2. Index query: $.store.book[0].title
    const title0 = try doc.jsonPath(std.testing.allocator, "$.store.book[0].title");
    defer std.testing.allocator.free(title0);
    try std.testing.expectEqual(@as(usize, 1), title0.len);
    try std.testing.expectEqualStrings("Sayings of the Century", try title0[0].asString());

    // 3. Negative index query: $.store.book[-1].title
    const title_last = try doc.jsonPath(std.testing.allocator, "$.store.book[-1].title");
    defer std.testing.allocator.free(title_last);
    try std.testing.expectEqual(@as(usize, 1), title_last.len);
    try std.testing.expectEqualStrings("The Lord of the Rings", try title_last[0].asString());

    // 4. Recursive descent: $..author
    const all_authors = try doc.jsonPath(std.testing.allocator, "$..author");
    defer std.testing.allocator.free(all_authors);
    try std.testing.expectEqual(@as(usize, 4), all_authors.len);
    try std.testing.expectEqualStrings("Nigel Rees", try all_authors[0].asString());
    try std.testing.expectEqualStrings("J. R. R. Tolkien", try all_authors[3].asString());

    // 5. Recursive descent: $.store..price (4 books + 1 bicycle = 5 prices)
    const all_prices = try doc.jsonPath(std.testing.allocator, "$.store..price");
    defer std.testing.allocator.free(all_prices);
    try std.testing.expectEqual(@as(usize, 5), all_prices.len);
    try std.testing.expectEqual(@as(f64, 8.95), try all_prices[0].asDouble());
    try std.testing.expectEqual(@as(f64, 12.99), try all_prices[1].asDouble());
    try std.testing.expectEqual(@as(f64, 8.99), try all_prices[2].asDouble());
    try std.testing.expectEqual(@as(f64, 22.99), try all_prices[3].asDouble());
    try std.testing.expectEqual(@as(f64, 19.95), try all_prices[4].asDouble());

    // 6. Object wildcard: $.store.bicycle.*
    const bike_props = try doc.jsonPath(std.testing.allocator, "$.store.bicycle.*");
    defer std.testing.allocator.free(bike_props);
    try std.testing.expectEqual(@as(usize, 2), bike_props.len);
    try std.testing.expectEqualStrings("red", try bike_props[0].asString());
    try std.testing.expectEqual(@as(f64, 19.95), try bike_props[1].asDouble());

    // 7. jsonPathFirst helper
    const first_author = try doc.jsonPathFirst(std.testing.allocator, "$.store.book[*].author");
    try std.testing.expect(first_author != null);
    try std.testing.expectEqualStrings("Nigel Rees", try first_author.?.asString());

    const no_match = try doc.jsonPathFirst(std.testing.allocator, "$.nonexistent");
    try std.testing.expect(no_match == null);
}

test "JSONPath (RFC 9535): Array Slices and Bracket Unions" {
    const json = "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]";

    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var indexes: [64]u32 = undefined;
    const structurals = try Stage1Indexer.indexPadded(padded, json.len, &indexes);

    var tape_buf: [128]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &indexes, structurals, &tape_buf);
    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);

    // 1. Slice: $[0:3] -> [0, 1, 2]
    const slice1 = try doc.jsonPath(std.testing.allocator, "$[0:3]");
    defer std.testing.allocator.free(slice1);
    try std.testing.expectEqual(@as(usize, 3), slice1.len);
    try std.testing.expectEqual(@as(i64, 0), try slice1[0].asInt());
    try std.testing.expectEqual(@as(i64, 1), try slice1[1].asInt());
    try std.testing.expectEqual(@as(i64, 2), try slice1[2].asInt());

    // 2. Slice with start omitted: $[:3] -> [0, 1, 2]
    const slice2 = try doc.jsonPath(std.testing.allocator, "$[:3]");
    defer std.testing.allocator.free(slice2);
    try std.testing.expectEqual(@as(usize, 3), slice2.len);
    try std.testing.expectEqual(@as(i64, 2), try slice2[2].asInt());

    // 3. Negative start slice: $[-3:] -> [7, 8, 9]
    const slice3 = try doc.jsonPath(std.testing.allocator, "$[-3:]");
    defer std.testing.allocator.free(slice3);
    try std.testing.expectEqual(@as(usize, 3), slice3.len);
    try std.testing.expectEqual(@as(i64, 7), try slice3[0].asInt());
    try std.testing.expectEqual(@as(i64, 8), try slice3[1].asInt());
    try std.testing.expectEqual(@as(i64, 9), try slice3[2].asInt());

    // 4. Stepped slice: $[0:6:2] -> [0, 2, 4]
    const slice4 = try doc.jsonPath(std.testing.allocator, "$[0:6:2]");
    defer std.testing.allocator.free(slice4);
    try std.testing.expectEqual(@as(usize, 3), slice4.len);
    try std.testing.expectEqual(@as(i64, 0), try slice4[0].asInt());
    try std.testing.expectEqual(@as(i64, 2), try slice4[1].asInt());
    try std.testing.expectEqual(@as(i64, 4), try slice4[2].asInt());

    // 5. Negative step reversed slice: $[::-1] -> [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]
    const slice5 = try doc.jsonPath(std.testing.allocator, "$[::-1]");
    defer std.testing.allocator.free(slice5);
    try std.testing.expectEqual(@as(usize, 10), slice5.len);
    try std.testing.expectEqual(@as(i64, 9), try slice5[0].asInt());
    try std.testing.expectEqual(@as(i64, 0), try slice5[9].asInt());

    // 6. Union selector: $[0, 2, 5]
    const union1 = try doc.jsonPath(std.testing.allocator, "$[0, 2, 5]");
    defer std.testing.allocator.free(union1);
    try std.testing.expectEqual(@as(usize, 3), union1.len);
    try std.testing.expectEqual(@as(i64, 0), try union1[0].asInt());
    try std.testing.expectEqual(@as(i64, 2), try union1[1].asInt());
    try std.testing.expectEqual(@as(i64, 5), try union1[2].asInt());
}

test "JSONPath (RFC 9535): Filter queries (numeric, string, boolean, existence, logical ops)" {
    const json =
        \\{
        \\  "max_budget": 10.0,
        \\  "books": [
        \\    { "title": "A", "price": 8.5, "category": "fiction", "instock": true },
        \\    { "title": "B", "price": 12.0, "category": "fiction", "instock": false },
        \\    { "title": "C", "price": 9.9, "category": "reference", "isbn": "111", "instock": true },
        \\    { "title": "D", "price": 25.0, "category": "reference", "isbn": "222", "instock": true }
        \\  ]
        \\}
    ;

    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var indexes: [1024]u32 = undefined;
    const structurals = try Stage1Indexer.indexPadded(padded, json.len, &indexes);

    var tape_buf: [512]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &indexes, structurals, &tape_buf);
    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);

    // 1. Numeric comparison: $.books[?(@.price < 10)].title -> ["A", "C"]
    const cheap_books = try doc.jsonPath(std.testing.allocator, "$.books[?(@.price < 10)].title");
    defer std.testing.allocator.free(cheap_books);
    try std.testing.expectEqual(@as(usize, 2), cheap_books.len);
    try std.testing.expectEqualStrings("A", try cheap_books[0].asString());
    try std.testing.expectEqualStrings("C", try cheap_books[1].asString());

    // 2. String comparison: $.books[?(@.category == 'reference')].title -> ["C", "D"]
    const ref_books = try doc.jsonPath(std.testing.allocator, "$.books[?(@.category == 'reference')].title");
    defer std.testing.allocator.free(ref_books);
    try std.testing.expectEqual(@as(usize, 2), ref_books.len);
    try std.testing.expectEqualStrings("C", try ref_books[0].asString());
    try std.testing.expectEqualStrings("D", try ref_books[1].asString());

    // 3. Property existence test: $.books[?(@.isbn)].title -> ["C", "D"]
    const isbn_books = try doc.jsonPath(std.testing.allocator, "$.books[?(@.isbn)].title");
    defer std.testing.allocator.free(isbn_books);
    try std.testing.expectEqual(@as(usize, 2), isbn_books.len);
    try std.testing.expectEqualStrings("C", try isbn_books[0].asString());
    try std.testing.expectEqualStrings("D", try isbn_books[1].asString());

    // 4. Logical AND: $.books[?(@.category == 'fiction' && @.price < 10)].title -> ["A"]
    const cheap_fiction = try doc.jsonPath(std.testing.allocator, "$.books[?(@.category == 'fiction' && @.price < 10)].title");
    defer std.testing.allocator.free(cheap_fiction);
    try std.testing.expectEqual(@as(usize, 1), cheap_fiction.len);
    try std.testing.expectEqualStrings("A", try cheap_fiction[0].asString());

    // 5. Logical OR: $.books[?(@.price > 20 || @.title == 'B')].title -> ["B", "D"]
    const or_books = try doc.jsonPath(std.testing.allocator, "$.books[?(@.price > 20 || @.title == 'B')].title");
    defer std.testing.allocator.free(or_books);
    try std.testing.expectEqual(@as(usize, 2), or_books.len);
    try std.testing.expectEqualStrings("B", try or_books[0].asString());
    try std.testing.expectEqualStrings("D", try or_books[1].asString());

    // 6. Logical NOT: $.books[?(!(@.category == 'fiction'))].title -> ["C", "D"]
    const not_fiction = try doc.jsonPath(std.testing.allocator, "$.books[?(!(@.category == 'fiction'))].title");
    defer std.testing.allocator.free(not_fiction);
    try std.testing.expectEqual(@as(usize, 2), not_fiction.len);
    try std.testing.expectEqualStrings("C", try not_fiction[0].asString());
    try std.testing.expectEqualStrings("D", try not_fiction[1].asString());

    // 7. Root reference in filter: $.books[?(@.price < $.max_budget)].title -> ["A", "C"]
    const root_budget_books = try doc.jsonPath(std.testing.allocator, "$.books[?(@.price < $.max_budget)].title");
    defer std.testing.allocator.free(root_budget_books);
    try std.testing.expectEqual(@as(usize, 2), root_budget_books.len);
    try std.testing.expectEqualStrings("A", try root_budget_books[0].asString());
    try std.testing.expectEqualStrings("C", try root_budget_books[1].asString());

    // 8. Reusable compiled query
    var compiled = try simdjson.JsonPath.compile(std.testing.allocator, "$.books[?(@.instock == true)].title");
    defer compiled.deinit();
    const instock_books = try compiled.eval(doc.root(), std.testing.allocator);
    defer std.testing.allocator.free(instock_books);
    try std.testing.expectEqual(@as(usize, 3), instock_books.len);
    try std.testing.expectEqualStrings("A", try instock_books[0].asString());
    try std.testing.expectEqualStrings("C", try instock_books[1].asString());
    try std.testing.expectEqualStrings("D", try instock_books[2].asString());
}

test "JSONPath (RFC 9535): Built-in functions (length, count), scalar items (@), and bracket notation" {
    const json =
        \\{
        \\  "numbers": [5, 10, 15, 20, 25],
        \\  "items": [
        \\    { "name": "chair", "tags": ["furniture", "wood", "office"] },
        \\    { "name": "desk", "tags": ["furniture", "office"] },
        \\    { "name": "pen", "tags": ["stationery"] }
        \\  ]
        \\}
    ;

    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var indexes: [512]u32 = undefined;
    const structurals = try Stage1Indexer.indexPadded(padded, json.len, &indexes);

    var tape_buf: [512]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &indexes, structurals, &tape_buf);
    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);

    // 1. Scalar filter: $.numbers[?(@ >= 15)] -> [15, 20, 25]
    const big_nums = try doc.jsonPath(std.testing.allocator, "$.numbers[?(@ >= 15)]");
    defer std.testing.allocator.free(big_nums);
    try std.testing.expectEqual(@as(usize, 3), big_nums.len);
    try std.testing.expectEqual(@as(i64, 15), try big_nums[0].asInt());
    try std.testing.expectEqual(@as(i64, 20), try big_nums[1].asInt());
    try std.testing.expectEqual(@as(i64, 25), try big_nums[2].asInt());

    // 2. length() function on string: $.items[?(length(@.name) > 4)].name -> ["chair"]
    const long_names = try doc.jsonPath(std.testing.allocator, "$.items[?(length(@.name) > 4)].name");
    defer std.testing.allocator.free(long_names);
    try std.testing.expectEqual(@as(usize, 1), long_names.len);
    try std.testing.expectEqualStrings("chair", try long_names[0].asString());

    // 3. length() function on array: $.items[?(length(@.tags) >= 2)].name -> ["chair", "desk"]
    const multi_tags = try doc.jsonPath(std.testing.allocator, "$.items[?(length(@.tags) >= 2)].name");
    defer std.testing.allocator.free(multi_tags);
    try std.testing.expectEqual(@as(usize, 2), multi_tags.len);
    try std.testing.expectEqualStrings("chair", try multi_tags[0].asString());
    try std.testing.expectEqualStrings("desk", try multi_tags[1].asString());

    // 4. count() function on node collection: $.items[?(count(@.tags[*]) == 1)].name -> ["pen"]
    const single_tag = try doc.jsonPath(std.testing.allocator, "$.items[?(count(@.tags[*]) == 1)].name");
    defer std.testing.allocator.free(single_tag);
    try std.testing.expectEqual(@as(usize, 1), single_tag.len);
    try std.testing.expectEqualStrings("pen", try single_tag[0].asString());

    // 5. Bracket notation with quotes: $['items'][0]['name'] -> "chair"
    const bracket_chair = try doc.jsonPath(std.testing.allocator, "$['items'][0]['name']");
    defer std.testing.allocator.free(bracket_chair);
    try std.testing.expectEqual(@as(usize, 1), bracket_chair.len);
    try std.testing.expectEqualStrings("chair", try bracket_chair[0].asString());

    // 6. Root element query: "$"
    const root_res = try doc.jsonPath(std.testing.allocator, "$");
    defer std.testing.allocator.free(root_res);
    try std.testing.expectEqual(@as(usize, 1), root_res.len);
    try std.testing.expectEqual(simdjson.dom.Type.object, root_res[0].getType());
}

test "Serde: parseFromSlice into complex nested Zig struct with optionals, enums, slices" {
    const Protocol = enum { tcp, udp, grpc };
    const Endpoint = struct {
        host: []const u8,
        port: u16,
        protocol: Protocol = .tcp,
    };
    const Config = struct {
        service_name: []const u8,
        endpoints: []const Endpoint,
        timeout_ms: u32 = 5000,
        rate_limit: ?f64 = null,
        enabled: bool = true,
    };

    const json =
        \\{
        \\  "service_name": "payment_gateway",
        \\  "endpoints": [
        \\    {"host": "10.0.0.1", "port": 8080, "protocol": "tcp"},
        \\    {"host": "10.0.0.2", "port": 9090, "protocol": "grpc"}
        \\  ],
        \\  "rate_limit": 1500.5
        \\}
    ;

    var parsed = try simdjson.parseFromSlice(Config, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const cfg = parsed.value;
    try std.testing.expectEqualStrings("payment_gateway", cfg.service_name);
    try std.testing.expectEqual(@as(usize, 2), cfg.endpoints.len);
    try std.testing.expectEqualStrings("10.0.0.1", cfg.endpoints[0].host);
    try std.testing.expectEqual(@as(u16, 8080), cfg.endpoints[0].port);
    try std.testing.expectEqual(Protocol.tcp, cfg.endpoints[0].protocol);
    try std.testing.expectEqualStrings("10.0.0.2", cfg.endpoints[1].host);
    try std.testing.expectEqual(@as(u16, 9090), cfg.endpoints[1].port);
    try std.testing.expectEqual(Protocol.grpc, cfg.endpoints[1].protocol);
    try std.testing.expectEqual(@as(u32, 5000), cfg.timeout_ms); // default value
    try std.testing.expectEqual(@as(?f64, 1500.5), cfg.rate_limit);
    try std.testing.expectEqual(true, cfg.enabled); // default value
}

test "Serde: stringifyAlloc and fixed buffer stringify on nested Zig struct" {
    const GeoPoint = struct {
        lat: f64,
        lon: f64,
    };
    const Location = struct {
        name: []const u8,
        geo: GeoPoint,
        altitude: ?i32 = null,
    };

    const loc = Location{
        .name = "Tokyo Tower",
        .geo = .{ .lat = 35.6586, .lon = 139.7454 },
        .altitude = 333,
    };

    // 1. Fixed buffer stringify (zero heap allocation)
    var stack_buf: [256]u8 = undefined;
    const json_slice = try simdjson.stringify(loc, &stack_buf, .{});

    const expected = "{\"name\":\"Tokyo Tower\",\"geo\":{\"lat\":35.6586,\"lon\":139.7454},\"altitude\":333}";
    try std.testing.expectEqualStrings(expected, json_slice);

    // 2. Allocated stringify
    const allocated_json = try simdjson.stringifyAlloc(std.testing.allocator, loc, .{});
    defer std.testing.allocator.free(allocated_json);
    try std.testing.expectEqualStrings(expected, allocated_json);

    // 3. Omitting null optionals
    const loc_no_alt = Location{
        .name = "Sea Level",
        .geo = .{ .lat = 0.0, .lon = 0.0 },
        .altitude = null,
    };
    const json_omitted = try simdjson.stringify(loc_no_alt, &stack_buf, .{ .emit_null_optional_fields = false });
    try std.testing.expectEqualStrings("{\"name\":\"Sea Level\",\"geo\":{\"lat\":0,\"lon\":0}}", json_omitted);
}

test "Serde: Document.to and Element.to struct deserialization" {
    const json = "{\"version\": 2, \"active\": true, \"cluster\": \"us-east-1\"}";

    const padded = try std.testing.allocator.alloc(u8, json.len + simdjson.SIMDJSON_PADDING);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..json.len], json);
    @memset(padded[json.len..], ' ');

    var idx: [64]u32 = undefined;
    const cnt = try simdjson.Stage1Indexer.indexPadded(padded, json.len, &idx);

    var tape_buf: [64]u64 = undefined;
    const tape_len = try simdjson.Stage2Parser.parse(padded, &idx, cnt, &tape_buf);

    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);

    const ClusterConfig = struct {
        version: u32,
        active: bool,
        cluster: []const u8,
    };

    // 1. Directly via doc.to(T)
    const cfg1 = try doc.to(ClusterConfig, std.testing.allocator);
    defer std.testing.allocator.free(cfg1.cluster);
    try std.testing.expectEqual(@as(u32, 2), cfg1.version);
    try std.testing.expectEqual(true, cfg1.active);
    try std.testing.expectEqualStrings("us-east-1", cfg1.cluster);

    // 2. Directly via root element: el.to(T)
    const cfg2 = try doc.root().to(ClusterConfig, std.testing.allocator);
    defer std.testing.allocator.free(cfg2.cluster);
    try std.testing.expectEqual(@as(u32, 2), cfg2.version);
    try std.testing.expectEqual(true, cfg2.active);
    try std.testing.expectEqualStrings("us-east-1", cfg2.cluster);
}

test "Serde: Round-trip Zig Struct -> JSON String -> Zig Struct -> JSON String" {
    const SensorReport = struct {
        sensor_id: i64,
        readings: []const f64,
        status: []const u8,
    };

    const initial = SensorReport{
        .sensor_id = 42001,
        .readings = &.{ 23.4, 24.1, 23.9 },
        .status = "nominal",
    };

    // 1. Struct -> JSON String
    const json1 = try simdjson.stringifyAlloc(std.testing.allocator, initial, .{});
    defer std.testing.allocator.free(json1);

    // 2. JSON String -> Struct
    var parsed = try simdjson.parseFromSlice(SensorReport, std.testing.allocator, json1, .{});
    defer parsed.deinit();

    // 3. Struct -> JSON String
    const json2 = try simdjson.stringifyAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(json2);

    // Both outputs match bit-for-bit
    try std.testing.expectEqualStrings(json1, json2);
}

// =============================================================================
// FUZZ TESTING
// =============================================================================

test "fuzz: stage1 and stage2 parser with arbitrary byte mutations" {
    try std.testing.fuzz({}, testFuzzParser, .{});
}

fn testFuzzParser(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    const gpa = std.testing.allocator;

    const len = @as(usize, smith.value(u11)); // 0..2047 bytes
    if (len == 0) return;

    const input = try gpa.alloc(u8, len);
    defer gpa.free(input);
    smith.bytes(input);

    // 1. Prepare padded buffer
    const padded = try gpa.alloc(u8, len + SIMDJSON_PADDING);
    defer gpa.free(padded);
    @memcpy(padded[0..len], input);
    @memset(padded[len..], ' ');

    const indexes = try gpa.alloc(u32, len + 3);
    defer gpa.free(indexes);

    // Stage 1 must never crash on arbitrary input
    const structurals = Stage1Indexer.indexPadded(padded, len, indexes) catch return;

    // Stage 2 must never crash or read out of bounds
    const tape_buf = try gpa.alloc(u64, structurals * 2 + 16);
    defer gpa.free(tape_buf);

    const tape_len = Stage2Parser.parse(padded, indexes, structurals, tape_buf) catch return;

    // If valid tape was produced, DOM traversal must be safe
    const doc = Document.init(padded, tape_buf[0..tape_len]);
    _ = doc.root().getType();

    // OnDemand parser test on same input
    var od_doc = OnDemandDocument.init(padded, indexes, structurals);
    var val = od_doc.root();
    _ = val.skip() catch {};
}

// =============================================================================
// SLIDING WINDOW LARGER FILE TEST
// =============================================================================

test "streaming: sliding window on multi-megabyte stream across chunk boundaries" {
    const allocator = std.testing.allocator;

    // Generate a simulated 2.5 MB JSON stream with 10,000 concatenated records
    const num_records: usize = 10000;
    var total_bytes: usize = 0;
    var stream_builder: std.ArrayList(u8) = .empty;
    defer stream_builder.deinit(allocator);

    var i: usize = 0;
    while (i < num_records) : (i += 1) {
        var record_buf: [128]u8 = undefined;
        const slice = try std.fmt.bufPrint(
            &record_buf,
            \\{{"seq":{d},"status":"ok","sensor":"temp_alpha","val":{d}.5}}
        ,
            .{ i, i % 100 },
        );
        try stream_builder.appendSlice(allocator, slice);
        total_bytes += slice.len;
    }

    try std.testing.expect(total_bytes > 500_000); // Verify substantial size

    // Parse with a deliberately small sliding window (16 KB) to force thousands of window refills
    var reader = std.Io.Reader.fixed(stream_builder.items);
    var chunk_stream = try stream.chunkedDocumentStream(
        allocator,
        &reader,
        .{ .window_capacity = 16 * 1024, .auto_grow = true },
    );
    defer chunk_stream.deinit();

    var records_parsed: usize = 0;
    var last_seq: i64 = -1;

    while (try chunk_stream.next()) |doc| {
        const root_el = doc.root();
        const obj = try root_el.asObject();

        if (obj.get("seq")) |seq_el| {
            const seq = try seq_el.asInt();
            try std.testing.expectEqual(last_seq + 1, seq);
            last_seq = seq;
        }

        records_parsed += 1;
    }

    try std.testing.expectEqual(num_records, records_parsed);
}

// =============================================================================
// MULTIPLE JSON PARSING FILE TEST
// =============================================================================

test "streaming: multiple concatenated JSON documents (without commas or brackets)" {
    const allocator = std.testing.allocator;

    // Multi-document stream (e.g. streaming log records or API event streams)
    const multi_json =
        \\{"id": 1, "type": "login", "user": "alice"}
        \\{"id": 2, "type": "action", "user": "bob"}
        \\{"id": 3, "type": "logout", "user": "alice"}
        \\{"id": 4, "type": "payment", "user": "charlie"}
    ;

    // Method 1: Low-Level Two-Stage DocumentStream
    {
        const padded = try allocator.alloc(u8, multi_json.len + SIMDJSON_PADDING);
        defer allocator.free(padded);
        @memcpy(padded[0..multi_json.len], multi_json);
        @memset(padded[multi_json.len..], ' ');

        const indexes = try allocator.alloc(u32, multi_json.len + 3);
        defer allocator.free(indexes);
        const structurals = try Stage1Indexer.indexPadded(padded, multi_json.len, indexes);

        const tape_buf = try allocator.alloc(u64, structurals * 2 + 16);
        defer allocator.free(tape_buf);

        var doc_stream = DocumentStream.init(padded, indexes, structurals, tape_buf);
        var ids: [4]i64 = undefined;
        var count: usize = 0;

        while (try doc_stream.next()) |doc| : (count += 1) {
            const obj = try doc.root().asObject();
            ids[count] = try (obj.get("id").?).asInt();
        }

        try std.testing.expectEqual(@as(usize, 4), count);
        try std.testing.expectEqual(@as(i64, 1), ids[0]);
        try std.testing.expectEqual(@as(i64, 2), ids[1]);
        try std.testing.expectEqual(@as(i64, 3), ids[2]);
        try std.testing.expectEqual(@as(i64, 4), ids[3]);
    }

    // Method 2: High-Speed OnDemand Stream (zero tape allocations)
    {
        const padded = try allocator.alloc(u8, multi_json.len + SIMDJSON_PADDING);
        defer allocator.free(padded);
        @memcpy(padded[0..multi_json.len], multi_json);
        @memset(padded[multi_json.len..], ' ');

        const indexes = try allocator.alloc(u32, multi_json.len + 3);
        defer allocator.free(indexes);
        const structurals = try Stage1Indexer.indexPadded(padded, multi_json.len, indexes);

        var od_stream = OnDemandDocumentStream.init(padded, indexes, structurals);
        var users: [4][]const u8 = undefined;
        var count: usize = 0;

        while (try od_stream.next()) |record| : (count += 1) {
            var obj = try record.asObject();
            if (try obj.get("user")) |user_val| {
                users[count] = try user_val.asString();
            }
        }

        try std.testing.expectEqual(@as(usize, 4), count);
        try std.testing.expectEqualStrings("alice", users[0]);
        try std.testing.expectEqualStrings("bob", users[1]);
        try std.testing.expectEqualStrings("alice", users[2]);
        try std.testing.expectEqualStrings("charlie", users[3]);
    }
}
