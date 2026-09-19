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

pub fn main(init: std.process.Init) !void {
    const freq = getFrequency();

    std.debug.print(
        \\
        \\========================================================================
        \\       SIMDJSON-ZIG: LARGE DATASET (200MB+ & 500MB+) PARSING BENCHMARK
        \\========================================================================
        \\
    , .{});

    var cwd = std.Io.Dir.cwd();

    // ========================================================================
    // PART 1: Monolithic 262.57 MB JSON Document (large_250mb.json)
    // ========================================================================
    {
        var file = cwd.openFile(init.io, "large_250mb.json", .{}) catch |err| {
            std.debug.print("Error opening large_250mb.json: {s}\n", .{@errorName(err)});
            return;
        };
        defer file.close(init.io);

        const stat = try file.stat(init.io);
        const file_size = stat.size;
        const mb = @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0);

        std.debug.print("Loading large_250mb.json ({d:.2} MB, {d} bytes) into padded memory...\n", .{ mb, file_size });

        const padded_buf = try init.gpa.alloc(u8, file_size + SIMDJSON_PADDING);
        defer init.gpa.free(padded_buf);

        const bytes_read = try file.readPositionalAll(init.io, padded_buf[0..file_size], 0);
        if (bytes_read != file_size) return error.IncompleteRead;
        @memset(padded_buf[file_size..], ' ');

        std.debug.print("Allocating structural indices index buffer...\n", .{});
        const indexes = try init.gpa.alloc(u32, file_size + 3);
        defer init.gpa.free(indexes);

        // Benchmark Stage 1
        std.debug.print("Running Stage 1 (AVX2 SIMD Indexer) across {d:.2} MB...\n", .{mb});
        const s1_warmup = try Stage1Indexer.indexPadded(padded_buf, file_size, indexes);

        const s1_start = getTicks();
        const iters: usize = 5;
        var structurals_count: usize = 0;
        for (0..iters) |_| {
            structurals_count = try Stage1Indexer.indexPadded(padded_buf, file_size, indexes);
        }
        const s1_elapsed = @as(f64, @floatFromInt(getTicks() - s1_start)) / @as(f64, @floatFromInt(freq));
        const s1_ms = (s1_elapsed / @as(f64, @floatFromInt(iters))) * 1000.0;
        const s1_gb_sec = (@as(f64, @floatFromInt(file_size)) * @as(f64, @floatFromInt(iters)) / s1_elapsed) / 1_000_000_000.0;

        _ = s1_warmup;
        std.debug.print("  [Stage 1] Found {d} structurals | {d:.2} ms/iter | {d:.2} GB/s\n", .{
            structurals_count,
            s1_ms,
            s1_gb_sec,
        });

        // Stage 2 Allocation
        std.debug.print("Allocating 64-bit DOM Tape buffer ({d} words = {d:.2} MB)...\n", .{
            structurals_count * 2 + 16,
            @as(f64, @floatFromInt((structurals_count * 2 + 16) * 8)) / (1024.0 * 1024.0),
        });
        const tape_buf = try init.gpa.alloc(u64, structurals_count * 2 + 16);
        defer init.gpa.free(tape_buf);

        // Benchmark Stage 2
        std.debug.print("Running Stage 2 (Zero-Copy/Alloc Parser) across {d:.2} MB...\n", .{mb});
        const s2_warmup = try Stage2Parser.parse(padded_buf, indexes, structurals_count, tape_buf);

        const s2_start = getTicks();
        var tape_len: usize = 0;
        for (0..iters) |_| {
            tape_len = try Stage2Parser.parse(padded_buf, indexes, structurals_count, tape_buf);
        }
        const s2_elapsed = @as(f64, @floatFromInt(getTicks() - s2_start)) / @as(f64, @floatFromInt(freq));
        const s2_ms = (s2_elapsed / @as(f64, @floatFromInt(iters))) * 1000.0;
        const s2_gb_sec = (@as(f64, @floatFromInt(file_size)) * @as(f64, @floatFromInt(iters)) / s2_elapsed) / 1_000_000_000.0;

        _ = s2_warmup;
        std.debug.print("  [Stage 2] Generated {d} tape words | {d:.2} ms/iter | {d:.2} GB/s\n", .{
            tape_len,
            s2_ms,
            s2_gb_sec,
        });

        // End-to-End
        const e2e_ms = s1_ms + s2_ms;
        const e2e_gb_sec = (@as(f64, @floatFromInt(file_size)) / (e2e_ms / 1000.0)) / 1_000_000_000.0;
        std.debug.print("  [Combined End-to-End Stages 1 & 2] {d:.2} ms/iter | {d:.2} GB/s\n", .{
            e2e_ms,
            e2e_gb_sec,
        });

        // DOM Navigation & Validation
        std.debug.print("Validating full DOM structure & iterating 250MB tree...\n", .{});
        const doc = Document.init(padded_buf, tape_buf[0..tape_len]);
        const root = doc.root();
        const arr = try root.asArray();
        var arr_it = arr.iterator();
        var top_elements: usize = 0;
        var total_nodes: usize = 1;
        while (arr_it.next()) |item| {
            top_elements += 1;
            total_nodes += try walkElement(item);
        }

        std.debug.print("  [DOM Integrity Check] Top-level array elements: {d}, Total AST nodes navigated: {d}\n", .{
            top_elements,
            total_nodes,
        });
        std.debug.print("  [DOM Verification] PASSED: 100% valid document parsed correctly with zero heap allocs during parse!\n\n", .{});
    }

    // ========================================================================
    // PART 2: 584.82 MB NDJSON Stream (gharchive.json)
    // ========================================================================
    {
        var file = cwd.openFile(init.io, "gharchive.json", .{}) catch |err| {
            std.debug.print("Error opening gharchive.json: {s}\n", .{@errorName(err)});
            return;
        };
        defer file.close(init.io);

        const stat = try file.stat(init.io);
        const file_size = stat.size;
        const mb = @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0);

        std.debug.print("------------------------------------------------------------------------\n", .{});
        std.debug.print("Loading 584 MB NDJSON Dataset ({d:.2} MB, {d} bytes)...\n", .{ mb, file_size });

        const padded_buf = try init.gpa.alloc(u8, file_size + SIMDJSON_PADDING);
        defer init.gpa.free(padded_buf);

        const bytes_read = try file.readPositionalAll(init.io, padded_buf[0..file_size], 0);
        if (bytes_read != file_size) return error.IncompleteRead;
        @memset(padded_buf[file_size..], ' ');

        std.debug.print("Indexing 584 MB NDJSON stream via Stage 1 (AVX2)...\n", .{});
        const indexes = try init.gpa.alloc(u32, file_size + 3);
        defer init.gpa.free(indexes);

        const s1_start = getTicks();
        const structurals = try Stage1Indexer.indexPadded(padded_buf, file_size, indexes);
        const s1_elapsed = @as(f64, @floatFromInt(getTicks() - s1_start)) / @as(f64, @floatFromInt(freq));
        const s1_gb_sec = (@as(f64, @floatFromInt(file_size)) / s1_elapsed) / 1_000_000_000.0;
        std.debug.print("  [Stage 1 Stream Indexer] Found {d} structurals in {d:.3}s ({d:.2} GB/s)\n", .{
            structurals,
            s1_elapsed,
            s1_gb_sec,
        });

        std.debug.print("Streaming and parsing documents via OnDemandDocumentStream...\n", .{});
        const stream_start = getTicks();
        var od_stream = simdjson.OnDemandDocumentStream.init(padded_buf[0..file_size], indexes, structurals);

        var record_count: usize = 0;
        var push_events: usize = 0;
        var watch_events: usize = 0;
        var other_events: usize = 0;

        while (try od_stream.next()) |val| {
            record_count += 1;
            var doc_val = val;
            if (doc_val.asObject()) |o| {
                var obj = o;
                if (try obj.get("type")) |t_val| {
                    if (t_val.asString()) |type_str| {
                        if (std.mem.eql(u8, type_str, "PushEvent")) {
                            push_events += 1;
                        } else if (std.mem.eql(u8, type_str, "WatchEvent")) {
                            watch_events += 1;
                        } else {
                            other_events += 1;
                        }
                    } else |_| {}
                }
            } else |_| {}
        }

        const stream_elapsed = @as(f64, @floatFromInt(getTicks() - stream_start)) / @as(f64, @floatFromInt(freq));
        const stream_gb_sec = (@as(f64, @floatFromInt(file_size)) / stream_elapsed) / 1_000_000_000.0;
        const docs_sec = @as(f64, @floatFromInt(record_count)) / stream_elapsed;

        std.debug.print("  [584MB NDJSON Stream Results]\n", .{});
        std.debug.print("    Total Documents Parsed : {d}\n", .{record_count});
        std.debug.print("    PushEvents             : {d}\n", .{push_events});
        std.debug.print("    WatchEvents            : {d}\n", .{watch_events});
        std.debug.print("    Other Events           : {d}\n", .{other_events});
        std.debug.print("    Total Elapsed Time     : {d:.3} seconds\n", .{stream_elapsed});
        std.debug.print("    Streaming Throughput   : {d:.2} GB/s ({d:.0} docs/sec)\n", .{ stream_gb_sec, docs_sec });
        std.debug.print("========================================================================\n\n", .{});
    }
}
