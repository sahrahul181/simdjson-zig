const std = @import("std");
const simdjson = @import("simdjson");
const Stage1Indexer = simdjson.Stage1Indexer;
const Stage2Parser = simdjson.Stage2Parser;
const Document = simdjson.Document;
const SIMDJSON_PADDING = simdjson.SIMDJSON_PADDING;
const Element = simdjson.Element;
const OnDemandDocument = simdjson.OnDemandDocument;
const OnDemandValue = simdjson.Value;

const builtin = @import("builtin");

const win32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(if (builtin.cpu.arch == .x86) .winapi else .c) c_int;
    extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(if (builtin.cpu.arch == .x86) .winapi else .c) c_int;
} else struct {};

fn getTicks() i64 {
    if (builtin.os.tag == .windows) {
        var count: i64 = 0;
        _ = win32.QueryPerformanceCounter(&count);
        return count;
    } else if (builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
    } else {
        return 0;
    }
}

fn getFrequency() i64 {
    if (builtin.os.tag == .windows) {
        var freq: i64 = 0;
        _ = win32.QueryPerformanceFrequency(&freq);
        return freq;
    } else {
        return 1_000_000_000;
    }
}

/// 1. DOM Recursion Walk
fn walkElement(el: Element) !usize {
    var count: usize = 1;
    switch (el.getType()) {
        .object => {
            const obj = try el.asObject();
            var it = obj.iterator();
            while (it.next()) |field| {
                _ = field.key;
                count += try walkElement(field.value);
            }
        },
        .array => {
            const arr = try el.asArray();
            var it = arr.iterator();
            while (it.next()) |child| {
                count += try walkElement(child);
            }
        },
        .string => {
            _ = try el.asString();
        },
        .int64 => {
            _ = try el.asInt();
        },
        .uint64 => {
            _ = try el.asUint();
        },
        .double => {
            _ = try el.asDouble();
        },
        .bool => {
            _ = try el.asBool();
        },
        .null => {},
    }
    return count;
}

/// 2. OnDemand Recursion Walk (Direct stream over Stage 1 indices)
fn walkOnDemand(val: OnDemandValue) !usize {
    var count: usize = 1;
    const c = val.doc.buf[val.doc.indexes[val.doc.cur]];
    switch (c) {
        '{' => {
            var obj = try val.asObject();
            while (try obj.next()) |field| {
                _ = field.key;
                count += try walkOnDemand(field.value);
            }
        },
        '[' => {
            var arr = try val.asArray();
            while (try arr.next()) |child| {
                count += try walkOnDemand(child);
            }
        },
        '"' => {
            _ = try val.asString();
        },
        't', 'f' => {
            _ = try val.asBool();
        },
        else => {
            // Numbers and nulls. Since we are just benchmarking iteration speed,
            // the hardware skip() inherently pushes the cursor forward instantly.
            try val.skip();
        },
    }
    return count;
}

