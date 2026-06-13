//! Zeepseek TUI — ZigZag Elm Architecture
//!
//! New main entry point using ZigZag's Model-Update-View pattern.
//! Replaces the monolithic tui.zig with clean, componentized architecture.
//!
//! Architecture:
//!   App (root Model)
//!   - messages[]       (chat history)
//!   - input editing    (inline)
//!   - command palette  (overlay)
//!   - help overlay     (overlay)

const std = @import("std");
const zz = @import("zigzag");
const cc = @import("c");
const stream_client_mod = @import("../net/stream_client.zig");
const SlashDispatcher = @import("slash_command_dispatcher.zig");
const theme = @import("theme.zig");
const dispatch_loop = @import("../dispatch/cache_first_loop.zig");
const zeep_config = @import("../utils/config.zig");
const tools_mod = @import("../tools/mod.zig");
const ProviderManager = @import("../providers/manager.zig").ProviderManager;
const ProviderConfig = @import("../providers/manager.zig").ProviderConfig;
const I18nManager = @import("../i18n/manager.zig").I18nManager;
const Sandbox = @import("../utils/sandbox.zig").Sandbox;
const subagent_mod = @import("../agent/subagent.zig");
const skills_registry = @import("../skills/registry.zig");
const session_manager = @import("../storage/session_manager.zig");
const ContextManager = @import("../dispatch/context_manager.zig").ContextManager;
const ImmutablePrefix = @import("../dispatch/context_manager.zig").ImmutablePrefix;
const reasonix_mod = @import("../cache/reasonix.zig");

const join = zz.join;

const CacheDecision = enum { none, hit, miss };

// ═══════════════════════════════════════════════════════════════════════
// ANSI helpers — from theme.zig Pal (Catppuccin Mocha)
// ═══════════════════════════════════════════════════════════════════════

const Pal = theme.Pal;
const R = Pal.R;
const B = Pal.B;
const D = Pal.D;
const U = Pal.U;
const I = "\x1b[3m";      // italic

const CodeBg = Pal.bg_code;
const CodeInlineBg = Pal.bg_code_inline;
const SearchHighlight = Pal.bg_highlight;

// ═══════════════════════════════════════════════════════════════════════
// Formatting helpers
// ═══════════════════════════════════════════════════════════════════════

fn appendFmt(buf: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (std.fmt.allocPrint(a, fmt, args)) |s| {
        buf.appendSlice(a, s) catch {};
    } else |_| {}
}

// ═══════════════════════════════════════════════════════════════════════
// Markdown → ANSI renderer (lightweight, inline)
// ═══════════════════════════════════════════════════════════════════════

fn renderMarkdownAnsi(buf: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8, width: u16) void {
    var in_code_block = false;
    var code_lang: []const u8 = "";
    var code_lines: [512][]const u8 = undefined;
    var code_count: usize = 0;
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line| {
        // Code block fence
        if (std.mem.startsWith(u8, line, "```")) {
            if (in_code_block) {
                // Render accumulated code block with line numbers
                renderCodeBlockWithLineNums(buf, a, &code_lines, code_count, code_lang, width);
                code_count = 0;
                in_code_block = false;
            } else {
                in_code_block = true;
                code_lang = if (line.len > 3) std.mem.trim(u8, line[3..], " ") else "";
                code_count = 0;
            }
            continue;
        }

        if (in_code_block) {
            if (code_count < code_lines.len) {
                code_lines[code_count] = line;
                code_count += 1;
            }
            continue;
        }

        // Headings
        if (std.mem.startsWith(u8, line, "# ")) {
            appendFmt(buf, a, "{s}{s}{s}{s}\n", .{ B, Pal.blue, line[2..], R });
            continue;
        }
        if (std.mem.startsWith(u8, line, "## ")) {
            appendFmt(buf, a, "{s}{s}{s}{s}\n", .{ B, Pal.green, line[3..], R });
            continue;
        }
        if (std.mem.startsWith(u8, line, "### ")) {
            appendFmt(buf, a, "{s}{s}{s}{s}\n", .{ B, Pal.yellow, line[4..], R });
            continue;
        }

        // Horizontal rule
        if (line.len >= 3 and std.mem.allEqual(u8, line, '-')) {
            appendFmt(buf, a, "{s}", .{D});
            var col: u16 = 0;
            while (col < width) : (col += 1) { buf.appendSlice(a, "x") catch {}; }
            appendFmt(buf, a, "{s}\n", .{R});
            continue;
        }

        // List items
        if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) {
            appendFmt(buf, a, "  {s}•{s} ", .{ Pal.green, R });
            renderInlineAnsi(buf, a, line[2..]);
            buf.appendSlice(a, "\n") catch {};
            continue;
        }
        if (line.len >= 3 and line[0] >= '1' and line[0] <= '9' and (line[1] == '.' or (line[1] >= '0' and line[1] <= '9' and line[2] == '.'))) {
            const dot = std.mem.indexOfScalar(u8, line, '.') orelse 0;
            appendFmt(buf, a, "  {s}{s}{s} ", .{ Pal.green, line[0 .. dot + 1], R });
            renderInlineAnsi(buf, a, std.mem.trim(u8, line[dot + 1 ..], " "));
            buf.appendSlice(a, "\n") catch {};
            continue;
        }

        // Blockquote
        if (std.mem.startsWith(u8, line, "> ")) {
            appendFmt(buf, a, "  {s}|{s} {s}", .{ D, R, line[2..] });
            buf.appendSlice(a, R) catch {};
            buf.appendSlice(a, "\n") catch {};
            continue;
        }

        // Regular paragraph
        renderInlineAnsi(buf, a, line);
        buf.appendSlice(a, "\n") catch {};
    }
    // Unclosed code block
    if (in_code_block) {
        renderCodeBlockWithLineNums(buf, a, &code_lines, code_count, code_lang, width);
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Code block renderer with line numbers
// ═══════════════════════════════════════════════════════════════════════

fn renderCodeBlockWithLineNums(
    buf: *std.ArrayList(u8),
    a: std.mem.Allocator,
    code_lines: [][]const u8,
    count: usize,
    lang: []const u8,
    width: u16,
) void {
    if (count == 0) {
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, "+---") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, "\n") catch {};
        return;
    }

    // Line number width: enough digits for max line number
    var digits: usize = 1;
    if (count >= 100) digits = 3 else if (count >= 10) digits = 2;
    const gutter_w = @as(u16, @intCast(digits + 2)); // " N │ "
    const content_w = if (width > gutter_w) width - gutter_w else 10;

    // Header
    buf.appendSlice(a, D) catch {};
    buf.appendSlice(a, "┌─") catch {};
    buf.appendSlice(a, R) catch {};
    buf.appendSlice(a, B) catch {};
    buf.appendSlice(a, Pal.cyan) catch {};
    buf.appendSlice(a, lang) catch {};
    buf.appendSlice(a, R) catch {};
    if (lang.len > 0) {
        buf.appendSlice(a, " ") catch {};
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, "|") catch {};
        buf.appendSlice(a, R) catch {};
    }
    // " X lines\n"
    var num_buf: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, " {d} line{s}\n", .{ count, if (count == 1) "" else "s" }) catch " lines\n";
    buf.appendSlice(a, num_str) catch {};

    // Code lines
    for (0..count) |i| {
        const line = code_lines[i];
        // Line number with manual padding to digits width
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, "│") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, " ") catch {};
        buf.appendSlice(a, Pal.blue) catch {};
        // Line number
        var line_num_buf: [16]u8 = undefined;
        const ln_str = std.fmt.bufPrint(&line_num_buf, "{d}", .{i + 1}) catch "0";
        buf.appendSlice(a, ln_str) catch {};
        buf.appendSlice(a, " ") catch {};
        buf.appendSlice(a, "│") catch {};
        buf.appendSlice(a, " ") catch {};
        buf.appendSlice(a, R) catch {};
        // Pad line number to fixed width
        var pd: usize = ln_str.len;
        while (pd < digits) : (pd += 1) buf.appendSlice(a, " ") catch {};

        // Code content with background
        buf.appendSlice(a, CodeBg) catch {};
        buf.appendSlice(a, Pal.code_fg) catch {};
        if (line.len > content_w) {
            buf.appendSlice(a, line[0..content_w]) catch {};
        } else {
            buf.appendSlice(a, line) catch {};
        }
        buf.appendSlice(a, R) catch {};

        // Pad
        const used = if (line.len > content_w) content_w else line.len;
        const pad = content_w - used;
        var p: u16 = 0;
        while (p < pad) : (p += 1) { buf.appendSlice(a, " ") catch {}; }
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, "│") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, "\n") catch {};
    }

    // Footer
    buf.appendSlice(a, D) catch {};
    buf.appendSlice(a, "└─") catch {};
    buf.appendSlice(a, R) catch {};
    buf.appendSlice(a, "\n") catch {};
}

fn renderInlineAnsi(buf: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) {
        // Inline code `...`
        if (text[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                appendFmt(buf, a, "{s}{s}{s}{s}{s}", .{ CodeInlineBg, Pal.fg, text[i + 1 .. end], R, R });
                i = end + 1;
                continue;
            }
        }
        // Bold **...**
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |end| {
                buf.appendSlice(a, B) catch {};
                buf.appendSlice(a, text[i + 2 .. end]) catch {};
                buf.appendSlice(a, R) catch {};
                i = end + 2;
                continue;
            }
        }
        // Italic _..._ (single underscore)
        if (text[i] == '_' and i + 1 < text.len and text[i + 1] != '_') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '_')) |end| {
                buf.appendSlice(a, U) catch {};
                buf.appendSlice(a, text[i + 1 .. end]) catch {};
                buf.appendSlice(a, R) catch {};
                i = end + 1;
                continue;
            }
        }
        // Strikethrough ~~...~~
        if (i + 1 < text.len and text[i] == '~' and text[i + 1] == '~') {
            if (std.mem.indexOfPos(u8, text, i + 2, "~~")) |end| {
                buf.appendSlice(a, "\x1b[9m") catch {};
                buf.appendSlice(a, text[i + 2 .. end]) catch {};
                buf.appendSlice(a, R) catch {};
                i = end + 2;
                continue;
            }
        }
        // Link [text](url) — render as underlined text
        if (text[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |cb| {
                if (cb + 1 < text.len and text[cb + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, cb + 2, ')')) |cp| {
                        buf.appendSlice(a, Pal.cyan) catch {};
                        buf.appendSlice(a, text[i + 1 .. cb]) catch {};
                        buf.appendSlice(a, R) catch {};
                        i = cp + 1;
                        continue;
                    }
                }
            }
        }
        // Plain text — emit until next special char
        var j = i;
        while (j < text.len) {
            if (text[j] == '`' or text[j] == '*' or text[j] == '_' or text[j] == '~' or text[j] == '[') break;
            j += 1;
        }
        if (j > i) {
            buf.appendSlice(a, text[i..j]) catch {};
        }
        i = @max(j, i + 1);
    }
}

