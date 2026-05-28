const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");

const Style = vaxis.Style;
const Color = vaxis.Color;
const Segment = vaxis.Segment;
const ColorPalette = theme.ColorPalette;

/// Inline element within a block
pub const Inline = union(enum) {
    text: []const u8,
    bold: []const u8,
    italic: []const u8,
    code: []const u8,
    strikethrough: []const u8,
    link: struct { text: []const u8, url: []const u8 },
};

pub const TableCell = struct {
    inlines: []Inline,
};

pub const TableRow = struct {
    cells: []TableCell,
};

pub const Table = struct {
    headers: TableRow,
    rows: []TableRow,
    col_count: usize,
};

/// Block-level element
pub const Block = union(enum) {
    heading: struct { level: u8, inlines: []Inline },
    paragraph: []Inline,
    code_block: struct { language: ?[]const u8, content: []const u8 },
    list_item: struct { bullet: []const u8, inlines: []Inline },
    table: Table,
    horizontal_rule,
    blank,
};

/// A single rendered line composed of styled segments
pub const Line = struct {
    segments: std.ArrayList(Segment),
    alloc: ?std.mem.Allocator = null,

    pub fn init(alloc: std.mem.Allocator) Line {
        return .{ .segments = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *Line) void {
        if (self.alloc) |a| {
            self.segments.deinit(a);
        }
    }

    pub fn append(self: *Line, text: []const u8, style: Style) !void {
        const alloc = self.alloc orelse return error.NoAllocator;
        try self.segments.append(alloc, .{ .text = text, .style = style });
    }
};

/// Parsed markdown document
pub const ParsedMarkdown = struct {
    blocks: std.ArrayList(Block),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) ParsedMarkdown {
        return .{
            .blocks = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *ParsedMarkdown) void {
        for (self.blocks.items) |*block| {
            switch (block.*) {
                .heading => |*h| self.alloc.free(h.inlines),
                .paragraph => |inlines| self.alloc.free(inlines),
                .code_block => |*cb| {
                    if (cb.language) |l| self.alloc.free(l);
                    self.alloc.free(cb.content);
                },
                .list_item => |*li| self.alloc.free(li.inlines),
                .table => |*t| {
                    for (t.headers.cells) |*cell| self.alloc.free(cell.inlines);
                    self.alloc.free(t.headers.cells);
                    for (t.rows) |*row| {
                        for (row.cells) |*cell| self.alloc.free(cell.inlines);
                        self.alloc.free(row.cells);
                    }
                    self.alloc.free(t.rows);
                },
                else => {},
            }
        }
        self.blocks.deinit(self.alloc);
    }
};

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.mem.eql(u8, text[0..prefix.len], prefix);
}

fn trimLeft(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    return text[i..];
}