fn benchmarkDataset(
    name: []const u8,
    raw_data: []const u8,
    allocator: std.mem.Allocator,
    freq: i64,
    iters: usize,
) !void {
    const size = raw_data.len;
    const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);

    const padded_buf = try allocator.alloc(u8, size + SIMDJSON_PADDING);
    defer allocator.free(padded_buf);
    @memcpy(padded_buf[0..size], raw_data);
    @memset(padded_buf[size..], ' ');

    const indexes = try allocator.alloc(u32, size + 3);
    defer allocator.free(indexes);

    const structurals = try Stage1Indexer.indexPadded(padded_buf, size, indexes);

    const tape_buf = try allocator.alloc(u64, structurals * 2 + 16);
    defer allocator.free(tape_buf);

    // ------------------------------------------------------------------------
    // 1. Benchmark Stage 1 Standalone
    // ------------------------------------------------------------------------
    for (0..10) |_| {
        _ = try Stage1Indexer.indexPadded(padded_buf, size, indexes);
    }
    const s1_start = getTicks();
    for (0..iters) |_| {
        _ = try Stage1Indexer.indexPadded(padded_buf, size, indexes);
    }
    const s1_end = getTicks();

    const s1_elapsed_s = @as(f64, @floatFromInt(s1_end - s1_start)) / @as(f64, @floatFromInt(freq));
    const s1_ms_per_iter = (s1_elapsed_s / @as(f64, @floatFromInt(iters))) * 1000.0;
    const s1_gb_per_sec = (@as(f64, @floatFromInt(size * iters)) / s1_elapsed_s) / 1_000_000_000.0;

    // ------------------------------------------------------------------------
    // 2. Benchmark Stage 2 Standalone
    // ------------------------------------------------------------------------
    var tape_len: usize = 0;
    for (0..10) |_| {
        tape_len = try Stage2Parser.parse(padded_buf, indexes, structurals, tape_buf);
    }
    const s2_start = getTicks();
    for (0..iters) |_| {
        _ = try Stage2Parser.parse(padded_buf, indexes, structurals, tape_buf);
    }
    const s2_end = getTicks();

    const s2_elapsed_s = @as(f64, @floatFromInt(s2_end - s2_start)) / @as(f64, @floatFromInt(freq));
    const s2_ms_per_iter = (s2_elapsed_s / @as(f64, @floatFromInt(iters))) * 1000.0;
    const s2_gb_per_sec = (@as(f64, @floatFromInt(size * iters)) / s2_elapsed_s) / 1_000_000_000.0;

    // ------------------------------------------------------------------------
    // 3. Benchmark End-to-End Pipeline (Stage 1 + Stage 2 combined)
    // ------------------------------------------------------------------------
    const e2e_start = getTicks();
    for (0..iters) |_| {
        const s_cnt = try Stage1Indexer.indexPadded(padded_buf, size, indexes);
        _ = try Stage2Parser.parse(padded_buf, indexes, s_cnt, tape_buf);
    }
    const e2e_end = getTicks();

    const e2e_elapsed_s = @as(f64, @floatFromInt(e2e_end - e2e_start)) / @as(f64, @floatFromInt(freq));
    const e2e_ms_per_iter = (e2e_elapsed_s / @as(f64, @floatFromInt(iters))) * 1000.0;
    const e2e_gb_per_sec = (@as(f64, @floatFromInt(size * iters)) / e2e_elapsed_s) / 1_000_000_000.0;

    // ------------------------------------------------------------------------
    // 4. Benchmark Full DOM Traversal (Requires Stage 1 + Stage 2)
    // ------------------------------------------------------------------------
    const doc = Document.init(padded_buf, tape_buf[0..tape_len]);
    var dom_nodes: usize = 0;

    for (0..10) |_| {
        dom_nodes = try walkElement(doc.root());
    }

    const dom_start = getTicks();
    for (0..iters) |_| {
        dom_nodes +%= try walkElement(doc.root());
    }
    const dom_end = getTicks();

    const dom_elapsed_s = @as(f64, @floatFromInt(dom_end - dom_start)) / @as(f64, @floatFromInt(freq));
    const dom_ms_per_iter = (dom_elapsed_s / @as(f64, @floatFromInt(iters))) * 1000.0;
    const dom_gb_per_sec = (@as(f64, @floatFromInt(size * iters)) / dom_elapsed_s) / 1_000_000_000.0;

    // ------------------------------------------------------------------------
    // 5. Benchmark OnDemand Full Traversal (Requires Stage 1 ONLY)
    // ------------------------------------------------------------------------
    var od_nodes: usize = 0;
    for (0..10) |_| {
        var od_doc = OnDemandDocument.init(padded_buf, indexes, structurals);
        od_nodes = try walkOnDemand(od_doc.root());
    }

    const od_start = getTicks();
    for (0..iters) |_| {
        var od_doc = OnDemandDocument.init(padded_buf, indexes, structurals);
        od_nodes +%= try walkOnDemand(od_doc.root());
    }
    const od_end = getTicks();

    const od_elapsed_s = @as(f64, @floatFromInt(od_end - od_start)) / @as(f64, @floatFromInt(freq));
    const od_ms_per_iter = (od_elapsed_s / @as(f64, @floatFromInt(iters))) * 1000.0;
    const od_gb_per_sec = (@as(f64, @floatFromInt(size * iters)) / od_elapsed_s) / 1_000_000_000.0;

    // ------------------------------------------------------------------------
    // 6. Benchmark OnDemand TARGETED Query (The 15+ GB/s sweet spot)
    // ------------------------------------------------------------------------
    for (0..10) |_| {
        var od_doc = OnDemandDocument.init(padded_buf, indexes, structurals);
        var root = try od_doc.root().asObject();
        if (try root.get("performance_metrics")) |metrics| {
            _ = metrics;
        }
    }

    const targeted_start = getTicks();
    for (0..iters) |_| {
        var od_doc = OnDemandDocument.init(padded_buf, indexes, structurals);
        var root = try od_doc.root().asObject();

        // Simulating finding a specific field.
        // This forces OnDemand to rapid-skip unrequested blobs.
        if (try root.get("performance_metrics")) |metrics| {
            _ = metrics; // Found it!
        }
    }
    const targeted_end = getTicks();

    const targeted_elapsed_s = @as(f64, @floatFromInt(targeted_end - targeted_start)) / @as(f64, @floatFromInt(freq));
    const targeted_ms_per_iter = (targeted_elapsed_s / @as(f64, @floatFromInt(iters))) * 1000.0;
    const targeted_gb_per_sec = (@as(f64, @floatFromInt(size * iters)) / targeted_elapsed_s) / 1_000_000_000.0;

    // ------------------------------------------------------------------------
    // Print Results
    // ------------------------------------------------------------------------
    std.debug.print(
        \\------------------------------------------------------------------------
        \\Dataset: {s} ({d:.4} MB, {d} bytes)
        \\Structurals: {d} | Tape Words: {d} (64-bit)
        \\------------------------------------------------------------------------
        \\  [Stage 1 (AVX2 SIMD Indexer)] : {d:.4} ms/iter | {d:.2} GB/s
        \\  [Stage 2 (Zero-Copy/Alloc)]   : {d:.4} ms/iter | {d:.2} GB/s
        \\  [Combined End-to-End]        : {d:.4} ms/iter | {d:.2} GB/s
        \\  [DOM Full Tree Walk]         : {d:.4} ms/iter | {d:.2} GB/s
        \\  [OnDemand Full Tree Walk]    : {d:.4} ms/iter | {d:.2} GB/s
        \\  [OnDemand Targeted Query]    : {d:.4} ms/iter | {d:.2} GB/s
        \\
    , .{
        name,           mb,              size,           structurals,    tape_len,
        s1_ms_per_iter, s1_gb_per_sec,   s2_ms_per_iter, s2_gb_per_sec,  e2e_ms_per_iter,
        e2e_gb_per_sec, dom_ms_per_iter, dom_gb_per_sec, od_ms_per_iter, od_gb_per_sec,
        targeted_ms_per_iter, targeted_gb_per_sec, // Added here
    });
}

