# simdjson-zig

A high-performance, zero-allocation, SIMD-accelerated JSON parsing engine implemented in **Zig 0.16.0+**, inspired by Daniel Lemire and Geoff Langdale's `simdjson`.

`simdjson-zig` parses JSON at multi-gigabytes per second per core, utilizing AVX2 256-bit vector instructions on x86_64 and ARM NEON on AArch64. Beyond raw parsing speed, it provides a comprehensive suite of standards-compliant tooling: **OnDemand stream parsing**, **RFC 9535 JSONPath**, **RFC 6901 JSON Pointer**, **RFC 6902 JSON Patch**, **RFC 7396 JSON Merge Patch**, **NDJSON streaming**, **Chunked Sliding Window streaming**, and **Mutable DOM trees**.

> [!WARNING]
> **Experimental Software**: `simdjson-zig` is currently in active early development and is considered **experimental**. While covered by 100 unit/integration tests and verified against upstream datasets, APIs may evolve and the parser may contain bugs, edge-case discrepancies, or incomplete platform optimizations. Use with care, and avoid mission-critical production deployment without thorough testing and fuzzing.

---

## Benchmark Results (Zig 0.16.0 `ReleaseFast`, AVX2)

| Benchmark / Workload | Throughput | Latency / Rate | Description |
|---|---|---|---|
| **Stage 1 AVX2 Indexer (`twitter.json`)** | **7.8 – 8.1 GB/s** | ~0.080 ms/iter | 256-bit SIMD structural bitmask indexer |
| **Stage 1 AVX2 Indexer (`citm_catalog.json`)** | **8.0 – 8.2 GB/s** | ~0.213 ms/iter | Zero memory allocations |
| **Stage 2 Zero-Copy Tape (`citm_catalog.json`)** | **6.0 – 6.2 GB/s** | ~0.279 ms/iter | 64-bit compact tape generator |
| **Combined End-to-End (`citm_catalog.json`)** | **3.3 – 3.5 GB/s** | ~0.488 ms/iter | Stage 1 + Stage 2 combined |
| **OnDemand Targeted Query** | **22.5 – 24.8 GB/s** | ~0.027 ms/iter | Direct stream index traversal |
| **DOM Full Tree Walk** | **7.9 – 8.1 GB/s** | ~0.080 ms/iter | Sequential tape traversal |
| **NDJSON / JSON Lines Stream** | **3.6 – 3.8 GB/s** | **25.8M docs/sec** | 10,000 log records in memory |
| **Float Parsing (`fast_float`)** | **74.7 M floats/sec** | ~13.4 ns/op | Lemire algorithm vs `std.fmt` (1.37x faster) |
| **Struct Serialization (`stringify`)** | **699 MB/s** | **~151 ns/op** | **6.61M structs/sec** (**80.7x faster** than `std.json.fmt`) |
| **Struct Deserialization (Zero-Copy)** | **338 – 375 MB/s** | **~282 – 312 ns/op** | **3.20M – 3.55M structs/sec** (**28x – 33x faster** than `std.json`) |
| **Struct Deserialization (Arena)** | **22.5 MB/s** | **~4,695 ns/op** | **213K structs/sec** (**1.9x faster** than `std.json`) |

---

## Standards Compliance

| Standard | Title | Status |
|---|---|---|
| **RFC 8259** | The JavaScript Object Notation (JSON) Data Interchange Format | **Fully Compliant** |
| **RFC 3629** | UTF-8, a transformation format of ISO 10646 | **Fully Compliant** (SIMD validator) |
| **RFC 6901** | JavaScript Object Notation (JSON) Pointer | **Fully Compliant** (Supports `~0` and `~1` escapes) |
| **RFC 6902** | JavaScript Object Notation (JSON) Patch | **Fully Compliant** (Atomic rollback on test failure) |
| **RFC 7396** | JSON Merge Patch | **Fully Compliant** (Recursive merge, null deletions) |
| **RFC 9535** | JSONPath: Query Expressions for JSON | **Fully Compliant** (Wildcards, slices, recursive descent, filters) |

---

## Installation (Zig 0.16.0)

### 1. Add Dependency

Add `simdjson-zig` to your project using `zig fetch --save` (which automatically computes the content hash and adds it to `build.zig.zon`):

```bash
# Fetch latest main branch
zig fetch --save git+https://github.com/sahrahul181/simdjson-zig.git#main

# Or fetch a specific commit hash
# zig fetch --save git+https://github.com/sahrahul181/simdjson-zig.git#<commit_hash>
```

This updates your `build.zig.zon`:

```zig
.{
    .name = .my_project,
    .version = "1.0.0",
    .fingerprint = 0xcb48777c496097f0,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .simdjson = .{
            .url = "git+https://github.com/sahrahul181/simdjson-zig.git#main",
            .hash = "...", // Computed automatically by zig fetch --save
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

### 2. Import Module in `build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const simdjson_dep = b.dependency("simdjson", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "simdjson", .module = simdjson_dep.module("simdjson") },
            },
        }),
    });

    b.installArtifact(exe);
}
```

---

## Quick Start (30-Second Tutorial)

```zig
const std = @import("std");
const simdjson = @import("simdjson");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_json =
        \\{
        \\  "project": "simdjson-zig",
        \\  "stars": 1500,
        \\  "tags": ["simd", "json", "fast"],
        \\  "maintainer": { "name": "Alice", "verified": true }
        \\}
    ;

    // 1. Prepare buffer with 64-byte padding required for SIMD vector reads
    const padded = try allocator.alloc(u8, raw_json.len + simdjson.SIMDJSON_PADDING);
    defer allocator.free(padded);
    @memcpy(padded[0..raw_json.len], raw_json);
    @memset(padded[raw_json.len..], ' ');

    // 2. Stage 1: Index structural positions
    const indexes = try allocator.alloc(u32, raw_json.len + 3);
    defer allocator.free(indexes);
    const structurals = try simdjson.Stage1Indexer.indexPadded(padded, raw_json.len, indexes);

    // 3. Stage 2: Parse into 64-bit compact DOM tape (zero allocations)
    const tape_buf = try allocator.alloc(u64, structurals + 4);
    defer allocator.free(tape_buf);
    const tape_len = try simdjson.Stage2Parser.parse(padded, indexes, structurals, tape_buf);

    // 4. Navigate using Immutable DOM
    const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);
    const obj = try doc.root().asObject();

    if (obj.get("project")) |project| {
        std.debug.print("Project: {s}\n", .{try project.asString()});
    }

    // 5. Query using RFC 9535 JSONPath
    const matches = try doc.jsonPath(allocator, "$.maintainer.name");
    defer allocator.free(matches);
    if (matches.len > 0) {
        std.debug.print("Maintainer: {s}\n", .{try matches[0].asString()});
    }
}
```

---

## Comprehensive API Reference & Guide

All code examples use **Zig 0.16.0** conventions.

```zig
const simdjson = @import("simdjson");
// (Note: `const simdjson = @import("simdjson").simdjson;` also supported for backward compatibility)
```

---

### 1. Stage 1 Indexer (`simdjson.Stage1Indexer`)

Stage 1 scans the raw JSON byte buffer using vectorized 256-bit AVX2 (or 128-bit NEON) instructions. It detects quotes, backslash escape sequences, and structural delimiters (`{`, `}`, `[`, `]`, `:`, `,`, primitives), populating an array of 32-bit indices.

#### API Signatures
```zig
pub const Stage1Indexer = struct {
    pub const SIMDJSON_PADDING: usize = 64;

    /// Indexes padded buffer into out_indexes slice.
    pub fn indexPadded(
        buf: []const u8,
        len: usize,
        out_indexes: []u32,
    ) SimdJsonError!usize;

    /// Indexes padded buffer with configurable options (e.g. UTF-8 validation).
    pub fn indexPaddedOptions(
        options: struct { validate_utf8: bool = false },
        buf: []const u8,
        len: usize,
        out_indexes: []u32,
    ) SimdJsonError!usize;

    /// Helper allocating a temporary padded buffer automatically.
    pub fn indexAlloc(
        allocator: std.mem.Allocator,
        json: []const u8,
        out_indexes: []u32,
    ) (SimdJsonError || std.mem.Allocator.Error)!usize;

    pub fn indexAllocOptions(
        options: struct { validate_utf8: bool = false },
        allocator: std.mem.Allocator,
        json: []const u8,
        out_indexes: []u32,
    ) (SimdJsonError || std.mem.Allocator.Error)!usize;
};
```

#### Buffer Requirements
* **Input Buffer (`buf`)**: Must have capacity of at least `len + simdjson.SIMDJSON_PADDING` (64 bytes). The tail bytes (`buf[len .. len + 64]`) must be padded (typically with spaces `' '`).
* **Output Buffer (`out_indexes`)**: Must have capacity of at least `len + 3` elements.

#### Example (Zig 0.16.0)
```zig
const raw = "{\"id\": 101, \"data\": [1, 2, 3]}";
const padded = try allocator.alloc(u8, raw.len + simdjson.SIMDJSON_PADDING);
defer allocator.free(padded);
@memcpy(padded[0..raw.len], raw);
@memset(padded[raw.len..], ' ');

const indexes = try allocator.alloc(u32, raw.len + 3);
defer allocator.free(indexes);