/// Parse inline formatting within a line of text
fn parseInlines(allocator: std.mem.Allocator, text: []const u8) ![]Inline {
    var inlines: std.ArrayList(Inline) = .empty;
    errdefer inlines.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        // Check for escaped backticks in code spans - skip them
        if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == '`') {
            try inlines.append(allocator, .{ .text = "`" });
            i += 2;
            continue;
        }

        // Code span: `...`
        if (text[i] == '`') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '`');
            if (end) |e| {
                try inlines.append(allocator, .{ .code = text[i + 1 .. e] });
                i = e + 1;
                continue;
            }
        }

        // Bold: **...**
        if (startsWith(text[i..], "**")) {
            const end = std.mem.indexOfPos(u8, text, i + 2, "**");
            if (end) |e| {
                try inlines.append(allocator, .{ .bold = text[i + 2 .. e] });
                i = e + 2;
                continue;
            }
        }

        // Strikethrough: ~~...~~
        if (startsWith(text[i..], "~~")) {
            const end = std.mem.indexOfPos(u8, text, i + 2, "~~");
            if (end) |e| {
                try inlines.append(allocator, .{ .strikethrough = text[i + 2 .. e] });
                i = e + 2;
                continue;
            }
        }

        // Italic: *...* (but not **)
        if (text[i] == '*' and (i + 1 >= text.len or text[i + 1] != '*')) {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '*');
            if (end) |e| {
                try inlines.append(allocator, .{ .italic = text[i + 1 .. e] });
                i = e + 1;
                continue;
            }
        }

        // Link: [text](url)
        if (text[i] == '[') {
            const close_bracket = std.mem.indexOfScalarPos(u8, text, i + 1, ']');
            if (close_bracket) |cb| {
                if (cb + 1 < text.len and text[cb + 1] == '(') {
                    const close_paren = std.mem.indexOfScalarPos(u8, text, cb + 2, ')');
                    if (close_paren) |cp| {
                        try inlines.append(allocator, .{ .link = .{
                            .text = text[i + 1 .. cb],
                            .url = text[cb + 2 .. cp],
                        } });
                        i = cp + 1;
                        continue;
                    }
                }
            }
        }

        // Collect plain text until next special char
        var j = i;
        while (j < text.len) {
            const c = text[j];
            if (c == '`' or c == '[' or c == '\\') break;
            if (c == '*' and j + 1 < text.len) {
                if (text[j + 1] == '*') break; // bold
                break; // italic
            }
            if (c == '~' and j + 1 < text.len and text[j + 1] == '~') break;
            j += 1;
        }

        if (j > i) {
            try inlines.append(allocator, .{ .text = text[i..j] });
        }
        i = j;
        if (i == j and j < text.len) {
            // No progress - consume one char to avoid infinite loop
            try inlines.append(allocator, .{ .text = text[i .. i + 1] });
            i += 1;
        }
    }

    return inlines.toOwnedSlice(allocator);
}

fn isTableSeparator(text: []const u8) bool {
    if (text.len == 0) return false;
    var has_dash = false;
    for (text) |c| {
        if (c == '|' or c == ' ' or c == ':' or c == '-') {
            if (c == '-') has_dash = true;
        } else {
            return false;
        }
    }
    return has_dash;
}

fn splitTableCells(alloc: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var cells: std.ArrayList([]const u8) = .empty;
    errdefer cells.deinit(alloc);
    var parts = std.mem.splitScalar(u8, text, '|');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            try cells.append(alloc, trimmed);
        }
    }
    return cells.toOwnedSlice(alloc);
}

fn parseTableRow(alloc: std.mem.Allocator, text: []const u8) ![]TableCell {
    const cells = try splitTableCells(alloc, text);
    errdefer alloc.free(cells);
    var result = try alloc.alloc(TableCell, cells.len);
    for (cells, 0..) |cell, i| {
        result[i] = .{ .inlines = try parseInlines(alloc, cell) };
    }
    alloc.free(cells);
    return result;
}

