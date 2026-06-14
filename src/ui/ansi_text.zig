//! ANSI text helpers for the Zeepseek TUI.
//!
//! Provides word wrapping, tab expansion, and lightweight syntax highlighting
//! that respects Unicode display widths and preserves inline ANSI escapes.

const std = @import("std");
const zz = @import("zigzag");
const Pal = @import("theme.zig").Pal;

const charWidth = zz.unicode.charWidth;

const Codepoint = struct { cp: u21, len: usize };

// ═══════════════════════════════════════════════════════════════════════
// Plain-text word wrapping
// ═══════════════════════════════════════════════════════════════════════

/// Free the result of `wrapLine`.
pub fn freeWrapped(alloc: std.mem.Allocator, lines: []const []const u8) void {
    for (lines) |line| {
        alloc.free(line);
    }
    alloc.free(lines);
}

/// Word-wrap a plain line at spaces and punctuation, returning an array of lines.
/// Breaks are chosen at spaces/punctuation; if a single word is too long it is
/// hard-wrapped. Display widths are computed with `zz.unicode.charWidth`.
pub fn wrapLine(alloc: std.mem.Allocator, text: []const u8, max_width: usize) ![]const []const u8 {
    if (max_width == 0) {
        return try alloc.alloc([]const u8, 0);
    }

    var result = std.ArrayList([]const u8).empty;
    errdefer {
        for (result.items) |item| {
            alloc.free(item);
        }
        result.deinit(alloc);
    }

    if (text.len == 0) {
        const empty = try alloc.dupe(u8, "");
        errdefer alloc.free(empty);
        try result.append(alloc, empty);
        return result.toOwnedSlice(alloc);
    }

    var line_start: usize = 0;
    var line_width: usize = 0;
    var break_after: usize = 0;
    var break_width: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        const decoded = decodeCodepoint(text, i);
        const cp = decoded.cp;
        const len = decoded.len;
        const w = charWidth(cp);

        if (line_width + w <= max_width) {
            i += len;
            line_width += w;

            if (isBreakChar(cp)) {
                break_after = i;
                break_width = line_width;
            }
            continue;
        }

        // Overflow: try to wrap at the last break point.
        if (break_after > line_start) {
            const end = trimTrailingBreaks(text[line_start..break_after]);
            const line = try alloc.dupe(u8, end);
            try result.append(alloc, line);

            line_start = break_after;
            line_width -= break_width;
            break_after = line_start;
            break_width = 0;
            continue;
        }

        // No break point available: hard wrap here.
        const line = try alloc.dupe(u8, text[line_start..i]);
        try result.append(alloc, line);

        line_start = i;
        line_width = 0;
        break_after = line_start;
        break_width = 0;
    }

    if (line_start < text.len or result.items.len == 0) {
        const end = trimTrailingBreaks(text[line_start..]);
        const line = try alloc.dupe(u8, end);
        try result.append(alloc, line);
    }

    return result.toOwnedSlice(alloc);
}

fn decodeCodepoint(text: []const u8, i: usize) Codepoint {
    if (i >= text.len) {
        return .{ .cp = 0, .len = 0 };
    }
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
        return .{ .cp = @as(u21, text[i]), .len = 1 };
    };
    if (i + len > text.len) {
        return .{ .cp = @as(u21, text[i]), .len = 1 };
    }
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
        return .{ .cp = @as(u21, text[i]), .len = 1 };
    };
    return .{ .cp = cp, .len = len };
}

fn isBreakChar(cp: u21) bool {
    return cp == ' ' or cp == '\t' or std.ascii.isPunctuation(@intCast(if (cp <= 127) cp else ' '));
}

fn trimTrailingBreaks(slice: []const u8) []const u8 {
    var end: usize = slice.len;
    while (end > 0) {
        const prev = decodeCodepointBack(slice, end);
        if (prev.len == 0) break;
        if (!isBreakChar(prev.cp)) break;
        end -= prev.len;
    }
    return slice[0..end];
}

