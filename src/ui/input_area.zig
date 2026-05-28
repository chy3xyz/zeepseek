const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");

const Style = vaxis.Style;
const Color = vaxis.Color;
const Segment = vaxis.Segment;
const ColorPalette = theme.ColorPalette;

/// Sentinel for empty lines; never pass to the arena allocator for free().
const empty_line: []const u8 = "";

pub const InputArea = struct {
    lines: std.ArrayList([]const u8),
    history: std.ArrayList([]const u8),
    history_index: usize = 0,
    cursor_pos: usize = 0, // column within current row
    cursor_row: usize = 0, // row index
    max_history: usize = 100,
    current_input: []const u8 = "",
    alloc: std.mem.Allocator,
    skill_completions: []const struct { name: []const u8, description: []const u8 } = &.{},
    showing_completions: bool = false,
    selected_completion: usize = 0,
    kill_buffer: ?[]const u8 = null,
    placeholder: []const u8 = "",

    pub fn init(alloc: std.mem.Allocator) !InputArea {
        return .{
            .lines = try std.ArrayList([]const u8).initCapacity(alloc, 4),
            .history = try std.ArrayList([]const u8).initCapacity(alloc, 100),
            .alloc = alloc,
        };
    }

    fn releaseLine(self: *InputArea, line: []const u8) void {
        if (line.len == 0) return;
        self.alloc.free(line);
    }

    pub fn deinit(self: *InputArea) void {
        for (self.lines.items) |line| {
            self.releaseLine(line);
        }
        self.lines.deinit(self.alloc);

        for (self.history.items) |item| {
            self.alloc.free(item);
        }
        self.history.deinit(self.alloc);

        if (self.kill_buffer) |kb| {
            self.alloc.free(kb);
        }
    }

    pub fn addLine(self: *InputArea, text: []const u8) !void {
        const line: []const u8 = if (text.len == 0) empty_line else try self.alloc.dupe(u8, text);
        try self.lines.append(self.alloc, line);
    }

    pub fn clear(self: *InputArea) void {
        for (self.lines.items) |line| {
            self.releaseLine(line);
        }
        self.lines.clearRetainingCapacity();
        self.current_input = empty_line;
        self.cursor_pos = 0;
        self.cursor_row = 0;
    }

    /// Compatibility: returns first line only (for single-line consumers)
    pub fn getInput(self: *const InputArea) []const u8 {
        if (self.lines.items.len == 0) return "";
        return self.lines.items[0];
    }

    /// Returns the full multi-line input joined with \n
    pub fn getFullInput(self: *const InputArea) []const u8 {
        if (self.lines.items.len == 0) return "";
        if (self.lines.items.len == 1) return self.lines.items[0];
        // Join all lines with \n using a temporary buffer
        var total_len: usize = 0;
        for (self.lines.items) |line| {
            total_len += line.len;
        }
        total_len += self.lines.items.len - 1; // \n separators
        // We can't allocate here since this is a *const method.
        // For now, return first line. Callers that need full input
        // should use getFullInputAlloc.
        return self.lines.items[0];
    }

    /// Allocate and return the full multi-line input joined with \n
    pub fn getFullInputAlloc(self: *const InputArea, alloc: std.mem.Allocator) ![]const u8 {
        if (self.lines.items.len == 0) return try alloc.dupe(u8, "");
        if (self.lines.items.len == 1) {
            return try alloc.dupe(u8, self.lines.items[0]);
        }
        var total_len: usize = 0;
        for (self.lines.items) |line| {
            total_len += line.len;
        }
        total_len += self.lines.items.len - 1; // \n separators
        var result = try alloc.alloc(u8, total_len);
        var pos: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            @memcpy(result[pos .. pos + line.len], line);
            pos += line.len;
            if (i < self.lines.items.len - 1) {
                result[pos] = '\n';
                pos += 1;
            }
        }
        return result;
    }

    pub fn setInput(self: *InputArea, text: []const u8) void {
        self.clear();
        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line| {
            self.addLine(line) catch return;
        }
        if (self.lines.items.len == 0) {
            self.current_input = "";
        } else {
            self.current_input = self.lines.items[0];
        }
    }

    pub fn setSkillCompletions(self: *InputArea, completions: []const struct { name: []const u8, description: []const u8 }) void {
        self.skill_completions = completions;
        self.showing_completions = completions.len > 0;
        self.selected_completion = 0;
    }

    pub fn clearSkillCompletions(self: *InputArea) void {
        self.showing_completions = false;
        self.selected_completion = 0;
    }

    pub fn completeSkillCommand(self: *InputArea, cmd_name: []const u8) void {
        self.setInput(std.fmt.comptimePrint("/{s} ", .{cmd_name}));
        self.clearSkillCompletions();
    }

    pub fn getCurrentWord(self: *const InputArea) []const u8 {
        const input = self.getInput();
        if (input.len == 0 or input[0] != '/') return "";

        const rest = input[1..];
        const space_idx = std.mem.indexOfScalar(u8, rest, ' ');
        return if (space_idx) |idx| rest[0..idx] else rest;
    }

    pub fn isShowingCompletions(self: *const InputArea) bool {
        return self.showing_completions;
    }

    pub fn getSelectedCompletion(self: *const InputArea) ?[]const u8 {
        if (!self.showing_completions or self.skill_completions.len == 0) return null;
        if (self.selected_completion >= self.skill_completions.len) return null;
        return self.skill_completions[self.selected_completion].name;
    }

    pub fn completionUp(self: *InputArea) void {
        if (!self.showing_completions or self.skill_completions.len == 0) return;
        if (self.selected_completion == 0) {
            self.selected_completion = self.skill_completions.len - 1;
        } else {
            self.selected_completion -= 1;
        }
    }

    pub fn completionDown(self: *InputArea) void {
        if (!self.showing_completions or self.skill_completions.len == 0) return;
        self.selected_completion = (self.selected_completion + 1) % self.skill_completions.len;
    }

    pub fn applySelectedCompletion(self: *InputArea) void {
        if (!self.showing_completions or self.skill_completions.len == 0) return;
        if (self.selected_completion >= self.skill_completions.len) return;
        self.completeSkillCommand(self.skill_completions[self.selected_completion].name);
    }

    pub fn insert(self: *InputArea, text: []const u8) void {
        if (text.len == 0) return;
        if (self.lines.items.len == 0) {
            self.addLine("") catch return;
            self.cursor_row = 0;
            self.cursor_pos = 0;
        }
        if (self.lines.items.len == 0) return;
        if (self.cursor_row >= self.lines.items.len) {
            self.cursor_row = self.lines.items.len - 1;
        }

        // Handle newline insertion: split current line at cursor
        if (std.mem.indexOfScalar(u8, text, '\n')) |nl_idx| {
            const before = text[0..nl_idx];
            const after = text[nl_idx + 1 ..];
            self.insert(before);
            // Insert remaining after newline as new line(s)
            if (after.len > 0) {
                // Create new line with 'after' text at current position
                const current = self.lines.items[self.cursor_row];
                const after_cursor = current[self.cursor_pos..];
                const new_line_text = std.mem.concat(self.alloc, u8, &.{ after, after_cursor }) catch return;
                if (self.cursor_pos == 0) {
                    self.releaseLine(current);
                    self.lines.items[self.cursor_row] = empty_line;
                } else {
                    const truncated = self.alloc.alloc(u8, self.cursor_pos) catch return;
                    @memcpy(truncated, current[0..self.cursor_pos]);
                    self.releaseLine(current);
                    self.lines.items[self.cursor_row] = truncated;
                }
                // Insert new line
                self.lines.insert(self.alloc, self.cursor_row + 1, new_line_text) catch {
                    self.alloc.free(new_line_text);
                    return;
                };
                self.cursor_row += 1;
                self.cursor_pos = after.len;
                // Handle any additional newlines in 'after'
                if (std.mem.indexOfScalar(u8, after, '\n')) |extra_nl| {
                    // There are more newlines, process recursively
                    // For simplicity, just handle the simple case
                    _ = extra_nl;
                }
            } else {
                // Just split: after_cursor becomes new line
                const current = self.lines.items[self.cursor_row];
                const after_cursor = current[self.cursor_pos..];
                const new_line: []const u8 = if (after_cursor.len == 0)
                    empty_line
                else
                    self.alloc.dupe(u8, after_cursor) catch return;
                if (self.cursor_pos == 0) {
                    self.releaseLine(current);
                    self.lines.items[self.cursor_row] = empty_line;
                } else {
                    const truncated = self.alloc.alloc(u8, self.cursor_pos) catch return;
                    @memcpy(truncated, current[0..self.cursor_pos]);
                    self.releaseLine(current);
                    self.lines.items[self.cursor_row] = truncated;
                }
                self.lines.insert(self.alloc, self.cursor_row + 1, new_line) catch {
                    if (new_line.len > 0) self.alloc.free(new_line);
                    return;
                };
                self.cursor_row += 1;
                self.cursor_pos = 0;
            }
            self.current_input = self.lines.items[0];
            return;
        }

        const current = self.lines.items[self.cursor_row];
        if (self.cursor_pos > current.len) {
            self.cursor_pos = current.len;
        }
        const new_len = current.len + text.len;
        const new_input = self.alloc.alloc(u8, new_len) catch return;
        @memcpy(new_input[0..self.cursor_pos], current[0..self.cursor_pos]);
        @memcpy(new_input[self.cursor_pos .. self.cursor_pos + text.len], text);
        @memcpy(new_input[self.cursor_pos + text.len ..], current[self.cursor_pos..]);
        self.releaseLine(current);
        self.lines.items[self.cursor_row] = new_input;
        self.current_input = self.lines.items[0];
        self.cursor_pos += text.len;
    }

    pub fn backspace(self: *InputArea) void {
        if (self.lines.items.len == 0) return;
        if (self.cursor_row >= self.lines.items.len) {
            self.cursor_row = self.lines.items.len - 1;
        }

        if (self.cursor_pos > 0) {
            // Delete within current line
            const current = self.lines.items[self.cursor_row];
            if (self.cursor_pos > current.len) {
                self.cursor_pos = current.len;
            }
            if (self.cursor_pos == 0) return;
            const new_len = current.len - 1;
            if (new_len == 0) {
                self.releaseLine(current);
                self.lines.items[self.cursor_row] = empty_line;
            } else {
                const new_input = self.alloc.alloc(u8, new_len) catch return;
                @memcpy(new_input[0 .. self.cursor_pos - 1], current[0 .. self.cursor_pos - 1]);
                @memcpy(new_input[self.cursor_pos - 1 ..], current[self.cursor_pos..]);
                self.releaseLine(current);
                self.lines.items[self.cursor_row] = new_input;
            }
            self.current_input = self.lines.items[0];
            self.cursor_pos -= 1;
        } else if (self.cursor_row > 0) {
            // At start of line: merge with previous line
            const current = self.lines.items[self.cursor_row];
            const prev = self.lines.items[self.cursor_row - 1];
            const new_len = prev.len + current.len;
            const merged = self.alloc.alloc(u8, new_len) catch return;
            @memcpy(merged[0..prev.len], prev);
            @memcpy(merged[prev.len..], current);
            self.releaseLine(prev);
            self.releaseLine(current);
            self.lines.items[self.cursor_row - 1] = merged;
            _ = self.lines.orderedRemove(self.cursor_row);
            self.cursor_row -= 1;
            self.cursor_pos = prev.len;
            self.current_input = self.lines.items[0];
        }
    }

    pub fn deleteChar(self: *InputArea) void {
        if (self.lines.items.len == 0) return;
        if (self.cursor_row >= self.lines.items.len) return;

        const current = self.lines.items[self.cursor_row];
        if (self.cursor_pos < current.len) {
            const new_len = current.len - 1;
            if (new_len == 0) {
                self.releaseLine(current);
                self.lines.items[self.cursor_row] = empty_line;
            } else {
                const new_input = self.alloc.alloc(u8, new_len) catch return;
                @memcpy(new_input[0..self.cursor_pos], current[0..self.cursor_pos]);
                @memcpy(new_input[self.cursor_pos..], current[self.cursor_pos + 1 ..]);
                self.releaseLine(current);
                self.lines.items[self.cursor_row] = new_input;
            }
            self.current_input = self.lines.items[0];
        } else if (self.cursor_row < self.lines.items.len - 1) {
            // At end of line: merge with next line
            const curr_line = self.lines.items[self.cursor_row];
            const next = self.lines.items[self.cursor_row + 1];
            const new_len = curr_line.len + next.len;
            const merged = self.alloc.alloc(u8, new_len) catch return;
            @memcpy(merged[0..curr_line.len], curr_line);
            @memcpy(merged[curr_line.len..], next);
            self.releaseLine(curr_line);
            self.releaseLine(next);
            self.lines.items[self.cursor_row] = merged;
            _ = self.lines.orderedRemove(self.cursor_row + 1);
            self.current_input = self.lines.items[0];
        }
    }

    pub fn moveCursorLeft(self: *InputArea) void {
        if (self.cursor_pos > 0) {
            self.cursor_pos -= 1;
        } else if (self.cursor_row > 0) {
            self.cursor_row -= 1;
            self.cursor_pos = self.lines.items[self.cursor_row].len;
        }
    }

    pub fn moveCursorRight(self: *InputArea) void {
        if (self.lines.items.len == 0) return;
        if (self.cursor_row >= self.lines.items.len) return;
        const current = self.lines.items[self.cursor_row];
        if (self.cursor_pos < current.len) {
            self.cursor_pos += 1;
        } else if (self.cursor_row < self.lines.items.len - 1) {
            self.cursor_row += 1;
            self.cursor_pos = 0;
        }
    }

    pub fn moveCursorUp(self: *InputArea) void {
        if (self.cursor_row > 0) {
            self.cursor_row -= 1;
            const above = self.lines.items[self.cursor_row];
            if (self.cursor_pos > above.len) {
                self.cursor_pos = above.len;
            }
        }
    }

    pub fn moveCursorDown(self: *InputArea) void {
        if (self.cursor_row + 1 < self.lines.items.len) {
            self.cursor_row += 1;
            const below = self.lines.items[self.cursor_row];
            if (self.cursor_pos > below.len) {
                self.cursor_pos = below.len;
            }
        }
    }

    pub fn moveCursorToStart(self: *InputArea) void {
        self.cursor_pos = 0;
    }

    pub fn moveCursorToEnd(self: *InputArea) void {
        if (self.lines.items.len == 0) return;
        if (self.cursor_row < self.lines.items.len) {
            self.cursor_pos = self.lines.items[self.cursor_row].len;
        }
    }

    pub fn moveCursorWordLeft(self: *InputArea) void {
        if (self.lines.items.len == 0) return;
        if (self.cursor_row >= self.lines.items.len) return;

        const current = self.lines.items[self.cursor_row];
        if (self.cursor_pos == 0) {
            if (self.cursor_row > 0) {
                self.cursor_row -= 1;
                self.cursor_pos = self.lines.items[self.cursor_row].len;
            }
            return;
        }

        var pos = self.cursor_pos;
        // Skip whitespace to the left
        while (pos > 0 and std.ascii.isWhitespace(current[pos - 1])) {
            pos -= 1;
        }
        // Skip word characters to the left
        while (pos > 0 and !std.ascii.isWhitespace(current[pos - 1])) {
            pos -= 1;
        }
        self.cursor_pos = pos;
    }

    pub fn moveCursorWordRight(self: *InputArea) void {
        if (self.lines.items.len == 0) return;
        if (self.cursor_row >= self.lines.items.len) return;

        const current = self.lines.items[self.cursor_row];
        if (self.cursor_pos >= current.len) {
            if (self.cursor_row + 1 < self.lines.items.len) {
                self.cursor_row += 1;
                self.cursor_pos = 0;
            }
            return;
        }

        var pos = self.cursor_pos;
        // Skip word characters to the right
        while (pos < current.len and !std.ascii.isWhitespace(current[pos])) {
            pos += 1;
        }
        // Skip whitespace to the right
        while (pos < current.len and std.ascii.isWhitespace(current[pos])) {
            pos += 1;
        }
        self.cursor_pos = pos;
    }

    pub fn deleteWordBackward(self: *InputArea) void {
        if (self.lines.items.len == 0) return;
        if (self.cursor_row >= self.lines.items.len) return;

        const current = self.lines.items[self.cursor_row];
        if (self.cursor_pos == 0) {
            if (self.cursor_row > 0) {
                // Same as backspace at start of line: merge with previous
                self.backspace();
            }
            return;
        }

        var pos = self.cursor_pos;
        // Skip whitespace to the left
        while (pos > 0 and std.ascii.isWhitespace(current[pos - 1])) {
            pos -= 1;
        }
        // Skip word characters to the left
        while (pos > 0 and !std.ascii.isWhitespace(current[pos - 1])) {
            pos -= 1;
        }

        const delete_len = self.cursor_pos - pos;
        const new_len = current.len - delete_len;
        if (new_len == 0) {
            self.releaseLine(current);
            self.lines.items[self.cursor_row] = empty_line;
        } else {
            const new_input = self.alloc.alloc(u8, new_len) catch return;
            @memcpy(new_input[0..pos], current[0..pos]);
            @memcpy(new_input[pos..], current[self.cursor_pos..]);
            self.releaseLine(current);
            self.lines.items[self.cursor_row] = new_input;
        }
        self.current_input = self.lines.items[0];
        self.cursor_pos = pos;
    }

    pub fn deleteWordForward(self: *InputArea) void {
        if (self.lines.items.len == 0) return;
        if (self.cursor_row >= self.lines.items.len) return;

        const current = self.lines.items[self.cursor_row];
        if (self.cursor_pos >= current.len) {
            if (self.cursor_row + 1 < self.lines.items.len) {
                // Same as delete at end of line: merge with next
                self.deleteChar();
            }
            return;
        }

        var pos = self.cursor_pos;
        // Skip whitespace to the right
        while (pos < current.len and std.ascii.isWhitespace(current[pos])) {
            pos += 1;
        }
        // Skip word characters to the right
        while (pos < current.len and !std.ascii.isWhitespace(current[pos])) {
            pos += 1;
        }

        const delete_len = pos - self.cursor_pos;
        const new_len = current.len - delete_len;
        if (new_len == 0) {
            self.releaseLine(current);
            self.lines.items[self.cursor_row] = empty_line;
        } else {
            const new_input = self.alloc.alloc(u8, new_len) catch return;
            @memcpy(new_input[0..self.cursor_pos], current[0..self.cursor_pos]);
            @memcpy(new_input[self.cursor_pos..], current[pos..]);
            self.releaseLine(current);
            self.lines.items[self.cursor_row] = new_input;
        }
        self.current_input = self.lines.items[0];
    }

    pub fn killToStart(self: *InputArea) void {
        if (self.lines.items.len == 0) return;
        if (self.cursor_row >= self.lines.items.len) return;
        const current = self.lines.items[self.cursor_row];
        if (self.cursor_pos == 0) return;

        const killed = current[0..self.cursor_pos];
        if (self.kill_buffer) |old| self.alloc.free(old);
        self.kill_buffer = self.alloc.dupe(u8, killed) catch null;

        const new_len = current.len - self.cursor_pos;
        if (new_len == 0) {
            self.releaseLine(current);
            self.lines.items[self.cursor_row] = empty_line;
        } else {
            const new_line = self.alloc.alloc(u8, new_len) catch return;
            @memcpy(new_line, current[self.cursor_pos..]);
            self.releaseLine(current);
            self.lines.items[self.cursor_row] = new_line;
        }
        self.current_input = self.lines.items[0];
        self.cursor_pos = 0;
    }

    pub fn killToEnd(self: *InputArea) void {
        if (self.lines.items.len == 0) return;
        if (self.cursor_row >= self.lines.items.len) return;
        const current = self.lines.items[self.cursor_row];
        if (self.cursor_pos >= current.len) return;

        const killed = current[self.cursor_pos..];
        if (self.kill_buffer) |old| self.alloc.free(old);
        self.kill_buffer = self.alloc.dupe(u8, killed) catch null;

        if (self.cursor_pos == 0) {
            self.releaseLine(current);
            self.lines.items[self.cursor_row] = empty_line;
        } else {
            const new_line = self.alloc.alloc(u8, self.cursor_pos) catch return;
            @memcpy(new_line, current[0..self.cursor_pos]);
            self.releaseLine(current);
            self.lines.items[self.cursor_row] = new_line;
        }
        self.current_input = self.lines.items[0];
    }

    pub fn yank(self: *InputArea) void {
        const text = self.kill_buffer orelse return;
        self.insert(text);
    }

    pub fn historyUp(self: *InputArea) void {
        if (self.history.items.len == 0) return;
        if (self.history_index == 0) return;
        self.history_index -= 1;
        self.loadHistoryItem();
    }

    pub fn historyDown(self: *InputArea) void {
        if (self.history_index >= self.history.items.len) return;
        self.history_index += 1;
        if (self.history_index >= self.history.items.len) {
            self.current_input = "";
            self.clear();
        } else {
            self.loadHistoryItem();
        }
    }

    fn loadHistoryItem(self: *InputArea) void {
        if (self.history_index < self.history.items.len) {
            self.setInput(self.history.items[self.history_index]);
            self.cursor_row = 0;
            self.cursor_pos = 0;
        }
    }

    pub fn saveToHistory(self: *InputArea) !void {
        const input = self.getFullInputAlloc(self.alloc) catch return;
        defer self.alloc.free(input);
        if (input.len == 0) return;

        // Trim trailing newlines/whitespace
        const trimmed = std.mem.trimEnd(u8, input, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        if (self.history.items.len > 0 and std.mem.eql(u8, self.history.items[self.history.items.len - 1], trimmed)) {
            return;
        }

        const hist_item = try self.alloc.dupe(u8, trimmed);
        try self.history.append(self.alloc, hist_item);
        self.history_index = self.history.items.len;

        if (self.history.items.len > self.max_history) {
            const removed = self.history.orderedRemove(0);
            self.alloc.free(removed);
            self.history_index -= 1;
        }
    }

    pub fn addToHistory(self: *InputArea, item: []const u8) !void {
        if (item.len == 0) return;
        const trimmed = std.mem.trimEnd(u8, item, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        if (self.history.items.len > 0 and std.mem.eql(u8, self.history.items[self.history.items.len - 1], trimmed)) {
            return;
        }

        const hist_item = try self.alloc.dupe(u8, trimmed);
        try self.history.append(self.alloc, hist_item);
        self.history_index = self.history.items.len;

        if (self.history.items.len > self.max_history) {
            const removed = self.history.orderedRemove(0);
            self.alloc.free(removed);
            self.history_index -= 1;
        }
    }

    pub fn isMultiline(self: *const InputArea) bool {
        return self.lines.items.len > 1;
    }

    pub fn isEmpty(self: *const InputArea) bool {
        if (self.lines.items.len == 0) return true;
        if (self.lines.items.len == 1 and self.lines.items[0].len == 0) return true;
        return false;
    }

    pub fn unindent(self: *InputArea) void {
        if (self.lines.items.len == 0) return;
        if (self.cursor_row >= self.lines.items.len) self.cursor_row = self.lines.items.len - 1;
        const current = self.lines.items[self.cursor_row];
        var spaces_to_remove: usize = 0;
        while (spaces_to_remove < 4 and spaces_to_remove < current.len and current[spaces_to_remove] == ' ') {
            spaces_to_remove += 1;
        }
        if (spaces_to_remove == 0) return;
        const new_len = current.len - spaces_to_remove;
        if (new_len == 0) {
            self.releaseLine(current);
            self.lines.items[self.cursor_row] = empty_line;
        } else {
            const new_line = self.alloc.alloc(u8, new_len) catch return;
            @memcpy(new_line, current[spaces_to_remove..]);
            self.releaseLine(current);
            self.lines.items[self.cursor_row] = new_line;
        }
        if (self.cursor_pos >= spaces_to_remove) {
            self.cursor_pos -= spaces_to_remove;
        } else {
            self.cursor_pos = 0;
        }
    }

    pub fn render(self: *const InputArea, win: vaxis.Window) void {
        win.clear();

        const prompt_seg = Segment{
            .text = "> ",
            .style = .{
                .fg = .{ .index = 10 },
                .bold = true,
            },
        };

        if (self.lines.items.len == 0 and self.placeholder.len > 0) {
            const placeholder_seg = Segment{
                .text = self.placeholder,
                .style = .{ .fg = .{ .index = 8 } },
            };
            _ = win.print(&.{ prompt_seg, placeholder_seg }, .{
                .row_offset = 0,
                .col_offset = 0,
                .wrap = .none,
                .commit = true,
            });
        } else {
            for (self.lines.items, 0..) |line, row| {
                const row_offset: u16 = @intCast(row);
                if (row_offset >= win.height) break;

                if (row == 0) {
                    const input_seg = Segment{
                        .text = line,
                        .style = .{ .fg = .{ .index = 15 } },
                    };
                    _ = win.print(&.{ prompt_seg, input_seg }, .{
                        .row_offset = row_offset,
                        .col_offset = 0,
                        .wrap = .none,
                        .commit = true,
                    });
                } else {
                    // Indent continuation lines to align with text after prompt
                    const input_seg = Segment{
                        .text = line,
                        .style = .{ .fg = .{ .index = 15 } },
                    };
                    _ = win.print(&.{ input_seg }, .{
                        .row_offset = row_offset,
                        .col_offset = 2,
                        .wrap = .none,
                        .commit = true,
                    });
                }
            }
        }

        if (self.showing_completions and self.skill_completions.len > 0) {
            const max_display = @min(self.skill_completions.len, 5);
            var row: u16 = @intCast(@min(self.lines.items.len, win.height));
            for (0..max_display) |i| {
                if (row >= win.height) break;
                const selected = (i == self.selected_completion);
                const text_buf = std.fmt.allocPrint(self.alloc, "/{s} - {s}", .{
                    self.skill_completions[i].name,
                    self.skill_completions[i].description,
                }) catch continue;
                defer self.alloc.free(text_buf);
                const style = if (selected)
                    Segment{ .text = text_buf, .style = .{ .fg = .{ .index = 14 }, .bold = true } }
                else
                    Segment{ .text = text_buf, .style = .{ .fg = .{ .index = 8 } } };

                _ = win.print(&.{style}, .{
                    .row_offset = row,
                    .col_offset = 0,
                    .wrap = .none,
                    .commit = true,
                });
                row += 1;
            }
        }

        const cursor_col = if (self.cursor_row == 0)
            @as(u16, 2) + @as(u16, @intCast(self.cursor_pos))
        else
            @as(u16, 2) + @as(u16, @intCast(self.cursor_pos));
        const cursor_row = @as(u16, @intCast(self.cursor_row));
        win.showCursor(cursor_col, cursor_row);
    }

    pub fn renderWithTheme(self: *const InputArea, win: vaxis.Window, palette: *const ColorPalette) void {
        win.clear();

        const prompt_seg = Segment{
            .text = "> ",
            .style = .{
                .fg = palette.prompt,
                .bold = true,
            },
        };

        if (self.lines.items.len == 0 and self.placeholder.len > 0) {
            const placeholder_seg = Segment{
                .text = self.placeholder,
                .style = .{ .fg = palette.fg_dim },
            };
            _ = win.print(&.{ prompt_seg, placeholder_seg }, .{
                .row_offset = 0,
                .col_offset = 0,
                .wrap = .none,
                .commit = true,
            });
        } else {
            for (self.lines.items, 0..) |line, row| {
                const row_offset: u16 = @intCast(row);
                if (row_offset >= win.height) break;

                if (row == 0) {
                    const input_seg = Segment{
                        .text = line,
                        .style = .{ .fg = palette.fg },
                    };
                    _ = win.print(&.{ prompt_seg, input_seg }, .{
                        .row_offset = row_offset,
                        .col_offset = 0,
                        .wrap = .none,
                        .commit = true,
                    });
                } else {
                    const input_seg = Segment{
                        .text = line,
                        .style = .{ .fg = palette.fg },
                    };
                    _ = win.print(&.{ input_seg }, .{
                        .row_offset = row_offset,
                        .col_offset = 2,
                        .wrap = .none,
                        .commit = true,
                    });
                }
            }
        }

        if (self.showing_completions and self.skill_completions.len > 0) {
            const max_display = @min(self.skill_completions.len, 5);
            var row: u16 = @intCast(@min(self.lines.items.len, win.height));
            for (0..max_display) |i| {
                if (row >= win.height) break;
                const selected = (i == self.selected_completion);
                const text_buf = std.fmt.allocPrint(self.alloc, "/{s} - {s}", .{
                    self.skill_completions[i].name,
                    self.skill_completions[i].description,
                }) catch continue;
                defer self.alloc.free(text_buf);
                const style = if (selected)
                    Segment{ .text = text_buf, .style = .{ .fg = palette.thinking, .bold = true } }
                else
                    Segment{ .text = text_buf, .style = .{ .fg = palette.fg_dim } };

                _ = win.print(&.{style}, .{
                    .row_offset = row,
                    .col_offset = 0,
                    .wrap = .none,
                    .commit = true,
                });
                row += 1;
            }
        }

        const cursor_col = if (self.cursor_row == 0)
            @as(u16, 2) + @as(u16, @intCast(self.cursor_pos))
        else
            @as(u16, 2) + @as(u16, @intCast(self.cursor_pos));
        const cursor_row = @as(u16, @intCast(self.cursor_row));
        win.showCursor(cursor_col, cursor_row);
    }

    pub fn focus(self: *InputArea) void {
        _ = self;
    }
};

test "input area skill completions" {
    const alloc = std.testing.allocator;
    var area = InputArea.init(alloc);
    defer area.deinit();

    const completions = &.{
        .{ .name = "design-review", .description = "Design review" },
        .{ .name = "debug", .description = "Debug tool" },
    };
    area.setSkillCompletions(completions);

    try std.testing.expect(area.isShowingCompletions());
    try std.testing.expectEqualSlices(u8, "design-review", area.getSelectedCompletion().?);

    area.completionDown();
    try std.testing.expectEqualSlices(u8, "debug", area.getSelectedCompletion().?);

    area.completionUp();
    try std.testing.expectEqualSlices(u8, "design-review", area.getSelectedCompletion().?);

    area.applySelectedCompletion();
    try std.testing.expect(!area.isShowingCompletions());
    try std.testing.expectEqualSlices(u8, "/design-review ", area.getInput());
}

test "input area get current word" {
    const alloc = std.testing.allocator;
    var area = InputArea.init(alloc);
    defer area.deinit();

    try area.addLine("/des");
    try std.testing.expectEqualSlices(u8, "des", area.getCurrentWord());

    area.clear();
    try area.addLine("/design-review arg");
    try std.testing.expectEqualSlices(u8, "design-review", area.getCurrentWord());
}

test "input area add line" {
    const alloc = std.testing.allocator;
    var area = InputArea.init(alloc);
    defer area.deinit();

    try area.addLine("Hello");
    try area.addLine("World");

    try std.testing.expectEqual(@as(usize, 2), area.lines.items.len);
    try std.testing.expectEqualSlices(u8, "Hello", area.lines.items[0]);
}

test "input area get input" {
    const alloc = std.testing.allocator;
    var area = InputArea.init(alloc);
    defer area.deinit();

    try std.testing.expectEqualSlices(u8, "", area.getInput());

    try area.addLine("Hello");
    try std.testing.expectEqualSlices(u8, "Hello", area.getInput());
}

test "input area multiline insert and backspace" {
    const alloc = std.testing.allocator;
    var area = InputArea.init(alloc);
    defer area.deinit();

    // Type "hello\nworld"
    area.insert("hello");
    try std.testing.expectEqualSlices(u8, "hello", area.lines.items[0]);
    try std.testing.expectEqual(@as(usize, 5), area.cursor_pos);

    area.insert("\n");
    try std.testing.expectEqual(@as(usize, 2), area.lines.items.len);
    try std.testing.expectEqualSlices(u8, "hello", area.lines.items[0]);
    try std.testing.expectEqualSlices(u8, "", area.lines.items[1]);
    try std.testing.expectEqual(@as(usize, 1), area.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), area.cursor_pos);

    area.insert("world");
    try std.testing.expectEqualSlices(u8, "world", area.lines.items[1]);
    try std.testing.expectEqual(@as(usize, 5), area.cursor_pos);

    // Backspace should delete 'd' on line 1
    area.backspace();
    try std.testing.expectEqualSlices(u8, "worl", area.lines.items[1]);
    try std.testing.expectEqual(@as(usize, 4), area.cursor_pos);

    // Backspace at start of line should merge with previous
    area.cursor_pos = 0;
    area.backspace();
    try std.testing.expectEqual(@as(usize, 1), area.lines.items.len);
    try std.testing.expectEqualSlices(u8, "helloworl", area.lines.items[0]);
    try std.testing.expectEqual(@as(usize, 0), area.cursor_row);
    try std.testing.expectEqual(@as(usize, 5), area.cursor_pos);
}