/// Parse markdown text into AST
pub fn parse(alloc: std.mem.Allocator, text: []const u8) !ParsedMarkdown {
    var doc = ParsedMarkdown.init(alloc);
    errdefer doc.deinit();

    // Collect all lines first for table peeking
    var all_lines: std.ArrayList([]const u8) = .empty;
    defer all_lines.deinit(alloc);
    {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            try all_lines.append(alloc, line);
        }
    }

    var idx: usize = 0;
    var in_code_block: bool = false;
    var code_lang: ?[]const u8 = null;
    var code_lines: std.ArrayList(u8) = .empty;
    defer code_lines.deinit(alloc);

    while (idx < all_lines.items.len) {
        const line = all_lines.items[idx];
        idx += 1;

        // Code block: ```language
        if (startsWith(line, "```")) {
            if (in_code_block) {
                // End code block
                const content = try alloc.dupe(u8, code_lines.items);
                try doc.blocks.append(alloc, .{ .code_block = .{
                    .language = if (code_lang) |l| try alloc.dupe(u8, l) else null,
                    .content = content,
                } });
                code_lines.clearRetainingCapacity();
                in_code_block = false;
                code_lang = null;
            } else {
                // Start code block
                in_code_block = true;
                const rest = trimLeft(line[3..]);
                if (rest.len > 0) {
                    code_lang = try alloc.dupe(u8, rest);
                }
            }
            continue;
        }

        if (in_code_block) {
            try code_lines.appendSlice(alloc, line);
            try code_lines.append(alloc, '\n');
            continue;
        }

        const trimmed = trimLeft(line);

        // Blank line
        if (trimmed.len == 0) {
            try doc.blocks.append(alloc, .blank);
            continue;
        }

        // Horizontal rule: --- or *** or ___
        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "***") or std.mem.eql(u8, trimmed, "___")) {
            try doc.blocks.append(alloc, .horizontal_rule);
            continue;
        }

        // Heading: # ... ## ... ### ...
        var heading_level: u8 = 0;
        var h_idx: usize = 0;
        while (h_idx < trimmed.len and trimmed[h_idx] == '#' and heading_level < 6) : (h_idx += 1) {
            heading_level += 1;
        }
        if (heading_level > 0 and h_idx < trimmed.len and std.ascii.isWhitespace(trimmed[h_idx])) {
            const content = trimLeft(trimmed[h_idx..]);
            const inlines = try parseInlines(alloc, content);
            try doc.blocks.append(alloc, .{ .heading = .{ .level = heading_level, .inlines = inlines } });
            continue;
        }

        // Table: | header | header |
        //       |--------|--------|
        //       | data   | data   |
        if (trimmed.len > 0 and trimmed[0] == '|') {
            // Peek next line to see if it's a separator
            if (idx < all_lines.items.len) {
                const next_line = trimLeft(all_lines.items[idx]);
                if (next_line.len > 0 and next_line[0] == '|' and isTableSeparator(next_line)) {
                    // This is a table!
                    const header_cells = try parseTableRow(alloc, trimmed);
                    const col_count = header_cells.len;
                    idx += 1; // skip separator line

                    var rows: std.ArrayList(TableRow) = .empty;
                    errdefer {
                        for (rows.items) |*row| {
                            for (row.cells) |*cell| alloc.free(cell.inlines);
                            alloc.free(row.cells);
                        }
                        rows.deinit(alloc);
                    }

                    while (idx < all_lines.items.len) {
                        const data_line = trimLeft(all_lines.items[idx]);
                        if (data_line.len == 0 or data_line[0] != '|') break;
                        const data_cells = try parseTableRow(alloc, data_line);
                        // Pad or truncate to match col_count
                        if (data_cells.len != col_count) {
                            var normalized = try alloc.alloc(TableCell, col_count);
                            var ci: usize = 0;
                            while (ci < col_count) : (ci += 1) {
                                if (ci < data_cells.len) {
                                    normalized[ci] = data_cells[ci];
                                } else {
                                    normalized[ci] = .{ .inlines = try parseInlines(alloc, "") };
                                }
                            }
                            // Free extras
                            while (ci < data_cells.len) : (ci += 1) {
                                alloc.free(data_cells[ci].inlines);
                            }
                            alloc.free(data_cells);
                            try rows.append(alloc, .{ .cells = normalized });
                        } else {
                            try rows.append(alloc, .{ .cells = data_cells });
                        }
                        idx += 1;
                    }

                    try doc.blocks.append(alloc, .{ .table = .{
                        .headers = .{ .cells = header_cells },
                        .rows = try rows.toOwnedSlice(alloc),
                        .col_count = col_count,
                    } });
                    continue;
                }
            }
        }

        // List item: - ... or * ... or 1. ...
        var is_list = false;
        var bullet: []const u8 = "";
        var content_start: usize = 0;

        if (trimmed.len >= 2 and trimmed[0] == '-' and std.ascii.isWhitespace(trimmed[1])) {
            is_list = true;
            bullet = "•";
            content_start = 2;
        } else if (trimmed.len >= 2 and trimmed[0] == '*' and std.ascii.isWhitespace(trimmed[1])) {
            is_list = true;
            bullet = "•";
            content_start = 2;
        } else if (trimmed.len >= 3 and std.ascii.isDigit(trimmed[0]) and trimmed[1] == '.' and std.ascii.isWhitespace(trimmed[2])) {
            is_list = true;
            bullet = trimmed[0..2];
            content_start = 3;
        }

        if (is_list) {
            const content = trimLeft(trimmed[content_start..]);
            const inlines = try parseInlines(alloc, content);
            try doc.blocks.append(alloc, .{ .list_item = .{ .bullet = bullet, .inlines = inlines } });
            continue;
        }

        // Paragraph
        const inlines = try parseInlines(alloc, trimmed);
        try doc.blocks.append(alloc, .{ .paragraph = inlines });
    }

    // Handle unclosed code block
    if (in_code_block and code_lines.items.len > 0) {
        const content = try alloc.dupe(u8, code_lines.items);
        try doc.blocks.append(alloc, .{ .code_block = .{
            .language = if (code_lang) |l| try alloc.dupe(u8, l) else null,
            .content = content,
        } });
    }
    if (code_lang) |l| alloc.free(l);

    return doc;
}

