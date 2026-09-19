const std = @import("std");
const dom = @import("dom.zig");
const Element = dom.Element;
const Document = dom.Document;
const Type = dom.Type;
const common = @import("common.zig");

pub const JsonPathError = error{
    InvalidJsonPath,
    UnexpectedToken,
    UnterminatedString,
    UnterminatedBracket,
    UnterminatedFilter,
    InvalidNumber,
    InvalidEscape,
    OutOfMemory,
    IncorrectType,
    TapeError,
};

pub const CompareOp = enum {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
};

pub const SliceSelector = struct {
    start: ?i64 = null,
    end: ?i64 = null,
    step: ?i64 = null,
};

pub const Selector = union(enum) {
    name: []const u8,
    wildcard: void,
    index: i64,
    slice: SliceSelector,
    filter: FilterExpr,
};

pub const Segment = struct {
    is_descendant: bool = false,
    selectors: []const Selector,
};

pub const PathQuery = struct {
    is_root: bool, // true if $, false if @
    segments: []const Segment,
};

pub const FilterOperand = union(enum) {
    literal_string: []const u8,
    literal_number: f64,
    literal_bool: bool,
    literal_null: void,
    path: PathQuery,
    func_length: PathQuery,
    func_count: PathQuery,
};

pub const FilterExpr = union(enum) {
    comparison: struct {
        left: FilterOperand,
        op: CompareOp,
        right: FilterOperand,
    },
    test_expr: FilterOperand,
    logical_not: *FilterExpr,
    logical_and: struct {
        left: *FilterExpr,
        right: *FilterExpr,
    },
    logical_or: struct {
        left: *FilterExpr,
        right: *FilterExpr,
    },
};

const TokenType = enum {
    root, // $
    current, // @
    dot, // .
    dot_dot, // ..
    star, // *
    lbracket, // [
    rbracket, // ]
    lparen, // (
    rparen, // )
    comma, // ,
    colon, // :
    question, // ?
    bang, // !
    and_and, // &&
    or_or, // ||
    eq, // ==
    ne, // !=
    le, // <=
    ge, // >=
    lt, // <
    gt, // >
    identifier,
    string_lit,
    number_lit,
    bool_lit,
    null_lit,
    eof,
};

const Token = struct {
    token_type: TokenType,
    str: []const u8 = "",
    number: f64 = 0,
    boolean: bool = false,
};