// Stage 1 index with on-the-fly SIMD UTF-8 validation
const count = try simdjson.Stage1Indexer.indexPaddedOptions(
    .{ .validate_utf8 = true },
    padded,
    raw.len,
    indexes,
);
std.debug.print("Indexed {d} structural tokens\n", .{count});
```

---

### 2. Stage 2 Parser (`simdjson.Stage2Parser`)

Stage 2 transforms structural indices into a sequential 64-bit DOM tape representation. It performs **zero heap allocations** and **zero string copies**, writing directly into a caller-provided `[]u64` tape buffer.

#### API Signatures
```zig
pub const Stage2Parser = struct {
    /// Parses a single JSON document into tape_buf. Returns number of 64-bit tape words written.
    pub fn parse(
        buf: []const u8,
        indexes: []const u32,
        structurals_count: usize,
        tape_buf: []u64,
    ) SimdJsonError!usize;

    /// Parses a single document and captures rich line and column diagnostic on error.
    pub fn parseWithDiagnostic(
        buf: []const u8,
        indexes: []const u32,
        structurals_count: usize,
        tape_buf: []u64,
        diag: *Diagnostic,
    ) SimdJsonError!usize;

    /// Streaming parser: parses a single document starting from cur_struct_ptr.* and advances the pointer.
    pub fn parseSingle(
        buf: []const u8,
        indexes: []const u32,
        structurals_count: usize,
        cur_struct_ptr: *usize,
        tape_buf: []u64,
    ) SimdJsonError!?usize;
};
```

#### Example (Zig 0.16.0)
```zig
// Tape buffer size is bounded by (structurals + 4) words
const tape_buf = try allocator.alloc(u64, count + 4);
defer allocator.free(tape_buf);

var diag = simdjson.Diagnostic{};
const tape_len = simdjson.Stage2Parser.parseWithDiagnostic(
    padded,
    indexes,
    count,
    tape_buf,
    &diag,
) catch |err| {
    std.debug.print("Parse error at line {d}, col {d}: {s}\n", .{
        diag.line, diag.column, simdjson.errorMessage(err),
    });
    return err;
};
```

---

### 3. Immutable Tape DOM (`simdjson.Document` & `simdjson.Element`)

Provides zero-copy, read-only navigation of parsed JSON. An `Element` is a lightweight 24-byte handle containing a reference to the `Document` and a tape index.

#### Type Tag Definition
```zig
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
```

#### `Document` API Methods
| Method | Return Type | Description |
|---|---|---|
| `Document.init(buf, tape)` | `Document` | Constructs a document wrapper around source buffer and tape. |
| `doc.root()` | `Element` | Returns the root `Element` of the document. |
| `doc.atPointer(pointer)` | `!Element` | Navigates the document via RFC 6901 JSON Pointer. |
| `doc.jsonPath(allocator, query)` | `![]Element` | Evaluates an RFC 9535 JSONPath query against document root. |
| `doc.jsonPathFirst(allocator, query)` | `!?Element` | Evaluates JSONPath query, returning the first match or `null`. |
| `doc.writeJson(writer)` | `!void` | Serializes document back to minified JSON format. |
| `doc.stringifyAlloc(allocator)` | `![]const u8` | Serializes document to a newly allocated JSON string. |
| `doc.formatJson(writer, options)` | `!void` | Pretty-prints document with custom indent options. |
| `doc.formatAlloc(allocator, options)`| `![]const u8` | Pretty-prints document to a newly allocated formatted string. |
| `doc.toMutable(allocator)` | `!MutDocument` | Converts immutable document tree into an in-memory mutable tree. |

#### `Element` API Methods
| Method | Return Type | Description |
|---|---|---|
| `el.getType()` | `Type` | Returns the JSON type enum tag. |
| `el.isNull()` | `bool` | Returns `true` if element represents `null`. |
| `el.asBool()` | `!bool` | Extracts boolean (`true` or `false`). Returns `error.IncorrectType` if not bool. |
| `el.asInt()` | `!i64` | Extracts signed 64-bit integer. Converts unsigned ints with range check. |
| `el.asUint()` | `!u64` | Extracts unsigned 64-bit integer. Returns `error.NumberOutOfRange` if negative. |
| `el.asDouble()` | `!f64` | Extracts `f64`. Converts integers to double without error. |
| `el.asString()` | `![]const u8` | Returns a zero-copy slice to raw string bytes in buffer. |
| `el.hasEscapes()` | `!bool` | SIMD check determining if backslash escapes exist in string. |
| `el.writeUnescaped(buf)` | `![]const u8` | Unescapes string into user-provided buffer (zero heap allocations). |
| `el.asUnescapedAlloc(alloc)` | `![]const u8` | Allocates and returns fully unescaped string copy. |
| `el.asObject()` | `!Object` | Casts element to `Object`. Returns `error.IncorrectType` if not object. |
| `el.asArray()` | `!Array` | Casts element to `Array`. Returns `error.IncorrectType` if not array. |
| `el.atPointer(pointer)` | `!Element` | Navigates subtree from this element via RFC 6901 pointer. |
| `el.jsonPath(alloc, query)` | `![]Element` | Evaluates RFC 9535 JSONPath query starting at this element. |
| `el.jsonPathFirst(alloc, query)`| `!?Element` | Evaluates JSONPath returning the first match. |
| `el.toMutable(alloc)` | `!MutElement` | Converts this element subtree into a mutable DOM node. |

#### `Object` & `Array` API Methods
```zig
// Object API
pub const Object = struct {
    pub fn get(self: Object, key: []const u8) ?Element;
    pub fn iterator(self: Object) ObjectIterator;
};