/// Word-wrap a string into lines of max_width
fn wordWrap(alloc: std.mem.Allocator, text: []const u8, max_width: usize) ![][]const u8 {
    if (max_width == 0) {
        const r = try alloc.alloc([]const u8, 1);
        r[0] = try alloc.dupe(u8, text);
        return r;
    }
    if (text.len == 0) {
        const empty = try alloc.alloc([]const u8, 1);
        empty[0] = "";
        return empty;
    }

    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |item| alloc.free(item);
        result.deinit(alloc);
    }

    var remaining = text;
    while (remaining.len > 0) {
        if (remaining.len <= max_width) {
            try result.append(alloc, try alloc.dupe(u8, remaining));
            break;
        }

        var cut = max_width;
        // Try to break at whitespace
        while (cut > 0 and !std.ascii.isWhitespace(remaining[cut])) {
            cut -= 1;
        }
        if (cut == 0) {
            // No whitespace found, hard break
            cut = max_width;
        }

        try result.append(alloc, try alloc.dupe(u8, remaining[0..cut]));
        remaining = remaining[cut..];
        // Skip leading whitespace on next line
        while (remaining.len > 0 and std.ascii.isWhitespace(remaining[0])) {
            remaining = remaining[1..];
        }
    }

    return result.toOwnedSlice(alloc);
}

/// Hard-wrap for code blocks (preserve indentation, break at exact width)
fn hardWrap(alloc: std.mem.Allocator, text: []const u8, max_width: usize) ![][]const u8 {
    if (max_width == 0) {
        const r = try alloc.alloc([]const u8, 1);
        r[0] = try alloc.dupe(u8, text);
        return r;
    }
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |item| alloc.free(item);
        result.deinit(alloc);
    }

    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];

        if (line.len <= max_width) {
            try result.append(alloc, try alloc.dupe(u8, line));
        } else {
            var pos: usize = 0;
            while (pos < line.len) {
                const end = @min(pos + max_width, line.len);
                try result.append(alloc, try alloc.dupe(u8, line[pos..end]));
                pos = end;
            }
        }
        line_start = line_end + 1;
    }

    if (result.items.len == 0) {
        try result.append(alloc, try alloc.dupe(u8, ""));
    }

    return result.toOwnedSlice(alloc);
}

