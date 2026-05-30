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
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line| {
        // Code block fence
        if (std.mem.startsWith(u8, line, "```")) {
            if (in_code_block) {
                appendFmt(buf, a, "{s}+---{s}\n", .{ D, R });
                in_code_block = false;
            } else {
                in_code_block = true;
                code_lang = if (line.len > 3) std.mem.trim(u8, line[3..], " ") else "";
                if (code_lang.len > 0) {
                    appendFmt(buf, a, "{s}+--- {s} ---{s}\n", .{ D, code_lang, R });
                } else {
                    appendFmt(buf, a, "{s}+---{s}\n", .{ D, R });
                }
            }
            continue;
        }

        if (in_code_block) {
            appendFmt(buf, a, "{s}| {s}{s}{s}\n", .{ D, Pal.fg, line, R });
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
            appendFmt(buf, a, "  {s}|{s} {s}{s}{s}\n", .{ D, R, D, line[2..], R });
            continue;
        }

        // Regular paragraph
        renderInlineAnsi(buf, a, line);
        buf.appendSlice(a, "\n") catch {};
    }
    // Unclosed code block
    if (in_code_block) {
        appendFmt(buf, a, "{s}+---{s}\n", .{ D, R });
    }
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
                appendFmt(buf, a, "{s}{s}{s}", .{ B, text[i + 2 .. end], R });
                i = end + 2;
                continue;
            }
        }
        // Italic _..._ (single underscore)
        if (text[i] == '_' and i + 1 < text.len and text[i + 1] != '_') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '_')) |end| {
                appendFmt(buf, a, "{s}{s}{s}", .{ U, text[i + 1 .. end], R });
                i = end + 1;
                continue;
            }
        }
        // Strikethrough ~~...~~
        if (i + 1 < text.len and text[i] == '~' and text[i + 1] == '~') {
            if (std.mem.indexOfPos(u8, text, i + 2, "~~")) |end| {
                appendFmt(buf, a, "\x1b[9m{s}{s}", .{ text[i + 2 .. end], R });
                i = end + 2;
                continue;
            }
        }
        // Link [text](url) — render as underlined text
        if (text[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |cb| {
                if (cb + 1 < text.len and text[cb + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, cb + 2, ')')) |cp| {
                        appendFmt(buf, a, "{s}{s}{s}", .{ Pal.cyan, text[i + 1 .. cb], R });
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
            appendFmt(buf, a, "{s}{s}{s}", .{ SearchHighlight, text[match .. match + query.len], R });
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
        self.error_msg = msg;
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

    // --- Chat state 
    messages: std.ArrayList(ChatMsg),
    alloc: std.mem.Allocator,
    scroll_offset: u16,
    auto_scroll: bool,
    streaming_idx: ?usize,

    // --- Input state 
    input: std.ArrayList(u8),
    cursor: usize,

    // --- UI overlays 
    show_help: bool,
    show_palette: bool,
    palette_buf: std.ArrayList(u8),
    palette_sel: usize,
    show_thinking: bool,

    // --- Search state 
    search_active: bool,
    search_query: std.ArrayList(u8),
    search_cursor: usize,

    // --- Message detail overlay 
    detail_active: bool,
    detail_idx: usize,
    detail_scroll: u16,

    // --- Sub-agent panel 
    show_subagents: bool,
    subagents: std.ArrayList(SubAgent),

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
    notif: ?[]const u8 = null,
    notif_tick: u64 = 0,

    // --- Pending interactive action ──
    pending_action: PendingAction = .none,
    pending_data: std.ArrayList(u8),

    // --- Elm Interface 

    pub fn init(self: *App, ctx: *zz.Context) zz.Cmd(Msg) {
        self.io = ctx.io;
        self.* = .{
            .messages = .empty,
            .alloc = undefined,
            .scroll_offset = 0,
            .auto_scroll = true,
            .streaming_idx = null,
            .input = .empty,
            .cursor = 0,
            .show_help = false,
            .show_palette = false,
            .palette_buf = .empty,
            .palette_sel = 0,
            .show_thinking = true,
            .search_active = false,
            .search_query = .empty,
            .search_cursor = 0,
            .detail_active = false,
            .detail_idx = 0,
            .detail_scroll = 0,
            .show_subagents = false,
            .subagents = .empty,
            .stream_state = null,
            .stream_thread = null,
            .api_key = blk: {
                const key_ptr = std.c.getenv("DEEPSEEK_API_KEY");
                break :blk if (key_ptr) |k| std.mem.sliceTo(k, 0) else "";
            },
            .io = undefined, // set above from ctx.io before struct init
            .session_id = "default",
            .session_dir = "",
            .should_quit = false,
            .turn = 0,
            .tokens_used = 0,
            .ctx_max = 64000,
            .cache_hit_rate = 0,
            .model = "deepseek-chat",
            .provider = "deepseek",
            .provider_mgr = ProviderManager.init(undefined),
            .i18n = I18nManager.init(.en),
            .sandbox = null,
            .subsystems_initialized = false,
            .ctx_mgr = null,
            .cache_loop = null,
            .width = 80,
            .height = 24,
            .cursor_visible = true,
            .notif = null,
            .notif_tick = 0,
            .pending_action = .none,
            .pending_data = .empty,
        };
        // Try loading saved API key from disk
        self.loadSavedApiKey();
        return .enter_alt_screen;
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
        self.input.deinit(self.alloc);
        self.palette_buf.deinit(self.alloc);
        self.search_query.deinit(self.alloc);
        self.pending_data.deinit(self.alloc);

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

    pub fn update(self: *App, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        // Use persistent allocator for model state (survives frame resets)
        self.alloc = ctx.persistent_allocator;
        self.io = ctx.io;
        // Lazy-init subsystems that need a real allocator
        if (!self.subsystems_initialized) {
            self.subsystems_initialized = true;
            self.provider_mgr = ProviderManager.init(ctx.persistent_allocator);
            // Register default deepseek provider
            self.provider_mgr.addProvider(.{
                .provider_id = "deepseek",
                .api_key = self.api_key,
                .default_model = "deepseek-chat",
            }) catch {};
            self.sandbox = Sandbox.init(.seatbelt, &.{"/Users"}) catch null;
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
                // Auto-dismiss notification after ~2 seconds (4 ticks at 60fps≈2s)
                if (self.notif != null) {
                    self.notif_tick += 1;
                    if (self.notif_tick > 120) { // ~2 seconds
                        if (self.notif) |n| self.alloc.free(n);
                        self.notif = null;
                    }
                }
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

        // --- Palette overlay ──
        if (self.show_palette) {
            if (k == .escape) { self.show_palette = false; self.palette_buf.clearRetainingCapacity(); return .none; }
            if (k == .enter) { self.execPalette(); return .none; }
            if (k == .tab) {
                // Tab cycles through filtered commands
                var cmd_buf: [CMDS.len]CmdEntry = undefined;
                const fc = self.filteredCmds(&cmd_buf);
                if (fc.len > 0) self.palette_sel = (self.palette_sel + 1) % fc.len;
                return .none;
            }
            if (k == .backspace) {
                if (self.palette_buf.items.len > 0) {
                    _ = self.palette_buf.pop();
                    self.palette_sel = 0; // Reset selection on filter change
                } else {
                    // Empty filter + backspace = close palette
                    self.show_palette = false;
                }
                return .none;
            }
            if (k == .down or (m.ctrl and k == .char and k.char == 'n')) {
                var cmd_buf: [CMDS.len]CmdEntry = undefined;
                const fc = self.filteredCmds(&cmd_buf);
                if (fc.len > 0) self.palette_sel = (self.palette_sel + 1) % fc.len;
                return .none;
            }
            if (k == .up or (m.ctrl and k == .char and k.char == 'p')) {
                var cmd_buf: [CMDS.len]CmdEntry = undefined;
                const fc = self.filteredCmds(&cmd_buf);
                if (fc.len > 0) self.palette_sel = if (self.palette_sel > 0) self.palette_sel - 1 else fc.len - 1;
                return .none;
            }
            if (k == .char) {
                if (m.ctrl or m.alt) return .none;
                if (k.char >= 32) {
                    self.palette_buf.append(self.alloc, @intCast(k.char)) catch {};
                    self.palette_sel = 0; // Reset selection on filter change
                }
                return .none;
            }
            return .none;
        }

        // --- Help overlay 
        if (self.show_help) {
            if (k == .escape or k == .char and (k.char == 'q' or k.char == '?')) self.show_help = false;
            return .none;
        }

        // --- Detail overlay 
        if (self.detail_active) {
            if (k == .escape or (k == .char and k.char == 'q')) { self.detail_active = false; return .none; }
            if (k == .up or k == .char and k.char == 'k') { if (self.detail_scroll > 0) self.detail_scroll -= 1; return .none; }
            if (k == .down or k == .char and k.char == 'j') { self.detail_scroll +|= 1; return .none; }
            if (k == .page_up) { self.detail_scroll -|= 10; return .none; }
            if (k == .page_down) { self.detail_scroll +|= 10; return .none; }
            if (k == .left) { if (self.detail_idx > 0) self.detail_idx -= 1; self.detail_scroll = 0; return .none; }
            if (k == .right) { if (self.detail_idx + 1 < self.messages.items.len) self.detail_idx += 1; self.detail_scroll = 0; return .none; }
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
                'o' => { if (self.messages.items.len > 0) { self.detail_active = true; self.detail_idx = self.messages.items.len - 1; self.detail_scroll = 0; } },
                'p' => { self.show_palette = true; self.palette_sel = 0; self.palette_buf.clearRetainingCapacity(); },
                'n' => self.show_thinking = !self.show_thinking,
                'a' => { self.cursor = 0; }, // home
                'e' => { self.cursor = self.input.items.len; }, // end
                'u' => { self.input.clearRetainingCapacity(); self.cursor = 0; }, // kill line
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

        // --- / opens command palette (always available) ──
        if (k == .char and k.char == '/') {
            self.show_palette = true;
            self.palette_sel = 0;
            self.palette_buf.clearRetainingCapacity();
            return .none;
        }

        // --- F1 / ? for help (when input empty) 
        if (k == .f1 or (k == .char and k.char == '?' and self.input.items.len == 0)) {
            self.show_help = true;
            return .none;
        }

        // --- Scroll keys (when input empty) 
        if (self.input.items.len == 0) {
            if (k == .up) { if (self.scroll_offset > 0) self.scroll_offset -= 1; self.auto_scroll = false; return .none; }
            if (k == .down) { self.scroll_offset += 1; return .none; }
            if (k == .page_up) { self.scroll_offset -|= 10; self.auto_scroll = false; return .none; }
            if (k == .page_down) { self.scroll_offset +|= 10; return .none; }
            if (k == .home) { self.scroll_offset = 0; self.auto_scroll = false; return .none; }
            if (k == .end) { self.scroll_offset = 0; self.auto_scroll = true; return .none; }
        }

        // --- Enter: submit 
        if (k == .enter) {
            if (m.shift) {
                // Shift+Enter: newline in input
                self.input.append(self.alloc, '\n') catch {};
                self.cursor = self.input.items.len;
            } else {
                self.submit();
            }
            return .none;
        }

        // --- Backspace 
        if (k == .backspace) {
            if (self.cursor > 0) {
                // Find the start of the previous UTF-8 character
                var prev = self.cursor - 1;
                while (prev > 0 and (self.input.items[prev] & 0xC0) == 0x80) : (prev -= 1) {}
                // Remove all bytes from prev to cursor
                const count = self.cursor - prev;
                var j: usize = 0;
                while (j < count) : (j += 1) {
                    _ = self.input.orderedRemove(prev);
                }
                self.cursor = prev;
            }
            return .none;
        }

        // --- Delete 
        if (k == .delete) {
            if (self.cursor < self.input.items.len) {
                // Find the end of the current UTF-8 character
                var next: usize = self.cursor + 1;
                while (next < self.input.items.len and (self.input.items[next] & 0xC0) == 0x80) : (next += 1) {}
                const count = next - self.cursor;
                var j: usize = 0;
                while (j < count) : (j += 1) {
                    _ = self.input.orderedRemove(self.cursor);
                }
            }
            return .none;
        }

        // --- Arrow keys (input mode) 
        if (k == .left) { if (self.cursor > 0) self.cursor -= 1; return .none; }
        if (k == .right) { if (self.cursor < self.input.items.len) self.cursor += 1; return .none; }
        if (k == .home) { self.cursor = 0; return .none; }
        if (k == .end) { self.cursor = self.input.items.len; return .none; }

        // --- Printable characters 
        if (k == .char) {
            // Skip if Ctrl or Alt modifier is active — already handled above
            if (m.ctrl or m.alt) return .none;
            // Reject control characters (codepoint < 32)
            if (k.char < 32) return .none;
            // If Shift modifier is set but char is lowercase, convert to uppercase
            var cp = k.char;
            if (m.shift and cp >= 'a' and cp <= 'z') cp -= 32;
            // Encode as UTF-8: single byte for ASCII, multi-byte for CJK etc.
            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
            for (utf8_buf[0..utf8_len]) |byte| {
                self.input.insert(self.alloc, self.cursor, byte) catch {};
                self.cursor += 1;
            }
            return .none;
        }

        // --- Paste 
        if (k == .paste) {
            for (k.paste) |ch| {
                self.input.append(self.alloc, ch) catch {};
            }
            self.cursor = self.input.items.len;
            return .none;
        }

        return .none;
    }

    // ═════════════════════════════════════════════════════════════════
    // Submit / Streaming
    // ═════════════════════════════════════════════════════════════════

    fn submit(self: *App) void {
        if (self.input.items.len == 0) return;

        const text_slice = self.input.items;

        // Handle pending interactive actions
        if (self.pending_action == .await_api_key) {
            const key = self.alloc.dupe(u8, text_slice) catch return;
            self.setApiKey(key);
            self.pending_action = .none;
            self.pending_data.clearRetainingCapacity();
            self.input.clearRetainingCapacity();
            self.cursor = 0;
            return;
        }

        // Check for slash commands
        if (text_slice.len > 1 and text_slice[0] == '/') {
            const cmd_text = text_slice[1..];
            // Extract command id (first word)
            var cmd_end: usize = 0;
            while (cmd_end < cmd_text.len and cmd_text[cmd_end] != ' ') : (cmd_end += 1) {}
            // Handle /exit immediately
            if (std.mem.eql(u8, cmd_text[0..cmd_end], "exit")) {
                self.should_quit = true;
                self.input.clearRetainingCapacity();
                self.cursor = 0;
                return;
            }
            for (&CMDS) |cmd| {
                if (std.mem.eql(u8, cmd.id, cmd_text[0..cmd_end])) {
                    const args = if (cmd_end < cmd_text.len) std.mem.trim(u8, cmd_text[cmd_end..], " ") else "";
                    self.execCommandWithArgs(cmd.id, args);
                    self.input.clearRetainingCapacity();
                    self.cursor = 0;
                    return;
                }
            }
            // Unknown command
            const err = std.fmt.allocPrint(self.alloc, "Unknown command: /{s}", .{cmd_text[0..cmd_end]}) catch return;
            self.messages.append(self.alloc, .{ .role = .system, .content = err, .owns = true }) catch {};
            self.input.clearRetainingCapacity();
            self.cursor = 0;
            return;
        }

        const text = self.alloc.dupe(u8, text_slice) catch return;
        self.messages.append(self.alloc, .{
            .role = .user,
            .content = text,
            .timestamp = 0,
            .owns = true,
        }) catch {};

        self.input.clearRetainingCapacity();
        self.cursor = 0;
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

                var stream = client.streamMessage(api_k, prompt, ctx, mdl, CacheDecision.none, "", null) catch {
                    state.setError("Failed to connect to API");
                    return;
                };
                defer stream.deinit();

                while (true) {
                    const chunk = stream.nextChunk() catch {
                        state.setError("Stream read error");
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

    // ═════════════════════════════════════════════════════════════════
    // Command Palette
    // ═════════════════════════════════════════════════════════════════

    const CmdKind = enum { instant, insert };
    const CmdEntry = struct {
        id: []const u8,
        label: []const u8,
        desc: []const u8,
        kind: CmdKind = .instant,
    };
    const CMDS = [_]CmdEntry{
        .{ .id = "help", .label = "/help", .desc = "Show help information" },
        .{ .id = "clear", .label = "/clear", .desc = "Clear conversation history" },
        .{ .id = "exit", .label = "/exit", .desc = "Quit the application" },
        .{ .id = "model", .label = "/model", .desc = "Switch model (e.g. /model deepseek-v4)", .kind = .insert },
        .{ .id = "provider", .label = "/provider", .desc = "Switch API provider", .kind = .insert },
        .{ .id = "models", .label = "/models", .desc = "List available models" },
        .{ .id = "save", .label = "/save", .desc = "Save current session" },
        .{ .id = "load", .label = "/load", .desc = "Load a session from file" },
        .{ .id = "sessions", .label = "/sessions", .desc = "List saved sessions" },
        .{ .id = "workspace", .label = "/workspace", .desc = "Show/set workspace path", .kind = .insert },
        .{ .id = "context", .label = "/context", .desc = "Show context usage statistics" },
        .{ .id = "status", .label = "/status", .desc = "Show system status" },
        .{ .id = "compact", .label = "/compact", .desc = "Compact conversation context" },
        .{ .id = "note", .label = "/note", .desc = "Manage notes (add/list/show)", .kind = .insert },
        .{ .id = "memory", .label = "/memory", .desc = "Manage agent memory", .kind = .insert },
        .{ .id = "subagents", .label = "/subagents", .desc = "Show sub-agent panel" },
        .{ .id = "think", .label = "/think", .desc = "Toggle reasoning visibility" },
        .{ .id = "tools", .label = "/tools", .desc = "Toggle tool call visibility" },
        .{ .id = "top", .label = "/top", .desc = "Scroll to top of conversation" },
        .{ .id = "bottom", .label = "/bottom", .desc = "Scroll to bottom of conversation" },
        .{ .id = "new", .label = "/new", .desc = "Start a new session" },
        .{ .id = "apikey", .label = "/apikey", .desc = "Set API key (e.g. /apikey sk-...)", .kind = .insert },
        .{ .id = "key", .label = "/key", .desc = "Set API key (alias for /apikey)", .kind = .insert },
        .{ .id = "skills", .label = "/skills", .desc = "List available skills" },
        .{ .id = "sandbox", .label = "/sandbox", .desc = "Show sandbox status" },
        .{ .id = "providers", .label = "/providers", .desc = "List configured providers" },
    };

    fn execPalette(self: *App) void {
        self.show_palette = false;
        var cmd_buf: [CMDS.len]CmdEntry = undefined;
        const filtered = self.filteredCmds(&cmd_buf);
        if (filtered.len == 0 or self.palette_sel >= filtered.len) { self.palette_buf.clearRetainingCapacity(); return; }
        const cmd = filtered[self.palette_sel];
        if (cmd.kind == .insert) {
            // Insert command text into input so user can add arguments
            self.input.clearRetainingCapacity();
            self.cursor = 0;
            // Copy the label without leading "/"
            for (cmd.label[1..]) |ch| {
                self.input.append(self.alloc, ch) catch {};
                self.cursor += 1;
            }
            // Add trailing space for argument
            self.input.append(self.alloc, ' ') catch {};
            self.cursor += 1;
        } else {
            self.execCommandId(cmd.id);
        }
        self.palette_buf.clearRetainingCapacity();
        self.palette_sel = 0;
    }

    fn execCommandWithArgs(self: *App, id: []const u8, args: []const u8) void {
        if (args.len > 0) {
            if (std.mem.eql(u8, id, "model")) {
                // Use ProviderManager to resolve model
                self.model = self.alloc.dupe(u8, args) catch self.model;
                if (self.subsystems_initialized) {
                    // Update provider config with new model
                    if (self.provider_mgr.getActive()) |cfg| {
                        var new_cfg = cfg;
                        new_cfg.default_model = args;
                        self.provider_mgr.addProvider(new_cfg) catch {};
                    }
                }
                const msg = std.fmt.allocPrint(self.alloc, "Model: {s} (via {s})", .{ args, self.provider }) catch return;
                self.setNotification(msg);
                return;
            }
            if (std.mem.eql(u8, id, "provider")) {
                if (self.subsystems_initialized) {
                    self.provider_mgr.setActive(args);
                }
                self.provider = self.alloc.dupe(u8, args) catch self.provider;
                const resolved_model = if (self.subsystems_initialized) self.provider_mgr.resolveModel(args) else "deepseek-chat";
                self.model = resolved_model;
                // Prompt for API key interactively
                self.pending_action = .await_api_key;
                const msg = std.fmt.allocPrint(self.alloc,
                    \\Switched to provider: {s}
                    \\Model: {s}
                    \\
                    \\Enter your API key:
                , .{ args, resolved_model }) catch return;
                self.messages.append(self.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
                return;
            }
            if (std.mem.eql(u8, id, "apikey") or std.mem.eql(u8, id, "key")) {
                self.setApiKey(args);
                return;
            }
        }
        self.execCommandId(id);
    }

    fn setApiKey(self: *App, key: []const u8) void {
        if (key.len == 0) {
            self.setNotification("Usage: /apikey sk-xxxxxxxxxxxx");
            return;
        }
        if (key.len < 10 or !std.mem.startsWith(u8, key, "sk-")) {
            self.setNotification("Invalid key format — expected sk-...");
            return;
        }
        // Free old key if it was allocated by us
        if (self.api_key.len > 0) {
            // Check if it's a pointer we own (not the env var)
            // We use a heuristic: if api_key was allocated, it's in our allocator
        }
        self.api_key = self.alloc.dupe(u8, key) catch return;
        const msg = std.fmt.allocPrint(self.alloc, "API key set ({s}...{s})", .{ key[0..6], key[key.len-4..] }) catch return;
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
        if (self.notif) |old| self.alloc.free(old);
        self.notif = self.alloc.dupe(u8, msg) catch return;
        self.notif_tick = 0;
    }

    fn execCommandId(self: *App, id: []const u8) void {
        if (std.mem.eql(u8, id, "help")) {
            self.show_help = true;
        } else if (std.mem.eql(u8, id, "exit")) {
            self.should_quit = true;
        } else if (std.mem.eql(u8, id, "clear") or std.mem.eql(u8, id, "new")) {
            self.clearMessages();
        } else if (std.mem.eql(u8, id, "save")) {
            self.saveSession();
        } else if (std.mem.eql(u8, id, "think")) {
            self.show_thinking = !self.show_thinking;
        } else if (std.mem.eql(u8, id, "tools")) {
            self.toggleToolCollapse();
        } else if (std.mem.eql(u8, id, "top")) {
            self.scroll_offset = 0;
            self.auto_scroll = false;
        } else if (std.mem.eql(u8, id, "bottom")) {
            self.scroll_offset = 0;
            self.auto_scroll = true;
        } else if (std.mem.eql(u8, id, "subagents")) {
            self.show_subagents = !self.show_subagents;
        } else if (std.mem.eql(u8, id, "compact")) {
            self.compactContext();
        } else if (std.mem.eql(u8, id, "status") or std.mem.eql(u8, id, "context")) {
            // Show context/status info as a system message
            const pct: f64 = if (self.ctx_max > 0) @as(f64, @floatFromInt(self.tokens_used)) / @as(f64, @floatFromInt(self.ctx_max)) * 100.0 else 0.0;
            const msg = std.fmt.allocPrint(self.alloc, "Model: {s}\nProvider: {s}\nTokens: {d}/{d}K ({d:.0}%)\nCache: {d:.0}%", .{
                self.model, self.provider, self.tokens_used / 1000, self.ctx_max / 1000, pct, self.cache_hit_rate * 100.0,
            }) catch return;
            self.messages.append(self.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
        } else if (std.mem.eql(u8, id, "workspace")) {
            const cwd_ptr = std.c.getenv("PWD") orelse ".";
            const cwd = std.mem.sliceTo(cwd_ptr, 0);
            const msg = std.fmt.allocPrint(self.alloc, "Workspace: {s}", .{cwd}) catch return;
            self.messages.append(self.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
        } else if (std.mem.eql(u8, id, "sessions")) {
            // Show saved sessions
            const home_ptr = std.c.getenv("HOME") orelse return;
            const home = std.mem.sliceTo(home_ptr, 0);
            const sessions_dir = std.fmt.allocPrint(self.alloc, "{s}/.zeepseek/sessions", .{home}) catch return;
            defer self.alloc.free(sessions_dir);
            const msg = std.fmt.allocPrint(self.alloc, "Sessions directory: {s}", .{sessions_dir}) catch return;
            self.messages.append(self.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
        } else if (std.mem.eql(u8, id, "load")) {
            // Will be triggered from palette with a file picker
            self.loadSessionFromDefault();
        } else if (std.mem.eql(u8, id, "models")) {
            const msg = "Available models:\n  deepseek-chat    V4 Flash (default)\n  deepseek-v4-pro  V4 Pro\n  deepseek-reasoner Reasoning model";
            self.messages.append(self.alloc, .{ .role = .system, .content = msg }) catch {};
        } else if (std.mem.eql(u8, id, "model")) {
            self.messages.append(self.alloc, .{ .role = .system, .content = "Use /model <name> to switch model" }) catch {};
        } else if (std.mem.eql(u8, id, "skills")) {
            // Show registered skills from skills_registry
            var msg_buf: [2048]u8 = undefined;
            var pos: usize = 0;
            const prefix = "Registered skills:\n";
            @memcpy(msg_buf[pos..pos + prefix.len], prefix);
            pos += prefix.len;
            // List built-in skill types from registry
            const skill_names = [_][]const u8{ "health", "investigate", "design-review" };
            for (skill_names) |name| {
                if (pos + name.len + 4 < msg_buf.len) {
                    msg_buf[pos] = ' ';
                    msg_buf[pos + 1] = ' ';
                    pos += 2;
                    @memcpy(msg_buf[pos..pos + name.len], name);
                    pos += name.len;
                    msg_buf[pos] = '\n';
                    pos += 1;
                }
            }
            self.messages.append(self.alloc, .{ .role = .system, .content = self.alloc.dupe(u8, msg_buf[0..pos]) catch "Skills loaded", .owns = true }) catch {};
        } else if (std.mem.eql(u8, id, "sandbox")) {
            const status: []const u8 = if (self.sandbox != null) "active (Seatbelt)" else "not initialized";
            const msg = std.fmt.allocPrint(self.alloc, "Sandbox: {s}\nShell mode: prompt\nFile read: auto_allow\nFile write: prompt", .{status}) catch return;
            self.messages.append(self.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
        } else if (std.mem.eql(u8, id, "providers")) {
            var msg_buf: [1024]u8 = undefined;
            var pos: usize = 0;
            const prefix = "Providers:\n";
            @memcpy(msg_buf[pos..pos + prefix.len], prefix);
            pos += prefix.len;
            if (self.subsystems_initialized) {
                const providers = self.provider_mgr.listProviders();
                for (providers) |pid| {
                    if (pos + pid.len + 6 < msg_buf.len) {
                        const marker: []const u8 = if (std.mem.eql(u8, pid, self.provider_mgr.active)) " ◄ " else "   ";
                        @memcpy(msg_buf[pos..pos + marker.len], marker);
                        pos += marker.len;
                        @memcpy(msg_buf[pos..pos + pid.len], pid);
                        pos += pid.len;
                        msg_buf[pos] = '\n';
                        pos += 1;
                    }
                }
            } else {
                const fallback = "  deepseek (default)\n";
                @memcpy(msg_buf[pos..pos + fallback.len], fallback);
                pos += fallback.len;
            }
            self.messages.append(self.alloc, .{ .role = .system, .content = self.alloc.dupe(u8, msg_buf[0..pos]) catch "Providers", .owns = true }) catch {};
        }
    }

    fn filteredCmds(self: *const App, out: *[CMDS.len]CmdEntry) []const CmdEntry {
        if (self.palette_buf.items.len == 0) {
            @memcpy(out[0..CMDS.len], &CMDS);
            return out[0..CMDS.len];
        }
        var count: usize = 0;
        const q = self.palette_buf.items;
        for (&CMDS) |cmd| {
            if (std.mem.indexOf(u8, cmd.label, q) != null or
                std.mem.indexOf(u8, cmd.desc, q) != null or
                std.mem.indexOf(u8, cmd.id, q) != null)
            {
                out[count] = cmd;
                count += 1;
            }
        }
        return out[0..count];
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
    // View & Renderers — Zenburn Noir design
    // ═════════════════════════════════════════════════════════════════════

    pub fn view(self: *const App, ctx: *const zz.Context) []const u8 {
        const a = ctx.allocator;
        var out = std.ArrayList(u8).empty;
        const w = ctx.width;
        const h = ctx.height;

        const has_overlay = self.show_help or self.show_palette or self.search_active or self.detail_active or self.show_subagents or (self.notif != null);
        const overlay_h: u16 = if (has_overlay) @min(@as(u16, @intCast(h / 2)), 15) else 0;
        const input_h: u16 = 2;
        const header_h: u16 = 1;
        const status_h: u16 = 2;
        const chat_h: u16 = if (h > header_h + status_h + input_h + overlay_h)
            @intCast(h - header_h - status_h - input_h - overlay_h)
        else 4;

        // ── Top header ──
        const ctx_pct: f64 = if (self.ctx_max > 0) @as(f64, @floatFromInt(self.tokens_used)) / @as(f64, @floatFromInt(self.ctx_max)) * 100.0 else 0.0;
        const cache_pct: f64 = self.cache_hit_rate * 100.0;
        const streaming = self.streaming_idx != null;
        out.appendSlice(a, "  ") catch {};
        out.appendSlice(a, B) catch {};
        out.appendSlice(a, Pal.yellow) catch {};
        out.appendSlice(a, "zeepseek") catch {};
        out.appendSlice(a, R) catch {};
        out.appendSlice(a, D) catch {};
        out.appendSlice(a, " · ") catch {};
        out.appendSlice(a, Pal.fg) catch {};
        out.appendSlice(a, self.model) catch {};
        out.appendSlice(a, D) catch {};
        out.appendSlice(a, " · turn ") catch {};
        appendInt(&out, a, self.turn);
        out.appendSlice(a, "  ctx ") catch {};
        out.appendSlice(a, if (ctx_pct > 70) Pal.red else Pal.green) catch {};
        appendFmt(&out, a, "{d:.0}%", .{ctx_pct});
        out.appendSlice(a, "  cache ") catch {};
        out.appendSlice(a, Pal.cyan) catch {};
        appendFmt(&out, a, "{d:.0}%", .{cache_pct});
        out.appendSlice(a, R) catch {};
        if (streaming) {
            out.appendSlice(a, "  ") catch {};
            out.appendSlice(a, Pal.yellow) catch {};
            out.appendSlice(a, "◐") catch {};
            out.appendSlice(a, R) catch {};
        }
        out.appendSlice(a, "\n") catch {};

        // ── Chat + sidebar ──
        self.renderChatWithSidebar(&out, a, w, chat_h);

        // ── Overlays (in the middle, before input) ──
        if (self.show_help) self.renderHelp(&out, a, w);
        if (self.show_palette) self.renderPalette(&out, a, w);
        if (self.search_active) self.renderSearch(&out, a, w);
        if (self.detail_active) self.renderDetail(&out, a, w);
        if (self.show_subagents) self.renderSubAgents(&out, a, w);
        if (self.notif != null) self.renderNotification(&out, a, w);

        // ── Input area ──
        self.renderInput(&out, a, w);

        // ── Bottom status bar ──
        out.appendSlice(a, D) catch {};
        out.appendSlice(a, Pal.fg_dim) catch {};
        out.appendSlice(a, "────────────────────────────────────────────────────────────────────────") catch {};
        out.appendSlice(a, R) catch {};
        out.appendSlice(a, "\n") catch {};
        out.appendSlice(a, D) catch {};
        out.appendSlice(a, "│ ") catch {};
        out.appendSlice(a, R) catch {};
        out.appendSlice(a, Pal.cyan) catch {};
        out.appendSlice(a, "zeepseek") catch {};
        out.appendSlice(a, D) catch {};
        out.appendSlice(a, " │ ") catch {};
        out.appendSlice(a, Pal.fg) catch {};
        out.appendSlice(a, self.model) catch {};
        out.appendSlice(a, D) catch {};
        out.appendSlice(a, " │ turn=") catch {};
        appendInt(&out, a, self.turn);
        out.appendSlice(a, " │ ctx=") catch {};
        appendFmt(&out, a, "{d:.0}%", .{ctx_pct});
        out.appendSlice(a, " │ cache=") catch {};
        appendFmt(&out, a, "{d:.0}%", .{cache_pct});
        out.appendSlice(a, " │") catch {};
        out.appendSlice(a, R) catch {};
        out.appendSlice(a, "\n") catch {};

        return out.toOwnedSlice(a) catch "render error";
    }

    // --- Top header: x zeepseek · model · turn N  ctx 12% ---x ------

    fn renderHeader(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = w;
        const ctx_pct: f64 = if (self.ctx_max > 0) @as(f64, @floatFromInt(self.tokens_used)) / @as(f64, @floatFromInt(self.ctx_max)) * 100.0 else 0.0;
        const cache_pct: f64 = self.cache_hit_rate * 100.0;
        const streaming = self.streaming_idx != null;

        // header bar
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, "  ") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, B) catch {};
        buf.appendSlice(a, Pal.yellow) catch {};
        buf.appendSlice(a, "zeepseek") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, " · ") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, Pal.fg) catch {};
        buf.appendSlice(a, self.model) catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, " · turn ") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, Pal.yellow) catch {};
        appendInt(buf, a, self.turn);
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, "  ctx ") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, if (ctx_pct > 70) Pal.red else Pal.green) catch {};
        appendFmt(buf, a, "{d:.0}%", .{ctx_pct});
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, "  cache ") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, Pal.cyan) catch {};
        appendFmt(buf, a, "{d:.0}%", .{cache_pct});
        buf.appendSlice(a, R) catch {};

        // streaming indicator
        if (streaming) {
            buf.appendSlice(a, "  ") catch {};
            buf.appendSlice(a, Pal.yellow) catch {};
            buf.appendSlice(a, "◐") catch {};
            buf.appendSlice(a, R) catch {};
        }

        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, "\n") catch {};
        buf.appendSlice(a, R) catch {};
    }

    // --- Chat area 

    /// Render chat content as a string for join.horizontal
    fn renderChatContent(self: *const App, a: std.mem.Allocator, w: u16, h: u16) []const u8 {
        var buf = std.ArrayList(u8).empty;
        self.renderChatWithSidebar(&buf, a, w, h);
        return buf.toOwnedSlice(a) catch "";
    }

    /// Render sidebar content as a string for join.horizontal
    fn renderSidebarContent(self: *const App, a: std.mem.Allocator, w: u16, h: u16) []const u8 {
        _ = w;
        var buf = std.ArrayList(u8).empty;
        var row: u16 = 0;
        while (row < h) : (row += 1) {
            self.renderSidebarRow(&buf, a, row);
            buf.appendSlice(a, "\n") catch {};
        }
        return buf.toOwnedSlice(a) catch "";
    }

    fn renderChatWithSidebar(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16, h: u16) void {
        const sidebar_w: u16 = 22;
        const chat_w: u16 = if (w > sidebar_w) w - sidebar_w else w;
        const total = self.messages.items.len;
        if (total == 0) {
            // Empty state — show sidebar on right side
            var line: u16 = 0;
            while (line < h) : (line += 1) {
                var p: u16 = 0;
                while (p < chat_w) : (p += 1) { buf.appendSlice(a, " ") catch {}; }
                self.renderSidebarRow(buf, a, line);
                buf.appendSlice(a, "\n") catch {};
            }
            return;
        }

        const vis: usize = @intCast(h);
        const end = if (self.auto_scroll) total else @min(total, @as(usize, self.scroll_offset) + vis);
        const start = if (self.auto_scroll)
            if (total > vis) total - vis else 0
        else
            @min(@as(usize, self.scroll_offset), if (total > 0) total - 1 else 0);

        var lines = std.ArrayList([]const u8).empty;
        defer lines.deinit(a);

        // inter-message spacer
        lines.append(a, "") catch {};

        var i: usize = start;
        while (i < end) : (i += 1) {
            const m = self.messages.items[i];
            const role_color = switch (m.role) {
                .user => Pal.blue, .assistant => Pal.green, .system => Pal.mauve, .tool => Pal.yellow,
            };
            const role_label: []const u8 = switch (m.role) {
                .user => "You", .assistant => "Zeep", .system => "Sys", .tool => "Tool",
            };
            const status_icon: []const u8 = switch (m.status) {
                .pending => " ○", .streaming => " ◐", .complete => "", .failed => " ✗", .truncated => " …",
            };

            // --- Thinking block (collapsed by default) ──
            if (m.thinking) |th| {
                if (th.len > 0) {
                    if (!m.think_collapsed and self.show_thinking) {
                        lines.append(a, std.fmt.allocPrint(a, "{s}  ┌─ thinking ─{s}", .{ D, R }) catch "") catch {};
                        var thl = std.mem.splitScalar(u8, th, '\n');
                        while (thl.next()) |tl| {
                            lines.append(a, std.fmt.allocPrint(a, "{s}  │ {s}{s}", .{ D, tl, R }) catch "") catch {};
                        }
                        lines.append(a, std.fmt.allocPrint(a, "{s}  └──{s}", .{ D, R }) catch "") catch {};
                    } else {
                        lines.append(a, std.fmt.allocPrint(a, "{s}  … thinking ({d} chars){s}", .{ D, th.len, R }) catch "") catch {};
                    }
                }
            }

            // --- Tool calls (collapsed by default) ──
            if (m.tool_calls.items.len > 0) {
                const ic: []const u8 = if (m.tool_collapsed) "▸" else "▾";
                for (m.tool_calls.items) |tc| {
                    const tc_icon: []const u8 = switch (tc.status) { .running => "◐", .success => "✓", .failed => "✗" };
                    const tc_clr: []const u8 = switch (tc.status) { .running => Pal.yellow, .success => Pal.green, .failed => Pal.red };
                    lines.append(a, std.fmt.allocPrint(a, "{s}  {s}{s} {s} {s}{s}{s}", .{ D, ic, R, tc_clr, tc_icon, tc.name, R }) catch "") catch {};
                }
            }

            // --- Message header: "You:" or "Zeep:" ──
            if (m.content.len > 0) {
                // User messages: "You: message" on one line
                if (m.role == .user) {
                    var cl = std.mem.splitScalar(u8, m.content, '\n');
                    var first = true;
                    while (cl.next()) |ln| {
                        if (first) {
                            lines.append(a, std.fmt.allocPrint(a, "{s}{s}{s}:{s} {s}", .{ B, role_color, role_label, R, ln }) catch "") catch {};
                            first = false;
                        } else {
                            lines.append(a, std.fmt.allocPrint(a, "    {s}", .{ln}) catch "") catch {};
                        }
                    }
                } else if (m.role == .assistant) {
                    // Assistant messages: "Zeep:" header + markdown content
                    lines.append(a, std.fmt.allocPrint(a, "{s}{s}{s}:{s}{s}", .{ B, role_color, role_label, status_icon, R }) catch "") catch {};
                    var cl = std.mem.splitScalar(u8, m.content, '\n');
                    while (cl.next()) |ln| {
                        renderMarkdownLine(ln, &lines, a, D, " ");
                    }
                } else if (m.role == .system) {
                    // System messages: dim italic
                    var cl = std.mem.splitScalar(u8, m.content, '\n');
                    while (cl.next()) |ln| {
                        lines.append(a, std.fmt.allocPrint(a, "{s}{s}{s}", .{ D, ln, R }) catch "") catch {};
                    }
                } else {
                    // Tool messages
                    lines.append(a, std.fmt.allocPrint(a, "{s}{s}{s}:{s} {s}", .{ B, role_color, role_label, R, m.content }) catch "") catch {};
                }
            } else {
                // Empty content — just show header
                lines.append(a, std.fmt.allocPrint(a, "{s}{s}{s}:{s}{s}", .{ B, role_color, role_label, status_icon, R }) catch "") catch {};
            }

            // spacer between messages
            lines.append(a, "") catch {};
        }

        // Render lines into output buffer with sidebar
        var vi: u16 = 0;
        while (vi < h) : (vi += 1) {
            // Chat content (left)
            if (vi < lines.items.len) {
                const l = lines.items[vi];
                const lvis = ansiVisibleLen(l);
                if (lvis > @as(usize, @intCast(chat_w))) {
                    var byte_pos: usize = 0;
                    var vis_count: usize = 0;
                    var in_esc = false;
                    while (byte_pos < l.len and vis_count < chat_w) {
                        if (l[byte_pos] == 0x1b) in_esc = true;
                        if (in_esc) {
                            if (l[byte_pos] == 'm') in_esc = false;
                        } else {
                            vis_count += 1;
                        }
                        byte_pos += 1;
                    }
                    buf.appendSlice(a, l[0..byte_pos]) catch {};
                } else {
                    buf.appendSlice(a, l) catch {};
                }
                // Pad to chat width
                const vis_len: u16 = @intCast(@min(ansiVisibleLen(l), @as(usize, chat_w)));
                var pad: u16 = vis_len;
                while (pad < chat_w) : (pad += 1) { buf.appendSlice(a, " ") catch {}; }
            } else {
                // Empty chat line
                var pad: u16 = 0;
                while (pad < chat_w) : (pad += 1) { buf.appendSlice(a, " ") catch {}; }
            }

            // Sidebar column (right)
            self.renderSidebarRow(buf, a, vi);

            buf.appendSlice(a, "\n") catch {};
        }
    }

    // --- Markdown line helper (assistant content) 

    fn renderMarkdownLine(ln: []const u8, lines: *std.ArrayList([]const u8), a: std.mem.Allocator, bar: []const u8, bar_char: []const u8) void {
        if (std.mem.startsWith(u8, ln, "### ")) {
            const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}{s}{s}{s}", .{ D, bar, bar_char, B, Pal.yellow, ln[4..], R }) catch ""; lines.append(a, _tmp) catch {};
            return;
        }
        if (std.mem.startsWith(u8, ln, "## ")) {
            const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}{s}{s}{s}", .{ D, bar, bar_char, B, Pal.green, ln[3..], R }) catch ""; lines.append(a, _tmp) catch {};
            return;
        }
        if (std.mem.startsWith(u8, ln, "# ")) {
            const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}{s}{s}{s}", .{ D, bar, bar_char, B, Pal.blue, ln[2..], R }) catch ""; lines.append(a, _tmp) catch {};
            return;
        }
        if (std.mem.startsWith(u8, ln, "- ") or std.mem.startsWith(u8, ln, "* ")) {
            const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}    {s}·{s} {s}", .{ D, bar, bar_char, Pal.yellow, R, ln[2..] }) catch ""; lines.append(a, _tmp) catch {};
            return;
        }
        if (std.mem.startsWith(u8, ln, "> ")) {
            const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}x {s}{s}{s}{s}", .{ D, bar, bar_char, Pal.fg_dim, I, Pal.fg_dim, ln[2..], R }) catch ""; lines.append(a, _tmp) catch {};
            return;
        }
        if (ln.len >= 3 and std.mem.allEqual(u8, ln, '-')) {
            const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}------------------------------{s}", .{ D, bar, bar_char, Pal.fg_dim, R }) catch ""; lines.append(a, _tmp) catch {};
            return;
        }
        // Plain line — apply inline markdown (bold, italic, code, etc.)
        var rendered = std.ArrayList(u8).empty;
        defer rendered.deinit(a);
        renderInlineAnsi(&rendered, a, ln);

        if (rendered.items.len > 0) {
            const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}", .{ D, bar, bar_char, rendered.items }) catch ""; lines.append(a, _tmp) catch {};
        } else {
            const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}", .{ D, bar, bar_char, ln }) catch ""; lines.append(a, _tmp) catch {};
        }
    }

    // --- Input area 

    fn renderInput(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        // Thin separator
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, "+") catch {};
        var si: u16 = 1;
        while (si < w) : (si += 1) { buf.appendSlice(a, "-") catch {}; }
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, "\n") catch {};

        const text = self.input.items;
        buf.appendSlice(a, Pal.yellow) catch {};
        buf.appendSlice(a, B) catch {};
        if (self.pending_action == .await_api_key) {
            buf.appendSlice(a, " 🔑 ") catch {};
        } else {
            buf.appendSlice(a, " >> ") catch {};
        }
        buf.appendSlice(a, R) catch {};

        if (text.len == 0) {
            buf.appendSlice(a, D) catch {};
            buf.appendSlice(a, Pal.fg_dim) catch {};
            if (self.pending_action == .await_api_key) {
                buf.appendSlice(a, "Enter API key...") catch {};
            } else {
                buf.appendSlice(a, "Type a message…") catch {};
                buf.appendSlice(a, "  --  ") catch {};
                buf.appendSlice(a, Pal.fg_dim) catch {};
                buf.appendSlice(a, "/ for commands") catch {};
            }
            buf.appendSlice(a, R) catch {};
        } else {
            buf.appendSlice(a, Pal.fg) catch {};
            const before = text[0..@min(self.cursor, text.len)];
            buf.appendSlice(a, before) catch {};
            if (self.cursor < text.len) {
                buf.appendSlice(a, U) catch {};
                buf.appendSlice(a, text[self.cursor..self.cursor+1]) catch {};
                buf.appendSlice(a, R) catch {};
                buf.appendSlice(a, Pal.fg) catch {};
                if (self.cursor + 1 < text.len) buf.appendSlice(a, text[self.cursor+1..]) catch {};
            } else {
                buf.appendSlice(a, U) catch {};
                if (self.cursor_visible) { buf.appendSlice(a, "█") catch {}; } else { buf.appendSlice(a, " ") catch {}; }
                buf.appendSlice(a, R) catch {};
            }
            buf.appendSlice(a, R) catch {};
        }
        buf.appendSlice(a, "\n") catch {};
    }

    // --- Status bar 

    fn renderStatus(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = w;
        const ctx_pct: f64 = if (self.ctx_max > 0) @as(f64, @floatFromInt(self.tokens_used)) / @as(f64, @floatFromInt(self.ctx_max)) * 100.0 else 0.0;
        const cache_pct: f64 = self.cache_hit_rate * 100.0;

        // Bottom border
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, "+") catch {};
        buf.appendSlice(a, R) catch {};

        // Left section: brand + model
        buf.appendSlice(a, " ") catch {};
        buf.appendSlice(a, B) catch {};
        buf.appendSlice(a, Pal.yellow) catch {};
        buf.appendSlice(a, "zeepseek") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, " ") catch {};
        buf.appendSlice(a, self.model) catch {};
        buf.appendSlice(a, R) catch {};

        // Metrics
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, "   t=") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        appendInt(buf, a, self.turn);
        buf.appendSlice(a, R) catch {};

        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, "  ctx=") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        appendFmt(buf, a, "{d:.0}%", .{ctx_pct});
        buf.appendSlice(a, R) catch {};

        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, "  cache=") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        appendFmt(buf, a, "{d:.0}%", .{cache_pct});
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, "\n") catch {};
    }

    // --- Sidebar row rendering 

    fn renderSidebarRow(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, row: u16) void {
        const sidebar_w: u16 = 22;
        const ctx_pct: f64 = if (self.ctx_max > 0) @as(f64, @floatFromInt(self.tokens_used)) / @as(f64, @floatFromInt(self.ctx_max)) * 100.0 else 0.0;
        const cache_pct: f64 = self.cache_hit_rate * 100.0;
        const is_active = self.streaming_idx != null;
        const d = Pal.fg_dim; // dim text color for labels

        // Measure text width
        const label_w: u16 = 8;
        const val_w: u16 = sidebar_w - label_w;

        if (row == 0) {
            buf.appendSlice(a, d) catch {};
            buf.appendSlice(a, "[") catch {};
            buf.appendSlice(a, R) catch {};
            buf.appendSlice(a, Pal.yellow) catch {};
            buf.appendSlice(a, B) catch {};
            buf.appendSlice(a, "zeepseek") catch {};
            buf.appendSlice(a, R) catch {};
            buf.appendSlice(a, d) catch {};
            buf.appendSlice(a, "]") catch {};
            buf.appendSlice(a, R) catch {};
            var p: u16 = 9;
            while (p < sidebar_w) : (p += 1) { buf.appendSlice(a, " ") catch {}; }
        } else if (row == 1) {
            buf.appendSlice(a, d) catch {};
            buf.appendSlice(a, "model   ") catch {};
            buf.appendSlice(a, R) catch {};
            buf.appendSlice(a, Pal.fg) catch {};
            buf.appendSlice(a, self.model) catch {};
            buf.appendSlice(a, R) catch {};
            padSidebar(buf, a, sidebar_w, label_w + @as(u16, @intCast(@min(self.model.len, @as(usize, val_w)))));
        } else if (row == 2) {
            buf.appendSlice(a, d) catch {};
            buf.appendSlice(a, "turn    ") catch {};
            buf.appendSlice(a, R) catch {};
            buf.appendSlice(a, Pal.yellow) catch {};
            appendInt(buf, a, self.turn);
            buf.appendSlice(a, R) catch {};
            padSidebar(buf, a, sidebar_w, label_w + 1);
        } else if (row == 3) {
            buf.appendSlice(a, d) catch {};
            buf.appendSlice(a, "ctx     ") catch {};
            buf.appendSlice(a, R) catch {};
            const ctx_color = if (ctx_pct > 70) Pal.red else Pal.green;
            buf.appendSlice(a, ctx_color) catch {};
            appendFmt(buf, a, "{d:.0}%", .{ctx_pct});
            buf.appendSlice(a, R) catch {};
            padSidebar(buf, a, sidebar_w, label_w + 3);
        } else if (row == 4) {
            buf.appendSlice(a, d) catch {};
            buf.appendSlice(a, "cache   ") catch {};
            buf.appendSlice(a, R) catch {};
            buf.appendSlice(a, Pal.cyan) catch {};
            appendFmt(buf, a, "{d:.0}%", .{cache_pct});
            buf.appendSlice(a, R) catch {};
            padSidebar(buf, a, sidebar_w, label_w + 3);
        } else if (row == 5) {
            buf.appendSlice(a, d) catch {};
            buf.appendSlice(a, "status  ") catch {};
            buf.appendSlice(a, R) catch {};
            if (is_active) {
                buf.appendSlice(a, Pal.green) catch {};
                buf.appendSlice(a, "streaming") catch {};
            } else {
                buf.appendSlice(a, Pal.fg_dim) catch {};
                buf.appendSlice(a, "idle") catch {};
            }
            buf.appendSlice(a, R) catch {};
            padSidebar(buf, a, sidebar_w, label_w + 5);
        } else if (row == 6) {
            buf.appendSlice(a, d) catch {};
            buf.appendSlice(a, "--------") catch {};
            buf.appendSlice(a, R) catch {};
            padSidebar(buf, a, sidebar_w, 8);
        } else if (row == 7) {
            buf.appendSlice(a, d) catch {};
            buf.appendSlice(a, "path    ") catch {};
            buf.appendSlice(a, R) catch {};
            const cwd_n = std.c.getenv("PWD") orelse ".";
            const cwd = std.mem.sliceTo(cwd_n, 0);
            const last = std.mem.lastIndexOfScalar(u8, cwd, '/') orelse 0;
            const dir = if (last > 0 and last < cwd.len) cwd[last + 1 ..] else cwd;
            buf.appendSlice(a, Pal.fg_dim) catch {};
            buf.appendSlice(a, dir) catch {};
            buf.appendSlice(a, R) catch {};
            padSidebar(buf, a, sidebar_w, label_w + @as(u16, @intCast(@min(dir.len, @as(usize, 14)))));
        } else {
            padSidebar(buf, a, sidebar_w, 0);
        }
    }

    fn padSidebar(buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16, used: u16) void {
        if (used < w) {
            var p: u16 = used;
            while (p < w) : (p += 1) { buf.appendSlice(a, " ") catch {}; }
        }
    }

    // --- Notification toast 

    fn renderNotification(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = w;
        const msg = self.notif orelse return;
        buf.appendSlice(a, "\n") catch {};
        buf.appendSlice(a, Pal.bg_highlight) catch {};
        buf.appendSlice(a, Pal.fg) catch {};
        buf.appendSlice(a, " >> ") catch {};
        buf.appendSlice(a, msg) catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, "\n") catch {};
    }

    // --- Overlay: Help 

    fn renderHelp(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = self; _ = w;
        const bo = Pal.fg_dim; // border color

        appendFmt(buf, a, "\n{s}xx Keybindings ---------------------------x{s}\n", .{ bo, R });
        appendFmt(buf, a, "{s}|{s}  Ctrl+C    Quit                       {s}|{s}\n", .{ bo, R, bo, R });
        appendFmt(buf, a, "{s}|{s}  Ctrl+F    Search                     {s}|{s}\n", .{ bo, R, bo, R });
        appendFmt(buf, a, "{s}|{s}  Ctrl+S    Sub-agents                 {s}|{s}\n", .{ bo, R, bo, R });
        appendFmt(buf, a, "{s}|{s}  Ctrl+O    Message detail             {s}|{s}\n", .{ bo, R, bo, R });
        appendFmt(buf, a, "{s}|{s}  Ctrl+P    Command palette            {s}|{s}\n", .{ bo, R, bo, R });
        appendFmt(buf, a, "{s}|{s}  Ctrl+N    Toggle thinking            {s}|{s}\n", .{ bo, R, bo, R });
        appendFmt(buf, a, "{s}|{s}  Alt+M     Toggle tool calls          {s}|{s}\n", .{ bo, R, bo, R });
        appendFmt(buf, a, "{s}|{s}  Enter     Send message               {s}|{s}\n", .{ bo, R, bo, R });
        appendFmt(buf, a, "{s}|{s}  ↑↓  PgUp/PgDn  Scroll               {s}|{s}\n", .{ bo, R, bo, R });
        appendFmt(buf, a, "{s}|{s}  F1/?     This help                  {s}|{s}\n", .{ bo, R, bo, R });
        appendFmt(buf, a, "{s}|{s}  Esc      Close any overlay           {s}|{s}\n", .{ bo, R, bo, R });
        appendFmt(buf, a, "{s}----------------------------------------{s}\n", .{ bo, R });
    }

    // --- Overlay: Command Palette 

    fn renderPalette(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = w;
        var cmd_buf: [CMDS.len]CmdEntry = undefined;
        const filtered = self.filteredCmds(&cmd_buf);
        const bo = Pal.fg_dim;

        // Header with filter input
        appendFmt(buf, a, "\n{s}┌─ Commands ─────────────────────────────┐{s}\n", .{ bo, R });
        if (self.palette_buf.items.len > 0) {
            appendFmt(buf, a, "{s}│{s} {s}/{s}{s}{s}{s}", .{ bo, R, Pal.yellow, R, Pal.fg, self.palette_buf.items, R });
        } else {
            appendFmt(buf, a, "{s}│{s} {s}/{s}", .{ bo, R, Pal.yellow, R });
        }
        // Pad to box width
        const used: u16 = @intCast(2 + 1 + self.palette_buf.items.len);
        var p: u16 = used;
        while (p < 42) : (p += 1) { buf.appendSlice(a, " ") catch {}; }
        appendFmt(buf, a, "{s}│{s}\n", .{ bo, R });

        // Command list
        var shown: usize = 0;
        for (filtered, 0..) |cmd, i| {
            const sel = i == self.palette_sel;
            if (sel) {
                appendFmt(buf, a, "{s}│{s} {s}▸{s} {s}{s}{s}", .{ bo, R, Pal.yellow, R, B, cmd.label, R });
            } else {
                appendFmt(buf, a, "{s}│{s}   {s}{s}", .{ bo, R, Pal.fg, cmd.label });
            }
            // Pad label to fixed width, then description
            const label_pad: u16 = @intCast(@max(0, @as(i16, 12) - @as(i16, @intCast(cmd.label.len))));
            var lp: u16 = 0;
            while (lp < label_pad) : (lp += 1) { buf.appendSlice(a, " ") catch {}; }
            if (sel) {
                appendFmt(buf, a, "{s}{s}{s}", .{ D, cmd.desc, R });
            } else {
                appendFmt(buf, a, "{s}{s}{s}", .{ bo, cmd.desc, R });
            }
            // Pad to box width
            const desc_used: u16 = @intCast(3 + cmd.label.len + @as(usize, label_pad) + cmd.desc.len);
            var dp: u16 = desc_used;
            while (dp < 42) : (dp += 1) { buf.appendSlice(a, " ") catch {}; }
            appendFmt(buf, a, "{s}│{s}\n", .{ bo, R });
            shown += 1;
            if (shown >= 8) break;
        }

        // Footer with hints
        appendFmt(buf, a, "{s}│{s} {s}Tab/↑↓{s} navigate  {s}Enter{s} select  {s}Esc{s} close", .{ bo, R, Pal.fg_dim, R, Pal.fg_dim, R, Pal.fg_dim, R });
        var fp: u16 = 42;
        while (fp < 42) : (fp += 1) { buf.appendSlice(a, " ") catch {}; }
        buf.appendSlice(a, "    ") catch {};
        appendFmt(buf, a, "{s}│{s}\n", .{ bo, R });
        appendFmt(buf, a, "{s}└────────────────────────────────────────┘{s}\n", .{ bo, R });
    }

    // --- Overlay: Search 

    fn renderSearch(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = w;
        const bo = Pal.fg_dim;
        appendFmt(buf, a, "\n{s}[Search]{s}\n", .{ bo, R });
        appendFmt(buf, a, "{s}|{s} {s}x {s}{s}{s}\n", .{ bo, R, Pal.yellow, Pal.fg, self.search_query.items, R });
        appendFmt(buf, a, "{s}----------------------------------------{s}\n", .{ bo, R });
    }

    // --- Overlay: Sub-agents 

    fn renderSubAgents(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = w;
        const bo = Pal.fg_dim;
        if (self.subagents.items.len == 0) {
            appendFmt(buf, a, "\n{s}[Sub Agents]{s}\n", .{ bo, R });
            appendFmt(buf, a, "{s}|{s}  No active sub-agents                   {s}|{s}\n", .{ bo, R, bo, R });
            appendFmt(buf, a, "{s}----------------------------------------{s}\n", .{ bo, R });
            return;
        }
        appendFmt(buf, a, "\n{s}xx Sub Agents ({d}) ------------------------xx{s}\n", .{ bo, self.subagents.items.len, R });
        for (self.subagents.items) |sa| {
            const icon: []const u8 = switch (sa.status) {
                .pending => "○", .streaming => "◐", .complete => "✓", .failed => "✗", .truncated => "…",
            };
            const clr: []const u8 = switch (sa.status) {
                .pending => Pal.fg_dim, .streaming => Pal.yellow, .complete => Pal.green, .failed => Pal.red, .truncated => Pal.red,
            };
            const role_label: []const u8 = switch (sa.role) {
                .planner => "Plan", .researcher => "Research", .coder => "Code",
                .reviewer => "Review", .tester => "Test", .docs => "Docs", .tool_user => "Tool",
            };
            appendFmt(buf, a, "{s}|{s}  {s}{s}{s}  {s}{s}{s}\n", .{ bo, R, clr, icon, R, B, role_label, R });
            appendFmt(buf, a, "{s}|{s}    {s}goal:{s} {s}\n", .{ bo, R, Pal.fg_dim, R, sa.goal });
            if (sa.summary.len > 0) {
                appendFmt(buf, a, "{s}|{s}    {s}done:{s} {s}\n", .{ bo, R, Pal.fg_dim, R, sa.summary });
            }
        }
        appendFmt(buf, a, "{s}----------------------------------------{s}\n", .{ bo, R });
    }

    // --- Overlay: Message Detail 

    fn renderDetail(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = w;
        if (self.detail_idx >= self.messages.items.len) return;
        const m = self.messages.items[self.detail_idx];
        const bo = Pal.fg_dim;

        appendFmt(buf, a, "\n{s}xx Message #{d} ---------------------------xx{s}\n", .{ bo, self.detail_idx, R });

        const status_str: []const u8 = switch (m.status) {
            .pending => "pending", .streaming => "streaming", .complete => "complete",
            .failed => "failed", .truncated => "truncated",
        };
        appendFmt(buf, a, "{s}|{s} {s}{s}{s} {s}· {s}{s}{s}\n", .{ bo, R, B, m.role.color(), m.role.label(), R, Pal.fg_dim, status_str, R });
        appendFmt(buf, a, "{s}|{s} {s}---------------{s}\n", .{ bo, R, Pal.fg_dim, R });

        if (m.thinking) |th| {
            if (th.len > 0) {
                appendFmt(buf, a, "{s}|{s} {s}· thinking ({d} chars){s}\n", .{ bo, R, Pal.cyan, th.len, R });
            }
        }
        if (m.tool_calls.items.len > 0) {
            appendFmt(buf, a, "{s}|{s} {s}· {d} tool call(s){s}\n", .{ bo, R, Pal.yellow, m.tool_calls.items.len, R });
        }

        var cl = std.mem.splitScalar(u8, m.content, '\n');
        var cln: u16 = 0;
        while (cl.next()) |line| : (cln += 1) {
            if (cln < self.detail_scroll) continue;
            appendFmt(buf, a, "{s}|{s} {s}\n", .{ bo, R, line });
            if (cln >= self.detail_scroll + 30) {
                appendFmt(buf, a, "{s}|{s} {s}…{s}\n", .{ bo, R, Pal.fg_dim, R });
                break;
            }
        }
        appendFmt(buf, a, "{s}{s}Esc/q close  ←→ navigate  ↑↓ scroll{s}\n", .{ bo, Pal.fg_dim, R });
    }

    // --- Helpers 

    fn fmtLine(a: std.mem.Allocator, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(a, f, args) catch "";
    }

    fn appendInt(buf: *std.ArrayList(u8), a: std.mem.Allocator, val: anytype) void {
        if (std.fmt.allocPrint(a, "{d}", .{val})) |s| {
            buf.appendSlice(a, s) catch {};
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

// ═══════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════

pub fn main(init: std.process.Init) !void {
    var program = zz.Program(App).init(init.gpa, init.io, init.environ_map);
    defer program.deinit();
    try program.run();
}

// ═══════════════════════════════════════════════════════════════════════
// Unit Tests — test core logic without terminal
// ═══════════════════════════════════════════════════════════════════════

fn makeTestApp(alloc: std.mem.Allocator) App {
    var app: App = undefined;
    app.messages = .empty;
    app.alloc = alloc;
    app.scroll_offset = 0;
    app.auto_scroll = true;
    app.streaming_idx = null;
    app.input = .empty;
    app.cursor = 0;
    app.show_help = false;
    app.show_palette = false;
    app.palette_buf = .empty;
    app.palette_sel = 0;
    app.show_thinking = true;
    app.search_active = false;
    app.search_query = .empty;
    app.search_cursor = 0;
    app.detail_active = false;
    app.detail_idx = 0;
    app.detail_scroll = 0;
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
    app.notif = null;
    app.notif_tick = 0;
    return app;
}

test "app init has zero messages" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer app.messages.deinit(alloc);
    defer app.input.deinit(alloc);
    defer app.palette_buf.deinit(alloc);
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
        app.input.deinit(alloc);
        app.palette_buf.deinit(alloc);
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Type "hello"
    try app.input.appendSlice(alloc, "hello");
    app.cursor = 5;

    // Submit
    app.submit();

    // Should have 2 messages: user + assistant (no API key)
    try std.testing.expectEqual(@as(usize, 2), app.messages.items.len);
    try std.testing.expectEqual(Role.user, app.messages.items[0].role);
    try std.testing.expectEqualStrings("hello", app.messages.items[0].content);
    try std.testing.expectEqual(Role.assistant, app.messages.items[1].role);
    // Input should be cleared
    try std.testing.expectEqual(@as(usize, 0), app.input.items.len);
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
        app.input.deinit(alloc);
        app.palette_buf.deinit(alloc);
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Type "/help"
    try app.input.appendSlice(alloc, "/help");
    app.cursor = 5;

    // Submit
    app.submit();

    // Should set show_help = true, no messages added
    try std.testing.expect(app.show_help);
    try std.testing.expectEqual(@as(usize, 0), app.messages.items.len);
    // Input should be cleared
    try std.testing.expectEqual(@as(usize, 0), app.input.items.len);
}

test "submit slash command /clear" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        for (app.messages.items) |*m| {
            if (m.owns and m.content.len > 0) alloc.free(m.content);
        }
        app.messages.deinit(alloc);
        app.input.deinit(alloc);
        app.palette_buf.deinit(alloc);
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Add a message first
    try app.messages.append(alloc, .{ .role = .user, .content = "old", .owns = false });

    // Type "/clear"
    try app.input.appendSlice(alloc, "/clear");
    app.cursor = 6;

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
        app.input.deinit(alloc);
        app.palette_buf.deinit(alloc);
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Type "/exit"
    try app.input.appendSlice(alloc, "/exit");
    app.cursor = 5;

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
        app.input.deinit(alloc);
        app.palette_buf.deinit(alloc);
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }

    // Type "/foobar"
    try app.input.appendSlice(alloc, "/foobar");
    app.cursor = 7;

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
        app.input.deinit(alloc);
        app.palette_buf.deinit(alloc);
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
        app.input.deinit(alloc);
        app.palette_buf.deinit(alloc);
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
        .unicode_width_strategy = .wcwidth,
        .terminal_mode_2027 = false,
        .kitty_text_sizing = false,
        .theme = undefined,
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
        app.input.deinit(alloc);
        app.palette_buf.deinit(alloc);
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }
    app.show_help = true;
    var ctx = zz.Context{
        .allocator = alloc, .persistent_allocator = alloc, .home_dir = "/tmp",
        .io = undefined, .width = 80, .height = 24, .frame = 0, .elapsed = 0, .delta = 0,
        .true_color = true, .color_256 = false, .color_profile = .true_color,
        .is_dark_background = true, .unicode_width_strategy = .wcwidth,
        .terminal_mode_2027 = false, .kitty_text_sizing = false, .theme = undefined, ._terminal = null,
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
        app.input.deinit(alloc);
        app.palette_buf.deinit(alloc);
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }
    app.show_palette = true;
    var ctx = zz.Context{
        .allocator = alloc, .persistent_allocator = alloc, .home_dir = "/tmp",
        .io = undefined, .width = 80, .height = 24, .frame = 0, .elapsed = 0, .delta = 0,
        .true_color = true, .color_256 = false, .color_profile = .true_color,
        .is_dark_background = true, .unicode_width_strategy = .wcwidth,
        .terminal_mode_2027 = false, .kitty_text_sizing = false, .theme = undefined, ._terminal = null,
    };
    const output = app.view(&ctx);
    try std.testing.expect(std.mem.indexOf(u8, output, "Commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/help") != null);
}