// ObjectIterator yields ObjectField
pub const ObjectField = struct {
    key: []const u8,
    value: Element,
};

// Array API
pub const Array = struct {
    pub fn len(self: Array) usize;
    pub fn at(self: Array, index: usize) ?Element;
    pub fn iterator(self: Array) ArrayIterator;
};
```

#### Full DOM Example (Zig 0.16.0)
```zig
const doc = simdjson.Document.init(padded, tape_buf[0..tape_len]);
const root = doc.root();

switch (root.getType()) {
    .object => {
        const obj = try root.asObject();
        var it = obj.iterator();
        while (it.next()) |field| {
            std.debug.print("Key: {s}, Type: {s}\n", .{ field.key, @tagName(field.value.getType()) });
        }
    },
    .array => {
        const arr = try root.asArray();
        for (0..arr.len()) |i| {
            if (arr.at(i)) |item| {
                std.debug.print("[{d}] = {d}\n", .{ i, try item.asInt() });
            }
        }
    },
    else => {},
}
```

---

### 4. OnDemand API (`simdjson.OnDemandDocument` & `simdjson.Value`)

The **OnDemand** engine parses JSON as a forward-only, streaming iterator without building a DOM tape. It skips unrequested fields and arrays at hardware speeds (up to **24.8 GB/s**).

#### `OnDemandDocument` Methods
```zig
pub const OnDemandDocument = struct {
    pub fn init(buf: []const u8, indexes: []const u32, count: usize) OnDemandDocument;
    pub fn root(self: *OnDemandDocument) !Value;
    pub fn atPointer(self: *OnDemandDocument, pointer: []const u8) !Value;
    pub fn minify(self: *const OnDemandDocument, writer: anytype) !void;
    pub fn format(self: *const OnDemandDocument, writer: anytype, options: FormatOptions) !void;
    pub fn getDiagnostic(self: *const OnDemandDocument, err: SimdJsonError) Diagnostic;
};
```

#### `Value` Methods
```zig
pub const Value = struct {
    pub fn getType(self: Value) Type;
    pub fn isNull(self: Value) bool;
    pub fn skip(self: Value) !void;
    pub fn asString(self: Value) ![]const u8;
    pub fn asRawString(self: Value) ![]const u8;
    pub fn hasEscapes(self: Value) !bool;
    pub fn unescape(self: Value, dest: []u8) ![]const u8;
    pub fn unescapeAlloc(self: Value, allocator: std.mem.Allocator) ![]const u8;
    pub fn asInt(self: Value) !i64;
    pub fn asUint(self: Value) !u64;
    pub fn asDouble(self: Value) !f64;
    pub fn asFloat(self: Value) !f32;
    pub fn asBool(self: Value) !bool;
    pub fn asObject(self: Value) !ObjectIterator;
    pub fn asArray(self: Value) !ArrayIterator;
    pub fn atPointer(self: Value, pointer: []const u8) !Value;
    pub fn getDiagnostic(self: Value, err: SimdJsonError) Diagnostic;
};
```

#### Example: High-Speed Targeted Extraction
```zig
var od_doc = simdjson.OnDemandDocument.init(padded, indexes, structurals);
var obj = try od_doc.root().asObject();

// get() automatically scans and skips intermediate fields
if (try obj.get("stars")) |stars_val| {
    const stars = try stars_val.asInt();
    std.debug.print("Stars: {d}\n", .{stars});
}
```

---

### 5. RFC 9535 JSONPath Query Engine (`simdjson.jsonpath`)

A full, standard-compliant RFC 9535 JSONPath query engine supporting wildcards, array slices, recursive descent, bracket unions, and filter expressions.

#### Query Syntax Reference
| Selector | Syntax | Example | Description |
|---|---|---|---|
| **Root Node** | `$` | `$` | Refers to the document root. |
| **Current Node** | `@` | `@.price` | Refers to the current element in filter evaluation. |
| **Name Selector** | `.name`, `['name']` | `$.store.book` | Selects a child object member. |
| **Wildcard** | `.*`, `[*]` | `$.store.*`, `$.items[*]` | Selects all member values of an object or all elements of an array. |
| **Array Index** | `[n]` | `$[0]`, `$[-1]` | Positive and negative (from end) array indexing. |
| **Array Slice** | `[start:end:step]` | `$[0:5:2]`, `$[::-1]` | Python-style slice indexing with optional step. |
| **Bracket Union** | `[sel1, sel2]` | `$[0, 2]`, `$['id', 'name']` | Selects union of multiple selectors in a single bracket. |
| **Recursive Descent** | `..name`, `..*` | `$..author`, `$.store..price` | Visits all descendant nodes recursively in document order. |
| **Filter Expression** | `[?(<expr>)]` | `$[?(@.price < 10)]` | Filters items using comparative and logical expressions. |

#### Filter Predicates & Built-ins
* **Comparisons**: `==`, `!=`, `<`, `<=`, `>`, `>=` (numbers and alphabetical strings)
* **Logical Combinations**: `&&`, `||`, `!` with parenthesized grouping `(...)`
* **Existence Tests**: `$[?(@.isbn)]`, `$[?(@.active == true)]`
* **Scalar Element Testing**: `$.numbers[?(@ >= 10)]`
* **Cross-Root References**: `$.books[?(@.price < $.max_budget)]`
* **Built-in Functions**:
  * `length(@.path)`: Evaluates string length, array element count, or object key count.
  * `count(@.path[*])`: Evaluates number of matched nodes in query.

#### API Signatures
```zig
pub const JsonPath = struct {
    /// Compiles an RFC 9535 query string into a reusable execution AST.
    pub fn compile(allocator: std.mem.Allocator, query_str: []const u8) !JsonPath;
    
    /// Evaluates query against DOM root, returning an allocated slice of matching Elements.
    pub fn eval(self: JsonPath, root: Element, allocator: std.mem.Allocator) ![]Element;
    
    /// Evaluates query returning the first match without full collection overhead.
    pub fn evalFirst(self: JsonPath, root: Element, allocator: std.mem.Allocator) !?Element;
    
    pub fn deinit(self: *JsonPath) void;
};