fn benchmarkNdjsonStream(allocator: std.mem.Allocator, freq: i64) !void {
    const single_record = "{\"timestamp\":1718000000,\"level\":\"info\",\"service\":\"auth_service\",\"user_id\":987654,\"message\":\"user authenticated successfully\",\"duration_ms\":1.42}\n";
    const record_count: usize = 10_000;
    const total_bytes = single_record.len * record_count;
    const mb = @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0);

    const stream_data = try allocator.alloc(u8, total_bytes + SIMDJSON_PADDING);
    defer allocator.free(stream_data);

    for (0..record_count) |i| {
        @memcpy(stream_data[i * single_record.len .. (i + 1) * single_record.len], single_record);
    }
    @memset(stream_data[total_bytes..], ' ');

    const indexes = try allocator.alloc(u32, total_bytes + 3);
    defer allocator.free(indexes);

    const structurals = try Stage1Indexer.indexPadded(stream_data, total_bytes, indexes);

    var tape_buf: [512]u64 = undefined;

    // 1. Benchmark DocumentStream (DOM Tape per document)
    const dom_start = getTicks();
    const dom_iters: usize = 20;
    var total_docs_parsed: usize = 0;

    for (0..dom_iters) |_| {
        var stream = simdjson.DocumentStream.init(stream_data, indexes, structurals, &tape_buf);
        while (try stream.next()) |doc| {
            _ = doc;
            total_docs_parsed += 1;
        }
    }
    const dom_end = getTicks();

    const dom_elapsed_s = @as(f64, @floatFromInt(dom_end - dom_start)) / @as(f64, @floatFromInt(freq));
    const dom_gb_per_sec = (@as(f64, @floatFromInt(total_bytes * dom_iters)) / dom_elapsed_s) / 1_000_000_000.0;
    const dom_docs_per_sec = @as(f64, @floatFromInt(total_docs_parsed)) / dom_elapsed_s;

    // 2. Benchmark OnDemandDocumentStream (Direct stream over Stage 1 indices)
    const od_start = getTicks();
    var od_docs_parsed: usize = 0;

    for (0..dom_iters) |_| {
        var od_stream = simdjson.OnDemandDocumentStream.init(stream_data, indexes, structurals);
        while (try od_stream.next()) |doc_val| {
            var obj = try doc_val.asObject();
            if (try obj.get("user_id")) |uid| {
                _ = uid;
            }
            od_docs_parsed += 1;
        }
    }
    const od_end = getTicks();

    const od_elapsed_s = @as(f64, @floatFromInt(od_end - od_start)) / @as(f64, @floatFromInt(freq));
    const od_gb_per_sec = (@as(f64, @floatFromInt(total_bytes * dom_iters)) / od_elapsed_s) / 1_000_000_000.0;
    const od_docs_per_sec = @as(f64, @floatFromInt(od_docs_parsed)) / od_elapsed_s;

    std.debug.print(
        \\------------------------------------------------------------------------
        \\NDJSON Stream: 10,000 JSON Lines log records ({d:.2} MB, {d} bytes)
        \\------------------------------------------------------------------------
        \\  [DOM DocumentStream]       : {d:.2} GB/s ({d:.0} docs/sec)
        \\  [OnDemand DocumentStream]  : {d:.2} GB/s ({d:.0} docs/sec)
        \\
    , .{ mb, total_bytes, dom_gb_per_sec, dom_docs_per_sec, od_gb_per_sec, od_docs_per_sec });
}