/// Render inline elements into a line buffer
fn renderInlines(
    alloc: std.mem.Allocator,
    inlines: []const Inline,
    base_style: Style,
    palette: *const ColorPalette,
    lines: *std.ArrayList(Line),
    max_width: usize,
    indent: usize,
) !void {
    var current_line = Line.init(alloc);
    var current_width: usize = 0;

    // Add indent spaces if needed
    if (indent > 0) {
        const spaces = try std.fmt.allocPrint(alloc, "{s: >[1]}", .{ "", indent });
        defer alloc.free(spaces);
        try current_line.append(spaces, base_style);
        current_width = indent;
    }

    for (inlines) |inl| {
        const text: []const u8 = switch (inl) {
            .text => |t| t,
            .bold => |t| t,
            .italic => |t| t,
            .code => |t| t,
            .strikethrough => |t| t,
            .link => |l| l.text,
        };

        const style: Style = switch (inl) {
            .text => base_style,
            .bold => .{
                .fg = palette.fg_bright,
                .bold = true,
            },
            .italic => .{
                .fg = palette.fg,
                .italic = true,
            },
            .code => .{
                .fg = palette.tool_call,
                .bg = palette.bg_alt,
            },
            .strikethrough => .{
                .fg = palette.fg_dim,
                .strikethrough = true,
            },
            .link => .{
                .fg = palette.link,
                .ul_style = .single,
            },
        };

        // Word-wrap this inline text
        const available = if (max_width > current_width) max_width - current_width else 0;
        if (available > 0 and text.len > available) {
            // Need to wrap
            var pos: usize = 0;
            while (pos < text.len) {
                const remaining = text.len - pos;
                const line_avail = if (lines.items.len == 0 and current_width == 0)
                    max_width
                else if (current_width == 0)
                    max_width
                else
                    @min(available, remaining);

                if (line_avail == 0) {
                    // Flush current line and start new
                    try lines.append(alloc, current_line);
                    current_line = Line.init(alloc);
                    current_width = 0;
                    continue;
                }

                const take = @min(remaining, line_avail);
                try current_line.append(text[pos .. pos + take], style);
                pos += take;
                current_width += take;

                if (current_width >= max_width and pos < text.len) {
                    try lines.append(alloc, current_line);
                    current_line = Line.init(alloc);
                    current_width = 0;
                }
            }
        } else {
            if (available == 0 and text.len > 0) {
                // Flush and start new line
                try lines.append(alloc, current_line);
                current_line = Line.init(alloc);
                current_width = 0;
            }
            try current_line.append(text, style);
            current_width += text.len;
        }
    }

    if (current_line.segments.items.len > 0) {
        try lines.append(alloc, current_line);
    } else {
        current_line.deinit();
    }
}