// Convenience helpers
pub fn query(root: Element, allocator: std.mem.Allocator, query_str: []const u8) ![]Element;
pub fn queryFirst(root: Element, allocator: std.mem.Allocator, query_str: []const u8) !?Element;
```

#### Example (Zig 0.16.0)
```zig
// 1. One-shot direct query
const authors = try doc.jsonPath(allocator, "$.store.book[*].author");
defer allocator.free(authors);
for (authors) |author| {
    std.debug.print("Author: {s}\n", .{try author.asString()});
}

// 2. Filter query with logical operators
const cheap_fiction = try doc.jsonPath(
    allocator,
    "$.store.book[?(@.price < 15.0 && @.category == 'fiction')].title",
);
defer allocator.free(cheap_fiction);

// 3. Pre-compiled query for maximum performance in hot loops
var compiled = try simdjson.JsonPath.compile(allocator, "$..price");
defer compiled.deinit();

const prices = try compiled.eval(doc.root(), allocator);
defer allocator.free(prices);
```

---

### 6. RFC 6901 JSON Pointer

Evaluates RFC 6901 JSON Pointers (`/users/0/name`) with full support for `~0` (`~`) and `~1` (`/`) escape sequences.

```zig
// 1. On immutable Document / Element
const title_el = try doc.atPointer("/store/book/0/title");
std.debug.print("Title: {s}\n", .{try title_el.asString()});

// 2. Escaped keys: key "a/b" -> pointer token "/a~1b"
const escaped_val = try doc.atPointer("/a~1b");

// 3. On OnDemand stream
var od_doc = simdjson.OnDemandDocument.init(padded, indexes, structurals);
const od_title = try od_doc.atPointer("/store/book/0/title");
std.debug.print("OnDemand Title: {s}\n", .{try od_title.asString()});
```

---

### 7. RFC 6902 JSON Patch & RFC 7396 Merge Patch (`simdjson.patch`)

Enables atomic mutations on mutable documents with automatic rollback on failure and precision-safe equality checks.

#### RFC 6902 Operations
* `add`: Inserts into array (`/-` to append, `/<idx>` to insert) or sets object key.
* `remove`: Removes array element or object property.
* `replace`: Replaces target value.
* `move`: Moves value from `from` path to `path`. Rejects circular moves.
* `copy`: Duplicates value from `from` path to `path`.
* `test`: Asserts equality; aborts and rolls back entire patch on failure.

#### Precision Safety Guarantee
Numeric comparisons enforce the IEEE-754 $2^{53} - 1 = 9{,}007{,}199{,}254{,}740{,}991$ boundary, preventing integer truncation false positives when comparing large 64-bit integers with floating-point values.

#### Example (Zig 0.16.0)
```zig
// Convert immutable Document to mutable DOM
var mut_doc = try doc.toMutable(allocator);
defer mut_doc.deinit();

// Apply atomic RFC 6902 JSON Patch
try mut_doc.applyPatch(
    \\[
    \\  { "op": "replace", "path": "/price", "value": 19.99 },
    \\  { "op": "add", "path": "/tags/-", "value": "sale" },
    \\  { "op": "test", "path": "/price", "value": 19.99 }
    \\]
);

// Apply RFC 7396 Merge Patch (null removes fields, objects merge recursively)
try mut_doc.applyMergePatch(
    \\{
    \\  "price": 14.99,
    \\  "discontinued": null
    \\}
);