fn benchmarkFastFloat(freq: i64) !void {
    const float_strings = [_][]const u8{
        "3.141592653589793",
        "123.456e7",
        "6.02214076e23",
        "19.99",
        "-0.00012345",
        "1.7976931348623157e308",
        "-123.456e-7",
        "0.0",
        "9876543210.12345",
        "2.718281828459045",
    };

    const iters: usize = 100_000;
    const total_parses: usize = iters * float_strings.len;

    // Warmup
    var dummy: f64 = 0;
    for (0..100) |_| {
        for (float_strings) |s| {
            dummy += try simdjson.fast_float.parse(s);
        }
    }

    // 1. Benchmark fast_float
    const ff_start = getTicks();
    for (0..iters) |_| {
        for (float_strings) |s| {
            dummy += try simdjson.fast_float.parse(s);
        }
    }
    const ff_end = getTicks();
    const ff_elapsed_s = @as(f64, @floatFromInt(ff_end - ff_start)) / @as(f64, @floatFromInt(freq));
    const ff_ns_per_op = (ff_elapsed_s / @as(f64, @floatFromInt(total_parses))) * 1_000_000_000.0;
    const ff_mops = @as(f64, @floatFromInt(total_parses)) / ff_elapsed_s / 1_000_000.0;

    // 2. Benchmark std.fmt.parseFloat
    const std_start = getTicks();
    for (0..iters) |_| {
        for (float_strings) |s| {
            dummy += try std.fmt.parseFloat(f64, s);
        }
    }
    const std_end = getTicks();
    const std_elapsed_s = @as(f64, @floatFromInt(std_end - std_start)) / @as(f64, @floatFromInt(freq));
    const std_ns_per_op = (std_elapsed_s / @as(f64, @floatFromInt(total_parses))) * 1_000_000_000.0;
    const std_mops = @as(f64, @floatFromInt(total_parses)) / std_elapsed_s / 1_000_000.0;

    std.mem.doNotOptimizeAway(dummy);

    std.debug.print(
        \\------------------------------------------------------------------------
        \\Float Parsing: 1,000,000 Floats (Lemire fast_float vs std.fmt.parseFloat)
        \\------------------------------------------------------------------------
        \\  [Lemire fast_float]        : {d:.1} ns/op | {d:.2} M floats/sec
        \\  [std.fmt.parseFloat]       : {d:.1} ns/op | {d:.2} M floats/sec
        \\  [Speedup]                  : {d:.2}x faster
        \\
    , .{ ff_ns_per_op, ff_mops, std_ns_per_op, std_mops, std_ns_per_op / ff_ns_per_op });
}