fn appendHighlighted(buf: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8, query: []const u8) void {
    if (query.len == 0 or text.len == 0) {
        buf.appendSlice(a, text) catch {};
        return;
    }
    var pos: usize = 0;
    while (pos < text.len) {
        if (std.mem.indexOfPos(u8, text, pos, query)) |match| {
            // Text before match
            if (match > pos) buf.appendSlice(a, text[pos..match]) catch {};
            // Highlighted match
            buf.appendSlice(a, SearchHighlight) catch {};
            buf.appendSlice(a, text[match .. match + query.len]) catch {};
            buf.appendSlice(a, R) catch {};
            pos = match + query.len;
        } else {
            buf.appendSlice(a, text[pos..]) catch {};
            break;
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Data Types
// ═══════════════════════════════════════════════════════════════════════

pub const Role = enum {
    user,
    assistant,
    system,
    tool,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .user => "You ●",
            .assistant => "Zeep ◆",
            .system => "Sys ▲",
            .tool => "Tool ◇",
        };
    }
    pub fn color(self: Role) []const u8 {
        return switch (self) {
            .user => Pal.blue,
            .assistant => Pal.fg,
            .system => Pal.mauve,
            .tool => Pal.yellow,
        };
    }
};

pub const MsgStatus = enum { pending, streaming, complete, failed, truncated };

pub const ToolCallStatus = enum { running, success, failed };

pub const ToolCall = struct {
    name: []const u8,
    args: []const u8 = "",
    output: ?[]const u8 = null,
    status: ToolCallStatus = .running,
    owns: bool = false,
};

pub const ChatMsg = struct {
    role: Role,
    content: []const u8,
    thinking: ?[]const u8 = null,
    tool_calls: std.ArrayList(ToolCall) = .empty,
    status: MsgStatus = .complete,
    timestamp: i64 = 0,
    think_collapsed: bool = true,
    tool_collapsed: bool = false,
    owns: bool = false,
};

pub const SubAgentRole = enum { planner, researcher, coder, reviewer, tester, docs, tool_user };

pub const SubAgent = struct {
    id: []const u8,
    role: SubAgentRole,
    goal: []const u8,
    status: MsgStatus = .pending,
    summary: []const u8 = "",
};

/// Semantic color theme (single dark palette matching Rust Whale defaults)
pub const Theme = struct {
    bg: []const u8 = "\x1b[48;2;13;21;37m",
    surface: []const u8 = "\x1b[48;2;19;29;48m",
    elevated: []const u8 = "\x1b[48;2;26;40;64m",
    fg: []const u8 = "\x1b[38;2;246;242;232m",
    fg_soft: []const u8 = "\x1b[38;2;217;224;234m",
    fg_muted: []const u8 = "\x1b[38;2;169;180;199m",
    accent_gold: []const u8 = "\x1b[38;2;246;196;83m",
    accent_seafoam: []const u8 = "\x1b[38;2;79;209;197m",
    accent_coral: []const u8 = "\x1b[38;2;255;122;89m",
    error_color: []const u8 = "\x1b[38;2;255;92;122m",
    success: []const u8 = "\x1b[38;2;79;209;197m",
    warning: []const u8 = "\x1b[38;2;240;160;48m",
    info: []const u8 = "\x1b[38;2;106;174;242m",
    border: []const u8 = "\x1b[38;2;42;74;127m",
    reasoning: []const u8 = "\x1b[38;2;224;153;72m",
    tool_live: []const u8 = "\x1b[38;2;133;184;234m",
    tool_output: []const u8 = "\x1b[38;2;194;208;224m",
    diff_add: []const u8 = "\x1b[38;2;87;199;133m",
    diff_del: []const u8 = "\x1b[38;2;255;92;122m",
};

// ═══════════════════════════════════════════════════════════════════════
// Streaming state (thread-safe bridge between background thread and UI)
// ═══════════════════════════════════════════════════════════════════════

const StreamState = struct {
    content_queue: std.ArrayList(u8) = .empty,
    reasoning_queue: std.ArrayList(u8) = .empty,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    has_tool_calls: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    tool_call_json: std.ArrayList(u8) = .empty,
    error_msg: ?[]const u8 = null,
    alloc: std.mem.Allocator = undefined,
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn init(alloc: std.mem.Allocator) StreamState {
        return .{ .alloc = alloc };
    }

    fn lock(self: *StreamState) void {
        while (self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {}
    }

    fn unlock(self: *StreamState) void {
        self.locked.store(false, .release);
    }

    fn pushContent(self: *StreamState, text: []const u8) void {
        self.lock();
        defer self.unlock();
        self.content_queue.appendSlice(self.alloc, text) catch {};
    }

    fn pushReasoning(self: *StreamState, text: []const u8) void {
        self.lock();
        defer self.unlock();
        self.reasoning_queue.appendSlice(self.alloc, text) catch {};
    }

    fn pushToolCallJson(self: *StreamState, json: []const u8) void {
        self.lock();
        defer self.unlock();
        self.tool_call_json.appendSlice(self.alloc, json) catch {};
        self.tool_call_json.append(self.alloc, '\n') catch {};
        self.has_tool_calls.store(true, .release);
    }

    fn drainToolCallJson(self: *StreamState, alloc: std.mem.Allocator) ?[]const u8 {
        self.lock();
        defer self.unlock();
        if (self.tool_call_json.items.len == 0) return null;
        const result = alloc.dupe(u8, self.tool_call_json.items) catch return null;
        self.tool_call_json.clearRetainingCapacity();
        return result;
    }

    fn setDone(self: *StreamState) void {
        self.done.store(true, .release);
    }

    fn setError(self: *StreamState, msg: []const u8) void {
        self.lock();
        defer self.unlock();
        if (self.error_msg) |old| self.alloc.free(old);
        self.error_msg = self.alloc.dupe(u8, msg) catch null;
        self.done.store(true, .release);
    }

    fn drainContent(self: *StreamState, alloc: std.mem.Allocator) ?[]const u8 {
        self.lock();
        defer self.unlock();
        if (self.content_queue.items.len == 0) return null;
        const result = alloc.dupe(u8, self.content_queue.items) catch return null;
        self.content_queue.clearRetainingCapacity();
        return result;
    }

    fn drainReasoning(self: *StreamState, alloc: std.mem.Allocator) ?[]const u8 {
        self.lock();
        defer self.unlock();
        if (self.reasoning_queue.items.len == 0) return null;
        const result = alloc.dupe(u8, self.reasoning_queue.items) catch return null;
        self.reasoning_queue.clearRetainingCapacity();
        return result;
    }

    fn isDone(self: *StreamState) bool {
        return self.done.load(.acquire);
    }

    fn deinit(self: *StreamState) void {
        self.content_queue.deinit(self.alloc);
        self.reasoning_queue.deinit(self.alloc);
        self.tool_call_json.deinit(self.alloc);
        if (self.error_msg) |m| self.alloc.free(m);
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Application Model (ZigZag Elm Architecture)
// ═══════════════════════════════════════════════════════════════════════

pub const App = struct {
    pub const PendingAction = enum {
        none,
        await_api_key, // waiting for user to enter API key
    };
    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        stream_content: []const u8,
        stream_reasoning: []const u8,
        stream_done,
        stream_error: []const u8,
        tool_start: struct { name: []const u8, args: []const u8 },
        tool_output: struct { name: []const u8, output: []const u8, success: bool },
        subagent_start: struct { id: []const u8, role: SubAgentRole, goal: []const u8 },
        subagent_update: struct { id: []const u8, summary: []const u8, status: MsgStatus },
        save_session,
        load_session: []const u8,
        tick: struct { timestamp: u64, delta: u64 },
    };

    const OutputData = union(enum) {
        table: SlashDispatcher.TableData,
        list: SlashDispatcher.ListData,

        fn deinit(self: *OutputData, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .table => |t| {
                    for (t.rows) |row| SlashDispatcher.freeRow(allocator, row);
                    allocator.free(t.rows);
                },
                .list => |l| {
                    for (l.items) |it| allocator.free(it);
                    allocator.free(l.items);
                },
            }
        }
    };

    // --- Chat state
    messages: std.ArrayList(ChatMsg),
    alloc: std.mem.Allocator,
    scroll_offset: u16,
    auto_scroll: bool,
    streaming_idx: ?usize,

    // --- Input state
    text_input: zz.components.TextInput,

    // --- UI overlays
    palette: zz.components.CommandPalette,
    show_thinking: bool,

    // --- Search state
    search_active: bool,
    search_query: std.ArrayList(u8),
    search_cursor: usize,

    // --- Overlays (Modal components)
    help_modal: zz.components.Modal,
    detail_modal: zz.components.Modal,
    detail_idx: usize,

    // --- Sub-agent panel
    show_subagents: bool,
    subagents: std.ArrayList(SubAgent),

    // --- Theme
    theme_manager: theme.ThemeManager,
    styles: theme.SemanticStyles,

    // --- Streaming
    stream_state: ?*StreamState,
    stream_thread: ?std.Thread,
    api_key: []const u8,
    io: std.Io,

    // --- Session state
    session_id: []const u8,
    session_dir: []const u8,
    should_quit: bool,

    // --- Metrics
    turn: u32,
    tokens_used: u64,
    ctx_max: u64,
    cache_hit_rate: f64,
    model: []const u8,
    provider: []const u8,
    provider_mgr: ProviderManager,
    i18n: I18nManager,
    sandbox: ?*Sandbox,
    subsystems_initialized: bool,
    ctx_mgr: ?*ContextManager,
    cache_loop: ?*dispatch_loop.CacheFirstLoop,

    // --- Dimensions
    width: u16,
    height: u16,
    cursor_visible: bool,

    // --- Notification toast
    toast: zz.components.Toast,

    // --- Pending interactive action ──
    pending_action: PendingAction = .none,
    pending_data: std.ArrayList(u8),

    // --- Slash command state
    slash_prompt_input: zz.components.TextInput = undefined,
    slash_awaiting_cmd: ?[]const u8 = null,
    slash_prompt_title: ?[]const u8 = null,
    slash_prompt_placeholder: ?[]const u8 = null,
    slash_output_active: bool = false,
    slash_output_title: []const u8 = "",
    slash_output_data: ?OutputData = null,

    // --- Elm Interface

    pub fn init(self: *App, ctx: *zz.Context) zz.Cmd(Msg) {
        self.* = .{
            .messages = .empty,
            .alloc = undefined,
            .scroll_offset = 0,
            .auto_scroll = true,
            .streaming_idx = null,
            .text_input = zz.components.TextInput.init(ctx.persistent_allocator),
            .palette = zz.components.CommandPalette.init(ctx.persistent_allocator) catch unreachable,
            .show_thinking = true,
            .search_active = false,
            .search_query = .empty,
            .search_cursor = 0,
            .help_modal = zz.components.Modal.info("Keybindings", ""),
            .detail_modal = zz.components.Modal.info("Message Detail", ""),
            .detail_idx = 0,
            .show_subagents = false,
            .subagents = .empty,
            .stream_state = null,
            .stream_thread = null,
            .api_key = blk: {
                const key_ptr = std.c.getenv("DEEPSEEK_API_KEY");
                break :blk if (key_ptr) |k| std.mem.sliceTo(k, 0) else "";
            },
            .io = ctx.io,
            .session_id = "default",
            .session_dir = "",
            .should_quit = false,
            .turn = 0,
            .tokens_used = 0,
            .ctx_max = 64000,
            .cache_hit_rate = 0,
            .model = "deepseek-chat",
            .provider = "deepseek",
            .provider_mgr = ProviderManager.init(ctx.allocator),
            .i18n = I18nManager.init(.en),
            .sandbox = null,
            .subsystems_initialized = false,
            .ctx_mgr = null,
            .cache_loop = null,
            .width = 80,
            .height = 24,
            .cursor_visible = true,
            .toast = zz.components.Toast.init(ctx.persistent_allocator),
            .theme_manager = theme.ThemeManager.init(ctx.persistent_allocator),
            .styles = undefined,
            .pending_action = .none,
            .pending_data = .empty,
            .slash_prompt_input = zz.components.TextInput.init(ctx.persistent_allocator),
            .slash_awaiting_cmd = null,
            .slash_prompt_title = null,
            .slash_prompt_placeholder = null,
            .slash_output_active = false,
            .slash_output_title = "",
            .slash_output_data = null,
        };
        // Try loading saved API key from disk
        self.loadSavedApiKey();
        return .{ .batch = &[_]zz.Cmd(Msg){ .enter_alt_screen, zz.Cmd(Msg).everyMs(100) } };
    }

    fn loadSavedApiKey(self: *App) void {
        // Only load if env var didn't provide one
        if (self.api_key.len > 0) return;
        const home_ptr = std.c.getenv("HOME") orelse return;
        const home = std.mem.sliceTo(home_ptr, 0);
        var path_buf: [512:0]u8 = undefined;
        _ = std.fmt.bufPrintSentinel(&path_buf, "{s}/.zeepseek/apikey", .{home}, 0) catch return;
        const fd = std.c.open(&path_buf, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        var file_buf: [512]u8 = undefined;
        const n = std.c.read(fd, &file_buf, file_buf.len);
        if (n <= 0) return;
        const trimmed = std.mem.trim(u8, file_buf[0..@intCast(n)], &.{ ' ', '\n', '\r' });
        if (trimmed.len > 0) {
            // Store in page allocator since persistent_allocator isn't available yet
            const duped = std.heap.page_allocator.dupe(u8, trimmed) catch return;
            self.api_key = duped;
        }
    }

    pub fn deinit(self: *App) void {
        // Free stream state
        if (self.stream_state) |ss| {
            ss.deinit();
            self.alloc.destroy(ss);
        }
        if (self.stream_thread) |t| t.join();

        // Free messages and their content
        self.clearMessages();
        self.messages.deinit(self.alloc);

        // Free input buffers
        self.text_input.deinit();
        self.palette.deinit();
        self.toast.deinit();
        self.theme_manager.deinit();
        self.search_query.deinit(self.alloc);
        self.pending_data.deinit(self.alloc);
        self.slash_prompt_input.deinit();
        if (self.slash_awaiting_cmd) |s| self.alloc.free(s);
        if (self.slash_prompt_title) |s| self.alloc.free(s);
        if (self.slash_prompt_placeholder) |s| self.alloc.free(s);
        if (self.slash_output_data) |*d| {
            d.deinit(self.alloc);
            self.slash_output_data = null;
        }

        // Free subsystems
        if (self.subsystems_initialized) {
            self.provider_mgr.deinit();
            if (self.ctx_mgr) |cm| {
                cm.deinit();
                self.alloc.destroy(cm);
            }
            if (self.cache_loop) |cl| {
                cl.deinit();
                self.alloc.destroy(cl);
            }
        }

        // Free API key if page-allocated
        if (self.api_key.len > 0) {
            std.heap.page_allocator.free(self.api_key);
        }
    }

    fn textInputAppend(self: *App, bytes: []const u8) void {
        const current = self.text_input.getValue();
        const new_text = std.fmt.allocPrint(self.alloc, "{s}{s}", .{ current, bytes }) catch return;
        defer self.alloc.free(new_text);
        self.text_input.setValue(new_text) catch {};
        self.text_input.cursor = self.text_input.getValue().len;
    }

    pub fn update(self: *App, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        // Use persistent allocator for model state (survives frame resets)
        self.alloc = ctx.persistent_allocator;
        self.io = ctx.io;
        // Lazy-init subsystems that need a real allocator
        if (!self.subsystems_initialized) {
            self.subsystems_initialized = true;
            self.text_input.setPrompt("> ");
            self.text_input.setPlaceholder("Type a message, or / for commands");
            self.text_input.setWidth(self.width - 6);
            self.provider_mgr = ProviderManager.init(ctx.persistent_allocator);
            // Register default deepseek provider
            self.provider_mgr.addProvider(.{
                .provider_id = "deepseek",
                .api_key = self.api_key,
                .default_model = "deepseek-chat",
            }) catch {};
            // Sandbox: skip on macOS due to Seatbelt policy issues
            // self.sandbox stays null; tools work without sandbox
            // Initialize dispatch layer
            const cm = ctx.persistent_allocator.create(ContextManager) catch null;
            if (cm) |c| {
                c.* = ContextManager.init(ctx.persistent_allocator);
                self.ctx_mgr = c;
            }
            const cl = ctx.persistent_allocator.create(dispatch_loop.CacheFirstLoop) catch null;
            if (cl) |c| {
                const prefix = ImmutablePrefix.init(ctx.persistent_allocator, "", "", "");
                c.* = dispatch_loop.CacheFirstLoop.init(ctx.persistent_allocator, .{
                    .prefix = prefix,
                    .context = self.ctx_mgr.?,
                    .reasonix = undefined,
                    .model = .deepseek_chat,
                    .io = self.io,
                    .api_key = self.api_key,
                    .stream = true,
                });
                self.cache_loop = c;
            }
            for (SlashDispatcher.Dispatcher.commands()) |cmd| {
                self.palette.addCommand(.{
                    .id = cmd.id,
                    .label = cmd.label,
                    .description = cmd.desc,
                }) catch {};
            }
            self.toast.position = .top_right;
            self.toast.max_visible = 3;
            self.styles = theme.SemanticStyles.fromPalette(self.theme_manager.getPalette());
            self.help_modal.backdrop = .{};
            self.detail_modal.backdrop = .{};
        }
        if (self.should_quit) return .quit;
        switch (msg) {
            .key => |k| return self.onKey(k),
            .stream_content => |text| self.onStreamContent(text),
            .stream_reasoning => |text| self.onStreamReasoning(text),
            .stream_done => self.onStreamDone(),
            .stream_error => |e| self.onStreamError(e),
            .tool_start => |t| self.onToolStart(t.name, t.args),
            .tool_output => |t| self.onToolOutput(t.name, t.output, t.success),
            .subagent_start => |s| self.onSubAgentStart(s.id, s.role, s.goal),
            .subagent_update => |s| self.onSubAgentUpdate(s.id, s.summary, s.status),
            .save_session => self.saveSession(),
            .load_session => |path| self.loadSession(path),
            .tick => |t| {
                self.cursor_visible = (t.timestamp / 500_000_000) % 2 == 0; // blink every 500ms
                self.pollStream();
                // Toast auto-dismiss is handled by zz.components.Toast based on timestamps
            },
        }
        return .none;
    }

    // ═════════════════════════════════════════════════════════════════
    // Key Handling (all UI logic lives here)
    // ═════════════════════════════════════════════════════════════════

    fn onKey(self: *App, key: zz.KeyEvent) zz.Cmd(Msg) {
        const k = key.key;
        const m = key.modifiers;

        // --- Slash output modal
        if (self.slash_output_active) {
            if (k == .escape or k == .enter or (k == .char and k.char == 'q')) {
                self.closeSlashOutput();
            }
            return .none;
        }

        // --- Slash prompt overlay
        if (self.slash_awaiting_cmd != null) {
            if (k == .escape) {
                self.closeSlashPrompt();
                return .none;
            }
            if (k == .enter) {
                const cmd_id = self.slash_awaiting_cmd orelse "";
                const value = self.slash_prompt_input.getValue();
                self.closeSlashPrompt();
                self.executeSlashCommand(cmd_id, value);
                return .none;
            }
            _ = self.slash_prompt_input.handleKey(key);
            return .none;
        }

        // --- Palette overlay
        if (self.palette.isOpen()) {
            const result = self.palette.handleKey(key) catch .ignored;
            switch (result) {
                .accepted => if (self.palette.selected()) |cmd| {
                    self.palette.close();
                    self.executeSlashCommand(cmd.id, "");
                },
                .cancelled => self.palette.close(),
                .consumed, .ignored => {},
            }
            return .none;
        }

        // --- Help overlay (Modal)
        if (self.help_modal.isVisible()) {
            _ = self.help_modal.handleKey(key);
            return .none;
        }

        // --- Detail overlay (Modal)
        if (self.detail_modal.isVisible()) {
            const had = self.detail_modal.isVisible();
            _ = self.detail_modal.handleKey(key);
            if (had and !self.detail_modal.isVisible()) {
                // Modal was dismissed; nothing extra to do
            }
            // Arrow keys navigate between messages while modal stays open
            if (k == .left) { if (self.detail_idx > 0) self.detail_idx -= 1; self.updateDetailModal(); }
            if (k == .right) { if (self.detail_idx + 1 < self.messages.items.len) self.detail_idx += 1; self.updateDetailModal(); }
            return .none;
        }

        // --- Search overlay
        if (self.search_active) {
            if (k == .escape) { self.search_active = false; self.search_query.clearRetainingCapacity(); return .none; }
            if (k == .enter) {
                // Jump to first matching message
                if (self.search_query.items.len > 0) {
                    self.jumpToMatch();
                }
                self.search_active = false;
                return .none;
            }
            if (k == .backspace) { if (self.search_query.items.len > 0) _ = self.search_query.pop(); return .none; }
            if (k == .char) { self.search_query.append(self.alloc, @intCast(k.char)) catch {}; return .none; }
            return .none;
        }

        // --- Global Ctrl shortcuts
        if (m.ctrl and k == .char) {
            switch (k.char) {
                'c' => { self.should_quit = true; return .none; },
                'f' => { self.search_active = true; self.search_query.clearRetainingCapacity(); },
                's' => { self.show_subagents = !self.show_subagents; },
                'o' => { if (self.messages.items.len > 0) { self.detail_idx = self.messages.items.len - 1; self.updateDetailModal(); self.detail_modal.show(); } },
                'p' => self.palette.open(),
                'n' => self.show_thinking = !self.show_thinking,
                't' => self.cycleTheme(),
                else => {},
            }
            return .none;
        }

        // --- Global Alt shortcuts
        if (m.alt and k == .char) {
            switch (k.char) {
                't' => self.show_thinking = !self.show_thinking,
                'm' => self.toggleToolCollapse(),
                else => {},
            }
            return .none;
        }

        // --- / at start of input opens palette; otherwise type as normal
        if (k == .char and k.char == '/' and self.text_input.getValue().len == 0) {
            self.palette.open();
            return .none;
        }

        // --- F1 / ? for help (when input empty)
        if (k == .f1 or (k == .char and k.char == '?' and self.text_input.getValue().len == 0)) {
            self.updateHelpModal();
            self.help_modal.show();
            return .none;
        }

        // --- Scroll keys (when input empty)
        if (self.text_input.getValue().len == 0) {
            if (k == .up) { if (self.scroll_offset > 0) self.scroll_offset -= 1; self.auto_scroll = false; return .none; }
            if (k == .down) { self.scroll_offset += 1; return .none; }
            if (k == .page_up) { self.scroll_offset -|= 10; self.auto_scroll = false; return .none; }
            if (k == .page_down) { self.scroll_offset +|= 10; return .none; }
            if (k == .home) { self.scroll_offset = 0; self.auto_scroll = false; return .none; }
            if (k == .end) { self.scroll_offset = 0; self.auto_scroll = true; return .none; }
        }

        // --- Enter: submit
        if (k == .enter) {
            if (key.modifiers.shift) {
                self.textInputAppend("\n");
            } else {
                self.submit();
            }
            return .none;
        }

        // --- Input editing via ZigZag TextInput
        self.text_input.handleKey(key);
        return .none;
    }

    // ═════════════════════════════════════════════════════════════════
    // Submit / Streaming
    // ═════════════════════════════════════════════════════════════════

    fn submit(self: *App) void {
        const text_slice = self.text_input.getValue();
        if (text_slice.len == 0) return;

        // Handle pending interactive actions
        if (self.pending_action == .await_api_key) {
            const key = self.alloc.dupe(u8, text_slice) catch return;
            self.setApiKey(key);
            self.pending_action = .none;
            self.pending_data.clearRetainingCapacity();
            self.text_input.setValue("") catch {};
            self.text_input.cursor = 0;
            return;
        }

        // Check for slash commands
        if (text_slice.len > 1 and text_slice[0] == '/') {
            const rest = text_slice[1..];
            var it = std.mem.splitScalar(u8, rest, ' ');
            const cmd_id = it.first();
            const args = std.mem.trim(u8, rest[cmd_id.len..], " ");
            self.executeSlashCommand(cmd_id, args);
            self.text_input.setValue("") catch {};
            self.text_input.cursor = 0;
            return;
        }

        const text = self.alloc.dupe(u8, text_slice) catch return;
        self.messages.append(self.alloc, .{
            .role = .user,
            .content = text,
            .timestamp = 0,
            .owns = true,
        }) catch {};

        self.text_input.setValue("") catch {};
        self.text_input.cursor = 0;
        self.auto_scroll = true;
        self.scroll_offset = 0;
        self.turn += 1;

        // Start streaming if API key is available
        if (self.api_key.len > 0) {
            self.startStreaming(text);
        } else {
            // No API key — placeholder
            self.messages.append(self.alloc, .{
                .role = .assistant,
                .content = self.i18n.t().msg_no_api_key,
                .status = .complete,
            }) catch {};
        }
    }

    fn startStreaming(self: *App, user_input: []const u8) void {
        // Clean up previous stream state
        if (self.stream_state) |ss| {
            ss.deinit();
            self.alloc.destroy(ss);
        }
        if (self.stream_thread) |t| t.join();

        // Create new stream state
        const ss = self.alloc.create(StreamState) catch return;
        ss.* = StreamState.init(self.alloc);
        self.stream_state = ss;

        // Add placeholder assistant message
        const idx = self.messages.items.len;
        self.messages.append(self.alloc, .{
            .role = .assistant,
            .content = "",
            .status = .streaming,
        }) catch return;
        self.streaming_idx = idx;

        // Build context from recent messages
        var ctx_items = std.ArrayList(stream_client_mod.CtxItem).empty;
        defer ctx_items.deinit(self.alloc);
        const msg_count = self.messages.items.len - 1; // exclude the empty assistant msg
        const start: usize = if (msg_count > 20) msg_count - 20 else 0;
        for (self.messages.items[start..msg_count]) |m| {
            const role_str: []const u8 = switch (m.role) {
                .user => "user", .assistant => "assistant", .system => "system", .tool => "tool",
            };
            ctx_items.append(self.alloc, .{ .role = role_str, .content = m.content }) catch {};
        }

        // Capture values for the thread
        const api_key = self.provider_mgr.resolveApiKey(self.provider) orelse self.api_key;
        const model = self.provider_mgr.resolveModel(self.provider);
        const alloc = self.alloc;
        const io = self.io;
        const ctx_slice = ctx_items.toOwnedSlice(self.alloc) catch &.{};

        // Spawn streaming thread
        const thread = std.Thread.spawn(.{}, struct {
            fn run(api_k: []const u8, prompt: []const u8, ctx: []const stream_client_mod.CtxItem, mdl: []const u8, a: std.mem.Allocator, sio: std.Io, state: *StreamState) void {
                var client = stream_client_mod.DeepSeekStreamClient.init(a, sio, null, null);
                defer client.deinit();

                var stream = client.streamMessage(api_k, prompt, ctx, mdl, CacheDecision.none, "", null) catch |err| {
                    if (err == error.HttpError and client.last_http_status != 0) {
                        const detail = std.fmt.allocPrint(a, "HTTP {d}: {s}", .{
                            client.last_http_status,
                            client.last_http_body orelse "",
                        }) catch {
                            state.setError(@errorName(err));
                            return;
                        };
                        state.setError(detail);
                        a.free(detail);
                    } else {
                        state.setError(@errorName(err));
                    }
                    return;
                };
                defer stream.deinit();

                while (true) {
                    const chunk = stream.nextChunk() catch |err| {
                        state.setError(@errorName(err));
                        return;
                    };
                    if (chunk == null) break;
                    switch (chunk.?) {
                        .content => |c| state.pushContent(c),
                        .reasoning => |r| state.pushReasoning(r),
                    }
                }
                // Capture tool call JSON if present
                if (stream.has_tool_calls and stream.tool_call_json.items.len > 0) {
                    state.pushToolCallJson(stream.tool_call_json.items);
                }
                state.setDone();
            }
        }.run, .{ api_key, user_input, ctx_slice, model, alloc, io, ss }) catch {
            ss.setError("Failed to spawn thread");
            return;
        };
        self.stream_thread = thread;
    }

    fn pollStream(self: *App) void {
        const ss = self.stream_state orelse return;

        // Drain content
        if (ss.drainContent(self.alloc)) |content| {
            defer self.alloc.free(content);
            self.onStreamContent(content);
        }

        // Drain reasoning
        if (ss.drainReasoning(self.alloc)) |reasoning| {
            defer self.alloc.free(reasoning);
            self.onStreamReasoning(reasoning);
        }

        // Check done
        if (ss.isDone()) {
            // Check for tool calls BEFORE marking done
            const has_tc = ss.has_tool_calls.load(.acquire);
            const tc_json = if (has_tc) ss.drainToolCallJson(self.alloc) else null;

            if (ss.error_msg) |msg| {
                self.onStreamError(msg);
            } else if (tc_json != null) {
                // Handle tool calls — don't mark stream done yet
                self.handleToolCalls(tc_json.?);
                self.alloc.free(tc_json.?);
                // Cleanup stream state but keep streaming_idx alive
                if (self.stream_thread) |t| {
                    t.join();
                    self.stream_thread = null;
                }
                ss.deinit();
                self.alloc.destroy(ss);
                self.stream_state = null;
                return;
            } else {
                self.onStreamDone();
            }
            // Cleanup
            if (self.stream_thread) |t| {
                t.join();
                self.stream_thread = null;
            }
            ss.deinit();
            self.alloc.destroy(ss);
            self.stream_state = null;
        }
    }

    fn handleToolCalls(self: *App, tc_json: []const u8) void {
        var pipeline = stream_client_mod.ToolCallRepairPipeline.init(self.alloc);
        defer pipeline.deinit();

        const parse_result = pipeline.processChunk(tc_json) catch return;
        defer {
            for (parse_result.calls) |call| {
                self.alloc.free(call.name);
                self.alloc.free(call.arguments);
                self.alloc.free(call.signature);
            }
            self.alloc.free(parse_result.calls);
        }

        if (parse_result.calls.len == 0) return;

        // Get working directory
        const cwd_ptr = std.c.getenv("PWD") orelse ".";
        const cwd = std.mem.sliceTo(cwd_ptr, 0);

        // Execute each tool call and collect results
        var tool_results = std.ArrayList(u8).empty;
        defer tool_results.deinit(self.alloc);

        for (parse_result.calls) |call| {
            // Notify UI about tool call
            self.onToolStart(call.name, call.arguments);

            // Execute the tool
            const result = self.executeToolCall(call.name, call.arguments, cwd);
            const success = result.len > 0 and !std.mem.startsWith(u8, result, "Error:");

            // Notify UI about result
            self.onToolOutput(call.name, result, success);

            // Accumulate results for re-submission
            tool_results.appendSlice(self.alloc, "Tool ") catch {};
            tool_results.appendSlice(self.alloc, call.name) catch {};
            tool_results.appendSlice(self.alloc, " result:\n") catch {};
            tool_results.appendSlice(self.alloc, result) catch {};
            tool_results.appendSlice(self.alloc, "\n\n") catch {};
        }

        // Re-submit with tool results to continue the conversation
        if (tool_results.items.len > 0) {
            const result_text = self.alloc.dupe(u8, tool_results.items) catch return;
            self.messages.append(self.alloc, .{
                .role = .tool,
                .content = result_text,
                .owns = true,
            }) catch {};

            // Start a new stream with the tool results in context
            self.startStreaming("(tool results)");
        }
    }

    fn executeToolCall(self: *App, name: []const u8, args: []const u8, cwd: []const u8) []const u8 {
        // Use tools/mod.zig unified execution (shell, file, git, web with sandbox)
        const call = tools_mod.ToolCall{
            .index = 0,
            .name = name,
            .arguments = args,
        };
        // Check sandbox approval
        if (tools_mod.requiresApproval(self.sandbox, call)) {
            // Auto-allow for now (future: prompt user via TUI overlay)
        }
        const result = tools_mod.executeTool(self.alloc, self.sandbox, cwd, call) catch {
            return "Error: tool execution failed";
        };
        if (result.success) {
            return if (result.output.len > 0) result.output else "(no output)";
        }
        return result.err_msg orelse "Error: unknown tool error";
    }

    fn execShell(self: *App, args_json: []const u8, cwd: []const u8) []const u8 {
        // Extract "command" from JSON args
        const cmd = self.extractJsonString(args_json, "command") orelse return "Error: no command";

        // Execute via popen
        var cmd_buf: [4096]u8 = undefined;
        const full_cmd = std.fmt.bufPrint(&cmd_buf, "cd {s} && {s} 2>&1", .{ cwd, cmd }) catch return "Error: cmd too long";

        const result = cc.popen(full_cmd.ptr, "r") orelse return "Error: popen failed";
        defer _ = cc.pclose(result);

        var output = std.ArrayList(u8).empty;
        defer output.deinit(self.alloc);
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = cc.fread(&read_buf, 1, read_buf.len, result);
            if (n == 0) break;
            output.appendSlice(self.alloc, read_buf[0..n]) catch break;
        }

        if (output.items.len == 0) return "(no output)";
        return self.alloc.dupe(u8, output.items) catch "(alloc error)";
    }

    fn execFileRead(self: *App, args_json: []const u8) []const u8 {
        const path = self.extractJsonString(args_json, "path") orelse return "Error: no path";
        const path_z = self.alloc.dupeSentinel(u8, path, 0) catch return "Error: alloc";
        defer self.alloc.free(path_z);

        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return "Error: file not found";
        defer _ = std.c.close(fd);

        var data = std.ArrayList(u8).empty;
        defer data.deinit(self.alloc);
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &read_buf, read_buf.len);
            if (n <= 0) break;
            data.appendSlice(self.alloc, read_buf[0..@intCast(n)]) catch break;
        }

        if (data.items.len == 0) return "(empty file)";
        return self.alloc.dupe(u8, data.items) catch "(alloc error)";
    }

    fn execFileWrite(self: *App, args_json: []const u8) []const u8 {
        const path = self.extractJsonString(args_json, "path") orelse return "Error: no path";
        const content = self.extractJsonString(args_json, "content") orelse return "Error: no content";
        const path_z = self.alloc.dupeSentinel(u8, path, 0) catch return "Error: alloc";
        defer self.alloc.free(path_z);

        const flags = std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        const fd = std.c.open(path_z.ptr, flags, @as(std.c.mode_t, 0o644));
        if (fd < 0) return "Error: cannot create file";
        defer _ = std.c.close(fd);

        _ = std.c.write(fd, content.ptr, content.len);
        return "OK";
    }

    fn extractJsonString(_: *App, json: []const u8, key: []const u8) ?[]const u8 {
        // Simple JSON string extractor: finds "key":"value"
        var search_buf: [256]u8 = undefined;
        const search = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
        if (std.mem.indexOf(u8, json, search)) |start| {
            const val_start = start + search.len;
            if (std.mem.indexOfScalarPos(u8, json, val_start, '"')) |end| {
                return json[val_start..end];
            }
        }
        return null;
    }

    fn onStreamContent(self: *App, text: []const u8) void {
        if (self.streaming_idx) |idx| {
            if (idx < self.messages.items.len) {
                const old = self.messages.items[idx].content;
                const new = std.mem.concat(self.alloc, u8, &.{ old, text }) catch return;
                if (self.messages.items[idx].owns and old.len > 0) self.alloc.free(old);
                self.messages.items[idx].content = new;
                self.messages.items[idx].owns = true;
            }
        } else {
            const idx = self.messages.items.len;
            const duped = self.alloc.dupe(u8, text) catch return;
            self.messages.append(self.alloc, .{
                .role = .assistant,
                .content = duped,
                .status = .streaming,
                .timestamp = 0, // TODO: use std.Io.Timestamp when ctx is available
                .owns = true,
            }) catch return;
            self.streaming_idx = idx;
        }
        if (self.auto_scroll) self.scroll_offset = 0;
    }

    fn onStreamReasoning(self: *App, text: []const u8) void {
        if (self.streaming_idx) |idx| {
            if (idx < self.messages.items.len) {
                const old = self.messages.items[idx].thinking orelse "";
                const new = std.mem.concat(self.alloc, u8, &.{ old, text }) catch return;
                if (old.len > 0) self.alloc.free(old);
                self.messages.items[idx].thinking = new;
            }
        }
    }

    fn onStreamDone(self: *App) void {
        if (self.streaming_idx) |idx| {
            if (idx < self.messages.items.len) {
                self.messages.items[idx].status = .complete;
            }
        }
        self.streaming_idx = null;
        self.turn += 1;
    }

    fn onStreamError(self: *App, err_msg: []const u8) void {
        if (self.streaming_idx) |idx| {
            if (idx < self.messages.items.len) {
                self.messages.items[idx].status = .failed;
                const old = self.messages.items[idx].content;
                const new = std.fmt.allocPrint(self.alloc, "{s}\n[Error: {s}]", .{ old, err_msg }) catch return;
                if (self.messages.items[idx].owns and old.len > 0) self.alloc.free(old);
                self.messages.items[idx].content = new;
                self.messages.items[idx].owns = true;
            }
        }
        self.streaming_idx = null;
    }

    fn onToolStart(self: *App, name: []const u8, args: []const u8) void {
        // Add tool call to the last assistant message, or create a tool message
        const last_idx = if (self.messages.items.len > 0) self.messages.items.len - 1 else 0;
        const target = if (self.messages.items.len > 0 and self.messages.items[last_idx].role == .assistant)
            last_idx
        else blk: {
            self.messages.append(self.alloc, .{
                .role = .assistant,
                .content = "",
                .tool_calls = .empty,
                .status = .streaming,
            }) catch return;
            break :blk self.messages.items.len - 1;
        };
        self.messages.items[target].tool_calls.append(self.alloc, .{
            .name = name,
            .args = args,
            .status = .running,
        }) catch {};
    }

    fn onToolOutput(self: *App, name: []const u8, output: []const u8, success: bool) void {
        // Find the last matching tool call and update it
        var i: usize = self.messages.items.len;
        while (i > 0) {
            i -= 1;
            const msg = &self.messages.items[i];
            var j: usize = msg.tool_calls.items.len;
            while (j > 0) {
                j -= 1;
                if (std.mem.eql(u8, msg.tool_calls.items[j].name, name) and msg.tool_calls.items[j].status == .running) {
                    msg.tool_calls.items[j].output = self.alloc.dupe(u8, output) catch null;
                    msg.tool_calls.items[j].status = if (success) .success else .failed;
                    msg.tool_calls.items[j].owns = true;
                    return;
                }
            }
        }
    }

    fn onSubAgentStart(self: *App, id: []const u8, role: SubAgentRole, goal: []const u8) void {
        self.subagents.append(self.alloc, .{
            .id = id,
            .role = role,
            .goal = goal,
            .status = .pending,
        }) catch {};
    }

    fn onSubAgentUpdate(self: *App, id: []const u8, summary: []const u8, status: MsgStatus) void {
        for (self.subagents.items) |*sa| {
            if (std.mem.eql(u8, sa.id, id)) {
                sa.status = status;
                if (summary.len > 0) sa.summary = summary;
                break;
            }
        }
    }

    fn cycleTheme(self: *App) void {
        self.theme_manager.cycle();
        self.styles = theme.SemanticStyles.fromPalette(self.theme_manager.getPalette());
        const msg = std.fmt.allocPrint(self.alloc, "Theme: {s}", .{self.theme_manager.getThemeName()}) catch return;
        self.setNotification(msg);
    }

    fn setThemeByName(self: *App, name: []const u8) void {
        for (theme.themes) |t| {
            if (std.mem.eql(u8, name, t.name) or std.mem.eql(u8, name, @tagName(t.id))) {
                self.theme_manager.setTheme(t.id);
                self.styles = theme.SemanticStyles.fromPalette(self.theme_manager.getPalette());
                const msg = std.fmt.allocPrint(self.alloc, "Theme: {s}", .{t.name}) catch return;
                self.setNotification(msg);
                return;
            }
        }
        self.setNotification("Unknown theme");
    }

    // ═════════════════════════════════════════════════════════════════
    // Command Palette
    // ═════════════════════════════════════════════════════════════════


    fn setApiKey(self: *App, key: []const u8) void {
        if (key.len == 0) {
            self.setNotification("Usage: /apikey <your-api-key>");
            return;
        }
        if (key.len < 8) {
            self.setNotification("Key too short — expected 8+ characters");
            return;
        }
        self.api_key = self.alloc.dupe(u8, key) catch return;
        const msg = std.fmt.allocPrint(self.alloc, "API key saved ({d} chars)", .{key.len}) catch return;
        self.setNotification(msg);

        // Persist to store
        self.saveApiKey() catch {};
    }

    fn saveApiKey(self: *App) !void {
        const home_ptr = std.c.getenv("HOME") orelse return;
        const home = std.mem.sliceTo(home_ptr, 0);
        // Ensure dir exists
        var dir_buf: [512:0]u8 = undefined;
        _ = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.zeepseek", .{home}, 0) catch return;
        _ = std.c.mkdir(&dir_buf, 0o755);
        // Write key file
        var path_buf: [512:0]u8 = undefined;
        _ = std.fmt.bufPrintSentinel(&path_buf, "{s}/.zeepseek/apikey", .{home}, 0) catch return;
        const flags = std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        const fd = std.c.open(&path_buf, flags, @as(std.c.mode_t, 0o600));
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        _ = std.c.write(fd, self.api_key.ptr, self.api_key.len);
    }

    fn setNotification(self: *App, msg: []const u8) void {
        self.toast.push(msg, .info, 2000, 0) catch {};
    }

    fn executeSlashCommand(self: *App, id: []const u8, args: []const u8) void {
        const ctx = SlashDispatcher.CommandContext{
            .allocator = self.alloc,
            .io = self.io,
            .provider = self.provider,
            .model = self.model,
            .subsystems_initialized = self.subsystems_initialized,
            .provider_mgr = &self.provider_mgr,
            .sandbox = if (self.sandbox) |s| s else null,
            .tokens_used = self.tokens_used,
            .ctx_max = self.ctx_max,
            .cache_hit_rate = self.cache_hit_rate,
            .session_id = self.session_id,
        };

        const result = SlashDispatcher.Dispatcher.execute(ctx, id, args) catch |err| {
            const msg = std.fmt.allocPrint(self.alloc, "Command error: {s}", .{@errorName(err)}) catch return;
            defer self.alloc.free(msg);
            self.setNotification(msg);
            return;
        };

        switch (result) {
            .none => {},

            .set_input => |text| {
                self.text_input.setValue(text) catch {};
                self.text_input.cursor = self.text_input.getValue().len;
                self.alloc.free(text);
            },

            .notify => |msg| {
                self.setNotification(msg);
                self.alloc.free(msg);
            },

            .quit => self.should_quit = true,
            .clear_chat => self.clearMessages(),
            .save_session => self.saveSession(),
            .load_session => self.loadSessionFromDefault(),
            .toggle_thinking => self.show_thinking = !self.show_thinking,
            .toggle_tools => self.toggleToolCollapse(),
            .toggle_subagents => self.show_subagents = !self.show_subagents,
            .scroll_top => { self.scroll_offset = 0; self.auto_scroll = false; },
            .scroll_bottom => { self.scroll_offset = 0; self.auto_scroll = true; },
            .compact_context => self.compactContext(),
            .show_help => { self.updateHelpModal(); self.help_modal.show(); },

            .set_model => |name| {
                self.model = self.alloc.dupe(u8, name) catch self.model;
                if (self.subsystems_initialized) {
                    if (self.provider_mgr.getActive()) |cfg| {
                        var new_cfg = cfg;
                        new_cfg.default_model = name;
                        self.provider_mgr.addProvider(new_cfg) catch {};
                    }
                }
                const msg = std.fmt.allocPrint(self.alloc, "Model: {s} (via {s})", .{ name, self.provider }) catch return;
                defer self.alloc.free(msg);
                self.setNotification(msg);
                self.alloc.free(name);
            },

            .set_theme => |name| {
                self.setThemeByName(name);
                self.alloc.free(name);
            },

            .set_apikey => |key| {
                self.setApiKey(key);
                self.alloc.free(key);
            },

            .set_provider => |name| {
                if (self.subsystems_initialized) {
                    self.provider_mgr.setActive(name) catch {};
                }
                self.provider = self.alloc.dupe(u8, name) catch self.provider;
                const resolved_model = if (self.subsystems_initialized)
                    self.provider_mgr.resolveModel(name)
                else
                    "deepseek-chat";
                self.model = self.alloc.dupe(u8, resolved_model) catch self.model;

                const title = std.fmt.allocPrint(self.alloc, "Enter API key for {s}", .{name}) catch return;
                self.alloc.free(name);
                self.openSlashPrompt("apikey", title, "sk-...");
                self.alloc.free(title);
            },

            .prompt => |p| {
                const title = self.alloc.dupe(u8, p.title) catch return;
                const placeholder = self.alloc.dupe(u8, p.placeholder) catch {
                    self.alloc.free(title);
                    return;
                };
                self.alloc.free(p.title);
                self.alloc.free(p.placeholder);
                self.openSlashPrompt(id, title, placeholder);
            },

            .show_table => |t| {
                self.setSlashOutput(.{ .table = t });
            },

            .show_list => |l| {
                self.setSlashOutput(.{ .list = l });
            },
        }
    }

    fn openSlashPrompt(self: *App, cmd_id: []const u8, title: []const u8, placeholder: []const u8) void {
        if (self.slash_awaiting_cmd) |old| self.alloc.free(old);
        if (self.slash_prompt_title) |old| self.alloc.free(old);
        if (self.slash_prompt_placeholder) |old| self.alloc.free(old);

        self.slash_awaiting_cmd = self.alloc.dupe(u8, cmd_id) catch return;
        self.slash_prompt_title = self.alloc.dupe(u8, title) catch return;
        self.slash_prompt_placeholder = self.alloc.dupe(u8, placeholder) catch return;

        self.slash_prompt_input.setValue("") catch {};
        self.slash_prompt_input.setPlaceholder(placeholder);
    }

    fn closeSlashPrompt(self: *App) void {
        if (self.slash_awaiting_cmd) |s| self.alloc.free(s);
        if (self.slash_prompt_title) |s| self.alloc.free(s);
        if (self.slash_prompt_placeholder) |s| self.alloc.free(s);
        self.slash_awaiting_cmd = null;
        self.slash_prompt_title = null;
        self.slash_prompt_placeholder = null;
        self.slash_prompt_input.setValue("") catch {};
    }

    fn setSlashOutput(self: *App, data: OutputData) void {
        if (self.slash_output_data) |*old| {
            old.deinit(self.alloc);
        }
        self.slash_output_data = data;

        self.slash_output_title = switch (data) {
            .table => |t| t.title,
            .list => |l| l.title,
        };
        self.slash_output_active = true;
    }

    fn closeSlashOutput(self: *App) void {
        self.slash_output_active = false;
        if (self.slash_output_data) |*d| {
            d.deinit(self.alloc);
            self.slash_output_data = null;
        }
    }

    fn saveSession(self: *App) void {
        const home_ptr = std.c.getenv("HOME") orelse return;
        const home = std.mem.sliceTo(home_ptr, 0);
        if (home.len == 0) return;
        // Ensure dir exists
        var dir_buf: [512:0]u8 = undefined;
        _ = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.zeepseek/sessions", .{home}, 0) catch return;
        _ = std.c.mkdir(&dir_buf, 0o755);
        // Build file path
        var path_buf: [512:0]u8 = undefined;
        _ = std.fmt.bufPrintSentinel(&path_buf, "{s}/.zeepseek/sessions/{s}.txt", .{ home, self.session_id }, 0) catch return;
        // Write messages using C API
        const flags = std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        const fd = std.c.open(&path_buf, flags, @as(std.c.mode_t, 0o644));
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        for (self.messages.items) |m| {
            const role_str: []const u8 = switch (m.role) {
                .user => "USER", .assistant => "ASSISTANT", .system => "SYSTEM", .tool => "TOOL",
            };
            // Write role:content\n using write()
            var line_buf: [4096]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "{s}:{s}\n", .{ role_str, m.content }) catch &.{};
            _ = std.c.write(fd, line.ptr, line.len);
        }
    }

    fn loadSessionFromDefault(self: *App) void {
        const home_ptr = std.c.getenv("HOME") orelse return;
        const home = std.mem.sliceTo(home_ptr, 0);
        var path_buf: [512:0]u8 = undefined;
        _ = std.fmt.bufPrintSentinel(&path_buf, "{s}/.zeepseek/sessions/{s}.txt", .{ home, self.session_id }, 0) catch return;
        // Check if file exists
        const fd = std.c.open(&path_buf, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) {
            const msg = std.fmt.allocPrint(self.alloc, "No saved session found at {s}", .{&path_buf}) catch return;
            self.messages.append(self.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
            return;
        }
        _ = std.c.close(fd);
        self.loadSession(std.mem.sliceTo(&path_buf, 0));
    }

    fn loadSession(self: *App, path: []const u8) void {
        const path_z = self.alloc.dupeSentinel(u8, path, 0) catch return;
        defer self.alloc.free(path_z);
        const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        // Read entire file
        var data = std.ArrayList(u8).empty;
        defer data.deinit(self.alloc);
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &read_buf, read_buf.len);
            if (n <= 0) break;
            data.appendSlice(self.alloc, read_buf[0..@intCast(n)]) catch break;
        }
        self.clearMessages();
        var line_iter = std.mem.splitScalar(u8, data.items, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const role_str = line[0..colon];
                const content = if (colon + 1 < line.len) line[colon + 1 ..] else "";
                const role: Role = if (std.mem.eql(u8, role_str, "USER")) .user
                    else if (std.mem.eql(u8, role_str, "ASSISTANT")) .assistant
                    else if (std.mem.eql(u8, role_str, "SYSTEM")) .system
                    else .tool;
                self.messages.append(self.alloc, .{
                    .role = role,
                    .content = self.alloc.dupe(u8, content) catch continue,
                    .owns = true,
                }) catch {};
            }
        }
        self.auto_scroll = true;
    }

    fn jumpToMatch(self: *App) void {
        const q = self.search_query.items;
        if (q.len == 0) return;
        self.auto_scroll = false;
        for (self.messages.items, 0..) |m, idx| {
            if (std.mem.indexOf(u8, m.content, q) != null) {
                self.scroll_offset = @intCast(idx);
                return;
            }
        }
    }

    fn toggleToolCollapse(self: *App) void {
        for (self.messages.items) |*m| {
            if (m.tool_calls.items.len > 0) {
                m.tool_collapsed = !m.tool_collapsed;
            }
        }
    }

    fn clearMessages(self: *App) void {
        for (self.messages.items) |*m| {
            if (m.owns and m.content.len > 0) self.alloc.free(m.content);
            if (m.thinking) |t| self.alloc.free(t);
            for (m.tool_calls.items) |tc| {
                if (tc.owns) {
                    if (tc.output) |o| if (o.len > 0) self.alloc.free(o);
                }
            }
            m.tool_calls.deinit(self.alloc);
        }
        self.messages.clearRetainingCapacity();
        self.streaming_idx = null;
        self.turn = 0;
    }

    /// Compact older messages to reduce token usage.
    /// Keeps the last KEEP_EXCHANGES exchanges intact, collapses older ones
    /// into a single compacted summary system message.
    fn compactContext(self: *App) void {
        const KEEP_EXCHANGES: usize = 6; // last 6 user↔assistant rounds
        const total = self.messages.items.len;
        if (total <= KEEP_EXCHANGES * 2) {
            // Not enough messages to compact meaningfully
            self.messages.append(self.alloc, .{
                .role = .system,
                .content = "Not enough context to compact (need >{d} messages).",
                .owns = false,
            }) catch {};
            return;
        }

        // Count non-system messages to determine how many to keep
        var non_system_count: usize = 0;
        for (self.messages.items) |m| {
            if (m.role != .system) non_system_count += 1;
        }
        if (non_system_count <= KEEP_EXCHANGES * 2) {
            self.messages.append(self.alloc, .{
                .role = .system,
                .content = "Not enough conversation history to compact.",
                .owns = false,
            }) catch {};
            return;
        }

        // Count backwards: find how many messages to keep
        var keep_count: usize = 0;
        var keep_end: usize = total;
        var i: usize = total;
        while (i > 0) {
            i -= 1;
            keep_count += 1;
            if (keep_count >= KEEP_EXCHANGES * 2) {
                keep_end = i;
                break;
            }
        }

        // Build compacted summary of messages before keep_end
        var summary = std.ArrayList(u8).empty;
        defer summary.deinit(self.alloc);

        const compact_prefix = "[Compacted: previous conversation summary]\n\n";
        summary.appendSlice(self.alloc, compact_prefix) catch {};

        var compacted_count: usize = 0;
        for (self.messages.items[0..keep_end]) |m| {
            const role_label: []const u8 = switch (m.role) {
                .user => "User",
                .assistant => "Assistant",
                .system => "System",
                .tool => "Tool",
            };
            // Truncate each message to 200 chars for the summary
            const content_preview = if (m.content.len > 200) m.content[0..200] else m.content;
            summary.appendSlice(self.alloc, role_label) catch {};
            summary.appendSlice(self.alloc, ": ") catch {};
            summary.appendSlice(self.alloc, content_preview) catch {};
            if (m.content.len > 200) {
                summary.appendSlice(self.alloc, "...") catch {};
            }
            summary.appendSlice(self.alloc, "\n") catch {};
            compacted_count += 1;
        }

        // Free old compacted messages
        for (self.messages.items[0..keep_end]) |*m| {
            if (m.owns and m.content.len > 0) self.alloc.free(m.content);
            if (m.thinking) |t| self.alloc.free(t);
            for (m.tool_calls.items) |*tc| {
                if (tc.owns) {
                    if (tc.output) |o| if (o.len > 0) self.alloc.free(o);
                }
            }
            m.tool_calls.deinit(self.alloc);
        }

        // Replace compacted range with a single system summary message
        const summary_text = summary.items;
        const duped = self.alloc.dupe(u8, summary_text) catch return;
        const compacted_msg = ChatMsg{
            .role = .system,
            .content = duped,
            .owns = true,
            .status = .complete,
        };

        // Remove old range and insert summary
        for (0..keep_end) |_| {
            _ = self.messages.orderedRemove(0);
        }
        self.messages.insert(self.alloc, 0, compacted_msg) catch {};

        // Notify user
        const note = std.fmt.allocPrint(self.alloc, "Compacted {d} messages into summary. {d} messages remain.", .{
            compacted_count, self.messages.items.len,
        }) catch return;
        self.messages.append(self.alloc, .{
            .role = .system,
            .content = note,
            .owns = true,
        }) catch {};
    }

    // ═════════════════════════════════════════════════════════════════════
    // View & Renderers — Claude CLI inspired layout
    // ═════════════════════════════════════════════════════════════════════

    pub fn view(self: *const App, ctx: *const zz.Context) []const u8 {
        const a = ctx.allocator;
        const w = ctx.width;
        const h = ctx.height;
        if (w == 0 or h == 0) return "";

        const header_h: u16 = 3; // top border + title row + bottom border
        const footer_h: u16 = 3; // input(1) + separator(1) + status(1)
        const sidebar_w: u16 = 32;
        const chat_w: u16 = if (w > sidebar_w + 1) @as(u16, @intCast(w - sidebar_w - 1)) else w;
        const body_h = if (h > header_h + footer_h) h - header_h - footer_h else @as(u16, @intCast(@max(h, 6) - header_h - footer_h));

        // Build header — title bar with model info
        var header_buf = std.ArrayList(u8).empty;
        self.renderClaudeHeader(&header_buf, a, w);
        const header_text = header_buf.toOwnedSlice(a) catch return "";

        // Build footer — input + separator + status (each renderer adds its own newline)
        var footer_buf = std.ArrayList(u8).empty;
        @constCast(self).renderClaudeInput(&footer_buf, a, w);
        self.renderClaudeSeparator(&footer_buf, a, w);
        self.renderClaudeStatus(&footer_buf, a, w);
        const footer_text = footer_buf.toOwnedSlice(a) catch "";

        // Build body: chat (left) + sidebar (right) using join.horizontal
        const chat_text = self.renderClaudeChat(a, chat_w, body_h);
        defer a.free(chat_text);
        const sidebar_text = self.renderClaudeSidebar(a, sidebar_w, body_h);
        defer a.free(sidebar_text);
        const sep_text = self.buildVerticalSeparator(a, body_h);
        defer a.free(sep_text);
        const chat_padded = enforceWidth(a, chat_text, chat_w) catch chat_text;
        defer if (chat_padded.ptr != chat_text.ptr) a.free(chat_padded);
        const sidebar_padded = enforceWidth(a, sidebar_text, sidebar_w) catch sidebar_text;
        defer if (sidebar_padded.ptr != sidebar_text.ptr) a.free(sidebar_padded);
        const body_parts = [_][]const u8{ chat_padded, sep_text, sidebar_padded };
        const body_text = join.horizontal(a, .top, &body_parts) catch chat_padded;

        // Compose: header | body | footer
        var all_parts = std.ArrayList([]const u8).empty;
        defer all_parts.deinit(a);
        all_parts.append(a, header_text) catch {};
        all_parts.append(a, body_text) catch {};
        all_parts.append(a, footer_text) catch {};

        // Compose base layout
        var result = join.vertical(a, .left, all_parts.items) catch body_text;

        // Render palette via ZigZag component (ANSI-aware overlay)
        if (self.palette.isOpen()) {
            const palette_view = self.palette.view(a) catch "";
            defer if (palette_view.len > 0) a.free(palette_view);
            if (palette_view.len > 0) {
                const pw = zz.layout.measure.maxLineWidth(palette_view);
                const ph = zz.layout.measure.height(palette_view);
                const px = (w -| @as(u16, @intCast(pw))) / 2;
                const py = (h -| @as(u16, @intCast(ph))) / 2;
                result = ansiOverlay(a, result, palette_view, px, py) catch result;
            }
        }

        // Render help and detail overlays via ZigZag Modal (full-screen backdrop)
        if (self.help_modal.isVisible()) {
            const modal_view = self.help_modal.viewWithBackdrop(a, w, h) catch "";
            if (modal_view.len > 0) {
                a.free(result);
                result = modal_view;
            } else {
                a.free(modal_view);
            }
        }
        if (self.detail_modal.isVisible()) {
            const modal_view = self.detail_modal.viewWithBackdrop(a, w, h) catch "";
            if (modal_view.len > 0) {
                a.free(result);
                result = modal_view;
            } else {
                a.free(modal_view);
            }
        }

        // Render slash command output modal
        if (self.slash_output_active) {
            const rendered = if (self.slash_output_data) |data| switch (data) {
                .table => |t| blk: {
                    if (t.headers.len != 2) break :blk (a.dupe(u8, "") catch "");
                    var table = zz.components.Table(2).init(a);
                    defer table.deinit();
                    table.setHeaders(.{ t.headers[0], t.headers[1] });
                    for (t.rows) |row| {
                        if (row.len != 2) continue;
                        table.addRow(.{ row[0], row[1] }) catch break :blk (a.dupe(u8, "") catch "");
                    }
                    break :blk table.view(a) catch (a.dupe(u8, "") catch "");
                },
                .list => |l| blk: {
                    var list = zz.components.List(void).init(a);
                    defer list.deinit();
                    for (l.items) |item| {
                        list.addItem(zz.components.List(void).Item.init({}, item)) catch break :blk (a.dupe(u8, "") catch "");
                    }
                    break :blk list.view(a) catch (a.dupe(u8, "") catch "");
                },
            } else "";
            defer if (self.slash_output_data != null) a.free(rendered);

            const modal = zz.components.Modal.info(self.slash_output_title, rendered);
            const overlay = modal.viewWithBackdrop(a, w, h) catch "";
            if (overlay.len > 0) {
                a.free(result);
                result = overlay;
            } else {
                a.free(overlay);
            }
        }

        // Render slash command prompt overlay
        if (self.slash_awaiting_cmd != null) {
            const title = self.slash_prompt_title orelse "";
            const input_view = self.slash_prompt_input.view(a) catch "";
            const body = std.fmt.allocPrint(a, "{s}\n\n{s}\n\n[Enter] submit  [Esc] cancel", .{ title, input_view }) catch "";

            var style = zz.Style{};
            style = style.borderAll(.rounded);
            style = style.width(50);
            style = style.paddingAll(1);
            const boxed = style.render(a, body) catch "";
            const overlay = zz.place.place(a, w, h, .center, .middle, boxed) catch "";
            result = ansiOverlay(a, result, overlay, 0, 0) catch result;
        }

        // Render search overlay (custom; Modal has no built-in input)
        if (self.search_active) {
            var overlay_lines = std.ArrayList([]const u8).empty;
            defer overlay_lines.deinit(a);
            self.renderSearchOverlay(&overlay_lines, a, w, h);
            if (overlay_lines.items.len > 0) {
                const overlay_text = join.vertical(a, .left, overlay_lines.items) catch "";
                defer a.free(overlay_text);
                const overlay_w: u16 = if (w > 20) @as(u16, @intCast(@min(w - 10, 60))) else @as(u16, @intCast(@max(w, 30)));
                const overlay_box = self.wrapInBox(a, overlay_text, overlay_w) catch overlay_text;
                result = join.vertical(a, .left, &[_][]const u8{ header_text, overlay_box, body_text, footer_text }) catch body_text;
            }
        }

        // Render sub-agent panel overlay (ANSI-aware overlay)
        if (self.show_subagents) {
            const panel_view = self.renderClaudeSubAgentPanel(a, w, h);
            defer a.free(panel_view);
            if (panel_view.len > 0) {
                const pw = zz.layout.measure.maxLineWidth(panel_view);
                const px = w -| @as(u16, @intCast(pw));
                const py: usize = 0;
                result = ansiOverlay(a, result, panel_view, px, py) catch result;
            }
        }

        // Render notification toasts on top of everything (ANSI-aware overlay)
        const toast_view = self.toast.view(a, ctx.elapsed) catch "";
        defer a.free(toast_view);
        if (toast_view.len > 0) {
            const tw = zz.layout.measure.maxLineWidth(toast_view);
            const tx = w -| @as(u16, @intCast(tw));
            const ty: usize = 0;
            result = ansiOverlay(a, result, toast_view, tx, ty) catch result;
        }

        return result;
    }

    fn wrapInBox(self: *const App, a: std.mem.Allocator, content: []const u8, box_w: u16) ![]const u8 {
        _ = self;
        var result = std.ArrayList(u8).empty;
        defer result.deinit(a);

        // Top border
        result.appendSlice(a, D) catch {};
        result.appendSlice(a, Pal.fg_dim) catch {};
        result.appendSlice(a, "┌") catch {};
        var i: u16 = 1;
        while (i < box_w - 1) : (i += 1) { result.appendSlice(a, "─") catch {}; }
        result.appendSlice(a, "┐") catch {};
        result.appendSlice(a, R) catch {};
        result.appendSlice(a, "\n") catch {};

        // Content lines (truncate each to box_w - 4)
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |ln| {
            result.appendSlice(a, D) catch {};
            result.appendSlice(a, "│") catch {};
            result.appendSlice(a, " ") catch {};
            result.appendSlice(a, R) catch {};
            const max_content = if (box_w > 4) box_w - 4 else 0;
            if (ln.len > max_content) {
                result.appendSlice(a, ln[0..max_content]) catch {};
            } else {
                result.appendSlice(a, ln) catch {};
                var p = @as(u16, @intCast(ln.len + 1));
                while (p < box_w - 1) : (p += 1) { result.appendSlice(a, " ") catch {}; }
            }
            result.appendSlice(a, D) catch {};
            result.appendSlice(a, "│") catch {};
            result.appendSlice(a, R) catch {};
            result.appendSlice(a, "\n") catch {};
        }

        // Bottom border
        result.appendSlice(a, D) catch {};
        result.appendSlice(a, Pal.fg_dim) catch {};
        result.appendSlice(a, "└") catch {};
        i = 1;
        while (i < box_w - 1) : (i += 1) { result.appendSlice(a, "─") catch {}; }
        result.appendSlice(a, "┘") catch {};
        result.appendSlice(a, R) catch {};
        result.appendSlice(a, "\n") catch {};

        return result.toOwnedSlice(a);
    }

    // ── Search overlay (kept custom because Modal has no built-in input) ──

    fn renderSearchOverlay(self: *const App, lines: *std.ArrayList([]const u8), a: std.mem.Allocator, w: u16, h: u16) void {
        _ = h; _ = w;
        const bo = Pal.fg_dim;
        lines.append(a, std.fmt.allocPrint(a, "{s}┌─ Search ─────────────────────────────────────────┐{s}", .{ bo, R }) catch "") catch {};
        lines.append(a, std.fmt.allocPrint(a, "{s}│{s} {s}▸{s} {s}{s}{s}", .{ bo, R, Pal.yellow, R, Pal.fg, self.search_query.items, R }) catch "") catch {};
        lines.append(a, std.fmt.allocPrint(a, "{s}└────────────────────────────────────────────────────┘{s}", .{ bo, R }) catch "") catch {};
    }

    fn updateHelpModal(self: *App) void {
        self.help_modal.title = "Keybindings";
        self.help_modal.body =
            \\Ctrl+C      Quit
            \\Ctrl+P      Open command palette
            \\Ctrl+F      Search messages
            \\Ctrl+N      Toggle thinking display
            \\Ctrl+S      Toggle sub-agent panel
            \\Ctrl+T      Cycle color theme
            \\Ctrl+O      Message detail
            \\Enter       Send message
            \\Shift+Enter Newline in input
            \\↑/↓         Scroll / navigate
            \\/           Open command palette
            \\F1 / ?      Toggle this help
            \\Esc         Close overlay
        ;
    }

    fn updateDetailModal(self: *App) void {
        if (self.detail_idx >= self.messages.items.len) {
            self.detail_modal.title = "Message Detail";
            self.detail_modal.body = "";
            return;
        }
        const m = self.messages.items[self.detail_idx];
        self.detail_modal.title = std.fmt.allocPrint(self.alloc, "Message Detail ({d}/{d})", .{ self.detail_idx + 1, self.messages.items.len }) catch "Message Detail";
        self.detail_modal.body = m.content;
    }

    // ── Claude-style header: border box with title + model info ──

    fn renderClaudeHeader(self: *const App, out: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        const streaming = self.streaming_idx != null;
        const cell_w = if (w >= 2) w - 2 else 0;

        // Top border
        out.appendSlice(a, D) catch {};
        out.appendSlice(a, Pal.fg_dim) catch {};
        out.appendSlice(a, "┌") catch {};
        var c: u16 = 1;
        while (c < w - 1) : (c += 1) { out.appendSlice(a, "─") catch {}; }
        out.appendSlice(a, "┐") catch {};
        out.appendSlice(a, R) catch {};
        out.appendSlice(a, "\n") catch {};

        // Title row: left="zeepseek", center=model, right=status
        // Pre-compute the right segment so we know its visual width.
        const ctx_pct: f64 = if (self.ctx_max > 0) @as(f64, @floatFromInt(self.tokens_used)) / @as(f64, @floatFromInt(self.ctx_max)) * 100.0 else 0.0;
        var right_buf = std.ArrayList(u8).empty;
        right_buf.appendSlice(a, " ") catch {};
        right_buf.appendSlice(a, Pal.fg_dim) catch {};
        right_buf.appendSlice(a, "turn ") catch {};
        right_buf.appendSlice(a, R) catch {};
        right_buf.appendSlice(a, Pal.yellow) catch {};
        appendIntFn(&right_buf, a, self.turn);
        right_buf.appendSlice(a, R) catch {};
        right_buf.appendSlice(a, D) catch {};
        right_buf.appendSlice(a, " ctx ") catch {};
        right_buf.appendSlice(a, R) catch {};
        right_buf.appendSlice(a, if (ctx_pct > 70) Pal.red else Pal.green) catch {};
        appendFmtFn(&right_buf, a, "{d:.0}%", .{ctx_pct});
        right_buf.appendSlice(a, R) catch {};
        right_buf.appendSlice(a, D) catch {};
        right_buf.appendSlice(a, " cache ") catch {};
        right_buf.appendSlice(a, R) catch {};
        right_buf.appendSlice(a, Pal.cyan) catch {};
        appendFmtFn(&right_buf, a, "{d:.0}%", .{self.cache_hit_rate * 100.0});
        right_buf.appendSlice(a, R) catch {};
        if (streaming) {
            right_buf.appendSlice(a, " ") catch {};
            right_buf.appendSlice(a, B) catch {};
            right_buf.appendSlice(a, Pal.yellow) catch {};
            right_buf.appendSlice(a, "◐") catch {};
            right_buf.appendSlice(a, R) catch {};
        }
        const right_text = right_buf.toOwnedSlice(a) catch "";
        const right_len = zz.layout.measure.width(right_text);

        const left_text = " zeepseek ";
        const left_len: u16 = 10;
        const model_len: u16 = @min(@as(u16, @intCast(self.model.len)), if (cell_w > left_len + right_len) cell_w - left_len - right_len else 0);

        // Distribute remaining space: center the model between left and right.
        const total_fixed = left_len + model_len + @as(u16, @intCast(right_len));
        const remaining = if (cell_w > total_fixed) cell_w - total_fixed else 0;
        const left_pad = remaining / 2;
        const right_pad = remaining - left_pad;

        out.appendSlice(a, D) catch {};
        out.appendSlice(a, "│") catch {};
        out.appendSlice(a, R) catch {};

        // Left: zeepseek
        out.appendSlice(a, B) catch {};
        out.appendSlice(a, Pal.yellow) catch {};
        out.appendSlice(a, left_text) catch {};
        out.appendSlice(a, R) catch {};

        // Center: model name
        out.appendSlice(a, D) catch {};
        var pad: u16 = 0;
        while (pad < left_pad) : (pad += 1) { out.appendSlice(a, " ") catch {}; }
        out.appendSlice(a, Pal.fg) catch {};
        if (model_len < self.model.len) {
            out.appendSlice(a, self.model[0..model_len]) catch {};
            out.appendSlice(a, "…") catch {};
        } else {
            out.appendSlice(a, self.model) catch {};
        }
        out.appendSlice(a, R) catch {};
        pad = 0;
        while (pad < right_pad) : (pad += 1) { out.appendSlice(a, " ") catch {}; }

        // Right: turn + ctx + cache
        out.appendSlice(a, right_text) catch {};

        out.appendSlice(a, D) catch {};
        out.appendSlice(a, "│") catch {};
        out.appendSlice(a, R) catch {};
        out.appendSlice(a, "\n") catch {};

        // Bottom border
        out.appendSlice(a, D) catch {};
        out.appendSlice(a, Pal.fg_dim) catch {};
        out.appendSlice(a, "└") catch {};
        c = 1;
        while (c < w - 1) : (c += 1) { out.appendSlice(a, "─") catch {}; }
        out.appendSlice(a, "┘") catch {};
        out.appendSlice(a, R) catch {};
    }

    // ── Claude-style input line ──

    fn renderClaudeInput(self: *App, out: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        out.appendSlice(a, D) catch {};
        out.appendSlice(a, "│ ") catch {};
        out.appendSlice(a, R) catch {};

        if (self.pending_action == .await_api_key) {
            self.text_input.setEchoMode(.password);
            self.text_input.setPrompt("🔑 ");
            self.text_input.setPlaceholder("Enter API key...");
        } else {
            self.text_input.setEchoMode(.normal);
            self.text_input.setPrompt("▸ ");
            self.text_input.setPlaceholder("Type a message, or / for commands");
        }

        const input_view = self.text_input.view(a) catch "Error";
        defer if (input_view.ptr != "Error".ptr) a.free(input_view);
        const input_vis = zz.layout.measure.width(input_view);
        const max_input = if (w > 4) w - 4 else 0;
        const display_input = if (input_vis > max_input)
            (zz.layout.measure.truncate(a, input_view, max_input) catch input_view)
        else
            input_view;
        defer if (display_input.ptr != input_view.ptr) a.free(display_input);
        out.appendSlice(a, display_input) catch {};

        // Pad to fill the cell (inside width is w - 2, leading space consumed 1)
        const display_vis = zz.layout.measure.width(display_input);
        const pad_target = if (w > 3) w - 3 else 0;
        var p = display_vis;
        while (p < pad_target) : (p += 1) { out.appendSlice(a, " ") catch {}; }

        out.appendSlice(a, D) catch {};
        out.appendSlice(a, "│") catch {};
        out.appendSlice(a, R) catch {};
        out.appendSlice(a, "\n") catch {};
    }

    // ── Vertical separator between chat and sidebar ──

    fn buildVerticalSeparator(self: *const App, a: std.mem.Allocator, h: u16) []const u8 {
        _ = self;
        var buf = std.ArrayList(u8).empty;
        var row: u16 = 0;
        while (row < h) : (row += 1) {
            buf.appendSlice(a, D) catch {};
            buf.appendSlice(a, Pal.fg_dim) catch {};
            buf.appendSlice(a, "│") catch {};
            buf.appendSlice(a, R) catch {};
            if (row + 1 < h) buf.appendSlice(a, "\n") catch {};
        }
        return buf.toOwnedSlice(a) catch "";
    }

    // ── Separator line ──

    fn renderClaudeSeparator(self: *const App, out: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = self;
        out.appendSlice(a, D) catch {};
        out.appendSlice(a, "│") catch {};
        out.appendSlice(a, R) catch {};
        var c: u16 = 2;
        while (c < w) : (c += 1) { out.appendSlice(a, "─") catch {}; }
        out.appendSlice(a, "│") catch {};
        out.appendSlice(a, "\n") catch {};
    }

    // ── Claude-style status bar ──

    fn renderClaudeStatus(self: *const App, out: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = self;
        const hint_full = "Ctrl+P palette  Ctrl+F search  Ctrl+S subagents  Ctrl+N thinking  Ctrl+C quit";
        const cell_w = if (w >= 2) w - 2 else 0;
        const content_w = if (cell_w > 1) cell_w - 1 else 0; // leading space

        out.appendSlice(a, D) catch {};
        out.appendSlice(a, "│") catch {};
        out.appendSlice(a, R) catch {};
        out.appendSlice(a, " ") catch {};
        out.appendSlice(a, Pal.fg_dim) catch {};

        // Truncate hint if the terminal is too narrow
        const hint = if (hint_full.len > content_w) hint_full[0..content_w] else hint_full;
        out.appendSlice(a, hint) catch {};

        var used: u16 = @as(u16, @intCast(1 + hint.len));
        while (used < cell_w) : (used += 1) { out.appendSlice(a, " ") catch {}; }
        out.appendSlice(a, D) catch {};
        out.appendSlice(a, "│") catch {};
        out.appendSlice(a, R) catch {};
    }

    // ── Claude-style chat rendering with markdown ──

    fn renderClaudeChat(self: *const App, a: std.mem.Allocator, w: u16, h: u16) []const u8 {
        var lines = std.ArrayList(u8).empty;
        defer lines.deinit(a);

        const total = self.messages.items.len;
        if (total == 0) {
            // Welcome / empty state
            self.renderClaudeWelcome(&lines, a, w);
            return lines.toOwnedSlice(a) catch "";
        }

        // Scroll: show last N messages that fit
        var consumed_h: u16 = 0;
        var start_idx: usize = 0;
        if (total > 0) {
            // Find how many messages we can show from the end
            start_idx = if (total > @as(usize, @intCast(h))) total - @as(usize, @intCast(h)) else 0;
        }

        for (start_idx..total) |i| {
            const m = &self.messages.items[i];
            const is_streaming = (self.streaming_idx == i);

            // Role label
            const role_color: []const u8 = switch (m.role) {
                .user => Pal.blue, .assistant => Pal.green, .system => Pal.mauve, .tool => Pal.yellow,
            };
            const role_label: []const u8 = switch (m.role) {
                .user => "You", .assistant => "Zeep", .system => "System", .tool => "Tool",
            };
            const status_icon: []const u8 = if (is_streaming) " ◐" else "";

            lines.appendSlice(a, D) catch {};
            lines.appendSlice(a, "│") catch {};
            lines.appendSlice(a, R) catch {};
            lines.appendSlice(a, " ") catch {};
            lines.appendSlice(a, B) catch {};
            lines.appendSlice(a, role_color) catch {};
            lines.appendSlice(a, role_label) catch {};
            lines.appendSlice(a, R) catch {};
            if (status_icon.len > 0) {
                lines.appendSlice(a, D) catch {};
                lines.appendSlice(a, status_icon) catch {};
                lines.appendSlice(a, R) catch {};
            }
            lines.appendSlice(a, "  ") catch {};

            // Content — render markdown for assistant, plain for others
            if (m.content.len > 0) {
                if (m.role == .assistant) {
                    self.renderClaudeMarkdownContent(&lines, a, m.content, w - 10);
                } else {
                    self.renderClaudePlainContent(&lines, a, m.content, w - 10);
                }
            } else if (is_streaming) {
                lines.appendSlice(a, D) catch {};
                lines.appendSlice(a, Pal.fg_dim) catch {};
                lines.appendSlice(a, "(waiting...)") catch {};
                lines.appendSlice(a, R) catch {};
            }

            // Thinking collapse toggle (only for assistant with thinking)
            if (m.thinking) |th| {
                if (th.len > 0) {
                    lines.appendSlice(a, "\n") catch {};
                    lines.appendSlice(a, D) catch {};
                    lines.appendSlice(a, "│   ") catch {};
                    lines.appendSlice(a, R) catch {};
                    const toggle_icon: []const u8 = if (m.think_collapsed) "▸" else "▾";
                    lines.appendSlice(a, Pal.cyan) catch {};
                    lines.appendSlice(a, toggle_icon) catch {};
                    lines.appendSlice(a, " ") catch {};
                    lines.appendSlice(a, Pal.fg_dim) catch {};
                    if (m.think_collapsed) {
                        lines.appendSlice(a, "thinking...") catch {};
                    } else {
                        lines.appendSlice(a, "thinking: ") catch {};
                        lines.appendSlice(a, Pal.orange) catch {};
                        lines.appendSlice(a, th) catch {};
                    }
                    lines.appendSlice(a, R) catch {};
                }
            }

            // Tool calls
            if (m.tool_calls.items.len > 0) {
                lines.appendSlice(a, "\n") catch {};
                lines.appendSlice(a, D) catch {};
                lines.appendSlice(a, "│   ") catch {};
                for (m.tool_calls.items) |tc| {
                    const tc_icon: []const u8 = switch (tc.status) {
                        .running => "◐", .success => "✓", .failed => "✗",
                    };
                    const tc_clr: []const u8 = switch (tc.status) {
                        .running => Pal.yellow, .success => Pal.green, .failed => Pal.red,
                    };
                    lines.appendSlice(a, tc_clr) catch {};
                    lines.appendSlice(a, tc_icon) catch {};
                    lines.appendSlice(a, R) catch {};
                    lines.appendSlice(a, " ") catch {};
                    lines.appendSlice(a, Pal.tool_call) catch {};
                    lines.appendSlice(a, tc.name) catch {};
                    lines.appendSlice(a, R) catch {};
                    lines.appendSlice(a, "  ") catch {};
                }
            }

            if (i + 1 < total and consumed_h + 1 < h) {
                lines.appendSlice(a, "\n") catch {};
            }
            consumed_h += 1;
            if (consumed_h >= h) break;
        }

        return lines.toOwnedSlice(a) catch "";
    }

    fn renderClaudeWelcome(self: *const App, lines: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = self; _ = w;
        lines.appendSlice(a, D) catch {};
        lines.appendSlice(a, "│") catch {};
        lines.appendSlice(a, R) catch {};
        lines.appendSlice(a, "\n") catch {};
        lines.appendSlice(a, D) catch {};
        lines.appendSlice(a, "│") catch {};
        lines.appendSlice(a, R) catch {};
        lines.appendSlice(a, "  ") catch {};
        lines.appendSlice(a, B) catch {};
        lines.appendSlice(a, Pal.yellow) catch {};
        lines.appendSlice(a, "zeepseek") catch {};
        lines.appendSlice(a, R) catch {};
        lines.appendSlice(a, D) catch {};
        lines.appendSlice(a, " — Claude CLI style TUI") catch {};
        lines.appendSlice(a, R) catch {};
        lines.appendSlice(a, "\n") catch {};
        lines.appendSlice(a, D) catch {};
        lines.appendSlice(a, "│") catch {};
        lines.appendSlice(a, R) catch {};
        lines.appendSlice(a, "  ") catch {};
        lines.appendSlice(a, D) catch {};
        lines.appendSlice(a, "Type a message to chat, or / for commands") catch {};
        lines.appendSlice(a, R) catch {};
        lines.appendSlice(a, "\n") catch {};
        lines.appendSlice(a, D) catch {};
        lines.appendSlice(a, "│") catch {};
        lines.appendSlice(a, R) catch {};
        lines.appendSlice(a, "  ") catch {};
        lines.appendSlice(a, D) catch {};
        lines.appendSlice(a, "Press Ctrl+P or / to open command palette") catch {};
        lines.appendSlice(a, R) catch {};
    }

    fn renderClaudeMarkdownContent(self: *const App, lines: *std.ArrayList(u8), a: std.mem.Allocator, content: []const u8, w: u16) void {
        _ = self;
        var buf = std.ArrayList(u8).empty;
        renderMarkdownAnsi(&buf, a, content, w);
        lines.appendSlice(a, buf.items) catch {};
        buf.deinit(a);
    }

    fn renderClaudePlainContent(self: *const App, lines: *std.ArrayList(u8), a: std.mem.Allocator, content: []const u8, w: u16) void {
        _ = self; _ = w;
        lines.appendSlice(a, Pal.fg) catch {};
        lines.appendSlice(a, content) catch {};
        lines.appendSlice(a, R) catch {};
    }

    // ── Claude-style right sidebar ──

    fn renderClaudeSidebar(self: *const App, a: std.mem.Allocator, w: u16, h: u16) []const u8 {
        var lines = std.ArrayList(u8).empty;
        defer lines.deinit(a);

        const ctx_pct: f64 = if (self.ctx_max > 0) @as(f64, @floatFromInt(self.tokens_used)) / @as(f64, @floatFromInt(self.ctx_max)) * 100.0 else 0.0;
        const cache_pct: f64 = self.cache_hit_rate * 100.0;
        const streaming = self.streaming_idx != null;

        const rows = [_]struct { label: []const u8, value: []const u8, color: []const u8 }{
            .{ .label = "model", .value = self.model, .color = Pal.fg },
            .{ .label = "provider", .value = self.provider, .color = Pal.cyan },
            .{ .label = "turn", .value = "", .color = Pal.yellow },
            .{ .label = "context", .value = "", .color = if (ctx_pct > 70) Pal.red else Pal.green },
            .{ .label = "cache", .value = "", .color = Pal.cyan },
            .{ .label = "status", .value = if (streaming) "streaming" else "idle", .color = if (streaming) Pal.yellow else Pal.fg_dim },
        };

        var r: u16 = 0;
        while (r < h) : (r += 1) {
            lines.appendSlice(a, D) catch {};
            lines.appendSlice(a, "│") catch {};
            lines.appendSlice(a, R) catch {};
            lines.appendSlice(a, " ") catch {};

            if (r == 0) {
                // Title
                lines.appendSlice(a, B) catch {};
                lines.appendSlice(a, Pal.fg_dim) catch {};
                lines.appendSlice(a, "INFO") catch {};
                lines.appendSlice(a, R) catch {};
                self.padToCol(&lines, a, w - 2, 5); // leading space + "INFO"
            } else if (r - 1 < rows.len) {
                const row = rows[r - 1];
                lines.appendSlice(a, Pal.fg_dim) catch {};
                lines.appendSlice(a, row.label) catch {};
                lines.appendSlice(a, "  ") catch {};
                lines.appendSlice(a, R) catch {};
                lines.appendSlice(a, row.color) catch {};
                const val: []const u8 = if (row.value.len > 0) row.value else val: {
                    if (std.mem.eql(u8, row.label, "turn")) {
                        break :val std.fmt.allocPrint(a, "{d}", .{self.turn}) catch "";
                    } else if (std.mem.eql(u8, row.label, "context")) {
                        break :val std.fmt.allocPrint(a, "{d:.0}%", .{ctx_pct}) catch "";
                    } else if (std.mem.eql(u8, row.label, "cache")) {
                        break :val std.fmt.allocPrint(a, "{d:.0}%", .{cache_pct}) catch "";
                    }
                    break :val "";
                };
                defer if (row.value.len == 0 and val.len > 0) a.free(@constCast(val));
                lines.appendSlice(a, val) catch {};
                lines.appendSlice(a, R) catch {};
                const used = 1 + row.label.len + 2 + val.len; // leading space + label + gap + value
                self.padToCol(&lines, a, w - 2, used);
            } else {
                // Empty rows
                self.padToCol(&lines, a, w - 2, 1); // leading space only
            }

            lines.appendSlice(a, D) catch {};
            lines.appendSlice(a, "│") catch {};
            lines.appendSlice(a, R) catch {};
            if (r + 1 < h) lines.appendSlice(a, "\n") catch {};
        }

        return lines.toOwnedSlice(a) catch "";
    }

    fn renderClaudeSubAgentPanel(self: *const App, a: std.mem.Allocator, w: u16, h: u16) []const u8 {
        _ = h;
        const panel_w: u16 = @min(w, 48);
        var lines = std.ArrayList([]const u8).empty;
        defer lines.deinit(a);

        const bo = Pal.fg_dim;
        const title = std.fmt.allocPrint(a, "{s}┌─ Sub-Agents {s}", .{ bo, R }) catch "";
        lines.append(a, title) catch {};
        const top_pad = panel_w -| 15;
        var top_line = std.ArrayList(u8).empty;
        top_line.appendSlice(a, title) catch {};
        var i: u16 = 0;
        while (i < top_pad) : (i += 1) { top_line.appendSlice(a, "─") catch {}; }
        top_line.appendSlice(a, "┐") catch {};
        top_line.appendSlice(a, R) catch {};
        lines.items[0] = top_line.toOwnedSlice(a) catch title;

        if (self.subagents.items.len == 0) {
            lines.append(a, std.fmt.allocPrint(a, "{s}│{s}  No active sub-agents  {s}│{s}", .{ bo, R, bo, R }) catch "") catch {};
        } else {
            for (self.subagents.items) |sa| {
                const status_icon: []const u8 = switch (sa.status) {
                    .pending => "○",
                    .streaming => "◐",
                    .complete => "✓",
                    .failed => "✗",
                    .truncated => "~",
                };
                const role_name = @tagName(sa.role);
                const line = std.fmt.allocPrint(a, "{s}│{s} {s} {s}: {s}{s}│{s}", .{
                    bo, R, status_icon, sa.id, role_name, bo, R,
                }) catch "";
                lines.append(a, line) catch {};
            }
        }
        lines.append(a, std.fmt.allocPrint(a, "{s}└──────────────────────────────────────┘{s}", .{ bo, R }) catch "") catch {};

        return join.vertical(a, .left, lines.items) catch "";
    }

    fn padToCol(self: *const App, out: *std.ArrayList(u8), a: std.mem.Allocator, target: u16, used: usize) void {
        _ = self;
        if (used < target) {
            var p = used;
            while (p < target) : (p += 1) { out.appendSlice(a, " ") catch {}; }
        }
    }

    /// Pad or truncate every line of a multi-line string to an exact visual width.
    /// The returned string is always a fresh allocation that the caller must free.
    fn enforceWidth(a: std.mem.Allocator, text: []const u8, target: u16) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(a);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try result.appendSlice(a, "\n");
            first = false;
            const line_w = zz.layout.measure.width(line);
            if (line_w > target) {
                const trunc = try zz.layout.measure.truncate(a, line, target);
                defer a.free(trunc);
                try result.appendSlice(a, trunc);
            } else {
                try result.appendSlice(a, line);
                var p = line_w;
                while (p < target) : (p += 1) { try result.appendSlice(a, " "); }
            }
        }
        return result.toOwnedSlice(a);
    }

    /// ANSI-aware overlay: places `content` onto `base` at (x, y), preserving
    /// escape sequences in both layers. Unlike zz.place.overlay, this does not
    /// corrupt ANSI codes by indexing into their byte sequences.
    fn ansiOverlay(a: std.mem.Allocator, base: []const u8, content: []const u8, x: usize, y: usize) ![]const u8 {
        const base_w = zz.layout.measure.maxLineWidth(base);
        const base_h = zz.layout.measure.height(base);
        const content_w = zz.layout.measure.maxLineWidth(content);
        const content_h = zz.layout.measure.height(content);

        var base_lines = std.ArrayList([]const u8).empty;
        defer base_lines.deinit(a);
        var base_iter = std.mem.splitScalar(u8, base, '\n');
        while (base_iter.next()) |line| try base_lines.append(a, line);

        var content_lines = std.ArrayList([]const u8).empty;
        defer content_lines.deinit(a);
        var content_iter = std.mem.splitScalar(u8, content, '\n');
        while (content_iter.next()) |line| try content_lines.append(a, line);

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(a);

        var row: usize = 0;
        while (row < base_h) : (row += 1) {
            if (row > 0) try result.appendSlice(a, "\n");
            const base_line = if (row < base_lines.items.len) base_lines.items[row] else "";
            if (row < y or row >= y + content_h or content_lines.items.len == 0) {
                try result.appendSlice(a, base_line);
                continue;
            }
            const content_row = row - y;
            const content_line = if (content_row < content_lines.items.len) content_lines.items[content_row] else "";
            const content_line_w = zz.layout.measure.width(content_line);
            var overlay_w = if (content_line_w > content_w) content_line_w else content_w;
            const max_overlay_w = if (x < base_w) base_w - x else 0;
            if (overlay_w > max_overlay_w) overlay_w = max_overlay_w;

            // Prefix: base columns [0, x)
            const prefix = try zz.layout.measure.truncate(a, base_line, x);
            defer a.free(prefix);
            // Suffix: base columns [x + overlay_w, base_w)
            const up_to_overlay_end = try zz.layout.measure.truncate(a, base_line, x + overlay_w);
            defer a.free(up_to_overlay_end);
            const suffix = base_line[up_to_overlay_end.len..];

            // Pad content to the overlay width
            const padded_content = if (overlay_w > 0)
                try zz.layout.measure.padRight(a, content_line, overlay_w)
            else
                try a.dupe(u8, "");
            defer a.free(padded_content);

            try result.appendSlice(a, prefix);
            try result.appendSlice(a, R); // reset before overlay
            try result.appendSlice(a, padded_content);
            try result.appendSlice(a, R); // reset after overlay
            try result.appendSlice(a, suffix);

            // Ensure the output line visually matches base_w
            const out_w = zz.layout.measure.width(prefix) + overlay_w + zz.layout.measure.width(suffix);
            if (out_w < base_w) {
                var p = out_w;
                while (p < base_w) : (p += 1) try result.appendSlice(a, " ");
            }
        }

        return result.toOwnedSlice(a);
    }

    fn appendIntFn(out: *std.ArrayList(u8), a: std.mem.Allocator, val: anytype) void {
        if (std.fmt.allocPrint(a, "{d}", .{val})) |s| {
            out.appendSlice(a, s) catch {};
        } else |_| {}
    }

    fn appendFmtFn(out: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
        if (std.fmt.allocPrint(a, fmt, args)) |s| {
            out.appendSlice(a, s) catch {};
        } else |_| {}
    }

    fn ansiVisibleLen(text: []const u8) usize {
        var len: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
                i += 2;
                while (i < text.len and text[i] != 'm') : (i += 1) {}
                i += 1;
            } else {
                len += 1;
                i += 1;
            }
        }
        return len;
    }

};