fn decodeCodepointBack(text: []const u8, end: usize) Codepoint {
    if (end == 0) return .{ .cp = 0, .len = 0 };

    // Scan backwards for a UTF-8 sequence start (not a continuation byte).
    var start: usize = end - 1;
    while (start > 0 and (text[start] & 0xC0) == 0x80) {
        start -= 1;
    }
    const len = end - start;
    if (len > 4) {
        return .{ .cp = @as(u21, text[end - 1]), .len = 1 };
    }
    const cp = std.unicode.utf8Decode(text[start..end]) catch {
        return .{ .cp = @as(u21, text[end - 1]), .len = 1 };
    };
    return .{ .cp = cp, .len = len };
}

// ═══════════════════════════════════════════════════════════════════════
// ANSI-aware line wrapping
// ═══════════════════════════════════════════════════════════════════════

/// Wrap an ANSI-formatted line at display column boundaries. ANSI escape
/// sequences do not consume columns. If a wrap occurs while an SGR escape is
/// active, that escape is re-emitted at the start of the next line.
pub fn wrapAnsiLine(alloc: std.mem.Allocator, text: []const u8, max_width: usize) ![]const u8 {
    if (max_width == 0) {
        return try alloc.dupe(u8, text);
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(alloc);

    var visible_width: usize = 0;
    var active_sgr: []const u8 = "";
    var i: usize = 0;

    while (i < text.len) {
        if (text[i] == '\x1b' and i + 1 < text.len and text[i + 1] == '[') {
            const seq_end = parseAnsiSequence(text, i);
            if (seq_end == 0) {
                // Not a well-formed sequence; emit the byte literally.
                try result.append(alloc, text[i]);
                i += 1;
                continue;
            }
            const seq = text[i..seq_end];
            try result.appendSlice(alloc, seq);

            if (seq[seq.len - 1] == 'm') {
                active_sgr = updateActiveSgr(seq);
            }
            i = seq_end;
            continue;
        }

        const decoded = decodeCodepoint(text, i);
        const cp = decoded.cp;
        const len = decoded.len;
        const w = charWidth(cp);

        if (visible_width + w > max_width) {
            try result.append(alloc, '\n');
            if (active_sgr.len > 0) {
                try result.appendSlice(alloc, active_sgr);
            }
            visible_width = 0;
        }

        try result.appendSlice(alloc, text[i..][0..len]);
        visible_width += w;
        i += len;
    }

    return result.toOwnedSlice(alloc);
}

fn parseAnsiSequence(text: []const u8, start: usize) usize {
    var i = start + 2;
    while (i < text.len) {
        const b = text[i];
        if (b >= 0x40 and b <= 0x7E) {
            return i + 1;
        }
        i += 1;
    }
    return 0;
}

fn updateActiveSgr(seq: []const u8) []const u8 {
    // seq is ESC[...m. Extract the parameter bytes between '[' and 'm'.
    const params = seq[2 .. seq.len - 1];
    if (params.len == 0) return "";
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |p| {
        const n = std.fmt.parseInt(u8, p, 10) catch continue;
        if (n == 0) return "";
    }
    return seq;
}

// ═══════════════════════════════════════════════════════════════════════
// Tab expansion
// ═══════════════════════════════════════════════════════════════════════

/// Replace tab characters with spaces to align to the given tab width.
pub fn expandTabs(alloc: std.mem.Allocator, text: []const u8, tab_width: usize) ![]const u8 {
    if (tab_width == 0) {
        return try alloc.dupe(u8, text);
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(alloc);

    var col: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const decoded = decodeCodepoint(text, i);
        const cp = decoded.cp;
        const len = decoded.len;

        if (cp == '\t') {
            const spaces = tab_width - (col % tab_width);
            try result.appendNTimes(alloc, ' ', spaces);
            col += spaces;
            i += len;
        } else {
            try result.appendSlice(alloc, text[i..][0..len]);
            if (cp == '\n') {
                col = 0;
            } else {
                col += charWidth(cp);
            }
            i += len;
        }
    }

    return result.toOwnedSlice(alloc);
}

// ═══════════════════════════════════════════════════════════════════════
// Lightweight syntax highlighting
// ═══════════════════════════════════════════════════════════════════════

const keywords = [_][]const u8{
    "if",        "else",     "while",  "for",            "return",
    "break",     "continue", "switch", "case",           "default",
    "fn",        "function", "def",    "const",          "var",
    "let",       "struct",   "enum",   "union",          "class",
    "pub",       "private",  "static", "inline",         "noinline",
    "comptime",  "try",      "catch",  "defer",          "errdefer",
    "async",     "await",    "import", "from",           "as",
    "in",        "is",       "not",    "and",            "or",
    "true",      "false",    "null",   "undefined",      "void",
    "new",       "this",     "super",  "extends",        "implements",
    "interface", "type",     "where",  "match",          "yield",
    "throw",     "finally",  "do",     "loop",           "goto",
    "pub",       "export",   "extern", "usingnamespace",
};

const types = [_][]const u8{
    "bool",    "void",     "int",      "float",     "char",
    "string",  "str",      "i8",       "i16",       "i32",
    "i64",     "i128",     "u8",       "u16",       "u32",
    "u64",     "u128",     "usize",    "isize",     "f16",
    "f32",     "f64",      "f128",     "anyerror",  "anyframe",
    "anytype", "noreturn", "c_int",    "c_uint",    "c_long",
    "c_ulong", "c_short",  "c_ushort", "anyopaque",
};

fn isKeyword(word: []const u8) bool {
    for (keywords) |kw| {
        if (std.mem.eql(u8, kw, word)) return true;
    }
    return false;
}

fn isType(word: []const u8) bool {
    for (types) |t| {
        if (std.mem.eql(u8, t, word)) return true;
    }
    return false;
}

fn isIdentifierStart(cp: u21) bool {
    return (cp >= 'a' and cp <= 'z') or
        (cp >= 'A' and cp <= 'Z') or
        cp == '_' or cp == '$';
}

fn isIdentifierPart(cp: u21) bool {
    return isIdentifierStart(cp) or (cp >= '0' and cp <= '9');
}

fn isDigit(cp: u21) bool {
    return cp >= '0' and cp <= '9';
}

fn isHexDigit(cp: u21) bool {
    return (cp >= '0' and cp <= '9') or
        (cp >= 'a' and cp <= 'f') or
        (cp >= 'A' and cp <= 'F');
}

/// Lightweight syntax highlighter. Returns an ANSI-coloured string.
pub fn highlightCode(alloc: std.mem.Allocator, lang: []const u8, code: []const u8) ![]const u8 {
    _ = lang;

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(alloc);

    var i: usize = 0;
    while (i < code.len) {
        const decoded = decodeCodepoint(code, i);
        const cp = decoded.cp;
        const len = decoded.len;

        // Strings.
        if (cp == '"' or cp == '\'' or cp == '`') {
            const str = readString(code, i, cp);
            try result.appendSlice(alloc, Pal.code_string);
            try result.appendSlice(alloc, str);
            try result.appendSlice(alloc, Pal.R);
            i += str.len;
            continue;
        }

        // Line comments: // and #.
        if (cp == '/') {
            const next = peekCodepoint(code, i + len);
            if (next.cp == '/') {
                const rest = code[i..];
                try result.appendSlice(alloc, Pal.code_comment);
                try result.appendSlice(alloc, rest);
                try result.appendSlice(alloc, Pal.R);
                break;
            }
        }
        if (cp == '#') {
            const rest = code[i..];
            try result.appendSlice(alloc, Pal.code_comment);
            try result.appendSlice(alloc, rest);
            try result.appendSlice(alloc, Pal.R);
            break;
        }

        // Numbers.
        if (isDigit(cp) or (cp == '.' and isDigit(peekCodepoint(code, i + len).cp)) or
            (cp == '-' and isDigit(peekCodepoint(code, i + len).cp)))
        {
            const num = readNumber(code, i);
            try result.appendSlice(alloc, Pal.code_number);
            try result.appendSlice(alloc, num);
            try result.appendSlice(alloc, Pal.R);
            i += num.len;
            continue;
        }

        // Identifiers / keywords / types / function calls.
        if (isIdentifierStart(cp)) {
            const word = readIdentifier(code, i);
            const after = skipSpaces(code, i + word.len);
            const next = peekCodepoint(code, after);

            const color: []const u8 = blk: {
                if (isKeyword(word)) break :blk Pal.code_keyword;
                if (isType(word)) break :blk Pal.code_type;
                if (next.cp == '(') break :blk Pal.code_function;
                break :blk Pal.code_fg;
            };

            try result.appendSlice(alloc, color);
            try result.appendSlice(alloc, word);
            try result.appendSlice(alloc, Pal.R);
            i += word.len;
            continue;
        }

        // Plain text.
        try result.appendSlice(alloc, textBytes(code, i, len));
        i += len;
    }

    return result.toOwnedSlice(alloc);
}

fn peekCodepoint(text: []const u8, pos: usize) Codepoint {
    if (pos >= text.len) return .{ .cp = 0, .len = 0 };
    return decodeCodepoint(text, pos);
}

fn textBytes(text: []const u8, i: usize, len: usize) []const u8 {
    return text[i..][0..len];
}

fn readString(text: []const u8, start: usize, quote: u21) []const u8 {
    var i = start + codepointByteLen(quote);
    while (i < text.len) {
        const decoded = decodeCodepoint(text, i);
        const cp = decoded.cp;
        const len = decoded.len;
        if (cp == '\\' and i + len < text.len) {
            const esc = decodeCodepoint(text, i + len);
            i += len + esc.len;
            continue;
        }
        if (cp == quote) {
            i += len;
            break;
        }
        i += len;
    }
    return text[start..i];
}

fn codepointByteLen(cp: u21) usize {
    if (cp <= 0x7F) return 1;
    if (cp <= 0x7FF) return 2;
    if (cp <= 0xFFFF) return 3;
    return 4;
}

fn readNumber(text: []const u8, start: usize) []const u8 {
    var i = start;
    // Optional leading sign.
    if (i < text.len and (text[i] == '-' or text[i] == '+')) {
        i += 1;
    }

    // Hex / binary / octal prefixes.
    if (i + 1 < text.len and text[i] == '0') {
        const next = std.ascii.toLower(text[i + 1]);
        if (next == 'x') {
            i += 2;
            while (i < text.len and isHexDigit(decodeCodepoint(text, i).cp)) i += decodeCodepoint(text, i).len;
            return text[start..i];
        }
    }

    var seen_dot = false;
    while (i < text.len) {
        const decoded = decodeCodepoint(text, i);
        const cp = decoded.cp;
        const len = decoded.len;
        if (isDigit(cp)) {
            i += len;
            continue;
        }
        if (cp == '.' and !seen_dot and i + len < text.len and isDigit(peekCodepoint(text, i + len).cp)) {
            seen_dot = true;
            i += len;
            continue;
        }
        if (cp == 'e' or cp == 'E') {
            const after = i + len;
            const sign = peekCodepoint(text, after);
            var exp_start = after;
            if (sign.cp == '+' or sign.cp == '-') exp_start += sign.len;
            if (exp_start < text.len and isDigit(peekCodepoint(text, exp_start).cp)) {
                i = exp_start;
                while (i < text.len and isDigit(decodeCodepoint(text, i).cp)) i += decodeCodepoint(text, i).len;
                continue;
            }
        }
        break;
    }
    return text[start..i];
}

fn readIdentifier(text: []const u8, start: usize) []const u8 {
    var i = start;
    while (i < text.len) {
        const decoded = decodeCodepoint(text, i);
        if (!isIdentifierPart(decoded.cp)) break;
        i += decoded.len;
    }
    return text[start..i];
}

fn skipSpaces(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) {
        const decoded = decodeCodepoint(text, i);
        if (decoded.cp != ' ' and decoded.cp != '\t') break;
        i += decoded.len;
    }
    return i;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "wrapLine basic word wrap" {
    const alloc = std.testing.allocator;
    const lines = try wrapLine(alloc, "hello world", 7);
    defer freeWrapped(alloc, lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("hello", lines[0]);
    try std.testing.expectEqualStrings("world", lines[1]);
}

test "wrapLine respects unicode width" {
    const alloc = std.testing.allocator;
    const lines = try wrapLine(alloc, "中文中文", 4);
    defer freeWrapped(alloc, lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("中文", lines[0]);
    try std.testing.expectEqualStrings("中文", lines[1]);
}

test "wrapLine hard wraps long words" {
    const alloc = std.testing.allocator;
    const lines = try wrapLine(alloc, "abcdefghij", 4);
    defer freeWrapped(alloc, lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("abcd", lines[0]);
    try std.testing.expectEqualStrings("efgh", lines[1]);
    try std.testing.expectEqualStrings("ij", lines[2]);
}

test "wrapAnsiLine preserves escapes" {
    const alloc = std.testing.allocator;
    const red = "\x1b[31m";
    const reset = "\x1b[0m";
    const text = red ++ "hello world" ++ reset;
    const wrapped = try wrapAnsiLine(alloc, text, 7);
    defer alloc.free(wrapped);

    try std.testing.expect(std.mem.indexOf(u8, wrapped, "\n") != null);
    // The first visible word should be present, and the SGR sequences should
    // appear at least once in the output.
    try std.testing.expect(std.mem.indexOf(u8, wrapped, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapped, red) != null);
}

test "wrapAnsiLine does not count escape width" {
    const alloc = std.testing.allocator;
    const colored = "\x1b[31mhello\x1b[0m";
    const wrapped = try wrapAnsiLine(alloc, colored, 5);
    defer alloc.free(wrapped);
    // With width 5, the five visible characters fit on one line.
    try std.testing.expect(std.mem.indexOf(u8, wrapped, "\n") == null);
}

test "highlightCode colors keywords and strings" {
    const alloc = std.testing.allocator;
    const code = "const x = \"hello\";";
    const highlighted = try highlightCode(alloc, "zig", code);
    defer alloc.free(highlighted);

    try std.testing.expect(std.mem.indexOf(u8, highlighted, Pal.code_keyword) != null);
    try std.testing.expect(std.mem.indexOf(u8, highlighted, Pal.code_string) != null);
}

test "highlightCode colors numbers and comments" {
    const alloc = std.testing.allocator;
    const code = "let n = 42; // answer";
    const highlighted = try highlightCode(alloc, "zig", code);
    defer alloc.free(highlighted);

    try std.testing.expect(std.mem.indexOf(u8, highlighted, Pal.code_number) != null);
    try std.testing.expect(std.mem.indexOf(u8, highlighted, Pal.code_comment) != null);
}

test "highlightCode colors function calls" {
    const alloc = std.testing.allocator;
    const code = "foo();";
    const highlighted = try highlightCode(alloc, "zig", code);
    defer alloc.free(highlighted);

    try std.testing.expect(std.mem.indexOf(u8, highlighted, Pal.code_function) != null);
}


test "wrapLine wraps long lines" {
    const alloc = std.testing.allocator;
    const text = "this is a long line that needs wrapping";
    const lines = try wrapLine(alloc, text, 10);
    defer freeWrapped(alloc, lines);

    try std.testing.expect(lines.len > 1);
    for (lines) |line| {
        var width: usize = 0;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            width += charWidth(line[i]);
        }
        try std.testing.expect(width <= 10);
    }
}

test "wrapAnsiLine preserves escapes across wraps" {
    const alloc = std.testing.allocator;
    const colored = Pal.code_keyword ++ "hello world" ++ Pal.R;
    const wrapped = try wrapAnsiLine(alloc, colored, 5);
    defer alloc.free(wrapped);

    try std.testing.expect(std.mem.indexOf(u8, wrapped, "\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapped, Pal.code_keyword) != null);
}

test "expandTabs aligns to tab width" {
    const alloc = std.testing.allocator;
    const expanded = try expandTabs(alloc, "a\tb", 4);
    defer alloc.free(expanded);

    try std.testing.expect(std.mem.eql(u8, expanded, "a   b"));
}