const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,

    fn init(src: []const u8, arena: std.mem.Allocator) Lexer {
        return .{
            .src = src,
            .pos = 0,
            .arena = arena,
        };
    }

    fn peekChar(self: *Lexer) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c >= 128;
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c >= 128;
    }

    fn nextToken(self: *Lexer) JsonPathError!Token {
        self.skipWhitespace();
        if (self.pos >= self.src.len) {
            return Token{ .token_type = .eof };
        }

        const c = self.src[self.pos];

        if (c == '$') {
            self.pos += 1;
            return Token{ .token_type = .root, .str = "$" };
        }
        if (c == '@') {
            self.pos += 1;
            return Token{ .token_type = .current, .str = "@" };
        }
        if (c == '.') {
            if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '.') {
                self.pos += 2;
                return Token{ .token_type = .dot_dot, .str = ".." };
            }
            self.pos += 1;
            return Token{ .token_type = .dot, .str = "." };
        }
        if (c == '*') {
            self.pos += 1;
            return Token{ .token_type = .star, .str = "*" };
        }
        if (c == '[') {
            self.pos += 1;
            return Token{ .token_type = .lbracket, .str = "[" };
        }
        if (c == ']') {
            self.pos += 1;
            return Token{ .token_type = .rbracket, .str = "]" };
        }
        if (c == '(') {
            self.pos += 1;
            return Token{ .token_type = .lparen, .str = "(" };
        }
        if (c == ')') {
            self.pos += 1;
            return Token{ .token_type = .rparen, .str = ")" };
        }
        if (c == ',') {
            self.pos += 1;
            return Token{ .token_type = .comma, .str = "," };
        }
        if (c == ':') {
            self.pos += 1;
            return Token{ .token_type = .colon, .str = ":" };
        }
        if (c == '?') {
            self.pos += 1;
            return Token{ .token_type = .question, .str = "?" };
        }
        if (c == '!') {
            if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                self.pos += 2;
                return Token{ .token_type = .ne, .str = "!=" };
            }
            self.pos += 1;
            return Token{ .token_type = .bang, .str = "!" };
        }
        if (c == '&') {
            if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '&') {
                self.pos += 2;
                return Token{ .token_type = .and_and, .str = "&&" };
            }
            return error.UnexpectedToken;
        }
        if (c == '|') {
            if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '|') {
                self.pos += 2;
                return Token{ .token_type = .or_or, .str = "||" };
            }
            return error.UnexpectedToken;
        }
        if (c == '=') {
            if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                self.pos += 2;
                return Token{ .token_type = .eq, .str = "==" };
            }
            return error.UnexpectedToken;
        }
        if (c == '<') {
            if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                self.pos += 2;
                return Token{ .token_type = .le, .str = "<=" };
            }
            self.pos += 1;
            return Token{ .token_type = .lt, .str = "<" };
        }
        if (c == '>') {
            if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                self.pos += 2;
                return Token{ .token_type = .ge, .str = ">=" };
            }
            self.pos += 1;
            return Token{ .token_type = .gt, .str = ">" };
        }

        // Strings: '...' or "..."
        if (c == '\'' or c == '"') {
            const quote = c;
            self.pos += 1;
            const start_content = self.pos;
            var has_escape = false;

            while (self.pos < self.src.len) {
                const sc = self.src[self.pos];
                if (sc == '\\') {
                    has_escape = true;
                    self.pos += 1;
                    if (self.pos >= self.src.len) return error.UnterminatedString;
                    self.pos += 1;
                } else if (sc == quote) {
                    const raw_str = self.src[start_content..self.pos];
                    self.pos += 1; // skip quote

                    const unescaped = if (has_escape)
                        try unescapeStringLiteral(self.arena, raw_str, quote)
                    else
                        raw_str;

                    return Token{
                        .token_type = .string_lit,
                        .str = unescaped,
                    };
                } else {
                    self.pos += 1;
                }
            }
            return error.UnterminatedString;
        }

        // Numbers: e.g. 10, -5, 3.14, 1e4
        if (std.ascii.isDigit(c) or (c == '-' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1]))) {
            const start = self.pos;
            if (c == '-') self.pos += 1;

            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
                self.pos += 1;
            }
            if (self.pos < self.src.len and self.src[self.pos] == '.') {
                if (self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1])) {
                    self.pos += 1; // dot
                    while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
                        self.pos += 1;
                    }
                }
            }
            if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
                self.pos += 1;
                if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) {
                    self.pos += 1;
                }
                while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
                    self.pos += 1;
                }
            }

            const num_str = self.src[start..self.pos];
            const num = std.fmt.parseFloat(f64, num_str) catch return error.InvalidNumber;
            return Token{
                .token_type = .number_lit,
                .str = num_str,
                .number = num,
            };
        }

        // Identifiers and keywords (true, false, null)
        if (isIdentStart(c)) {
            const start = self.pos;
            while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) {
                self.pos += 1;
            }
            const ident = self.src[start..self.pos];
            if (std.mem.eql(u8, ident, "true")) {
                return Token{ .token_type = .bool_lit, .str = ident, .boolean = true };
            }
            if (std.mem.eql(u8, ident, "false")) {
                return Token{ .token_type = .bool_lit, .str = ident, .boolean = false };
            }
            if (std.mem.eql(u8, ident, "null")) {
                return Token{ .token_type = .null_lit, .str = ident };
            }
            return Token{
                .token_type = .identifier,
                .str = ident,
            };
        }

        return error.UnexpectedToken;
    }
};