pub fn main(init: std.process.Init) !void {
    var program = zz.Program(App).init(init.gpa, init.io, init.environ_map);
    defer program.deinit();
    try program.run();
}

fn makeTestApp(alloc: std.mem.Allocator) App {
    var app: App = undefined;
    app.messages = .empty;
    app.alloc = alloc;
    app.scroll_offset = 0;
    app.auto_scroll = true;
    app.streaming_idx = null;
    app.text_input = zz.components.TextInput.init(alloc);
    app.palette = zz.components.CommandPalette.init(alloc) catch unreachable;
    for (App.CMDS) |cmd| {
        app.palette.addCommand(.{
            .id = cmd.id,
            .label = cmd.label,
            .description = cmd.desc,
        }) catch {};
    }
    app.show_thinking = true;
    app.search_active = false;
    app.search_query = .empty;
    app.search_cursor = 0;
    app.help_modal = zz.components.Modal.info("Keybindings", "");
    app.detail_modal = zz.components.Modal.info("Message Detail", "");
    app.detail_idx = 0;
    app.show_subagents = false;
    app.subagents = .empty;
    app.stream_state = null;
    app.stream_thread = null;
    app.api_key = "";
    app.io = undefined;
    app.session_id = "test";
    app.session_dir = "";
    app.should_quit = false;
    app.turn = 0;
    app.tokens_used = 0;
    app.ctx_max = 64000;
    app.cache_hit_rate = 0;
    app.model = "deepseek-chat";
    app.provider = "deepseek";
    app.provider_mgr = ProviderManager.init(alloc);
    app.i18n = I18nManager.init(.en);
    app.sandbox = null;
    app.subsystems_initialized = false;
    app.ctx_mgr = null;
    app.cache_loop = null;
    app.width = 80;
    app.height = 24;
    app.cursor_visible = true;
    app.toast = zz.components.Toast.init(alloc);
    app.theme_manager = theme.ThemeManager.init(alloc);
    app.styles = theme.SemanticStyles.fromPalette(app.theme_manager.getPalette());
    app.pending_action = .none;
    app.pending_data = .empty;
    return app;
}