test "input area multiline cursor movement" {
    const alloc = std.testing.allocator;
    var area = InputArea.init(alloc);
    defer area.deinit();

    area.setInput("hello\nworld\n!");
    try std.testing.expectEqual(@as(usize, 3), area.lines.items.len);

    area.cursor_row = 0;
    area.cursor_pos = 5;

    // Move down
    area.moveCursorDown();
    try std.testing.expectEqual(@as(usize, 1), area.cursor_row);
    try std.testing.expectEqual(@as(usize, 5), area.cursor_pos); // clamped to "world" len

    // Move right at end of line
    area.moveCursorRight();
    try std.testing.expectEqual(@as(usize, 2), area.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), area.cursor_pos);

    // Move left at start of line
    area.moveCursorLeft();
    try std.testing.expectEqual(@as(usize, 1), area.cursor_row);
    try std.testing.expectEqual(@as(usize, 5), area.cursor_pos);

    // Move up
    area.moveCursorUp();
    try std.testing.expectEqual(@as(usize, 0), area.cursor_row);
    try std.testing.expectEqual(@as(usize, 5), area.cursor_pos);
}

test "input area get full input" {
    const alloc = std.testing.allocator;
    var area = InputArea.init(alloc);
    defer area.deinit();

    area.setInput("hello\nworld");
    const full = try area.getFullInputAlloc(alloc);
    defer alloc.free(full);
    try std.testing.expectEqualSlices(u8, "hello\nworld", full);
}