// Serialize modified document back to JSON string
const updated_json = try mut_doc.stringifyAlloc(allocator);
defer allocator.free(updated_json);
```

---

### 8. Mutable In-Memory DOM (`simdjson.mut_dom`)

Construct and mutate JSON documents dynamically with arena-backed memory management and block-copy serialization.

#### `MutDocument` API
```zig
pub const MutDocument = struct {
    pub fn init(parent_allocator: std.mem.Allocator) !MutDocument;
    pub fn initArray(parent_allocator: std.mem.Allocator) !MutDocument;
    pub fn from(parent_allocator: std.mem.Allocator, doc: Document) !MutDocument;
    pub fn deinit(self: *MutDocument) void;
    pub fn root(self: *MutDocument) *MutElement;
    pub fn atPointer(self: *MutDocument, pointer: []const u8) !*MutElement;
    pub fn setPointer(self: *MutDocument, pointer: []const u8, val: anytype) !void;
    pub fn removePointer(self: *MutDocument, pointer: []const u8) !bool;
    pub fn writeJson(self: *const MutDocument, writer: anytype) !void;
    pub fn stringifyAlloc(self: *const MutDocument, allocator: std.mem.Allocator) ![]const u8;
    pub fn formatAlloc(self: *const MutDocument, allocator: std.mem.Allocator, options: FormatOptions) ![]const u8;
};
```

#### Example (Zig 0.16.0)
```zig
var mut_doc = try simdjson.MutDocument.init(allocator);
defer mut_doc.deinit();

// Build nested structure dynamically
const root = mut_doc.root();
try root.set("project", "simdjson-zig");
try root.set("version", 1);

var tags_arr = simdjson.MutArray{};
try tags_arr.append(allocator, "fast");
try tags_arr.append(allocator, "zero-alloc");
try root.set("tags", tags_arr);

// Modify via pointer
try mut_doc.setPointer("/tags/-", "zig");

const out = try mut_doc.stringifyAlloc(allocator);
defer allocator.free(out);
std.debug.print("Constructed: {s}\n", .{out});
```

---

### 9. NDJSON Streaming (`simdjson.DocumentStream`)

Iterates newline-delimited JSON (NDJSON / JSON Lines) streams at 25+ million documents per second.

```zig
// DOM DocumentStream
var stream = simdjson.DocumentStream.init(ndjson_buffer, indexes, structurals, tape_buf);
while (try stream.next()) |record_doc| {
    const obj = try record_doc.root().asObject();
    if (obj.get("event_id")) |id| {
        std.debug.print("Event: {d}\n", .{try id.asInt()});
    }
}

// OnDemandDocumentStream (zero tape generation)
var od_stream = simdjson.OnDemandDocumentStream.init(ndjson_buffer, indexes, structurals);
while (try od_stream.next()) |record_val| {
    var obj = try record_val.asObject();
    if (try obj.get("event_id")) |id| {
        std.debug.print("OnDemand Event: {d}\n", .{try id.asInt()});
    }
}
```

---

### 10. Sliding Window File & Reader Streaming (`simdjson.stream`)

Parses multi-gigabyte JSON files or continuous network streams with a fixed or auto-growing memory window, processing arbitrarily large files without loading the entire payload into RAM.

#### API Signatures
```zig
pub const StreamOptions = struct {
    window_capacity: usize = 1024 * 1024,  // Default 1 MB sliding window
    max_capacity: usize = 64 * 1024 * 1024,
    auto_grow: bool = false,
};

/// Dynamic window stream with heap allocation
pub fn chunkedDocumentStream(
    allocator: std.mem.Allocator,
    reader: anytype,
    options: StreamOptions,
) !ChunkedDocumentStream(@TypeOf(reader));

/// Zero-allocation stream using caller-provided buffers
pub fn fixedChunkedDocumentStream(
    reader: anytype,
    window_buf: []u8,
    indexes_buf: []u32,
    tape_buf: []u64,
) !ChunkedDocumentStream(@TypeOf(reader));
```

#### Example (Zig 0.16.0)
```zig
var file = try std.fs.cwd().openFile("massive_log.json", .{});
defer file.close();
var file_reader = file.reader();

var chunk_stream = try simdjson.chunkedDocumentStream(
    allocator,
    &file_reader,
    .{ .window_capacity = 2 * 1024 * 1024 }, // 2 MB window
);
defer chunk_stream.deinit();

while (try chunk_stream.next()) |doc| {
    const root_el = doc.root();
    // Process document...
    _ = root_el;
}
```

---

### 11. Struct Serialization & Deserialization (`simdjson.serde`)

`simdjson-zig` provides compile-time reflection-driven serialization and deserialization between native Zig types (`struct`, `enum`, `union`, `optional`, slices, arrays, primitives) and JSON with zero-copy string borrowing and arena lifecycle management.

#### Deserializing JSON into Zig Structs (`parseFromSlice`)
```zig
const Endpoint = struct {
    host: []const u8,
    port: u16,
};

const ServiceConfig = struct {
    name: []const u8,
    endpoints: []const Endpoint,
    timeout_ms: u32 = 5000,          // Default value if omitted
    rate_limit: ?f64 = null,         // Optional field
    active: bool = true,
};