fn makeTestCtx(alloc: std.mem.Allocator) zz.Context {
    return zz.Context{
        .allocator = alloc,
        .persistent_allocator = alloc,
        .home_dir = "/tmp",
        .io = undefined,
        .width = 80,
        .height = 24,
        .frame = 0,
        .elapsed = 0,
        .delta = 0,
        .true_color = true,
        .color_256 = false,
        .color_profile = .true_color,
        .is_dark_background = true,
        .unicode_width_strategy = .legacy_wcwidth,
        .terminal_mode_2027 = false,
        .kitty_text_sizing = false,
        .theme = zz.theme.Theme.fromPalette(zz.theme.Palette.default_dark),
        ._terminal = null,
    };
}

test "app init has zero messages" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer app.messages.deinit(alloc);
    defer app.text_input.deinit();
    defer app.palette.deinit();
    defer app.toast.deinit();
    defer app.theme_manager.deinit();
    defer app.search_query.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), app.messages.items.len);
}

test "submit adds user message" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| {
            if (m.owns and m.content.len > 0) alloc.free(m.content);
        }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Type "hello"
    try app.text_input.setValue("hello");
    app.text_input.cursor = 5;

    // Submit
    app.submit();

    // Should have 2 messages: user + assistant (no API key)
    try std.testing.expectEqual(@as(usize, 2), app.messages.items.len);
    try std.testing.expectEqual(Role.user, app.messages.items[0].role);
    try std.testing.expectEqualStrings("hello", app.messages.items[0].content);
    try std.testing.expectEqual(Role.assistant, app.messages.items[1].role);
    // Input should be cleared
    try std.testing.expectEqual(@as(usize, 0), app.text_input.getValue().len);
    // Turn should increment
    try std.testing.expectEqual(@as(u32, 1), app.turn);
}