/// Render parsed markdown into lines with the given width and theme
pub fn render(
    alloc: std.mem.Allocator,
    doc: *const ParsedMarkdown,
    width: u16,
    palette: *const ColorPalette,
) !std.ArrayList(Line) {
    var lines: std.ArrayList(Line) = .empty;
    errdefer {
        for (lines.items) |*line| line.deinit();
        lines.deinit(alloc);
    }

    const effective_width = if (width > 4) width - 4 else width;

    for (doc.blocks.items) |block| {
        switch (block) {
            .heading => |h| {
                const heading_style = switch (h.level) {
                    1 => Style{ .fg = palette.fg_bright, .bold = true, .ul_style = .single },
                    2 => Style{ .fg = palette.fg_bright, .bold = true },
                    else => Style{ .fg = palette.fg, .bold = true },
                };
                try renderInlines(alloc, h.inlines, heading_style, palette, &lines, effective_width, 0);
                try lines.append(alloc, Line.init(alloc)); // blank after heading
            },
            .paragraph => |inlines| {
                try renderInlines(alloc, inlines, .{ .fg = palette.fg }, palette, &lines, effective_width, 0);
            },
            .code_block => |cb| {
                // Code block border
                var border_line = Line.init(alloc);
                try border_line.append("┌", .{ .fg = palette.border });
                var i: usize = 0;
                while (i < effective_width -| 2) : (i += 1) {
                    try border_line.append("─", .{ .fg = palette.border });
                }
                try border_line.append("┐", .{ .fg = palette.border });
                try lines.append(alloc, border_line);

                // Language header if present
                if (cb.language) |lang| {
                    var lang_line = Line.init(alloc);
                    try lang_line.append("│ ", .{ .fg = palette.border });
                    const lang_style = Style{ .fg = palette.info, .italic = true };
                    const lang_text = if (lang.len > effective_width -| 4) lang[0 .. effective_width -| 4] else lang;
                    try lang_line.append(lang_text, lang_style);
                    try lines.append(alloc, lang_line);
                }

                // Code content (hard wrap, preserve indentation)
                const code_width = if (effective_width > 4) effective_width - 4 else effective_width;
                const code_lines = try hardWrap(alloc, cb.content, code_width);
                defer {
                    for (code_lines) |cl| alloc.free(cl);
                    alloc.free(code_lines);
                }

                const is_diff = cb.language != null and std.mem.eql(u8, cb.language.?, "diff");
                for (code_lines) |code_line| {
                    var cl = Line.init(alloc);
                    try cl.append("│ ", .{ .fg = palette.border });
                    if (is_diff) {
                        const style: Style = if (std.mem.startsWith(u8, code_line, "+"))
                            .{ .fg = palette.success }
                        else if (std.mem.startsWith(u8, code_line, "-"))
                            .{ .fg = palette.error_color }
                        else if (std.mem.startsWith(u8, code_line, "@@"))
                            .{ .fg = palette.warning, .bold = true }
                        else if (std.mem.startsWith(u8, code_line, "---") or std.mem.startsWith(u8, code_line, "+++"))
                            .{ .fg = palette.fg_dim, .italic = true }
                        else
                            .{ .fg = palette.fg };
                        try cl.append(code_line, style);
                    } else {
                        try cl.append(code_line, .{ .fg = palette.fg, .bg = palette.bg_alt });
                    }
                    try lines.append(alloc, cl);
                }

                // Bottom border
                var bottom_line = Line.init(alloc);
                try bottom_line.append("└", .{ .fg = palette.border });
                i = 0;
                while (i < effective_width -| 2) : (i += 1) {
                    try bottom_line.append("─", .{ .fg = palette.border });
                }
                try bottom_line.append("┘", .{ .fg = palette.border });
                try lines.append(alloc, bottom_line);
                try lines.append(alloc, Line.init(alloc)); // blank after code block
            },
            .list_item => |li| {
                var first_line = Line.init(alloc);
                try first_line.append(li.bullet, .{ .fg = palette.fg_bright, .bold = true });
                try first_line.append(" ", .{});
                try lines.append(alloc, first_line);
                try renderInlines(alloc, li.inlines, .{ .fg = palette.fg }, palette, &lines, effective_width -| 2, 2);
            },
            .table => |t| {
                if (t.col_count == 0) continue;
                // Calculate column widths
                var col_widths = try alloc.alloc(usize, t.col_count);
                defer alloc.free(col_widths);
                @memset(col_widths, 0);

                // Re-calculate properly with indices
                for (t.headers.cells, 0..) |cell, ci| {
                    var cell_len: usize = 0;
                    for (cell.inlines) |inl| {
                        cell_len += switch (inl) {
                            .text => |s| s.len,
                            .bold => |s| s.len,
                            .italic => |s| s.len,
                            .code => |s| s.len,
                            .strikethrough => |s| s.len,
                            .link => |l| l.text.len,
                        };
                    }
                    if (ci < col_widths.len and cell_len > col_widths[ci]) col_widths[ci] = cell_len;
                }
                for (t.rows) |row| {
                    for (row.cells, 0..) |cell, ci| {
                        if (ci >= col_widths.len) break;
                        var cell_len: usize = 0;
                        for (cell.inlines) |inl| {
                            cell_len += switch (inl) {
                                .text => |s| s.len,
                                .bold => |s| s.len,
                                .italic => |s| s.len,
                                .code => |s| s.len,
                                .strikethrough => |s| s.len,
                                .link => |l| l.text.len,
                            };
                        }
                        if (cell_len > col_widths[ci]) col_widths[ci] = cell_len;
                    }
                }
                // Minimum column width
                for (col_widths) |*cw| cw.* = @max(cw.*, 3);
                const total_width = blk: {
                    var sum: usize = 1; // left border
                    for (col_widths) |cw| sum += cw + 3; // " │ " + content + " │"
                    sum -= 2; // adjust
                    break :blk sum;
                };
                _ = total_width;

                const header_style = Style{ .fg = palette.fg_bright, .bold = true };

                // Helper to draw a row border
                const RowBorder = enum { top, mid, bottom };
                const drawBorder = struct {
                    fn call(a: std.mem.Allocator, cws: []const usize, which: RowBorder, pal: *const ColorPalette) !Line {
                        var line = Line.init(a);
                        const left: []const u8 = switch (which) {
                            .top => "┌",
                            .mid => "├",
                            .bottom => "└",
                        };
                        const mid: []const u8 = switch (which) {
                            .top => "┬",
                            .mid => "┼",
                            .bottom => "┴",
                        };
                        const right: []const u8 = switch (which) {
                            .top => "┐",
                            .mid => "┤",
                            .bottom => "┘",
                        };
                        const horiz = "─";
                        try line.append(left, .{ .fg = pal.border });
                        for (cws, 0..) |cw, i| {
                            var h: usize = 0;
                            while (h < cw + 2) : (h += 1) {
                                try line.append(horiz, .{ .fg = pal.border });
                            }
                            if (i < cws.len - 1) {
                                try line.append(mid, .{ .fg = pal.border });
                            }
                        }
                        try line.append(right, .{ .fg = pal.border });
                        return line;
                    }
                }.call;

                // Helper to draw a data row
                const drawRow = struct {
                    fn call(a: std.mem.Allocator, row_cells: []const TableCell, cws: []const usize, pal: *const ColorPalette, cell_style: Style) !Line {
                        var line = Line.init(a);
                        try line.append("│ ", .{ .fg = pal.border });
                        for (row_cells, 0..) |cell, ci| {
                            if (ci >= cws.len) break;
                            const cw = cws[ci];
                            // Render cell inlines into a temporary line to measure
                            var cell_lines: std.ArrayList(Line) = .empty;
                            defer {
                                for (cell_lines.items) |*cl| cl.deinit();
                                cell_lines.deinit(a);
                            }
                            try renderInlines(a, cell.inlines, cell_style, pal, &cell_lines, cw, 0);
                            const cell_text = if (cell_lines.items.len > 0)
                                blk: {
                                    // Extract text from first line segments
                                    var total_len: usize = 0;
                                    for (cell_lines.items[0].segments.items) |seg| total_len += seg.text.len;
                                    var buf = try a.alloc(u8, total_len);
                                    var pos: usize = 0;
                                    for (cell_lines.items[0].segments.items) |seg| {
                                        @memcpy(buf[pos..pos + seg.text.len], seg.text);
                                        pos += seg.text.len;
                                    }
                                    break :blk buf;
                                }
                            else
                                try a.dupe(u8, "");
                            defer a.free(cell_text);

                            const display = if (cell_text.len > cw) cell_text[0..cw] else cell_text;
                            try line.append(display, cell_style);
                            // Pad to column width
                            if (display.len < cw) {
                                const pad = try a.alloc(u8, cw - display.len);
                                defer a.free(pad);
                                @memset(pad, ' ');
                                try line.append(pad, cell_style);
                            }
                            try line.append(" │ ", .{ .fg = pal.border });
                        }
                        return line;
                    }
                }.call;

                // Top border
                try lines.append(alloc, try drawBorder(alloc, col_widths, .top, palette));

                // Header row
                try lines.append(alloc, try drawRow(alloc, t.headers.cells, col_widths, palette, header_style));

                // Middle border
                try lines.append(alloc, try drawBorder(alloc, col_widths, .mid, palette));

                // Data rows
                for (t.rows) |row| {
                    try lines.append(alloc, try drawRow(alloc, row.cells, col_widths, palette, .{ .fg = palette.fg }));
                }

                // Bottom border
                try lines.append(alloc, try drawBorder(alloc, col_widths, .bottom, palette));
                try lines.append(alloc, Line.init(alloc)); // blank after table
            },
            .horizontal_rule => {
                var hr = Line.init(alloc);
                try hr.append("─", .{ .fg = palette.border });
                var j: usize = 1;
                while (j < effective_width) : (j += 1) {
                    try hr.append("─", .{ .fg = palette.border });
                }
                try lines.append(alloc, hr);
            },
            .blank => {
                try lines.append(alloc, Line.init(alloc));
            },
        }
    }

    return lines;
}