const json =
    \\{
    \\  "name": "auth_service",
    \\  "endpoints": [{"host": "127.0.0.1", "port": 8080}],
    \\  "rate_limit": 500.0
    \\}
;

// Deserializes into a memory-managed Parsed(T) container
var parsed = try simdjson.parseFromSlice(ServiceConfig, allocator, json, .{});
defer parsed.deinit();

const cfg = parsed.value;
std.debug.print("Service: {s}, endpoints: {d}\n", .{ cfg.name, cfg.endpoints.len });
```

#### Deserializing Directly from DOM Elements (`doc.to` / `element.to`)
```zig
const doc = try parser.parse(json);
const cfg = try doc.to(ServiceConfig, allocator);
defer allocator.free(cfg.name);
```

#### Serializing Zig Structs to JSON (`stringify` / `stringifyAlloc`)
```zig
// 1. Zero heap allocation: Serialize directly into a preallocated stack buffer
var stack_buf: [512]u8 = undefined;
const json_slice = try simdjson.stringify(cfg, &stack_buf, .{});

// 2. Allocated serialization:
const heap_json = try simdjson.stringifyAlloc(allocator, cfg, .{
    .emit_null_optional_fields = false, // Omit null fields from output
    .enum_as_string = true,             // Emit "@tagName" for enums
});
defer allocator.free(heap_json);
```

---

### 12. Low-Level Utility Modules

#### Lemire `fast_float` Number Parser (`simdjson.fast_float`)
Parses IEEE-754 single and double precision floats from character buffers at ~74.7 million floats/sec (1.37x faster than standard library scalar routines).
```zig
const res = try simdjson.fast_float.parse("3.141592653589793");
std.debug.print("Float value: {d}\n", .{res.val});
```

#### SIMD UTF-8 Validation (`simdjson.utf8`)
Validates UTF-8 compliance across 64-byte and 128-byte vector registers.
```zig
const is_valid = simdjson.utf8.validate(slice);
```

#### String Unescaping Kernels (`simdjson.common`)
Vectorized shuffle unescaping (`vpshufb` on x86, tbl on ARM) with scalar fallback for Unicode `\uXXXX` sequences and surrogate pairs.
```zig
var out_buf: [512]u8 = undefined;
const unescaped = try simdjson.unescapeString("Hello\\nWorld\\uD83D\\uDE00", &out_buf);
```

#### Visual Diagnostic Formatting (`simdjson.Diagnostic`)
Produces rich compiler-style error diagnostics with 1-based line/column pointers and code snippets.
```zig
var diag = simdjson.Diagnostic.compute(json_buf, error_byte_offset, error.TrailingComma);
std.debug.print("{s}\n", .{diag.format()});
```

---

## Error Handling Reference (`SimdJsonError`)

All functions return strongly-typed errors with human-readable descriptions via `simdjson.errorMessage(err)`:

| Error Variant | Description | Typical Cause |
|---|---|---|
| `error.Empty` | Empty input buffer | Input document is empty or whitespace only. |
| `error.Capacity` | Buffer capacity exceeded | Input index or tape buffer is too small for document. |
| `error.TapeError` | Structural parsing failure | Invalid character encountered outside string. |
| `error.TrailingComma` | Trailing comma violation | Trailing comma in array (`[1, 2,]`) or object (`{"a": 1,}`). |
| `error.IncompleteArrayOrObject` | Unclosed container | Document ended without closing `}` or `]`. |
| `error.TrailingContent` | Trailing garbage | Unexpected characters after document root ends. |
| `error.UnclosedString` | Unclosed string literal | String opened with `"` but never terminated before EOF. |
| `error.UnescapedChars` | Unescaped control byte | Raw ASCII control byte (`< 0x20`) found inside string. |
| `error.NumberError` | Invalid number syntax | Malformed number (e.g. leading zero `0123`, dangling minus `-`). |
| `error.NumberOutOfRange` | Integer overflow/underflow | Value exceeds target representation (e.g. negative to `asUint`). |
| `error.Utf8Error` | Invalid UTF-8 sequence | Malformed or overlong UTF-8 byte sequence. |
| `error.NoSuchField` | Field not found | JSON Pointer or Object query requested missing key. |
| `error.IndexOutOfBounds` | Array index invalid | Index exceeds array length or format is invalid. |
| `error.InvalidJsonPointer` | Syntax error in pointer | Missing leading `/` in JSON Pointer. |
| `error.IncorrectType` | Type mismatch | Attempted `asObject()` on array, `asString()` on number, etc. |

---

## Running Tests & Benchmarks

### Run Full Test Suite (102 Tests)
```bash
zig test src/root.zig
```

### Run Cross-Compilation Verification (ARM64 Linux)
```bash
zig test src/root.zig -target aarch64-linux -mcpu=apple_m1 --test-no-exec
```