test "submit slash command /help" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| {
            if (m.owns and m.content.len > 0) alloc.free(m.content);
        }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Type "/help"
    try app.text_input.setValue("/help");
    app.text_input.cursor = 5;

    // Submit
    app.submit();

    // Should open help modal, no messages added
    try std.testing.expect(app.help_modal.isVisible());
    try std.testing.expectEqual(@as(usize, 0), app.messages.items.len);
    // Input should be cleared
    try std.testing.expectEqual(@as(usize, 0), app.text_input.getValue().len);
}

test "submit slash command /clear" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| {
            if (m.owns and m.content.len > 0) alloc.free(m.content);
        }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Add a message first
    try app.messages.append(alloc, .{ .role = .user, .content = "old", .owns = false });

    // Type "/clear"
    try app.text_input.setValue("/clear");
    app.text_input.cursor = 6;

    // Submit
    app.submit();

    // Messages should be cleared
    try std.testing.expectEqual(@as(usize, 0), app.messages.items.len);
}

test "submit slash command /exit" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Type "/exit"
    try app.text_input.setValue("/exit");
    app.text_input.cursor = 5;

    // Submit
    app.submit();

    // should_quit should be true
    try std.testing.expect(app.should_quit);
}

test "submit unknown command" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| {
            if (m.owns and m.content.len > 0) alloc.free(m.content);
        }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Type "/foobar"
    try app.text_input.setValue("/foobar");
    app.text_input.cursor = 7;

    // Submit
    app.submit();

    // Should have 1 system message: "Unknown command"
    try std.testing.expectEqual(@as(usize, 1), app.messages.items.len);
    try std.testing.expectEqual(Role.system, app.messages.items[0].role);
    try std.testing.expect(std.mem.indexOf(u8, app.messages.items[0].content, "Unknown") != null);
}