fn unescapeStringLiteral(allocator: std.mem.Allocator, raw: []const u8, quote_char: u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                '\'', '"' => |q| {
                    try out.append(allocator, q);
                    i += 1;
                },
                '\\' => {
                    try out.append(allocator, '\\');
                    i += 1;
                },
                '/' => {
                    try out.append(allocator, '/');
                    i += 1;
                },
                'b' => {
                    try out.append(allocator, 0x08);
                    i += 1;
                },
                'f' => {
                    try out.append(allocator, 0x0c);
                    i += 1;
                },
                'n' => {
                    try out.append(allocator, '\n');
                    i += 1;
                },
                'r' => {
                    try out.append(allocator, '\r');
                    i += 1;
                },
                't' => {
                    try out.append(allocator, '\t');
                    i += 1;
                },
                'u' => {
                    if (i + 4 < raw.len) {
                        const hex = raw[i + 1 .. i + 5];
                        const codepoint = common.decodeHex4(hex) catch return error.InvalidEscape;
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(@intCast(codepoint), &utf8_buf) catch return error.InvalidEscape;
                        try out.appendSlice(allocator, utf8_buf[0..len]);
                        i += 5;
                    } else {
                        return error.InvalidEscape;
                    }
                },
                else => {
                    if (raw[i] == quote_char) {
                        try out.append(allocator, quote_char);
                    } else {
                        try out.append(allocator, raw[i]);
                    }
                    i += 1;
                },
            }
        } else {
            try out.append(allocator, raw[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const Parser = struct {
    lexer: Lexer,
    curr_token: Token,
    peek_token: Token,
    arena: std.mem.Allocator,

    pub fn init(src: []const u8, arena: std.mem.Allocator) !Parser {
        var l = Lexer.init(src, arena);
        const t1 = try l.nextToken();
        const t2 = try l.nextToken();
        return Parser{
            .lexer = l,
            .curr_token = t1,
            .peek_token = t2,
            .arena = arena,
        };
    }

    fn advance(self: *Parser) !void {
        self.curr_token = self.peek_token;
        self.peek_token = try self.lexer.nextToken();
    }

    fn match(self: *Parser, tt: TokenType) !bool {
        if (self.curr_token.token_type == tt) {
            try self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, tt: TokenType) !Token {
        if (self.curr_token.token_type != tt) {
            return error.UnexpectedToken;
        }
        const tok = self.curr_token;
        try self.advance();
        return tok;
    }

    pub fn parseQuery(self: *Parser) !PathQuery {
        var is_root = true;
        if (self.curr_token.token_type == .root) {
            is_root = true;
            try self.advance();
        } else if (self.curr_token.token_type == .current) {
            is_root = false;
            try self.advance();
        } else {
            // If query starts without $ or @, default to root query
            is_root = true;
        }

        var segments: std.ArrayListUnmanaged(Segment) = .empty;

        while (self.curr_token.token_type != .eof and
            self.curr_token.token_type != .rbracket and
            self.curr_token.token_type != .rparen and
            self.curr_token.token_type != .comma and
            self.curr_token.token_type != .eq and
            self.curr_token.token_type != .ne and
            self.curr_token.token_type != .lt and
            self.curr_token.token_type != .le and
            self.curr_token.token_type != .gt and
            self.curr_token.token_type != .ge and
            self.curr_token.token_type != .and_and and
            self.curr_token.token_type != .or_or)
        {
            if (try self.match(.dot_dot)) {
                // Descendant segment: ..
                const seg = try self.parseDescendantSegment();
                try segments.append(self.arena, seg);
            } else if (try self.match(.dot)) {
                // Child dot segment: .name or .*
                const seg = try self.parseDotSegment();
                try segments.append(self.arena, seg);
            } else if (self.curr_token.token_type == .lbracket) {
                // Bracketed segment: [...]
                const seg = try self.parseBracketSegment(false);
                try segments.append(self.arena, seg);
            } else {
                break;
            }
        }

        return PathQuery{
            .is_root = is_root,
            .segments = try segments.toOwnedSlice(self.arena),
        };
    }

    fn parseDotSegment(self: *Parser) !Segment {
        if (try self.match(.star)) {
            const selectors = try self.arena.alloc(Selector, 1);
            selectors[0] = .wildcard;
            return Segment{ .is_descendant = false, .selectors = selectors };
        }

        const id_tok = try self.expect(.identifier);
        const selectors = try self.arena.alloc(Selector, 1);
        selectors[0] = Selector{ .name = id_tok.str };
        return Segment{ .is_descendant = false, .selectors = selectors };
    }

    fn parseDescendantSegment(self: *Parser) !Segment {
        if (try self.match(.star)) {
            const selectors = try self.arena.alloc(Selector, 1);
            selectors[0] = .wildcard;
            return Segment{ .is_descendant = true, .selectors = selectors };
        }

        if (self.curr_token.token_type == .identifier) {
            const id_tok = try self.expect(.identifier);
            const selectors = try self.arena.alloc(Selector, 1);
            selectors[0] = Selector{ .name = id_tok.str };
            return Segment{ .is_descendant = true, .selectors = selectors };
        }

        if (self.curr_token.token_type == .lbracket) {
            return try self.parseBracketSegment(true);
        }

        return error.UnexpectedToken;
    }

    fn parseBracketSegment(self: *Parser, is_descendant: bool) !Segment {
        _ = try self.expect(.lbracket);

        var selectors: std.ArrayListUnmanaged(Selector) = .empty;

        while (true) {
            const sel = try self.parseSelectorInBracket();
            try selectors.append(self.arena, sel);

            if (try self.match(.comma)) {
                continue;
            }
            break;
        }

        _ = try self.expect(.rbracket);

        return Segment{
            .is_descendant = is_descendant,
            .selectors = try selectors.toOwnedSlice(self.arena),
        };
    }

    fn parseSelectorInBracket(self: *Parser) !Selector {
        // Wildcard [*]
        if (try self.match(.star)) {
            return .wildcard;
        }

        // Filter [?(...)]
        if (try self.match(.question)) {
            _ = try self.expect(.lparen);
            const expr = try self.parseFilterLogicalOr();
            _ = try self.expect(.rparen);
            return Selector{ .filter = expr };
        }

        // Quoted string name: ['field'] or ["field"]
        if (self.curr_token.token_type == .string_lit) {
            const s = self.curr_token.str;
            try self.advance();
            return Selector{ .name = s };
        }

        // Slice starting with ':' (e.g. [:2] or [::2])
        if (self.curr_token.token_type == .colon) {
            try self.advance();
            return try self.parseSliceRest(null);
        }

        // Number: could be Index [0] or Slice [0:2]
        if (self.curr_token.token_type == .number_lit) {
            const num: i64 = @intFromFloat(self.curr_token.number);
            try self.advance();

            if (try self.match(.colon)) {
                return try self.parseSliceRest(num);
            } else {
                return Selector{ .index = num };
            }
        }

        return error.UnexpectedToken;
    }

    fn parseSliceRest(self: *Parser, start: ?i64) !Selector {
        var end: ?i64 = null;
        var step: ?i64 = null;

        if (self.curr_token.token_type == .number_lit) {
            end = @intFromFloat(self.curr_token.number);
            try self.advance();
        }

        if (try self.match(.colon)) {
            if (self.curr_token.token_type == .number_lit) {
                step = @intFromFloat(self.curr_token.number);
                try self.advance();
            }
        }

        return Selector{
            .slice = SliceSelector{
                .start = start,
                .end = end,
                .step = step,
            },
        };
    }

    // Filter expressions: Logical OR (||)
    fn parseFilterLogicalOr(self: *Parser) JsonPathError!FilterExpr {
        var left = try self.parseFilterLogicalAnd();

        while (try self.match(.or_or)) {
            const right = try self.parseFilterLogicalAnd();
            const left_ptr = try self.arena.create(FilterExpr);
            left_ptr.* = left;
            const right_ptr = try self.arena.create(FilterExpr);
            right_ptr.* = right;
            left = FilterExpr{
                .logical_or = .{
                    .left = left_ptr,
                    .right = right_ptr,
                },
            };
        }

        return left;
    }

    // Logical AND (&&)
    fn parseFilterLogicalAnd(self: *Parser) JsonPathError!FilterExpr {
        var left = try self.parseFilterUnary();

        while (try self.match(.and_and)) {
            const right = try self.parseFilterUnary();
            const left_ptr = try self.arena.create(FilterExpr);
            left_ptr.* = left;
            const right_ptr = try self.arena.create(FilterExpr);
            right_ptr.* = right;
            left = FilterExpr{
                .logical_and = .{
                    .left = left_ptr,
                    .right = right_ptr,
                },
            };
        }

        return left;
    }

    // Unary NOT (!)
    fn parseFilterUnary(self: *Parser) JsonPathError!FilterExpr {
        if (try self.match(.bang)) {
            const sub = try self.parseFilterUnary();
            const sub_ptr = try self.arena.create(FilterExpr);
            sub_ptr.* = sub;
            return FilterExpr{ .logical_not = sub_ptr };
        }

        return try self.parseFilterPrimary();
    }

    // Primary: Parenthesized expr ( ... ) or Comparison / Test
    fn parseFilterPrimary(self: *Parser) JsonPathError!FilterExpr {
        if (try self.match(.lparen)) {
            const expr = try self.parseFilterLogicalOr();
            _ = try self.expect(.rparen);
            return expr;
        }

        const left_op = try self.parseFilterOperand();

        // Check for comparison operator
        var comp_op: ?CompareOp = null;
        if (try self.match(.eq)) {
            comp_op = .eq;
        } else if (try self.match(.ne)) {
            comp_op = .ne;
        } else if (try self.match(.lt)) {
            comp_op = .lt;
        } else if (try self.match(.le)) {
            comp_op = .le;
        } else if (try self.match(.gt)) {
            comp_op = .gt;
        } else if (try self.match(.ge)) {
            comp_op = .ge;
        }

        if (comp_op) |op| {
            const right_op = try self.parseFilterOperand();
            return FilterExpr{
                .comparison = .{
                    .left = left_op,
                    .op = op,
                    .right = right_op,
                },
            };
        } else {
            // Standalone path/value test (e.g. [?(@.isbn)])
            return FilterExpr{
                .test_expr = left_op,
            };
        }
    }

    fn parseFilterOperand(self: *Parser) JsonPathError!FilterOperand {
        // String literal
        if (self.curr_token.token_type == .string_lit) {
            const s = self.curr_token.str;
            try self.advance();
            return FilterOperand{ .literal_string = s };
        }

        // Number literal
        if (self.curr_token.token_type == .number_lit) {
            const n = self.curr_token.number;
            try self.advance();
            return FilterOperand{ .literal_number = n };
        }

        // Boolean literal
        if (self.curr_token.token_type == .bool_lit) {
            const b = self.curr_token.boolean;
            try self.advance();
            return FilterOperand{ .literal_bool = b };
        }

        // Null literal
        if (self.curr_token.token_type == .null_lit) {
            try self.advance();
            return .literal_null;
        }

        // Function: length(path) or count(path)
        if (self.curr_token.token_type == .identifier) {
            if (std.mem.eql(u8, self.curr_token.str, "length") and self.peek_token.token_type == .lparen) {
                try self.advance(); // consume 'length'
                _ = try self.expect(.lparen);
                const path = try self.parseQuery();
                _ = try self.expect(.rparen);
                return FilterOperand{ .func_length = path };
            } else if (std.mem.eql(u8, self.curr_token.str, "count") and self.peek_token.token_type == .lparen) {
                try self.advance(); // consume 'count'
                _ = try self.expect(.lparen);
                const path = try self.parseQuery();
                _ = try self.expect(.rparen);
                return FilterOperand{ .func_count = path };
            }
        }

        // Path starting with @ or $
        if (self.curr_token.token_type == .current or self.curr_token.token_type == .root) {
            const path = try self.parseQuery();
            return FilterOperand{ .path = path };
        }

        return error.UnexpectedToken;
    }
};

pub const JsonPath = struct {
    arena: std.heap.ArenaAllocator,
    query: PathQuery,

    pub fn compile(allocator: std.mem.Allocator, query_str: []const u8) !JsonPath {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var parser = try Parser.init(query_str, arena.allocator());
        const q = try parser.parseQuery();

        return JsonPath{
            .arena = arena,
            .query = q,
        };
    }

    pub fn deinit(self: *JsonPath) void {
        self.arena.deinit();
    }

    pub fn eval(self: JsonPath, root: Element, allocator: std.mem.Allocator) ![]Element {
        return evaluateQuery(self.query, root, root, allocator);
    }

    pub fn evalFirst(self: JsonPath, root: Element, allocator: std.mem.Allocator) !?Element {
        const results = try self.eval(root, allocator);
        defer allocator.free(results);
        if (results.len == 0) return null;
        return results[0];
    }
};

/// Evaluates a JSONPath query directly on an Element.
pub fn query(root: Element, allocator: std.mem.Allocator, query_str: []const u8) ![]Element {
    var jp = try JsonPath.compile(allocator, query_str);
    defer jp.deinit();
    return jp.eval(root, allocator);
}

/// Evaluates a JSONPath query directly on an Element and returns the first matching Element, or null.
pub fn queryFirst(root: Element, allocator: std.mem.Allocator, query_str: []const u8) !?Element {
    var jp = try JsonPath.compile(allocator, query_str);
    defer jp.deinit();
    return jp.evalFirst(root, allocator);
}

fn normalizeRoot(el: Element) Element {
    if (el.tag() == .ROOT) {
        return Element{ .doc = el.doc, .tape_idx = 1 };
    }
    return el;
}

fn collectDescendants(node: Element, list: *std.ArrayListUnmanaged(Element), allocator: std.mem.Allocator) !void {
    try list.append(allocator, node);
    switch (node.getType()) {
        .object => {
            if (node.asObject()) |obj| {
                var it = obj.iterator();
                while (it.next()) |field| {
                    try collectDescendants(field.value, list, allocator);
                }
            } else |_| {}
        },
        .array => {
            if (node.asArray()) |arr| {
                var it = arr.iterator();
                while (it.next()) |item| {
                    try collectDescendants(item, list, allocator);
                }
            } else |_| {}
        },
        else => {},
    }
}

pub fn evaluateQuery(
    q: PathQuery,
    current_node: Element,
    root_node: Element,
    allocator: std.mem.Allocator,
) ![]Element {
    const actual_root = normalizeRoot(root_node);
    const actual_current = normalizeRoot(current_node);

    var current_list: std.ArrayListUnmanaged(Element) = .empty;
    defer current_list.deinit(allocator);

    const start_node = if (q.is_root) actual_root else actual_current;
    try current_list.append(allocator, start_node);

    var next_list: std.ArrayListUnmanaged(Element) = .empty;
    defer next_list.deinit(allocator);

    for (q.segments) |seg| {
        next_list.clearRetainingCapacity();

        // Candidates to evaluate selectors against
        var candidates: std.ArrayListUnmanaged(Element) = .empty;
        defer candidates.deinit(allocator);

        if (seg.is_descendant) {
            for (current_list.items) |node| {
                try collectDescendants(node, &candidates, allocator);
            }
        } else {
            try candidates.appendSlice(allocator, current_list.items);
        }

        for (candidates.items) |candidate| {
            for (seg.selectors) |sel| {
                switch (sel) {
                    .name => |key| {
                        if (candidate.getType() == .object) {
                            if (candidate.asObject()) |obj| {
                                if (obj.get(key)) |val| {
                                    try next_list.append(allocator, val);
                                }
                            } else |_| {}
                        }
                    },
                    .wildcard => {
                        if (candidate.getType() == .object) {
                            if (candidate.asObject()) |obj| {
                                var it = obj.iterator();
                                while (it.next()) |field| {
                                    try next_list.append(allocator, field.value);
                                }
                            } else |_| {}
                        } else if (candidate.getType() == .array) {
                            if (candidate.asArray()) |arr| {
                                var it = arr.iterator();
                                while (it.next()) |item| {
                                    try next_list.append(allocator, item);
                                }
                            } else |_| {}
                        }
                    },
                    .index => |idx| {
                        if (candidate.getType() == .array) {
                            if (candidate.asArray()) |arr| {
                                const arr_len: i64 = @intCast(arr.len());
                                const norm_idx = if (idx < 0) arr_len + idx else idx;
                                if (norm_idx >= 0 and norm_idx < arr_len) {
                                    if (arr.at(@intCast(norm_idx))) |item| {
                                        try next_list.append(allocator, item);
                                    }
                                }
                            } else |_| {}
                        }
                    },
                    .slice => |slice| {
                        if (candidate.getType() == .array) {
                            if (candidate.asArray()) |arr| {
                                const len: i64 = @intCast(arr.len());
                                const step = slice.step orelse 1;
                                if (step != 0) {
                                    if (step > 0) {
                                        var start = slice.start orelse 0;
                                        var end = slice.end orelse len;
                                        if (start < 0) start = @max(len + start, 0) else start = @min(start, len);
                                        if (end < 0) end = @max(len + end, 0) else end = @min(end, len);

                                        var it = arr.iterator();
                                        var i: i64 = 0;
                                        while (it.next()) |item| : (i += 1) {
                                            if (i >= start and i < end and @mod(i - start, step) == 0) {
                                                try next_list.append(allocator, item);
                                            }
                                        }
                                    } else {
                                        var start = slice.start orelse (len - 1);
                                        var end = slice.end orelse (-len - 1);
                                        if (start < 0) start = @max(len + start, -1) else start = @min(start, len - 1);
                                        if (end < 0) end = @max(len + end, -1) else end = @min(end, len - 1);

                                        var i = start;
                                        while (i > end) : (i += step) {
                                            if (arr.at(@intCast(i))) |item| {
                                                try next_list.append(allocator, item);
                                            }
                                        }
                                    }
                                }
                            } else |_| {}
                        }
                    },
                    .filter => |filter_expr| {
                        if (candidate.getType() == .array) {
                            if (candidate.asArray()) |arr| {
                                var it = arr.iterator();
                                while (it.next()) |item| {
                                    if (try evaluateFilter(item, actual_root, filter_expr, allocator)) {
                                        try next_list.append(allocator, item);
                                    }
                                }
                            } else |_| {}
                        } else if (candidate.getType() == .object) {
                            if (candidate.asObject()) |obj| {
                                var it = obj.iterator();
                                while (it.next()) |field| {
                                    if (try evaluateFilter(field.value, actual_root, filter_expr, allocator)) {
                                        try next_list.append(allocator, field.value);
                                    }
                                }
                            } else |_| {}
                        }
                    },
                }
            }
        }

        current_list.clearRetainingCapacity();
        try current_list.appendSlice(allocator, next_list.items);
    }

    return current_list.toOwnedSlice(allocator);
}

const FilterVal = union(enum) {
    nothing,
    string: []const u8,
    number: f64,
    boolean: bool,
    null_val: void,
};

fn evaluateOperand(
    op: FilterOperand,
    current: Element,
    root: Element,
    allocator: std.mem.Allocator,
) !FilterVal {
    switch (op) {
        .literal_string => |s| return FilterVal{ .string = s },
        .literal_number => |n| return FilterVal{ .number = n },
        .literal_bool => |b| return FilterVal{ .boolean = b },
        .literal_null => return .null_val,
        .path => |path| {
            const matches = try evaluateQuery(path, current, root, allocator);
            defer allocator.free(matches);
            if (matches.len == 0) return .nothing;
            const el = matches[0];
            switch (el.getType()) {
                .string => {
                    const str = el.asString() catch return .nothing;
                    return FilterVal{ .string = str };
                },
                .int64 => {
                    const i = el.asInt() catch return .nothing;
                    return FilterVal{ .number = @floatFromInt(i) };
                },
                .uint64 => {
                    const u = el.asUint() catch return .nothing;
                    return FilterVal{ .number = @floatFromInt(u) };
                },
                .double => {
                    const d = el.asDouble() catch return .nothing;
                    return FilterVal{ .number = d };
                },
                .bool => {
                    const b = el.asBool() catch return .nothing;
                    return FilterVal{ .boolean = b };
                },
                .null => return .null_val,
                else => return .nothing,
            }
        },
        .func_length => |path| {
            const matches = try evaluateQuery(path, current, root, allocator);
            defer allocator.free(matches);
            if (matches.len == 0) return .nothing;
            const el = matches[0];
            switch (el.getType()) {
                .string => {
                    const str = el.asString() catch return .nothing;
                    return FilterVal{ .number = @floatFromInt(str.len) };
                },
                .array => {
                    if (el.asArray()) |arr| {
                        return FilterVal{ .number = @floatFromInt(arr.len()) };
                    } else |_| return .nothing;
                },
                .object => {
                    if (el.asObject()) |obj| {
                        var it = obj.iterator();
                        var count: usize = 0;
                        while (it.next()) |_| count += 1;
                        return FilterVal{ .number = @floatFromInt(count) };
                    } else |_| return .nothing;
                },
                else => return .nothing,
            }
        },
        .func_count => |path| {
            const matches = try evaluateQuery(path, current, root, allocator);
            defer allocator.free(matches);
            return FilterVal{ .number = @floatFromInt(matches.len) };
        },
    }
}

fn compareVals(left: FilterVal, op: CompareOp, right: FilterVal) bool {
    // If either is nothing:
    if (left == .nothing or right == .nothing) {
        if (left == .nothing and right == .nothing) {
            return false;
        }
        return op == .ne;
    }

    switch (left) {
        .number => |ln| {
            if (right == .number) {
                const rn = right.number;
                return switch (op) {
                    .eq => ln == rn,
                    .ne => ln != rn,
                    .lt => ln < rn,
                    .le => ln <= rn,
                    .gt => ln > rn,
                    .ge => ln >= rn,
                };
            }
            return op == .ne;
        },
        .string => |ls| {
            if (right == .string) {
                const rs = right.string;
                const ord = std.mem.order(u8, ls, rs);
                return switch (op) {
                    .eq => ord == .eq,
                    .ne => ord != .eq,
                    .lt => ord == .lt,
                    .le => ord != .gt,
                    .gt => ord == .gt,
                    .ge => ord != .lt,
                };
            }
            return op == .ne;
        },
        .boolean => |lb| {
            if (right == .boolean) {
                const rb = right.boolean;
                return switch (op) {
                    .eq => lb == rb,
                    .ne => lb != rb,
                    else => false,
                };
            }
            return op == .ne;
        },
        .null_val => {
            if (right == .null_val) {
                return op == .eq;
            }
            return op == .ne;
        },
        .nothing => unreachable,
    }
}

fn evaluateFilter(
    item: Element,
    root: Element,
    expr: FilterExpr,
    allocator: std.mem.Allocator,
) anyerror!bool {
    switch (expr) {
        .comparison => |comp| {
            const left = try evaluateOperand(comp.left, item, root, allocator);
            const right = try evaluateOperand(comp.right, item, root, allocator);
            return compareVals(left, comp.op, right);
        },
        .test_expr => |op| {
            switch (op) {
                .path => |path| {
                    const matches = try evaluateQuery(path, item, root, allocator);
                    defer allocator.free(matches);
                    if (matches.len == 0) return false;
                    // If the single matched node is boolean, return its boolean value
                    if (matches.len == 1 and matches[0].getType() == .bool) {
                        return matches[0].asBool() catch false;
                    }
                    return true;
                },
                .literal_bool => |b| return b,
                .literal_null => return false,
                .literal_number => |n| return n != 0,
                .literal_string => |s| return s.len > 0,
                .func_count => |path| {
                    const matches = try evaluateQuery(path, item, root, allocator);
                    defer allocator.free(matches);
                    return matches.len > 0;
                },
                .func_length => |path| {
                    _ = path;
                    const val = try evaluateOperand(op, item, root, allocator);
                    if (val == .number) return val.number > 0;
                    return false;
                },
            }
        },
        .logical_not => |sub| {
            return !(try evaluateFilter(item, root, sub.*, allocator));
        },
        .logical_and => |pair| {
            const left_res = try evaluateFilter(item, root, pair.left.*, allocator);
            if (!left_res) return false;
            return try evaluateFilter(item, root, pair.right.*, allocator);
        },
        .logical_or => |pair| {
            const left_res = try evaluateFilter(item, root, pair.left.*, allocator);
            if (left_res) return true;
            return try evaluateFilter(item, root, pair.right.*, allocator);
        },
    }
}

test "JSONPath syntax error conditions" {
    const alloc = std.testing.allocator;

    // Unexpected token when bracket is unclosed
    try std.testing.expectError(error.UnexpectedToken, JsonPath.compile(alloc, "$[1, 2"));
    try std.testing.expectError(error.UnterminatedString, JsonPath.compile(alloc, "$['open_prop"));

    // Unterminated string literal
    try std.testing.expectError(error.UnterminatedString, JsonPath.compile(alloc, "$['unterminated"));

    // Unterminated filter expression
    try std.testing.expectError(error.UnexpectedToken, JsonPath.compile(alloc, "$[?(@.price > 10"));
}

test "JSONPath array slice edge cases: reverse, empty, bounds" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const Stage2Parser = @import("stage2.zig").Stage2Parser;
    const alloc = std.testing.allocator;

    const json = "[10, 20, 30, 40, 50]";
    var indexes: [64]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(alloc, json, &indexes);
    var tape_buf: [64]u64 = undefined;
    const tape_len = try Stage2Parser.parse(json, &indexes, count, &tape_buf);
    const doc = Document.init(json, tape_buf[0..tape_len]);

    // Reverse slice [::-1]
    const reversed = try query(doc.root(), alloc, "$[::-1]");
    defer alloc.free(reversed);
    try std.testing.expectEqual(@as(usize, 5), reversed.len);
    try std.testing.expectEqual(@as(i64, 50), try reversed[0].asInt());
    try std.testing.expectEqual(@as(i64, 10), try reversed[4].asInt());

    // Slice with step 2 [0:5:2] -> [10, 30, 50]
    const stepped = try query(doc.root(), alloc, "$[0:5:2]");
    defer alloc.free(stepped);
    try std.testing.expectEqual(@as(usize, 3), stepped.len);
    try std.testing.expectEqual(@as(i64, 10), try stepped[0].asInt());
    try std.testing.expectEqual(@as(i64, 30), try stepped[1].asInt());
    try std.testing.expectEqual(@as(i64, 50), try stepped[2].asInt());

    // Empty slice: start > end with positive step [4:2:1]
    const empty_slice = try query(doc.root(), alloc, "$[4:2:1]");
    defer alloc.free(empty_slice);
    try std.testing.expectEqual(@as(usize, 0), empty_slice.len);

    // Out-of-bounds slice clamping [-100:100]
    const clamped = try query(doc.root(), alloc, "$[-100:100]");
    defer alloc.free(clamped);
    try std.testing.expectEqual(@as(usize, 5), clamped.len);
}

test "JSONPath filters: string comparison, missing properties, logical ops" {
    const Stage1Indexer = @import("stage1.zig").Stage1Indexer;
    const Stage2Parser = @import("stage2.zig").Stage2Parser;
    const alloc = std.testing.allocator;

    const json =
        \\[
        \\  {"id": 1, "name": "alice", "active": true, "score": 85.5},
        \\  {"id": 2, "name": "bob", "active": false, "score": 92.0},
        \\  {"id": 3, "name": "charlie", "score": 78.0},
        \\  {"id": 4, "name": "david", "active": true, "score": 92.0}
        \\]
    ;
    var indexes: [256]u32 = undefined;
    const count = try Stage1Indexer.indexAlloc(alloc, json, &indexes);
    var tape_buf: [256]u64 = undefined;
    const tape_len = try Stage2Parser.parse(json, &indexes, count, &tape_buf);
    const doc = Document.init(json, tape_buf[0..tape_len]);

    // String alphabetical comparison: name > 'c' -> charlie, david
    const str_comp = try query(doc.root(), alloc, "$[?(@.name >= 'c')]");
    defer alloc.free(str_comp);
    try std.testing.expectEqual(@as(usize, 2), str_comp.len);

    // Missing property: id 3 has no "active" property.
    // Query !@.active should match id 2 (active: false) and id 3 (active missing -> falsy)
    const inactive = try query(doc.root(), alloc, "$[?(!@.active)]");
    defer alloc.free(inactive);
    try std.testing.expectEqual(@as(usize, 2), inactive.len);

    // Logical OR: active == true || score > 90 -> alice (active), bob (score 92), david (both)
    const or_query = try query(doc.root(), alloc, "$[?(@.active == true || @.score > 90)]");
    defer alloc.free(or_query);
    try std.testing.expectEqual(@as(usize, 3), or_query.len);

    // Non-existent path returns empty, queryFirst returns null
    const no_match = try query(doc.root(), alloc, "$.nonexistent[*]");
    defer alloc.free(no_match);
    try std.testing.expectEqual(@as(usize, 0), no_match.len);

    const first_null = try queryFirst(doc.root(), alloc, "$.nonexistent");
    try std.testing.expect(first_null == null);
}