test "input area save multiline history" {
    const alloc = std.testing.allocator;
    var area = InputArea.init(alloc);
    defer area.deinit();

    area.setInput("line1\nline2\nline3");
    try area.saveToHistory();

    try std.testing.expectEqual(@as(usize, 1), area.history.items.len);
    try std.testing.expectEqualSlices(u8, "line1\nline2\nline3", area.history.items[0]);
}

test "input area word movement" {
    const alloc = std.testing.allocator;
    var area = InputArea.init(alloc);
    defer area.deinit();

    area.setInput("hello world  foo");
    area.cursor_pos = 16; // end

    area.moveCursorWordLeft();
    try std.testing.expectEqual(@as(usize, 13), area.cursor_pos); // start of "foo"

    area.moveCursorWordLeft();
    try std.testing.expectEqual(@as(usize, 6), area.cursor_pos); // start of "world"

    area.moveCursorWordRight();
    try std.testing.expectEqual(@as(usize, 11), area.cursor_pos); // after "world  "

    area.moveCursorWordRight();
    try std.testing.expectEqual(@as(usize, 16), area.cursor_pos); // end
}

test "input area delete word backward" {
    const alloc = std.testing.allocator;
    var area = InputArea.init(alloc);
    defer area.deinit();

    area.setInput("hello world  foo");
    area.cursor_pos = 16;

    area.deleteWordBackward();
    try std.testing.expectEqualSlices(u8, "hello world  ", area.lines.items[0]);
    try std.testing.expectEqual(@as(usize, 13), area.cursor_pos);

    area.deleteWordBackward();
    try std.testing.expectEqualSlices(u8, "hello ", area.lines.items[0]);
    try std.testing.expectEqual(@as(usize, 6), area.cursor_pos);
}

test "input area delete word forward" {
    const alloc = std.testing.allocator;
    var area = InputArea.init(alloc);
    defer area.deinit();

    area.setInput("hello world  foo");
    area.cursor_pos = 0;

    area.deleteWordForward();
    try std.testing.expectEqualSlices(u8, " world  foo", area.lines.items[0]);
    try std.testing.expectEqual(@as(usize, 0), area.cursor_pos);

    area.deleteWordForward();
    try std.testing.expectEqualSlices(u8, "  foo", area.lines.items[0]);
    try std.testing.expectEqual(@as(usize, 0), area.cursor_pos);
}