test "submit empty input does nothing" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Submit with empty input
    app.submit();

    // Nothing should change
    try std.testing.expectEqual(@as(usize, 0), app.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), app.turn);
}

test "view produces non-empty output" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| {
            if (m.owns and m.content.len > 0) alloc.free(m.content);
        }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Create a mock context
    var ctx = zz.Context{
        .allocator = alloc,
        .persistent_allocator = alloc,
        .home_dir = "/tmp",
        .io = undefined,
        .width = 80,
        .height = 24,
        .frame = 0,
        .elapsed = 0,
        .delta = 0,
        .true_color = true,
        .color_256 = false,
        .color_profile = .true_color,
        .is_dark_background = true,
        .unicode_width_strategy = .legacy_wcwidth,
        .terminal_mode_2027 = false,
        .kitty_text_sizing = false,
        .theme = zz.theme.Theme.fromPalette(zz.theme.Palette.default_dark),
        ._terminal = null,
    };

    // View with no messages
    const output = app.view(&ctx);
    try std.testing.expect(output.len > 0);

    // View with a message
    try app.messages.append(alloc, .{ .role = .user, .content = "test message", .owns = false });
    const output2 = app.view(&ctx);
    try std.testing.expect(output2.len > 0);
    // Should contain the message text
    try std.testing.expect(std.mem.indexOf(u8, output2, "test message") != null);
}