/// Render a plain text string with optional markdown parsing
pub fn renderText(
    alloc: std.mem.Allocator,
    text: []const u8,
    width: u16,
    palette: *const ColorPalette,
) !std.ArrayList(Line) {
    var doc = try parse(alloc, text);
    defer doc.deinit();
    return render(alloc, &doc, width, palette);
}

// ============================================================================
// Tests
// ============================================================================

test "parse inline bold" {
    const alloc = std.testing.allocator;
    const inlines = try parseInlines(alloc, "Hello **world**!");
    defer alloc.free(inlines);

    try std.testing.expectEqual(@as(usize, 3), inlines.len);
    try std.testing.expectEqual(Inline.text, inlines[0]);
    try std.testing.expectEqualStrings("Hello ", inlines[0].text);
    try std.testing.expectEqual(Inline.bold, inlines[1]);
    try std.testing.expectEqualStrings("world", inlines[1].bold);
    try std.testing.expectEqualStrings("!", inlines[2].text);
}

test "parse inline italic" {
    const alloc = std.testing.allocator;
    const inlines = try parseInlines(alloc, "*italic* text");
    defer alloc.free(inlines);

    try std.testing.expectEqual(@as(usize, 2), inlines.len);
    try std.testing.expectEqualStrings("italic", inlines[0].italic);
    try std.testing.expectEqualStrings(" text", inlines[1].text);
}