fn benchmarkSerde(allocator: std.mem.Allocator, freq: i64) !void {
    const UserRole = enum { admin, member, guest };
    const UserRecord = struct {
        id: i64,
        name: []const u8,
        email: []const u8,
        role: UserRole = .member,
        active: bool,
        score: f64,
    };

    const sample_json = "{\"id\":108291,\"name\":\"Alice Henderson\",\"email\":\"alice.h@example.com\",\"role\":\"admin\",\"active\":true,\"score\":99.75}";
    const json_bytes = sample_json.len;
    const iters: usize = 20_000;

    // Warmup
    for (0..100) |_| {
        var p = try simdjson.parseFromSlice(UserRecord, allocator, sample_json, .{});
        p.deinit();
    }

    // 1. Benchmark simdjson Deserialization
    const s_start = getTicks();
    var dummy_id: i64 = 0;
    for (0..iters) |_| {
        var p = try simdjson.parseFromSlice(UserRecord, allocator, sample_json, .{});
        dummy_id +%= p.value.id;
        p.deinit();
    }
    const s_end = getTicks();
    const s_elapsed_s = @as(f64, @floatFromInt(s_end - s_start)) / @as(f64, @floatFromInt(freq));
    const s_ns_per_op = (s_elapsed_s / @as(f64, @floatFromInt(iters))) * 1_000_000_000.0;
    const s_ops_sec = @as(f64, @floatFromInt(iters)) / s_elapsed_s;
    const s_mb_sec = (@as(f64, @floatFromInt(json_bytes * iters)) / s_elapsed_s) / (1024.0 * 1024.0);

    // 2. Benchmark simdjson Zero-Copy Deserialization (Zero Heap Allocations)
    const zc_start = getTicks();
    var zc_dummy_id: i64 = 0;
    for (0..iters) |_| {
        const u = try simdjson.parseFromSliceLeaky(UserRecord, allocator, sample_json, .{ .zero_copy_strings = true });
        zc_dummy_id +%= u.id;
    }
    const zc_end = getTicks();
    const zc_elapsed_s = @as(f64, @floatFromInt(zc_end - zc_start)) / @as(f64, @floatFromInt(freq));
    const zc_ns_per_op = (zc_elapsed_s / @as(f64, @floatFromInt(iters))) * 1_000_000_000.0;
    const zc_ops_sec = @as(f64, @floatFromInt(iters)) / zc_elapsed_s;
    const zc_mb_sec = (@as(f64, @floatFromInt(json_bytes * iters)) / zc_elapsed_s) / (1024.0 * 1024.0);

    // 3. Benchmark std.json Deserialization
    const std_start = getTicks();
    var std_dummy_id: i64 = 0;
    for (0..iters) |_| {
        var p = try std.json.parseFromSlice(UserRecord, allocator, sample_json, .{});
        std_dummy_id +%= p.value.id;
        p.deinit();
    }
    const std_end = getTicks();
    const std_elapsed_s = @as(f64, @floatFromInt(std_end - std_start)) / @as(f64, @floatFromInt(freq));
    const std_ns_per_op = (std_elapsed_s / @as(f64, @floatFromInt(iters))) * 1_000_000_000.0;
    const std_ops_sec = @as(f64, @floatFromInt(iters)) / std_elapsed_s;
    const std_mb_sec = (@as(f64, @floatFromInt(json_bytes * iters)) / std_elapsed_s) / (1024.0 * 1024.0);

    // 4. Benchmark Serialization
    const user_instance = UserRecord{
        .id = 108291,
        .name = "Alice Henderson",
        .email = "alice.h@example.com",
        .role = .admin,
        .active = true,
        .score = 99.75,
    };

    const ser_iters: usize = 50_000;
    var stack_buf: [256]u8 = undefined;

    // simdjson stack stringify
    const ser_s_start = getTicks();
    var total_bytes: usize = 0;
    for (0..ser_iters) |_| {
        const out = try simdjson.stringify(user_instance, &stack_buf, .{});
        total_bytes +%= out.len;
    }
    const ser_s_end = getTicks();
    const ser_s_elapsed_s = @as(f64, @floatFromInt(ser_s_end - ser_s_start)) / @as(f64, @floatFromInt(freq));
    const ser_s_ns_per_op = (ser_s_elapsed_s / @as(f64, @floatFromInt(ser_iters))) * 1_000_000_000.0;
    const ser_s_ops_sec = @as(f64, @floatFromInt(ser_iters)) / ser_s_elapsed_s;
    const ser_s_mb_sec = (@as(f64, @floatFromInt(json_bytes * ser_iters)) / ser_s_elapsed_s) / (1024.0 * 1024.0);

    // std.json stringify via allocPrint
    const ser_std_start = getTicks();
    for (0..ser_iters) |_| {
        const s = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(user_instance, .{})});
        total_bytes +%= s.len;
        allocator.free(s);
    }
    const ser_std_end = getTicks();
    const ser_std_elapsed_s = @as(f64, @floatFromInt(ser_std_end - ser_std_start)) / @as(f64, @floatFromInt(freq));
    const ser_std_ns_per_op = (ser_std_elapsed_s / @as(f64, @floatFromInt(ser_iters))) * 1_000_000_000.0;
    const ser_std_ops_sec = @as(f64, @floatFromInt(ser_iters)) / ser_std_elapsed_s;
    const ser_std_mb_sec = (@as(f64, @floatFromInt(json_bytes * ser_iters)) / ser_std_elapsed_s) / (1024.0 * 1024.0);

    std.mem.doNotOptimizeAway(dummy_id);
    std.mem.doNotOptimizeAway(zc_dummy_id);
    std.mem.doNotOptimizeAway(std_dummy_id);
    std.mem.doNotOptimizeAway(total_bytes);

    std.debug.print(
        \\------------------------------------------------------------------------
        \\Struct Serde Benchmark: UserRecord ({d} bytes/struct)
        \\------------------------------------------------------------------------
        \\  [Deserialization]
        \\    simdjson.parseFromSlice (Arena)     : {d:.1} ns/op | {d:.2} MB/s ({d:.0} structs/sec)
        \\    simdjson.parseFromSlice (Zero-Copy) : {d:.1} ns/op | {d:.2} MB/s ({d:.0} structs/sec)
        \\    std.json.parseFromSlice             : {d:.1} ns/op | {d:.2} MB/s ({d:.0} structs/sec)
        \\    Speedup (Zero-Copy vs std.json)     : {d:.2}x faster
        \\  [Serialization]
        \\    simdjson.stringify (stack buf)      : {d:.1} ns/op | {d:.2} MB/s ({d:.0} structs/sec)
        \\    std.json.fmt                        : {d:.1} ns/op | {d:.2} MB/s ({d:.0} structs/sec)
        \\    Speedup                             : {d:.2}x faster
        \\
    , .{
        json_bytes,
        s_ns_per_op, s_mb_sec, s_ops_sec,
        zc_ns_per_op, zc_mb_sec, zc_ops_sec,
        std_ns_per_op, std_mb_sec, std_ops_sec,
        std_ns_per_op / zc_ns_per_op,
        ser_s_ns_per_op, ser_s_mb_sec, ser_s_ops_sec,
        ser_std_ns_per_op, ser_std_mb_sec, ser_std_ops_sec,
        ser_std_ns_per_op / ser_s_ns_per_op,
    });
}

pub fn main(init: std.process.Init) !void {
    const twitter_data = @embedFile("data/twitter.json");
    const citm_data = @embedFile("data/citm_catalog.json");

    const freq = getFrequency();

    std.debug.print(
        \\
        \\========================================================================
        \\       SIMDJSON ZIG BENCHMARK - ZERO COPY / ZERO ALLOC STAGES 1 & 2     
        \\========================================================================
        \\
        \\
    , .{});

    try benchmarkDataset("twitter.json", twitter_data, init.gpa, freq, 2000);
    try benchmarkDataset("citm_catalog.json", citm_data, init.gpa, freq, 1000);
    try benchmarkNdjsonStream(init.gpa, freq);
    try benchmarkFastFloat(freq);
    try benchmarkSerde(init.gpa, freq);

    std.debug.print("========================================================================\n\n", .{});
}