test "view with help overlay contains keybindings" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| { if (m.owns and m.content.len > 0) alloc.free(m.content); }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }
    app.updateHelpModal();
    app.help_modal.show();
    var ctx = zz.Context{
        .allocator = alloc, .persistent_allocator = alloc, .home_dir = "/tmp",
        .io = undefined, .width = 80, .height = 24, .frame = 0, .elapsed = 0, .delta = 0,
        .true_color = true, .color_256 = false, .color_profile = .true_color,
        .is_dark_background = true, .unicode_width_strategy = .legacy_wcwidth,
        .terminal_mode_2027 = false, .kitty_text_sizing = false, .theme = zz.theme.Theme.fromPalette(zz.theme.Palette.default_dark), ._terminal = null,
    };
    const output = app.view(&ctx);
    try std.testing.expect(std.mem.indexOf(u8, output, "Keybindings") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Ctrl+C") != null);
}

test "view with palette shows commands" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }
    app.palette.open();
    var ctx = zz.Context{
        .allocator = alloc, .persistent_allocator = alloc, .home_dir = "/tmp",
        .io = undefined, .width = 80, .height = 24, .frame = 0, .elapsed = 0, .delta = 0,
        .true_color = true, .color_256 = false, .color_profile = .true_color,
        .is_dark_background = true, .unicode_width_strategy = .legacy_wcwidth,
        .terminal_mode_2027 = false, .kitty_text_sizing = false, .theme = zz.theme.Theme.fromPalette(zz.theme.Palette.default_dark), ._terminal = null,
    };
    const output = app.view(&ctx);
    try std.testing.expect(std.mem.indexOf(u8, output, "/help") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Type a command") != null);
}