### Run ReleaseFast Benchmarks
```bash
zig build run -Doptimize=ReleaseFast
```

---

## Project Structure

```
simdjson-zig/
├── src/
│   ├── root.zig           # Main library entrypoint and exports
│   ├── main.zig           # Benchmark harness (AVX2 / NEON)
│   └── simdjson/
│       ├── stage1.zig     # AVX2 256-bit SIMD structural bitmask indexer
│       ├── stage2.zig     # Zero-allocation compact DOM tape parser
│       ├── tape.zig       # 64-bit compact tape encoders & decoders
│       ├── ondemand.zig   # OnDemand forward-only streaming parser
│       ├── dom.zig        # Immutable Tape DOM (Document, Element, Object, Array)
│       ├── mut_dom.zig    # Mutable in-memory DOM tree
│       ├── jsonpath.zig   # RFC 9535 JSONPath query engine
│       ├── serde.zig      # Struct serialization & deserialization (serde)
│       ├── patch.zig      # RFC 6902 JSON Patch & RFC 7396 Merge Patch
│       ├── stream.zig     # Sliding window streaming parser (ChunkedDocumentStream)
│       ├── fast_float.zig # Lemire IEEE-754 fast float algorithm
│       ├── common.zig     # SIMD vector types & string unescaping kernels
│       ├── utf8.zig       # Lemire SIMD UTF-8 validation
│       └── error.zig      # Visual diagnostic snippet formatting
├── build.zig              # Zig 0.16.0 build configuration
├── build.zig.zon          # Zig package manifest
├── LICENSE                # MIT License
└── README.md              # Documentation & API reference
```

---

## Contributing & Reporting Issues

Contributions, bug reports, and optimizations are warmly welcomed!

### Opening an Issue

If you discover a bug, unexpected panic, memory issue, or parity discrepancy with upstream C++ `simdjson`:
1. Search [existing GitHub issues](https://github.com/sahrahul181/simdjson-zig/issues) to see if it has already been reported.
2. Open a new issue at [github.com/sahrahul181/simdjson-zig/issues](https://github.com/sahrahul181/simdjson-zig/issues) with:
   - **Environment Details**: Operating system, CPU architecture (`x86_64`, `aarch64`), and exact Zig version (`zig version`).
   - **Minimal Reproduction**: Provide a small JSON snippet and the Zig code demonstrating the failure.
   - **Expected vs Actual**: Describe what you expected to happen vs what actually happened (including stack traces or error names).

### Contributing Code & Pull Requests

1. **Fork the Repository**: Create your fork on GitHub.
2. **Create a Feature Branch**:
   ```bash
   git checkout -b feature/my-enhancement
   ```
3. **Write Tests**: Add tests covering new functionality or bug fixes in `src/root.zig` or the relevant submodule in `src/simdjson/`.
4. **Format & Test**:
   ```bash
   # Format source files
   zig fmt src/ build.zig

   # Run test suite
   zig build test --summary all
   ```
5. **Benchmark Integrity**: Ensure that changes do not introduce performance regressions:
   ```bash
   zig build bench -Doptimize=ReleaseFast
   ```
6. **Submit Pull Request**: Push to your fork and submit a PR with a clear description of changes.

---

## Credits & Acknowledgements

This library is a clean-room Zig port and independent implementation deeply inspired by the pioneering work, papers, and software created by **Daniel Lemire**, **Geoff Langdale**, and the `simdjson` community.

### Key Contributions & Research:
- **`simdjson` Engine Architecture**:
  - **Daniel Lemire** (University of Quebec, TELUQ) & **Geoff Langdale**.
  - *Paper*: Geoff Langdale, Daniel Lemire, [Parsing Gigabytes of JSON per Second](https://arxiv.org/abs/1902.08318), *The VLDB Journal* 29 (6), 2020, pp. 1205–1215.
  - *Original C++ Repository*: [github.com/simdjson/simdjson](https://github.com/simdjson/simdjson) (Licensed under Apache-2.0).

- **High-Speed Float Parsing (`fast_float`)**:
  - **Daniel Lemire**.
  - *Paper*: Daniel Lemire, [Number Parsing at a Gigabyte per Second](https://arxiv.org/abs/2101.11408), *Software: Practice and Experience* 51 (8), 2021, pp. 1705–1734.
  - *Original C++ Repository*: [github.com/fastfloat/fast_float](https://github.com/fastfloat/fast_float) (Licensed under Apache-2.0 / MIT).

- **SIMD UTF-8 Validation**:
  - **John Keiser** & **Daniel Lemire**.
  - *Paper*: John Keiser, Daniel Lemire, [Validating UTF-8 In Less Than One Instruction Per Byte](https://arxiv.org/abs/2010.03090), *Software: Practice and Experience* 51 (4), 2021, pp. 690–705.

We express our profound gratitude to the original researchers and authors for publishing their algorithms, benchmarks, and reference implementations openly to the systems programming community.

---

## License

This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for the full license text and attribution notices.
