$files = Get-ChildItem conformance_suite/test_parsing/*.json
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('//! Auto-generated JSONTestSuite conformance test cases.')
$lines.Add('pub const Expectation = enum { must_pass, must_fail, indeterminate };')
$lines.Add('')
$lines.Add('pub const TestCase = struct {')
$lines.Add('    name: []const u8,')
$lines.Add('    data: []const u8,')
$lines.Add('    expected: Expectation,')
$lines.Add('};')
$lines.Add('')
$lines.Add('pub const cases = [_]TestCase{')

foreach ($f in $files) {
    $name = $f.Name
    $expected = if ($name.StartsWith('y_')) {
        '.must_pass'
    } elseif ($name.StartsWith('n_')) {
        '.must_fail'
    } else {
        '.indeterminate'
    }
    $escapedPath = "../conformance_data/" + $name
    $lines.Add("    .{ .name = `"$name`", .data = @embedFile(`"$escapedPath`"), .expected = $expected },")
}

$lines.Add('};')
[System.IO.File]::WriteAllLines('src/simdjson/conformance_cases.zig', $lines)
Write-Output "Generated $($files.Count) test cases in src/simdjson/conformance_cases.zig"