test "view sidebar contains model and metrics" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }
    var ctx = zz.Context{
        .allocator = alloc, .persistent_allocator = alloc, .home_dir = "/tmp",
        .io = undefined, .width = 80, .height = 24, .frame = 0, .elapsed = 0, .delta = 0,
        .true_color = true, .color_256 = false, .color_profile = .true_color,
        .is_dark_background = true, .unicode_width_strategy = .legacy_wcwidth,
        .terminal_mode_2027 = false, .kitty_text_sizing = false, .theme = zz.theme.Theme.fromPalette(zz.theme.Palette.default_dark), ._terminal = null,
    };
    const output = app.view(&ctx);
    try std.testing.expect(std.mem.indexOf(u8, output, "deepseek-chat") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zeepseek") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "turn=") != null);
}

test "view input shows placeholder when empty" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }
    var ctx = zz.Context{
        .allocator = alloc, .persistent_allocator = alloc, .home_dir = "/tmp",
        .io = undefined, .width = 80, .height = 24, .frame = 0, .elapsed = 0, .delta = 0,
        .true_color = true, .color_256 = false, .color_profile = .true_color,
        .is_dark_background = true, .unicode_width_strategy = .legacy_wcwidth,
        .terminal_mode_2027 = false, .kitty_text_sizing = false, .theme = zz.theme.Theme.fromPalette(zz.theme.Palette.default_dark), ._terminal = null,
    };
    const output = app.view(&ctx);
    try std.testing.expect(std.mem.indexOf(u8, output, "Type a message") != null);
}

test "palette select provider sets input" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| { if (m.owns and m.content.len > 0) alloc.free(m.content); }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Simulate palette selection of /provider
    app.execPaletteCommand(.{ .id = "provider", .label = "/provider", .description = "" });

    // After palette selection, input should have "/provider "
    try std.testing.expect(!app.palette.isOpen());
    try std.testing.expect(std.mem.startsWith(u8, app.text_input.getValue(), "/provider"));
    try std.testing.expect(app.text_input.getValue().len > 0);
}

test "command palette fuzzy filter finds command" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| { if (m.owns and m.content.len > 0) alloc.free(m.content); }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    app.palette.open();
    const chars = &[_]u8{ 'c', 'l', 'e', 'a' };
    for (chars) |ch| {
        const ev = zz.KeyEvent{ .key = .{ .char = ch }, .modifiers = .{} };
        _ = try app.palette.handleKey(ev);
    }
    const selected = app.palette.selected();
    try std.testing.expect(selected != null);
    try std.testing.expect(std.mem.indexOf(u8, selected.?.label, "/clear") != null);
}

test "submit /provider deepseek sets pending action" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| { if (m.owns and m.content.len > 0) alloc.free(m.content); }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Type "/provider deepseek" and submit
    try app.text_input.setValue("/provider deepseek");
    app.text_input.cursor = 18;
    app.submit();

    // Should have set pending_action
    try std.testing.expectEqual(App.PendingAction.await_api_key, app.pending_action);
    // Should have system message
    try std.testing.expect(app.messages.items.len > 0);
    const last = app.messages.items[app.messages.items.len - 1];
    try std.testing.expectEqual(Role.system, last.role);
    try std.testing.expect(std.mem.indexOf(u8, last.content, "API key") != null);
    // Input should be cleared
    try std.testing.expectEqual(@as(usize, 0), app.text_input.getValue().len);
}

test "pending api key submit saves key" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| { if (m.owns and m.content.len > 0) alloc.free(m.content); }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Set up pending action
    app.pending_action = .await_api_key;
    try app.text_input.setValue("sk-test123");
    app.text_input.cursor = 10;
    app.submit();

    // Key should be saved
    try std.testing.expectEqual(App.PendingAction.none, app.pending_action);
    try std.testing.expectEqualStrings("sk-test123", app.api_key);
}


test "text input accepts typed text" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| {
            if (m.owns and m.content.len > 0) alloc.free(m.content);
        }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    try app.text_input.setValue("hello");
    app.text_input.cursor = 5;
    try std.testing.expectEqualStrings("hello", app.text_input.getValue());
}

test "notification toast is rendered when set" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| {
            if (m.owns and m.content.len > 0) alloc.free(m.content);
        }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    app.setNotification("Hello toast");
    var ctx = makeTestCtx(alloc);
    const output = app.view(&ctx);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello toast") != null);
}

test "subagent panel toggle shows subagents" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| {
            if (m.owns and m.content.len > 0) alloc.free(m.content);
        }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    app.show_subagents = true;
    var ctx = makeTestCtx(alloc);
    const output = app.view(&ctx);
    try std.testing.expect(std.mem.indexOf(u8, output, "Sub-Agents") != null);
}

test "theme switch updates current theme id" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| {
            if (m.owns and m.content.len > 0) alloc.free(m.content);
        }
        app.messages.deinit(alloc);
        app.text_input.deinit();
        app.palette.deinit();
        app.toast.deinit();
        app.theme_manager.deinit();
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    const first = app.theme_manager.current;
    app.cycleTheme();
    try std.testing.expect(app.theme_manager.current != first);
}