test "parse inline code" {
    const alloc = std.testing.allocator;
    const inlines = try parseInlines(alloc, "Use `zig build` to compile");
    defer alloc.free(inlines);

    try std.testing.expectEqual(@as(usize, 3), inlines.len);
    try std.testing.expectEqualStrings("zig build", inlines[1].code);
}

test "parse inline link" {
    const alloc = std.testing.allocator;
    const inlines = try parseInlines(alloc, "Click [here](https://example.com) now");
    defer alloc.free(inlines);

    try std.testing.expectEqual(@as(usize, 3), inlines.len);
    try std.testing.expectEqualStrings("here", inlines[1].link.text);
    try std.testing.expectEqualStrings("https://example.com", inlines[1].link.url);
}

test "parse heading" {
    const alloc = std.testing.allocator;
    var doc = try parse(alloc, "# Hello World\n\nSome text.");
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 3), doc.blocks.items.len);
    try std.testing.expectEqual(Block.heading, doc.blocks.items[0]);
    try std.testing.expectEqual(@as(u8, 1), doc.blocks.items[0].heading.level);
    try std.testing.expectEqualStrings("Hello World", doc.blocks.items[0].heading.inlines[0].text);
}

test "parse code block" {
    const alloc = std.testing.allocator;
    var doc = try parse(alloc, "```zig\nconst x = 1;\n```");
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.items.len);
    try std.testing.expectEqual(Block.code_block, doc.blocks.items[0]);
    try std.testing.expectEqualStrings("zig", doc.blocks.items[0].code_block.language.?);
    try std.testing.expect(std.mem.containsAtLeast(u8, doc.blocks.items[0].code_block.content, 1, "const x"));
}

test "parse list item" {
    const alloc = std.testing.allocator;
    var doc = try parse(alloc, "- First item\n- Second item");
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.blocks.items.len);
    try std.testing.expectEqual(Block.list_item, doc.blocks.items[0]);
}

test "render markdown text" {
    const alloc = std.testing.allocator;
    const text = "# Title\n\nHello **world**!\n\n```zig\nconst x = 1;\n```";
    var lines = try renderText(alloc, text, 40, &theme.themes[0].palette);
    defer {
        for (lines.items) |*line| line.deinit();
        lines.deinit();
    }

    try std.testing.expect(lines.items.len > 0);
}

test "word wrap" {
    const alloc = std.testing.allocator;
    const lines = try wordWrap(alloc, "Hello world this is a test", 10);
    defer {
        for (lines) |l| alloc.free(l);
        alloc.free(lines);
    }
    try std.testing.expect(lines.len >= 2);
}