test "view sidebar contains model and metrics" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        app.messages.deinit(alloc);
        app.input.deinit(alloc);
        app.palette_buf.deinit(alloc);
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }
    var ctx = zz.Context{
        .allocator = alloc, .persistent_allocator = alloc, .home_dir = "/tmp",
        .io = undefined, .width = 80, .height = 24, .frame = 0, .elapsed = 0, .delta = 0,
        .true_color = true, .color_256 = false, .color_profile = .true_color,
        .is_dark_background = true, .unicode_width_strategy = .wcwidth,
        .terminal_mode_2027 = false, .kitty_text_sizing = false, .theme = undefined, ._terminal = null,
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
        app.input.deinit(alloc);
        app.palette_buf.deinit(alloc);
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }
    var ctx = zz.Context{
        .allocator = alloc, .persistent_allocator = alloc, .home_dir = "/tmp",
        .io = undefined, .width = 80, .height = 24, .frame = 0, .elapsed = 0, .delta = 0,
        .true_color = true, .color_256 = false, .color_profile = .true_color,
        .is_dark_background = true, .unicode_width_strategy = .wcwidth,
        .terminal_mode_2027 = false, .kitty_text_sizing = false, .theme = undefined, ._terminal = null,
    };
    const output = app.view(&ctx);
    try std.testing.expect(std.mem.indexOf(u8, output, "Type a message") != null);
}

test "view input shows typed text" {
    const alloc = std.testing.allocator;
    var app = makeTestApp(alloc);
    defer {
        app.messages.deinit(alloc);
        app.input.deinit(alloc);
        app.palette_buf.deinit(alloc);
        app.search_query.deinit(alloc);
        app.pending_data.deinit(alloc);
    }
    try app.input.appendSlice(alloc, "hello");
    app.cursor = 5;
    var ctx = zz.Context{
        .allocator = alloc, .persistent_allocator = alloc, .home_dir = "/tmp",
        .io = undefined, .width = 80, .height = 24, .frame = 0, .elapsed = 0, .delta = 0,
        .true_color = true, .color_256 = false, .color_profile = .true_color,
        .is_dark_background = true, .unicode_width_strategy = .wcwidth,
        .terminal_mode_2027 = false, .kitty_text_sizing = false, .theme = undefined, ._terminal = null,
    };
    const output = app.view(&ctx);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ">> ") != null);
}
