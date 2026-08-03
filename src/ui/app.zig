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
const stream_client_mod = @import("stream_client");
const dangerous_patterns = @import("dangerous_patterns");
const tools_mod = @import("tools");
const session_format = @import("session_format");

const CacheDecision = enum { none, hit, miss };

/// Hard cap on tool output / file read size (bytes) to prevent OOM from
/// runaway commands (yes, cat /dev/zero) or oversized files.
const MAX_TOOL_OUTPUT: usize = 64 * 1024;

// ═══════════════════════════════════════════════════════════════════════
// ANSI helpers — Zenburn Noir palette
// ═══════════════════════════════════════════════════════════════════════

const R = "\x1b[0m";
const B = "\x1b[1m";      // bold
const D = "\x1b[2m";      // dim
const U = "\x1b[4m";      // underline
const I = "\x1b[3m";      // italic (if supported)

// 24-bit truecolor palette
const Pal = struct {
    // === Core ===
    const fg        = "\x1b[38;2;212;201;184m";  // warm cream
    const fg_dim    = "\x1b[38;2;122;125;127m";  // muted gray
    const fg_faint  = "\x1b[38;2;70;72;74m";    // very dim

    // === Accents ===
    const gold      = "\x1b[38;2;212;168;75m";   // main accent
    const blue      = "\x1b[38;2;127;157;181m";  // user / links
    const green     = "\x1b[38;2;139;184;139m";  // assistant / success
    const rose      = "\x1b[38;2;200;139;150m";  // error / alert
    const teal      = "\x1b[38;2;123;184;184m";  // thinking / info
    const violet    = "\x1b[38;2;168;153;199m";  // system / meta
    const soft_red  = "\x1b[38;2;194;99;99m";    // failure

    // === Backgrounds ===
    const bg_surface = "\x1b[48;2;24;26;28m";    // subtle card bg
    const bg_code    = "\x1b[48;2;30;32;34m";    // code block
    const bg_code_inline = "\x1b[48;2;36;38;40m";
    const bg_gold    = "\x1b[48;2;212;168;75;38;2;13;21;37m";  // gold on dark
};

const CodeBg = Pal.bg_code;
const CodeInlineBg = Pal.bg_code_inline;
const SearchHighlight = Pal.bg_gold;

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
                        appendFmt(buf, a, "{s}{s}{s}", .{ Pal.teal, text[i + 1 .. cb], R });
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
            .system => Pal.violet,
            .tool => Pal.gold,
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

    /// Store an error message; ownership passes to the stream state and the
    /// UI frees it after displaying (pollStream). Empty string = alloc failure
    /// fallback, never freed.
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


/// Pending tool-call run state: survives user-approval pauses between calls.
const ToolRunState = struct {
    /// All duplicated tool calls awaiting execution
    calls: std.ArrayList(tools_mod.ToolCall),
    idx: usize,
    /// Accumulated "Tool X result:\n..." text for re-submission
    results: std.ArrayList(u8),
};

const PendingTool = struct {
    /// Index into tool_run.calls of the call awaiting user approval
    idx: usize,
    /// Duplicated working directory
    cwd: []const u8,
};

/// Background LLM run for one sub-agent. The UI polls completion in tick().
/// Owns a dedicated arena backed by page_allocator: if a run is still blocked
/// in a network connect when the app exits, its pages are reclaimed by the OS
/// and never reach the GPA leak checker (which would otherwise block exit by
/// printing a huge stack trace to a full stderr pipe).
const SubAgentRun = struct {
    thread: std.Thread = undefined,
    /// Index into App.subagents (stable: the panel never removes entries)
    sa_index: usize,
    arena: std.heap.ArenaAllocator,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    summary: std.ArrayList(u8) = .empty,
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn init(alloc: std.mem.Allocator, sa_index: usize) SubAgentRun {
        return .{ .sa_index = sa_index, .arena = std.heap.ArenaAllocator.init(alloc) };
    }
    fn allocator(self: *SubAgentRun) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn lock(self: *SubAgentRun) void {
        while (self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {}
    }
    fn unlock(self: *SubAgentRun) void {
        self.locked.store(false, .release);
    }
    fn pushSummary(self: *SubAgentRun, text: []const u8) void {
        self.lock();
        defer self.unlock();
        self.summary.appendSlice(self.arena.allocator(), text) catch {};
    }
    fn setDone(self: *SubAgentRun) void {
        self.done.store(true, .release);
    }
    fn setFailed(self: *SubAgentRun) void {
        self.failed.store(true, .release);
        self.done.store(true, .release);
    }
    fn isDone(self: *SubAgentRun) bool {
        return self.done.load(.acquire);
    }
    fn drainSummary(self: *SubAgentRun, alloc: std.mem.Allocator) ?[]const u8 {
        self.lock();
        defer self.unlock();
        if (self.summary.items.len == 0) return null;
        return alloc.dupe(u8, self.summary.items) catch null;
    }
    fn deinit(self: *SubAgentRun) void {
        self.summary.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

/// Background LLM summarization for /compact. Same ownership model as
/// SubAgentRun: dedicated page-allocator arena so a run blocked on the
/// network at exit never reaches the GPA leak checker.
const CompactRun = struct {
    thread: std.Thread = undefined,
    /// Number of leading messages to replace with the summary
    keep_end: usize,
    arena: std.heap.ArenaAllocator,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: std.ArrayList(u8) = .empty,
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn init(alloc: std.mem.Allocator, keep_end: usize) CompactRun {
        return .{ .keep_end = keep_end, .arena = std.heap.ArenaAllocator.init(alloc) };
    }
    fn allocator(self: *CompactRun) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn lock(self: *CompactRun) void {
        while (self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {}
    }
    fn unlock(self: *CompactRun) void {
        self.locked.store(false, .release);
    }
    fn pushResult(self: *CompactRun, text: []const u8) void {
        self.lock();
        defer self.unlock();
        self.result.appendSlice(self.arena.allocator(), text) catch {};
    }
    fn setDone(self: *CompactRun) void { self.done.store(true, .release); }
    fn setFailed(self: *CompactRun) void {
        self.failed.store(true, .release);
        self.done.store(true, .release);
    }
    fn isDone(self: *CompactRun) bool { return self.done.load(.acquire); }
    fn drainResult(self: *CompactRun, alloc: std.mem.Allocator) ?[]const u8 {
        self.lock();
        defer self.unlock();
        if (self.result.items.len == 0) return null;
        return alloc.dupe(u8, self.result.items) catch null;
    }
    fn deinit(self: *CompactRun) void {
        self.result.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

pub const App = struct {
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
    api_key_alloc: ?std.mem.Allocator = null,
    io: std.Io,

    // --- Tool execution (sandbox + approval) 
    sandbox: ?*tools_mod.Sandbox = null,
    tool_run: ?*ToolRunState = null,
    pending_tool: ?PendingTool = null,

    // --- Sub-agent runs (background LLM threads) 
    subagent_runs: std.ArrayList(*SubAgentRun) = .empty,

    // --- Context compaction (background LLM summarization) 
    compact_run: ?*CompactRun = null,

    // --- Session state 
    session_id: []const u8,
    session_id_alloc: ?std.mem.Allocator = null,
    session_dir: []const u8,
    should_quit: bool,

    // --- Metrics 
    turn: u32,
    tokens_used: u64,
    ctx_max: u64,
    cache_hit_rate: f64,
    model: []const u8,
    provider: []const u8,

    // --- Dimensions 
    width: u16,
    height: u16,
    cursor_visible: bool,

    // --- Notification toast 
    notif: ?[]const u8 = null,
    notif_tick: u64 = 0,

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
            .width = 80,
            .height = 24,
            .cursor_visible = true,
            .notif = null,
            .notif_tick = 0,
        };
        // Try loading saved API key from disk
        self.loadSavedApiKey();

        // Initialize sandbox for tool approval. Platform-level sandboxing
        // (Seatbelt/Landlock) may fail open, but the approval-mode checks in
        // requiresApproval/allowShell still gate every tool call.
        // Workspace model: allow the current working directory in the
        // platform sandbox; file tools additionally reject anything outside it.
        const ws_ptr = std.c.getenv("PWD") orelse ".";
        const workspace = std.mem.sliceTo(ws_ptr, 0);
        self.sandbox = tools_mod.Sandbox.init(tools_mod.Policy.host(), &.{workspace}) catch null;

        // Enter the alternate screen AND schedule a repeating tick (~60fps):
        // pollStream/pollSubAgents/pollCompact all run from the .tick message,
        // so without .every the streaming UI never updates.
        return .{ .batch = &.{ .{ .enter_alt_screen = {} }, .{ .every = 16_666_666 } } };
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
            // persistent_allocator isn't available during init; track the
            // allocator so deinit (and setApiKey) can release the key.
            const duped = std.heap.page_allocator.dupe(u8, trimmed) catch return;
            self.api_key = duped;
            self.api_key_alloc = std.heap.page_allocator;
        }
    }

    pub fn update(self: *App, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        // Use persistent allocator for model state (survives frame resets)
        self.alloc = ctx.persistent_allocator;
        self.io = ctx.io;
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
            .save_session => self.saveSession(self.session_id),
            .load_session => |path| self.loadSession(path),
            .tick => |t| {
                self.cursor_visible = (t.timestamp / 500_000_000) % 2 == 0; // blink every 500ms
                self.pollStream();
                self.pollSubAgents();
                self.pollCompact();
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

        // --- Tool approval overlay (highest priority)
        if (self.pending_tool != null) {
            if (k == .enter) { self.approvePendingTool(); return .none; }
            if (k == .escape) { self.rejectPendingTool(); return .none; }
            return .none;
        }

        // --- Palette overlay 
        if (self.show_palette) {
            if (k == .escape) { self.show_palette = false; return .none; }
            if (k == .enter) { self.execPalette(); return .none; }
            if (k == .backspace) { if (self.palette_buf.items.len > 0) _ = self.palette_buf.pop(); return .none; }
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
            if (k == .char) { self.palette_buf.append(self.alloc, @intCast(k.char)) catch {}; return .none; }
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

        // NOTE: '/' is intentionally a plain character here so users can type
        // slash commands directly (e.g. "/model deepseek-v4"). The command
        // palette is opened with Ctrl+P only.

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

        // Guard: sending a new message while the previous response is still
        // streaming would startStreaming -> join a possibly blocked network
        // thread, freezing the UI (no request timeout). Keep the input so the
        // user can retry after the current response finishes.
        if (self.streaming_idx != null) {
            self.setNotification("Wait for the current response to finish");
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
                .content = "Set DEEPSEEK_API_KEY environment variable to enable streaming.",
                .status = .complete,
            }) catch {};
        }
    }

    fn startStreaming(self: *App, user_input: []const u8) void {
        // Join the previous thread first: it may still be pushing into ss.
        if (self.stream_thread) |t| t.join();
        if (self.stream_state) |ss| {
            ss.deinit();
            self.alloc.destroy(ss);
        }

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

        // Build context from recent messages. Content is duplicated so the
        // background thread fully owns its data: the UI thread can run
        // /clear /new /compact /model /apikey at any time without racing.
        var ctx_items = std.ArrayList(stream_client_mod.CtxItem).empty;
        defer ctx_items.deinit(self.alloc);
        const msg_count = self.messages.items.len - 1; // exclude the empty assistant msg
        const start: usize = if (msg_count > 20) msg_count - 20 else 0;
        for (self.messages.items[start..msg_count]) |m| {
            const role_str: []const u8 = switch (m.role) {
                .user => "user", .assistant => "assistant", .system => "system", .tool => "tool",
            };
            const content = self.alloc.dupe(u8, m.content) catch continue;
            ctx_items.append(self.alloc, .{ .role = role_str, .content = content }) catch {
                self.alloc.free(content);
            };
        }

        // Duplicate inputs owned by the UI (prompt, api_key, model) — the
        // thread frees its copies when it finishes.
        const prompt_owned = self.alloc.dupe(u8, user_input) catch return;
        const api_key_owned = self.alloc.dupe(u8, self.api_key) catch {
            self.alloc.free(prompt_owned);
            return;
        };
        const model_owned = self.alloc.dupe(u8, self.model) catch {
            self.alloc.free(prompt_owned);
            self.alloc.free(api_key_owned);
            return;
        };
        const ctx_slice = ctx_items.toOwnedSlice(self.alloc) catch {
            self.alloc.free(prompt_owned);
            self.alloc.free(api_key_owned);
            self.alloc.free(model_owned);
            return;
        };
        const alloc = self.alloc;

        // Spawn streaming thread
        const thread = std.Thread.spawn(.{}, struct {
            fn run(prompt: []const u8, ctx: []const stream_client_mod.CtxItem, api_k: []const u8, mdl: []const u8, a: std.mem.Allocator, state: *StreamState) void {
                defer {
                    for (ctx) |ci| a.free(ci.content);
                    a.free(ctx);
                    a.free(prompt);
                    a.free(api_k);
                    a.free(mdl);
                }
                // Dedicated Io so blocking network reads never stall the UI
                // thread's shared std.Io (threaded-io socket hang on macOS).
                var threaded = std.Io.Threaded.init(a, .{ .argv0 = .empty, .environ = .empty });
                const sio_own = threaded.io();
                defer threaded.deinit();
                var client = stream_client_mod.DeepSeekStreamClient.init(a, sio_own, null, null);
                defer client.deinit();

                // Fast path: h2-over-TLS streaming (own TLS stack, read
                // timeouts, no std.http chunked-EOF quirk). Falls back to the
                // buffered std.http path when the stream errors early.
                const H2Ctx = struct {
                    state: *StreamState,
                    fn onChunk(uc: *anyopaque, kind: stream_client_mod.ChunkKind, data: []const u8) void {
                        const c: *@This() = @ptrCast(@alignCast(uc));
                        switch (kind) {
                            .content => c.state.pushContent(data),
                            .reasoning => c.state.pushReasoning(data),
                            .tool => c.state.pushToolCallJson(data),
                        }
                    }
                };
                var h2ctx = H2Ctx{ .state = state };
                const h2sink = stream_client_mod.ChunkSink{ .ctx = &h2ctx, .on_chunk = H2Ctx.onChunk };
                const h2_ok = blk: {
                    stream_client_mod.streamMessageH2(&client, api_k, prompt, ctx, mdl, CacheDecision.none, "", null, h2sink) catch break :blk false;
                    break :blk true;
                };
                if (!h2_ok) {
                    // Fallback: buffered (non-streaming) response via std.http.
                    var stream = client.streamMessage(api_k, prompt, ctx, mdl, CacheDecision.none, "", null) catch |err| {
                        state.setError(std.fmt.allocPrint(a, "API request failed ({s})", .{@errorName(err)}) catch "");
                        return;
                    };
                    defer stream.deinit();
                    while (true) {
                        const chunk = stream.nextChunk() catch |err| {
                            state.setError(std.fmt.allocPrint(a, "Stream read error ({s})", .{@errorName(err)}) catch "");
                            return;
                        };
                        if (chunk == null) break;
                        switch (chunk.?) {
                            .content => |c| {
                                state.pushContent(c);
                                a.free(c);
                            },
                            .reasoning => |r| {
                                state.pushReasoning(r);
                                a.free(r);
                            },
                        }
                    }
                    if (stream.has_tool_calls and stream.tool_call_json.items.len > 0) {
                        state.pushToolCallJson(stream.tool_call_json.items);
                    }
                }
                state.setDone();
            }
        }.run, .{ prompt_owned, ctx_slice, api_key_owned, model_owned, alloc, ss }) catch {
            // Thread failed to spawn: reclaim the data we duplicated for it
            for (ctx_slice) |ci| alloc.free(ci.content);
            alloc.free(ctx_slice);
            alloc.free(prompt_owned);
            alloc.free(api_key_owned);
            alloc.free(model_owned);
            ss.setError(std.fmt.allocPrint(self.alloc, "Failed to spawn thread", .{}) catch "");
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
                if (msg.len > 0) self.alloc.free(msg);
                ss.error_msg = null;
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

        // Duplicate calls into a run state that survives approval pauses.
        const tr = self.alloc.create(ToolRunState) catch return;
        tr.* = .{
            .calls = std.ArrayList(tools_mod.ToolCall).empty,
            .idx = 0,
            .results = std.ArrayList(u8).empty,
        };
        for (parse_result.calls) |call| {
            const name = self.alloc.dupe(u8, call.name) catch continue;
            const arguments = self.alloc.dupe(u8, call.arguments) catch {
                self.alloc.free(name);
                continue;
            };
            tr.calls.append(self.alloc, .{ .index = call.index, .name = name, .arguments = arguments }) catch {
                self.alloc.free(name);
                self.alloc.free(arguments);
            };
        }
        if (tr.calls.items.len == 0) {
            self.alloc.destroy(tr);
            return;
        }
        self.tool_run = tr;

        self.processNextTool();
    }

    /// Process the next queued tool call. Pauses at the first call that
    /// requires user approval (pending_tool) and resumes on Enter/Esc.
    fn processNextTool(self: *App) void {
        const tr = self.tool_run orelse return;
        if (tr.idx >= tr.calls.items.len) {
            self.finishToolRun();
            return;
        }
        const call = tr.calls.items[tr.idx];
        self.onToolStart(call.name, call.arguments);

        if (tools_mod.requiresApproval(self.sandbox, call)) {
            const cwd_ptr = std.c.getenv("PWD") orelse ".";
            const cwd = std.mem.sliceTo(cwd_ptr, 0);
            self.pending_tool = .{
                .idx = tr.idx,
                .cwd = self.alloc.dupe(u8, cwd) catch return,
            };
            return;
        }

        self.executeCurrentTool();
    }

    fn executeCurrentTool(self: *App) void {
        const tr = self.tool_run orelse return;
        const call = tr.calls.items[tr.idx];
        const cwd_ptr = std.c.getenv("PWD") orelse ".";
        const cwd = std.mem.sliceTo(cwd_ptr, 0);

        const result = self.runTool(call, cwd);
        defer {
            if (result.len > 0) self.alloc.free(result);
        }
        const success = result.len > 0 and !std.mem.startsWith(u8, result, "Error:");
        self.onToolOutput(call.name, result, success);

        tr.results.appendSlice(self.alloc, "Tool ") catch {};
        tr.results.appendSlice(self.alloc, call.name) catch {};
        tr.results.appendSlice(self.alloc, " result:\n") catch {};
        tr.results.appendSlice(self.alloc, result) catch {};
        tr.results.appendSlice(self.alloc, "\n\n") catch {};

        tr.idx += 1;
        self.processNextTool();
    }

    fn approvePendingTool(self: *App) void {
        const pt = self.pending_tool orelse return;
        self.alloc.free(pt.cwd);
        self.pending_tool = null;
        self.executeCurrentTool();
    }

    fn rejectPendingTool(self: *App) void {
        const pt = self.pending_tool orelse return;
        const tr = self.tool_run orelse return;
        const call = tr.calls.items[pt.idx];
        const denied = self.toolErr("Rejected by user", .{});
        defer self.alloc.free(denied);
        self.onToolOutput(call.name, denied, false);
        tr.results.appendSlice(self.alloc, "Tool ") catch {};
        tr.results.appendSlice(self.alloc, call.name) catch {};
        tr.results.appendSlice(self.alloc, " result:\nRejected by user\n\n") catch {};
        self.alloc.free(pt.cwd);
        self.pending_tool = null;
        tr.idx += 1;
        self.processNextTool();
    }

    /// All calls executed (or rejected) — re-submit the accumulated results.
    fn finishToolRun(self: *App) void {
        const tr = self.tool_run orelse return;
        if (tr.results.items.len > 0) {
            const result_text = self.alloc.dupe(u8, tr.results.items) catch return;
            self.messages.append(self.alloc, .{
                .role = .tool,
                .content = result_text,
                .owns = true,
            }) catch {};

            // Start a new stream with the tool results in context
            self.startStreaming("(tool results)");
        }
        // Cleanup run state
        for (tr.calls.items) |c| {
            self.alloc.free(c.name);
            self.alloc.free(c.arguments);
        }
        tr.calls.deinit(self.alloc);
        tr.results.deinit(self.alloc);
        self.alloc.destroy(tr);
        self.tool_run = null;
    }

    /// Execute one tool through the unified tools/ pipeline with extra guards.
    /// Returns a caller-owned string (empty slice on failure).
    fn runTool(self: *App, call: tools_mod.ToolCall, cwd: []const u8) []const u8 {
        // Extra guards on top of the sandbox: dangerous shell commands and
        // sensitive paths are refused before anything executes.
        if (std.mem.eql(u8, call.name, "shell")) {
            if (self.extractJsonString(call.arguments, "command")) |cmd| {
                if (dangerous_patterns.checkDangerousCommand(cmd)) |p| {
                    return self.toolErr("Error: blocked dangerous command ({s})", .{p.description});
                }
            }
        }
        if (std.mem.eql(u8, call.name, "file_read") or
            std.mem.eql(u8, call.name, "file_write") or
            std.mem.eql(u8, call.name, "file_edit"))
        {
            if (self.extractJsonString(call.arguments, "path")) |path| {
                if (isSensitivePath(path)) {
                    return self.toolErr("Error: blocked sensitive path", .{});
                }
            }
        }

        const res = tools_mod.executeTool(self.alloc, self.sandbox, cwd, call) catch {
            return self.toolErr("Error: tool execution failed", .{});
        };
        // ToolResult.output is allocator-owned when non-empty, static "" on error.
        if (res.output.len > 0) {
            const owned = self.alloc.dupe(u8, res.output) catch "";
            self.alloc.free(res.output);
            return owned;
        }
        return self.toolErr("Error: {s}", .{res.err_msg orelse "tool failed"});
    }

    /// Allocate an error/status string owned by the caller (freed by
    /// handleToolCalls). Returns an empty slice on allocation failure —
    /// callers must not free empty results.
    fn toolErr(self: *App, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.alloc, fmt, args) catch "";
    }

fn isSensitivePath(path: []const u8) bool {
    const sensitive_dirs = [_][]const u8{ ".ssh", ".aws", ".gnupg", ".kube", ".config" };
    const sensitive_files = [_][]const u8{ "id_rsa", "id_ed25519", "authorized_keys", "known_hosts", "shadow", "sudoers", "apikey" };
    const sensitive_prefixes = [_][]const u8{ "/etc/", "/proc/", "/sys/", "/dev/", "/boot/", "/private/" };

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        for (sensitive_dirs) |d| {
            if (std.mem.eql(u8, seg, d)) return true;
        }
        for (sensitive_files) |f| {
            if (std.mem.eql(u8, seg, f)) return true;
        }
    }
    for (sensitive_prefixes) |p| {
        if (std.mem.startsWith(u8, path, p)) return true;
    }
    return false;
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
        // Duplicate name/args: the stored ToolCall now owns them (released by
        // freeToolCall in clearMessages/compactContext/deinit). The caller
        // (handleToolCalls) keeps and frees its own copies independently.
        const name_owned = self.alloc.dupe(u8, name) catch return;
        const args_owned = self.alloc.dupe(u8, args) catch {
            self.alloc.free(name_owned);
            return;
        };
        self.messages.items[target].tool_calls.append(self.alloc, .{
            .name = name_owned,
            .args = args_owned,
            .status = .running,
            .owns = true,
        }) catch {
            self.alloc.free(name_owned);
            self.alloc.free(args_owned);
        };
    }

    fn freeToolCall(self: *App, tc: ToolCall) void {
        if (tc.owns) {
            if (tc.name.len > 0) self.alloc.free(tc.name);
            if (tc.args.len > 0) self.alloc.free(tc.args);
            if (tc.output) |o| if (o.len > 0) self.alloc.free(o);
        }
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

    fn startSubAgent(self: *App, goal: []const u8) void {
        const g = std.mem.trim(u8, goal, " ");
        if (g.len == 0) {
            self.setNotification("Usage: /subagent <goal>");
            return;
        }
        if (self.api_key.len == 0) {
            self.setNotification("Set an API key first (/apikey sk-...)");
            return;
        }
        if (self.subagent_runs.items.len >= 4) {
            self.setNotification("Too many concurrent sub-agents (max 4)");
            return;
        }

        const sa_index = self.subagents.items.len;
        const id = std.fmt.allocPrint(self.alloc, "sa-{d}", .{sa_index}) catch return;
        const goal_owned = self.alloc.dupe(u8, g) catch {
            self.alloc.free(id);
            return;
        };
        // id/goal ownership moves into subagents (released by deinit)
        self.onSubAgentStart(id, .researcher, goal_owned);

        const run = std.heap.page_allocator.create(SubAgentRun) catch return;
        run.* = SubAgentRun.init(std.heap.page_allocator, sa_index);
        const ra = run.allocator();

        const api_key_owned = ra.dupe(u8, self.api_key) catch {
            std.heap.page_allocator.destroy(run);
            return;
        };
        const model_owned = ra.dupe(u8, self.model) catch {
            std.heap.page_allocator.destroy(run);
            return;
        };
        const prompt_owned = ra.dupe(u8, g) catch {
            std.heap.page_allocator.destroy(run);
            return;
        };

        const thread = std.Thread.spawn(.{}, struct {
            fn runSubAgent(api_k: []const u8, prompt: []const u8, mdl: []const u8, a: std.mem.Allocator, rr: *SubAgentRun) void {
                // a is the run's arena allocator — freed wholesale by deinit.
                // Use a dedicated Io so a blocked network connect cannot stall
                // the UI thread's shared std.Io (would deadlock Ctrl+C exit).
                var threaded = std.Io.Threaded.init(a, .{ .argv0 = .empty, .environ = .empty });
                const sio_own = threaded.io();
                defer threaded.deinit();
                var client = stream_client_mod.DeepSeekStreamClient.init(a, sio_own, null, null);
                defer client.deinit();

                const role_prompt = "You are a focused research sub-agent. Complete the assigned goal, then reply with a concise summary of what you did and found.";
                const ctx_empty = [_]stream_client_mod.CtxItem{};
                var stream = client.streamMessage(api_k, prompt, &ctx_empty, mdl, CacheDecision.none, role_prompt, null) catch {
                    rr.setFailed();
                    return;
                };
                defer stream.deinit();

                while (true) {
                    const chunk = stream.nextChunk() catch {
                        rr.setFailed();
                        return;
                    };
                    if (chunk == null) break;
                    switch (chunk.?) {
                        .content => |c| rr.pushSummary(c),
                        .reasoning => {},
                    }
                }
                rr.setDone();
            }
        }.runSubAgent, .{ api_key_owned, prompt_owned, model_owned, ra, run }) catch {
            std.heap.page_allocator.destroy(run);
            self.setNotification("Failed to start sub-agent thread");
            return;
        };
        run.thread = thread;
        self.subagent_runs.append(self.alloc, run) catch {
            std.heap.page_allocator.destroy(run);
            self.setNotification("Failed to register sub-agent");
            return;
        };
        self.setNotification("Sub-agent started");
    }

    fn pollSubAgents(self: *App) void {
        var i: usize = 0;
        while (i < self.subagent_runs.items.len) {
            const run = self.subagent_runs.items[i];
            if (run.isDone()) {
                run.thread.join();
                const failed = run.failed.load(.acquire);
                const summary = run.drainSummary(self.alloc);
                defer {
                    if (summary) |s| self.alloc.free(s);
                }
                if (run.sa_index < self.subagents.items.len) {
                    const sa = &self.subagents.items[run.sa_index];
                    sa.status = if (failed) .failed else .complete;
                    if (summary) |s| {
                        if (s.len > 0) {
                            if (sa.summary.len > 0) self.alloc.free(sa.summary);
                            sa.summary = self.alloc.dupe(u8, s) catch "";
                        }
                    }
                }
                run.deinit();
                std.heap.page_allocator.destroy(run);
                _ = self.subagent_runs.orderedRemove(i);
            } else i += 1;
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
        .{ .id = "provider", .label = "/provider", .desc = "Custom providers not supported yet", .kind = .insert },
        .{ .id = "models", .label = "/models", .desc = "List available models" },
        .{ .id = "save", .label = "/save", .desc = "Save session (/save name)", .kind = .insert },
        .{ .id = "load", .label = "/load", .desc = "Load session (/load name)", .kind = .insert },
        .{ .id = "sessions", .label = "/sessions", .desc = "List saved sessions" },
        .{ .id = "workspace", .label = "/workspace", .desc = "Show current workspace path" },
        .{ .id = "context", .label = "/context", .desc = "Show context usage statistics" },
        .{ .id = "status", .label = "/status", .desc = "Show system status" },
        .{ .id = "compact", .label = "/compact", .desc = "Compact conversation context" },
        .{ .id = "subagent", .label = "/subagent", .desc = "Start a sub-agent (/subagent <goal>)", .kind = .insert },
        .{ .id = "subagents", .label = "/subagents", .desc = "Show sub-agent panel" },
        .{ .id = "think", .label = "/think", .desc = "Toggle reasoning visibility" },
        .{ .id = "tools", .label = "/tools", .desc = "Toggle tool call visibility" },
        .{ .id = "top", .label = "/top", .desc = "Scroll to top of conversation" },
        .{ .id = "bottom", .label = "/bottom", .desc = "Scroll to bottom of conversation" },
        .{ .id = "new", .label = "/new", .desc = "Start a new session" },
        .{ .id = "apikey", .label = "/apikey", .desc = "Set API key (e.g. /apikey sk-...)", .kind = .insert },
        .{ .id = "key", .label = "/key", .desc = "Set API key (alias for /apikey)", .kind = .insert },
    };

    fn execPalette(self: *App) void {
        self.show_palette = false;
        var cmd_buf: [CMDS.len]CmdEntry = undefined;
        const filtered = self.filteredCmds(&cmd_buf);
        if (filtered.len == 0 or self.palette_sel >= filtered.len) { self.palette_buf.clearRetainingCapacity(); return; }
        const cmd = filtered[self.palette_sel];
        if (cmd.kind == .insert) {
            // Insert command text into input so user can add arguments.
            // Keep the leading "/" so the inserted text is a real command
            // when submitted (e.g. "/save <name>").
            self.input.clearRetainingCapacity();
            self.cursor = 0;
            for (cmd.label) |ch| {
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
                self.model = self.alloc.dupe(u8, args) catch self.model;
                const msg = std.fmt.allocPrint(self.alloc, "Model switched to: {s}", .{args}) catch return;
                self.setNotification(msg);
                return;
            }
            if (std.mem.eql(u8, id, "provider")) {
                const msg = std.fmt.allocPrint(self.alloc, "Custom provider not supported — endpoint is fixed to DeepSeek", .{}) catch return;
                self.setNotification(msg);
                return;
            }
            if (std.mem.eql(u8, id, "apikey") or std.mem.eql(u8, id, "key")) {
                self.setApiKey(args);
                return;
            }
            if (std.mem.eql(u8, id, "save")) {
                if (args.len > 0) self.setSessionName(args);
                self.saveSession(self.session_id);
                return;
            }
            if (std.mem.eql(u8, id, "load")) {
                self.loadSession(args);
                return;
            }
            if (std.mem.eql(u8, id, "subagent")) {
                self.startSubAgent(args);
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
        // Allocate the new key first; only then release the old one, so an
        // allocation failure leaves api_key pointing at valid memory.
        const new_key = self.alloc.dupe(u8, key) catch return;
        if (self.api_key_alloc) |old_alloc| {
            old_alloc.free(self.api_key);
        }
        self.api_key = new_key;
        self.api_key_alloc = self.alloc;
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
            self.saveSession(self.session_id);
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
            const pct: f64 = if (self.ctx_max > 0) @as(f64, @floatFromInt(self.ctxTokens())) / @as(f64, @floatFromInt(self.ctx_max)) * 100.0 else 0.0;
            const msg = std.fmt.allocPrint(self.alloc, "Model: {s}\nProvider: {s}\nCtx (est): {d}/{d}K ({d:.0}%)\nCache: n/a", .{
                self.model, self.provider, self.ctxTokens() / 1000, self.ctx_max / 1000, pct,
            }) catch return;
            self.messages.append(self.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
        } else if (std.mem.eql(u8, id, "workspace")) {
            const cwd_ptr = std.c.getenv("PWD") orelse ".";
            const cwd = std.mem.sliceTo(cwd_ptr, 0);
            const msg = std.fmt.allocPrint(self.alloc, "Workspace: {s}", .{cwd}) catch return;
            self.messages.append(self.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
        } else if (std.mem.eql(u8, id, "sessions")) {
            self.listSessions();
        } else if (std.mem.eql(u8, id, "load")) {
            self.loadSession("default");
        } else if (std.mem.eql(u8, id, "models")) {
            const msg = "Available models:\n  deepseek-chat    V4 Flash (default)\n  deepseek-v4-pro  V4 Pro\n  deepseek-reasoner Reasoning model";
            self.messages.append(self.alloc, .{ .role = .system, .content = msg }) catch {};
        } else if (std.mem.eql(u8, id, "model")) {
            self.messages.append(self.alloc, .{ .role = .system, .content = "Use /model <name> to switch model" }) catch {};
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

    fn saveSession(self: *App, name: []const u8) void {
        if (!isValidSessionName(name)) {
            self.setNotification("Invalid session name (letters, digits, - and _ only)");
            return;
        }
        const home_ptr = std.c.getenv("HOME") orelse return;
        const home = std.mem.sliceTo(home_ptr, 0);
        if (home.len == 0) return;
        // Ensure dirs exist (mkdir is not recursive; both levels needed)
        var home_dir_buf: [512:0]u8 = undefined;
        _ = std.fmt.bufPrintSentinel(&home_dir_buf, "{s}/.zeepseek", .{home}, 0) catch return;
        _ = std.c.mkdir(&home_dir_buf, 0o755);
        var dir_buf: [512:0]u8 = undefined;
        _ = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.zeepseek/sessions", .{home}, 0) catch return;
        _ = std.c.mkdir(&dir_buf, 0o755);
        // Build file path
        var path_buf: [512:0]u8 = undefined;
        _ = std.fmt.bufPrintSentinel(&path_buf, "{s}/.zeepseek/sessions/{s}.txt", .{ home, name }, 0) catch return;
        // Serialize via the shared length-prefixed format
        var msgs = std.ArrayList(session_format.SerializedMessage).empty;
        defer msgs.deinit(self.alloc);
        for (self.messages.items) |m| {
            const role: session_format.Role = switch (m.role) {
                .user => .user, .assistant => .assistant, .system => .system, .tool => .tool,
            };
            msgs.append(self.alloc, .{ .role = role, .content = m.content }) catch {};
        }
        const blob = session_format.serialize(self.alloc, msgs.items) catch {
            self.setNotification("Save failed: serialization error");
            return;
        };
        defer self.alloc.free(blob);

        const flags = std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        const fd = std.c.open(&path_buf, flags, @as(std.c.mode_t, 0o644));
        if (fd < 0) {
            self.setNotification("Save failed: cannot open session file");
            return;
        }
        defer _ = std.c.close(fd);
        _ = std.c.write(fd, blob.ptr, blob.len);
        const note = std.fmt.allocPrint(self.alloc, "Session saved: {s}", .{name}) catch return;
        defer self.alloc.free(note);
        self.setNotification(note);
    }

    fn isValidSessionName(name: []const u8) bool {
        if (name.len == 0 or name.len > 100) return false;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
        }
        return true;
    }

    fn setSessionName(self: *App, name: []const u8) void {
        if (!isValidSessionName(name)) return;
        const new = self.alloc.dupe(u8, name) catch return;
        if (self.session_id_alloc) |a| a.free(self.session_id);
        self.session_id = new;
        self.session_id_alloc = self.alloc;
    }

    fn loadSession(self: *App, name: []const u8) void {
        if (!isValidSessionName(name)) {
            self.setNotification("Invalid session name (letters, digits, - and _ only)");
            return;
        }
        const home_ptr = std.c.getenv("HOME") orelse return;
        const home = std.mem.sliceTo(home_ptr, 0);
        var path_buf: [512:0]u8 = undefined;
        _ = std.fmt.bufPrintSentinel(&path_buf, "{s}/.zeepseek/sessions/{s}.txt", .{ home, name }, 0) catch return;
        const fd = std.c.open(&path_buf, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) {
            const msg = std.fmt.allocPrint(self.alloc, "No saved session \"{s}\"", .{name}) catch return;
            defer self.alloc.free(msg);
            self.messages.append(self.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
            return;
        }
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
        // Parse via the shared module; parsed content ownership moves into
        // the message list (owns = true).
        const parsed = session_format.parse(self.alloc, data.items) catch return;
        defer self.alloc.free(parsed);
        self.clearMessages();
        for (parsed) |pm| {
            const role: Role = switch (pm.role) {
                .user => .user, .assistant => .assistant, .system => .system, .tool => .tool,
            };
            self.messages.append(self.alloc, .{
                .role = role,
                .content = pm.content,
                .owns = true,
            }) catch {};
        }
        self.setSessionName(name);
        self.auto_scroll = true;
        self.streaming_idx = null;
    }

    fn listSessions(self: *App) void {
        const home_ptr = std.c.getenv("HOME") orelse return;
        const home = std.mem.sliceTo(home_ptr, 0);
        var dir_buf: [512:0]u8 = undefined;
        _ = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.zeepseek/sessions", .{home}, 0) catch return;
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        out.appendSlice(self.alloc, "Saved sessions:\n") catch {};
        var dir = std.Io.Dir.openDirAbsolute(self.io, std.mem.sliceTo(&dir_buf, 0), .{}) catch {
            out.appendSlice(self.alloc, "  (no sessions directory yet)\n") catch {};
            const msg = self.alloc.dupe(u8, out.items) catch return;
            self.messages.append(self.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
            return;
        };
        defer dir.close(self.io);
        var it = dir.iterate();
        var count: usize = 0;
        while (it.next(self.io) catch null) |e| {
            if (e.kind != .file) continue;
            if (!std.mem.endsWith(u8, e.name, ".txt")) continue;
            const name = e.name[0 .. e.name.len - 4];
            if (name.len == 0) continue;
            out.appendSlice(self.alloc, "  ") catch {};
            out.appendSlice(self.alloc, name) catch {};
            out.appendSlice(self.alloc, "\n") catch {};
            count += 1;
        }
        if (count == 0) out.appendSlice(self.alloc, "  (none)\n") catch {};
        const msg = self.alloc.dupe(u8, out.items) catch return;
        self.messages.append(self.alloc, .{ .role = .system, .content = msg, .owns = true }) catch {};
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
                self.freeToolCall(tc);
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
    /// Start a background LLM summarization of older messages (/compact).
    /// The result replaces the compacted range once the thread finishes.
    fn compactContext(self: *App) void {
        const KEEP_EXCHANGES: usize = 6; // last 6 user↔assistant rounds
        const total = self.messages.items.len;
        if (total <= KEEP_EXCHANGES * 2) {
            self.setNotification("Not enough context to compact (need >12 messages)");
            return;
        }
        if (self.compact_run != null) {
            self.setNotification("Compaction already in progress");
            return;
        }
        if (self.api_key.len == 0) {
            self.setNotification("Set an API key first (/apikey sk-...)");
            return;
        }

        // Count backwards: how many leading messages to replace
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

        const run = std.heap.page_allocator.create(CompactRun) catch return;
        run.* = CompactRun.init(std.heap.page_allocator, keep_end);
        const ra = run.allocator();

        // Snapshot the old messages into the run's arena
        var ctx = std.ArrayList(stream_client_mod.CtxItem).empty;
        defer ctx.deinit(ra);
        for (self.messages.items[0..keep_end]) |m| {
            const role_str: []const u8 = switch (m.role) {
                .user => "user", .assistant => "assistant", .system => "system", .tool => "tool",
            };
            const content = ra.dupe(u8, m.content) catch continue;
            ctx.append(ra, .{ .role = role_str, .content = content }) catch {
                ra.free(content);
            };
        }
        if (ctx.items.len == 0) {
            std.heap.page_allocator.destroy(run);
            self.setNotification("Nothing to compact");
            return;
        }
        const ctx_slice = ctx.toOwnedSlice(ra) catch {
            std.heap.page_allocator.destroy(run);
            return;
        };
        const api_key_owned = ra.dupe(u8, self.api_key) catch {
            std.heap.page_allocator.destroy(run);
            return;
        };
        const model_owned = ra.dupe(u8, self.model) catch {
            std.heap.page_allocator.destroy(run);
            return;
        };

        const thread = std.Thread.spawn(.{}, struct {
            fn runCompact(api_k: []const u8, mdl: []const u8, ctxs: []const stream_client_mod.CtxItem, a: std.mem.Allocator, rr: *CompactRun) void {
                // Dedicated Io: a blocked connect must not stall the UI thread.
                var threaded = std.Io.Threaded.init(a, .{ .argv0 = .empty, .environ = .empty });
                const sio_own = threaded.io();
                defer threaded.deinit();
                var client = stream_client_mod.DeepSeekStreamClient.init(a, sio_own, null, null);
                defer client.deinit();

                const prompt = "Summarize the following conversation history into one concise paragraph. Preserve key decisions, facts, code intent, and any unresolved questions. Reply with only the summary.";
                var stream = client.streamMessage(api_k, prompt, ctxs, mdl, CacheDecision.none, "", null) catch {
                    rr.setFailed();
                    return;
                };
                defer stream.deinit();

                while (true) {
                    const chunk = stream.nextChunk() catch {
                        rr.setFailed();
                        return;
                    };
                    if (chunk == null) break;
                    switch (chunk.?) {
                        .content => |c| rr.pushResult(c),
                        .reasoning => {},
                    }
                }
                rr.setDone();
            }
        }.runCompact, .{ api_key_owned, model_owned, ctx_slice, ra, run }) catch {
            std.heap.page_allocator.destroy(run);
            self.setNotification("Failed to start compaction");
            return;
        };
        run.thread = thread;
        self.compact_run = run;
        self.setNotification("Compacting context in background...");
    }

    fn pollCompact(self: *App) void {
        const run = self.compact_run orelse return;
        if (!run.isDone()) return;
        run.thread.join();
        const failed = run.failed.load(.acquire);
        const result = run.drainResult(self.alloc);
        defer {
            if (result) |r| self.alloc.free(r);
        }
        if (failed or result == null or result.?.len == 0) {
            self.setNotification("Compaction failed (check API key / network)");
        } else {
            self.applyCompact(run.keep_end, result.?);
        }
        run.deinit();
        std.heap.page_allocator.destroy(run);
        self.compact_run = null;
    }

    fn applyCompact(self: *App, keep_end: usize, summary: []const u8) void {
        const replaced = @min(keep_end, self.messages.items.len);
        // Free the compacted messages
        for (self.messages.items[0..replaced]) |*m| {
            if (m.owns and m.content.len > 0) self.alloc.free(m.content);
            if (m.thinking) |t| self.alloc.free(t);
            for (m.tool_calls.items) |tc| {
                self.freeToolCall(tc);
            }
            m.tool_calls.deinit(self.alloc);
        }
        for (0..replaced) |_| {
            _ = self.messages.orderedRemove(0);
        }
        // Insert the LLM summary as a system message
        const duped = self.alloc.dupe(u8, summary) catch return;
        self.messages.insert(self.alloc, 0, .{
            .role = .system,
            .content = duped,
            .owns = true,
            .status = .complete,
        }) catch {};
        self.setNotification("Context compacted via LLM summary");
    }

    // ═════════════════════════════════════════════════════════════════════
    // View & Renderers — Zenburn Noir design
    // ═════════════════════════════════════════════════════════════════════

    pub fn view(self: *const App, ctx: *const zz.Context) []const u8 {
        const a = ctx.allocator;
        var out = std.ArrayList(u8).empty;
        const w = ctx.width;
        const h = ctx.height;

        const input_h: u16 = 2;   // prompt line + separator
        const header_h: u16 = 1;  // top header bar
        const status_h: u16 = 1;  // bottom status bar
        const sidebar_w: u16 = 22; // right info panel
        const chat_w: u16 = if (w > sidebar_w) w - sidebar_w else w;
        const chat_h: u16 = if (h > header_h + status_h + input_h) @intCast(h - header_h - status_h - input_h) else 8;

        // Top header
        self.renderHeader(&out, a, w);

        // Chat + sidebar (main content area)
        self.renderChatWithSidebar(&out, a, chat_w, chat_h);

        // Input area
        self.renderInput(&out, a, w);
        if (self.pending_tool != null) self.renderToolApproval(&out, a, w);

        // Status bar
        self.renderStatus(&out, a, w);

        // Overlays
        if (self.show_help) self.renderHelp(&out, a, w);
        if (self.show_palette) self.renderPalette(&out, a, w);
        if (self.search_active) self.renderSearch(&out, a, w);
        if (self.detail_active) self.renderDetail(&out, a, w);
        if (self.show_subagents) self.renderSubAgents(&out, a, w);
        if (self.notif != null) self.renderNotification(&out, a, w);

        return out.toOwnedSlice(a) catch "render error";
    }

    // --- Top header: x zeepseek · model · turn N  ctx 12% ---x ------

    /// Rough token estimate for the current conversation (bytes / 4).
    /// Used instead of fake "tokens_used" metrics that never update.
    fn ctxTokens(self: *const App) u64 {
        var total: usize = 0;
        for (self.messages.items) |m| total += m.content.len;
        return @intCast(total / 4);
    }

    fn renderHeader(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = w;
        const ctx_pct: f64 = if (self.ctx_max > 0) @as(f64, @floatFromInt(self.ctxTokens())) / @as(f64, @floatFromInt(self.ctx_max)) * 100.0 else 0.0;
        const streaming = self.streaming_idx != null;

        // header bar
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_faint) catch {};
        buf.appendSlice(a, "  ") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, B) catch {};
        buf.appendSlice(a, Pal.gold) catch {};
        buf.appendSlice(a, "zeepseek") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_faint) catch {};
        buf.appendSlice(a, " · ") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, Pal.fg) catch {};
        buf.appendSlice(a, self.model) catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_faint) catch {};
        buf.appendSlice(a, " · turn ") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, Pal.gold) catch {};
        appendInt(buf, a, self.turn);
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_faint) catch {};
        buf.appendSlice(a, "  ctx ") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, if (ctx_pct > 70) Pal.soft_red else Pal.green) catch {};
        appendFmt(buf, a, "{d:.0}%", .{ctx_pct});
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_faint) catch {};
        buf.appendSlice(a, "  cache ") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, "--") catch {};
        buf.appendSlice(a, R) catch {};

        // streaming indicator
        if (streaming) {
            buf.appendSlice(a, "  ") catch {};
            buf.appendSlice(a, Pal.gold) catch {};
            buf.appendSlice(a, "◐") catch {};
            buf.appendSlice(a, R) catch {};
        }

        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_faint) catch {};
        buf.appendSlice(a, "\n") catch {};
        buf.appendSlice(a, R) catch {};
    }

    // --- Chat area 

    fn renderChatWithSidebar(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16, h: u16) void {
        const total = self.messages.items.len;
        if (total == 0) {
            // Empty state — show sidebar on right side
            var line: u16 = 0;
            while (line < h) : (line += 1) {
                var p: u16 = 0;
                while (p < w) : (p += 1) { buf.appendSlice(a, " ") catch {}; }
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
            const bar = switch (m.role) {
                .user => Pal.blue, .assistant => Pal.fg, .system => Pal.violet, .tool => Pal.gold,
            };
            const bar_char = switch (m.role) {
                .user => "▎", .assistant => "▍", .system => "▏", .tool => "▌",
            };
            const role_icon: []const u8 = switch (m.role) {
                .user => "●", .assistant => "◆", .system => "△", .tool => "◇",
            };
            const status_icon: []const u8 = switch (m.status) {
                .pending => " ○", .streaming => " ◐", .complete => "", .failed => " ✗", .truncated => " …",
            };
            const status_clr: []const u8 = switch (m.status) {
                .pending => Pal.fg_dim, .streaming => Pal.gold, .complete => "", .failed => Pal.soft_red, .truncated => Pal.fg_dim,
            };

            // --- Thinking block 
            if (m.thinking) |th| {
                if (th.len > 0) {
                    if (!m.think_collapsed and self.show_thinking) {
                        const think_header = std.fmt.allocPrint(a, "{s}{s}{s}  {s}{s}... thinking ...{s}", .{ D, bar, bar_char, D, Pal.teal, R }) catch "";
                        lines.append(a, think_header) catch {};
                        var thl = std.mem.splitScalar(u8, th, '\n');
                        while (thl.next()) |tl| {
                            const think_line = std.fmt.allocPrint(a, "{s}{s}{s}  {s}{s}| {s}{s}", .{ D, bar, bar_char, D, Pal.teal, tl, R }) catch "";
                            lines.append(a, think_line) catch {};
                        }
                        const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}{s}---{s}", .{ D, bar, bar_char, D, Pal.teal, R }) catch ""; lines.append(a, _tmp) catch {};
                    } else {
                        const _tmp2 = std.fmt.allocPrint(a, "{s}{s}{s}  {s}{s}... thinking ({d} chars){s}", .{ D, bar, bar_char, D, Pal.teal, th.len, R }) catch "";
                        lines.append(a, _tmp2) catch {};
                    }
                }
            }

            // --- Tool calls 
            if (m.tool_calls.items.len > 0) {
                const ic: []const u8 = if (m.tool_collapsed) "▸" else "▾";
                for (m.tool_calls.items) |tc| {
                    const tc_icon: []const u8 = switch (tc.status) { .running => "◐", .success => "✓", .failed => "✗" };
                    const tc_clr: []const u8 = switch (tc.status) { .running => Pal.gold, .success => Pal.green, .failed => Pal.soft_red };
                    const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}{s} {s} {s}{s}{s}{s}", .{ D, bar, bar_char, Pal.gold, ic, tc_clr, tc_icon, B, tc.name, R }) catch ""; lines.append(a, _tmp) catch {};
                }
            }

            // --- Message header 
            var hdr: [256]u8 = undefined;
            const header = std.fmt.bufPrint(&hdr, "{s}{s}{s} {s}{s}{s}{s}{s}{s}", .{ B, bar, bar_char, bar, role_icon, m.role.label(), status_clr, status_icon, R }) catch "";
            lines.append(a, header) catch {};

            // --- Content 
            if (m.content.len > 0) {
                if (m.role == .assistant) {
                    var cl = std.mem.splitScalar(u8, m.content, '\n');
                    while (cl.next()) |ln| {
                        // Code fence detection within assistant messages
                        if (std.mem.startsWith(u8, ln, "```")) {
                            if (ln.len > 3) {
                                const _tmp3 = std.fmt.allocPrint(a, "{s}{s}{s}  {s} {s} ...{s}{s}", .{ D, bar, bar_char, Pal.bg_code, Pal.teal, std.mem.trim(u8, ln[3..], " "), R }) catch "";
                                lines.append(a, _tmp3) catch {};
                            } else {
                                const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}{s}{s}", .{ D, bar, bar_char, Pal.bg_code, D, R }) catch ""; lines.append(a, _tmp) catch {};
                            }
                            continue;
                        }
                        if (std.mem.startsWith(u8, ln, "```")) {
                            const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}{s}backup{s}", .{ D, bar, bar_char, Pal.bg_code, D, R }) catch ""; lines.append(a, _tmp) catch {};
                            continue;
                        }
                        renderMarkdownLine(ln, &lines, a, bar, bar_char);
                    }
                } else {
                    var cl = std.mem.splitScalar(u8, m.content, '\n');
                    var first_line = true;
                    while (cl.next()) |ln| {
                        if (first_line and m.role != .assistant) {
                            // Append content to header line
                            if (lines.items.len > 0) {
                                var merged: [512]u8 = undefined;
                                lines.items[lines.items.len - 1] = std.fmt.bufPrint(&merged, "{s}  {s}", .{ lines.items[lines.items.len - 1], ln }) catch "";
                            }
                        } else {
                            if (ln.len > 0) {
                                const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}", .{ D, bar, bar_char, ln }) catch ""; lines.append(a, _tmp) catch {};
                            } else {
                                lines.append(a, "") catch {};
                            }
                        }
                        first_line = false;
                    }
                }
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
                if (lvis > @as(usize, @intCast(w))) {
                    var byte_pos: usize = 0;
                    var vis_count: usize = 0;
                    var in_esc = false;
                    while (byte_pos < l.len and vis_count < w) {
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
                const vis_len: u16 = @intCast(@min(ansiVisibleLen(l), @as(usize, w)));
                var pad: u16 = vis_len;
                while (pad < w) : (pad += 1) { buf.appendSlice(a, " ") catch {}; }
            } else {
                // Empty chat line
                var pad: u16 = 0;
                while (pad < w) : (pad += 1) { buf.appendSlice(a, " ") catch {}; }
            }

            // Sidebar column (right)
            self.renderSidebarRow(buf, a, vi);

            buf.appendSlice(a, "\n") catch {};
        }
    }

    // --- Markdown line helper (assistant content) 

    fn renderMarkdownLine(ln: []const u8, lines: *std.ArrayList([]const u8), a: std.mem.Allocator, bar: []const u8, bar_char: []const u8) void {
        if (std.mem.startsWith(u8, ln, "### ")) {
            const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}{s}{s}{s}", .{ D, bar, bar_char, B, Pal.gold, ln[4..], R }) catch ""; lines.append(a, _tmp) catch {};
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
            const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}    {s}·{s} {s}", .{ D, bar, bar_char, Pal.gold, R, ln[2..] }) catch ""; lines.append(a, _tmp) catch {};
            return;
        }
        if (std.mem.startsWith(u8, ln, "> ")) {
            const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}x {s}{s}{s}{s}", .{ D, bar, bar_char, Pal.fg_dim, I, Pal.fg_dim, ln[2..], R }) catch ""; lines.append(a, _tmp) catch {};
            return;
        }
        if (ln.len >= 3 and std.mem.allEqual(u8, ln, '-')) {
            const _tmp = std.fmt.allocPrint(a, "{s}{s}{s}  {s}------------------------------{s}", .{ D, bar, bar_char, Pal.fg_faint, R }) catch ""; lines.append(a, _tmp) catch {};
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

    fn renderToolApproval(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = w;
        const pt = self.pending_tool orelse return;
        const tr = self.tool_run orelse return;
        if (pt.idx >= tr.calls.items.len) return;
        const call = tr.calls.items[pt.idx];
        const desc = tools_mod.describeToolCall(a, call) catch return;
        defer a.free(desc);
        appendFmt(buf, a, "{s}{s}[Approve tool?] {s}{s}{s}\n{s}Enter={s}Allow  {s}Esc={s}Deny{s}\n", .{
            Pal.gold, B, R, desc, R, Pal.fg_dim, R, Pal.fg_dim, R, R,
        });
    }

    fn renderInput(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        // Thin separator
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_faint) catch {};
        buf.appendSlice(a, "+") catch {};
        var si: u16 = 1;
        while (si < w) : (si += 1) { buf.appendSlice(a, "-") catch {}; }
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, "\n") catch {};

        const text = self.input.items;
        buf.appendSlice(a, Pal.gold) catch {};
        buf.appendSlice(a, B) catch {};
        buf.appendSlice(a, " >> ") catch {};
        buf.appendSlice(a, R) catch {};

        if (text.len == 0) {
            buf.appendSlice(a, D) catch {};
            buf.appendSlice(a, Pal.fg_dim) catch {};
            buf.appendSlice(a, "Type a message…") catch {};
            buf.appendSlice(a, "  --  ") catch {};
            buf.appendSlice(a, Pal.fg_faint) catch {};
            buf.appendSlice(a, "/ for commands") catch {};
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
                if (self.cursor_visible) { buf.appendSlice(a, "x") catch {}; } else { buf.appendSlice(a, " ") catch {}; }
                buf.appendSlice(a, R) catch {};
            }
            buf.appendSlice(a, R) catch {};
        }
        buf.appendSlice(a, "\n") catch {};
    }

    // --- Status bar 

    fn renderStatus(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = w;
        const ctx_pct: f64 = if (self.ctx_max > 0) @as(f64, @floatFromInt(self.ctxTokens())) / @as(f64, @floatFromInt(self.ctx_max)) * 100.0 else 0.0;

        // Bottom border
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_faint) catch {};
        buf.appendSlice(a, "+") catch {};
        buf.appendSlice(a, R) catch {};

        // Left section: brand + model
        buf.appendSlice(a, " ") catch {};
        buf.appendSlice(a, B) catch {};
        buf.appendSlice(a, Pal.gold) catch {};
        buf.appendSlice(a, "zeepseek") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, " ") catch {};
        buf.appendSlice(a, self.model) catch {};
        buf.appendSlice(a, R) catch {};

        // Metrics
        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_faint) catch {};
        buf.appendSlice(a, "   t=") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        appendInt(buf, a, self.turn);
        buf.appendSlice(a, R) catch {};

        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_faint) catch {};
        buf.appendSlice(a, "  ctx=") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        appendFmt(buf, a, "{d:.0}%", .{ctx_pct});
        buf.appendSlice(a, R) catch {};

        buf.appendSlice(a, D) catch {};
        buf.appendSlice(a, Pal.fg_faint) catch {};
        buf.appendSlice(a, "  cache=") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, Pal.fg_dim) catch {};
        buf.appendSlice(a, "--") catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, "\n") catch {};
    }

    // --- Sidebar row rendering 

    fn renderSidebarRow(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, row: u16) void {
        const sidebar_w: u16 = 22;
        const ctx_pct: f64 = if (self.ctx_max > 0) @as(f64, @floatFromInt(self.ctxTokens())) / @as(f64, @floatFromInt(self.ctx_max)) * 100.0 else 0.0;
        const is_active = self.streaming_idx != null;
        const d = Pal.fg_faint; // dim text color for labels

        // Measure text width
        const label_w: u16 = 8;
        const val_w: u16 = sidebar_w - label_w;

        if (row == 0) {
            buf.appendSlice(a, d) catch {};
            buf.appendSlice(a, "[") catch {};
            buf.appendSlice(a, R) catch {};
            buf.appendSlice(a, Pal.gold) catch {};
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
            buf.appendSlice(a, Pal.gold) catch {};
            appendInt(buf, a, self.turn);
            buf.appendSlice(a, R) catch {};
            padSidebar(buf, a, sidebar_w, label_w + 1);
        } else if (row == 3) {
            buf.appendSlice(a, d) catch {};
            buf.appendSlice(a, "ctx     ") catch {};
            buf.appendSlice(a, R) catch {};
            const ctx_color = if (ctx_pct > 70) Pal.soft_red else Pal.green;
            buf.appendSlice(a, ctx_color) catch {};
            appendFmt(buf, a, "{d:.0}%", .{ctx_pct});
            buf.appendSlice(a, R) catch {};
            padSidebar(buf, a, sidebar_w, label_w + 3);
        } else if (row == 4) {
            buf.appendSlice(a, d) catch {};
            buf.appendSlice(a, "cache   ") catch {};
            buf.appendSlice(a, R) catch {};
            buf.appendSlice(a, Pal.fg_dim) catch {};
            buf.appendSlice(a, "--") catch {};
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
        buf.appendSlice(a, Pal.bg_gold) catch {};
        buf.appendSlice(a, Pal.fg) catch {};
        buf.appendSlice(a, " >> ") catch {};
        buf.appendSlice(a, msg) catch {};
        buf.appendSlice(a, R) catch {};
        buf.appendSlice(a, "\n") catch {};
    }

    // --- Overlay: Help 

    fn renderHelp(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = self; _ = w;
        const bo = Pal.fg_faint; // border color

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
        appendFmt(buf, a, "{s}xx Commands ------------------------------x{s}\n", .{ bo, R });
        for (&CMDS) |cmd| {
            appendFmt(buf, a, "{s}|{s}  {s}{s}{s}  {s}{s}{s}\n", .{ bo, R, Pal.gold, cmd.label, R, Pal.fg_dim, cmd.desc, R });
        }
        appendFmt(buf, a, "{s}----------------------------------------{s}\n", .{ bo, R });
    }

    // --- Overlay: Command Palette 

    fn renderPalette(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = w;
        var cmd_buf: [CMDS.len]CmdEntry = undefined;
        const filtered = self.filteredCmds(&cmd_buf);
        const bo = Pal.fg_faint;

        appendFmt(buf, a, "\n{s}[Commands]{s}\n", .{ bo, R });
        appendFmt(buf, a, "{s}|{s} {s}>{s} {s}{s}{s}\n", .{ bo, R, Pal.gold, R, Pal.fg, self.palette_buf.items, R });

        var shown: usize = 0;
        for (filtered, 0..) |cmd, i| {
            const sel = i == self.palette_sel;
            if (sel) {
                appendFmt(buf, a, "{s}|{s} {s}{s} > {s} {s}{s} {s} - {s}{s}\n", .{ bo, R, Pal.bg_surface, Pal.gold, R, B, cmd.label, R, Pal.fg_dim, cmd.desc });
            } else {
                appendFmt(buf, a, "{s}|{s}   {s}{s} {s} - {s}\n", .{ bo, R, Pal.fg, cmd.label, R, Pal.fg_dim });
            }
            shown += 1;
            if (shown >= 10) break;
        }
        appendFmt(buf, a, "{s}----------------------------------------{s}\n", .{ bo, R });
    }

    // --- Overlay: Search 

    fn renderSearch(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = w;
        const bo = Pal.fg_faint;
        appendFmt(buf, a, "\n{s}[Search]{s}\n", .{ bo, R });
        appendFmt(buf, a, "{s}|{s} {s}x {s}{s}{s}\n", .{ bo, R, Pal.gold, Pal.fg, self.search_query.items, R });
        appendFmt(buf, a, "{s}----------------------------------------{s}\n", .{ bo, R });
    }

    // --- Overlay: Sub-agents 

    fn renderSubAgents(self: *const App, buf: *std.ArrayList(u8), a: std.mem.Allocator, w: u16) void {
        _ = w;
        const bo = Pal.fg_faint;
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
                .pending => Pal.fg_dim, .streaming => Pal.gold, .complete => Pal.green, .failed => Pal.soft_red, .truncated => Pal.soft_red,
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
        const bo = Pal.fg_faint;

        appendFmt(buf, a, "\n{s}xx Message #{d} ---------------------------xx{s}\n", .{ bo, self.detail_idx, R });

        const status_str: []const u8 = switch (m.status) {
            .pending => "pending", .streaming => "streaming", .complete => "complete",
            .failed => "failed", .truncated => "truncated",
        };
        appendFmt(buf, a, "{s}|{s} {s}{s}{s} {s}· {s}{s}{s}\n", .{ bo, R, B, m.role.color(), m.role.label(), R, Pal.fg_dim, status_str, R });
        appendFmt(buf, a, "{s}|{s} {s}---------------{s}\n", .{ bo, R, Pal.fg_faint, R });

        if (m.thinking) |th| {
            if (th.len > 0) {
                appendFmt(buf, a, "{s}|{s} {s}· thinking ({d} chars){s}\n", .{ bo, R, Pal.teal, th.len, R });
            }
        }
        if (m.tool_calls.items.len > 0) {
            appendFmt(buf, a, "{s}|{s} {s}· {d} tool call(s){s}\n", .{ bo, R, Pal.gold, m.tool_calls.items.len, R });
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

    pub fn deinit(self: *App) void {
        // Streaming thread: join only if it already finished. A thread blocked
        // in a network connect (no request timeout yet — known L3 limitation)
        // would freeze Ctrl+C exit; the OS reclaims it at process exit.
        if (self.stream_state) |ss| {
            if (ss.isDone()) {
                if (self.stream_thread) |t| t.join();
                ss.deinit();
                self.alloc.destroy(ss);
            }
            // else: leave for process exit (memory reclaimed by the OS)
        } else if (self.stream_thread) |t| {
            t.join();
        }
        self.stream_state = null;
        self.stream_thread = null;

        for (self.messages.items) |*m| {
            if (m.owns and m.content.len > 0) self.alloc.free(m.content);
            if (m.thinking) |t| self.alloc.free(t);
            for (m.tool_calls.items) |tc| self.freeToolCall(tc);
            m.tool_calls.deinit(self.alloc);
        }
        self.messages.deinit(self.alloc);

        self.input.deinit(self.alloc);
        self.palette_buf.deinit(self.alloc);
        self.search_query.deinit(self.alloc);

        // Sub-agent threads may be blocked in a network connect (no request
        // timeout configured yet — known L3 limitation). Joining here would
        // deadlock Ctrl+C exit, so leave unfinished runs to be reclaimed by
        // process exit. Completed runs were already cleaned up by pollSubAgents.
        self.subagent_runs.deinit(self.alloc);

        for (self.subagents.items) |sa| {
            if (sa.id.len > 0) self.alloc.free(sa.id);
            if (sa.goal.len > 0) self.alloc.free(sa.goal);
            if (sa.summary.len > 0) self.alloc.free(sa.summary);
        }
        self.subagents.deinit(self.alloc);

        if (self.notif) |n| self.alloc.free(n);
        if (self.api_key_alloc) |ka| ka.free(self.api_key);
        if (self.session_id_alloc) |a| a.free(self.session_id);

        if (self.tool_run) |tr| {
            for (tr.calls.items) |c| {
                self.alloc.free(c.name);
                self.alloc.free(c.arguments);
            }
            tr.calls.deinit(self.alloc);
            tr.results.deinit(self.alloc);
            self.alloc.destroy(tr);
        }
        if (self.pending_tool) |pt| {
            self.alloc.free(pt.cwd);
        }
        if (self.sandbox) |sb| sb.deinit();
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
