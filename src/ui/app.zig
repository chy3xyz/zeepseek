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
const mcp_runner_mod = @import("../net/mcp_runner.zig");
const mcp_client_mod = @import("../net/mcp_client.zig");
const dangerous_patterns = @import("dangerous_patterns");
const tools_mod = @import("../tools/mod.zig");
const session_format = @import("session_format");
const SlashDispatcher = @import("slash_command_dispatcher.zig");
const theme = @import("theme.zig");
const render_text = @import("render_text.zig");
const render_ui = @import("render_ui.zig");
const slash_commands = @import("slash_commands.zig");
const tools_run = @import("tools_run.zig");
const sessions = @import("sessions.zig");
const dispatch_loop = @import("../dispatch/cache_first_loop.zig");
const zeep_config = @import("../utils/config.zig");
const ProviderManager = @import("../providers/manager.zig").ProviderManager;
const ProviderConfig = @import("../providers/manager.zig").ProviderConfig;
const I18nManager = @import("../i18n/manager.zig").I18nManager;
const Sandbox = @import("../utils/sandbox.zig").Sandbox;
const subagent_mod = @import("../agent/subagent.zig");
const skills_registry = @import("../skills/registry.zig");
const skills_builtin = @import("../skills/builtin.zig");
const session_manager = @import("../storage/session_manager.zig");
const ContextManager = @import("../dispatch/context_manager.zig").ContextManager;
const ImmutablePrefix = @import("../dispatch/context_manager.zig").ImmutablePrefix;
const reasonix_mod = @import("../cache/reasonix.zig");
const tokenizer_mod = @import("../utils/tokenizer.zig");
const memory_mod = @import("../cache/memory.zig");
const git_worker_mod = @import("../utils/git_worker.zig");

const join = zz.join;

const CacheDecision = enum { none, hit, miss };

/// Hard cap on tool output / file read size (bytes) to prevent OOM from
/// runaway commands (yes, cat /dev/zero) or oversized files.
const MAX_TOOL_OUTPUT: usize = 64 * 1024;

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


// ═══════════════════════════════════════════════════════════════════════
// Markdown → ANSI renderer (lightweight, inline)
// ═══════════════════════════════════════════════════════════════════════


// ═══════════════════════════════════════════════════════════════════════
// Data Types
// ═══════════════════════════════════════════════════════════════════════

/// Tool execution modes (like codex/claude-code).
pub const RunMode = enum { auto, plan, yolo };

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
    tool_call_id: []const u8 = "",
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


/// Pending tool-call run state: survives user-approval pauses between calls.
pub const ToolRunState = struct {
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
    pub const PendingAction = enum {
        none,
        await_api_key, // waiting for user to enter API key
    };
    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        mouse: zz.MouseEvent,
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

    pub const OutputData = union(enum) {
        table: SlashDispatcher.TableData,
        list: SlashDispatcher.ListData,

        pub fn deinit(self: *OutputData, allocator: std.mem.Allocator) void {
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
    mcp_servers: std.ArrayList(mcp_runner_mod.McpServer),
    mcp_session: ?mcp_runner_mod.McpSession,
    mcp_tools_json: []const u8 = "",
    app_io: std.Io = undefined,

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
    api_key_alloc: ?std.mem.Allocator = null,
    io: std.Io,

    // --- Tool execution (sandbox + approval)
    tool_run: ?*ToolRunState = null,
    pending_tool: ?PendingTool = null,

    // --- Sub-agent runs (background LLM threads)
    subagent_runs: std.ArrayList(*SubAgentRun) = .empty,

    // --- Context compaction (background LLM summarization)
    compact_run: ?*CompactRun = null,

    // --- Semantic cache (reasonix): exact-prompt reuse for self-contained queries
    reasonix: ?*reasonix_mod.Reasonix = null,
    reasonix_alloc: ?std.mem.Allocator = null,
    compact_hinted: bool = false,
    cleanup_tick: u32 = 0,
    git_changes: usize = 0,
    pending_inputs: std.ArrayList([]const u8) = .empty,
    history_edit_idx: ?usize = null,
    run_mode: RunMode = .auto,
    tool_fail_streak: u32 = 0,
    memory: ?*memory_mod.Memory = null,
    memory_alloc: ?std.mem.Allocator = null,
    skill_registry: ?*skills_registry.SkillRegistry = null,
    skill_registry_alloc: ?std.mem.Allocator = null,
    active_skill: []const u8 = "",
    git_worker: ?git_worker_mod.Client = null,

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
            .mcp_servers = .empty,
            .mcp_session = null,
            .mcp_tools_json = "",
            .app_io = undefined,
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

        // Semantic cache (exact-prompt reuse; conservative, see submit()).
        // Use page_allocator: the app's persistent allocator may return
        // under-aligned memory that trips 0.17's HashMap header alignment.
        const rx = std.heap.page_allocator.create(reasonix_mod.Reasonix) catch null;
        if (rx) |r| {
            r.* = reasonix_mod.Reasonix.init(std.heap.page_allocator, .{});
            self.reasonix = r;
            self.reasonix_alloc = std.heap.page_allocator;
        }



        self.git_worker = g_git_worker;
        self.app_io = ctx.io;

        // Skill registry with built-in skills. Uses page_allocator storage
        // (stable in-app, same pattern as the semantic cache) — the app's
        // persistent allocator invalidates the arena at runtime.
        const sr = std.heap.page_allocator.create(skills_registry.SkillRegistry) catch null;
        if (sr) |reg| {
            if (skills_registry.SkillRegistry.init(std.heap.page_allocator)) |reg_init| {
                reg.* = reg_init;
                self.skill_registry = reg;
                self.skill_registry_alloc = std.heap.page_allocator;
                var builtin = skills_builtin.BuiltinSkills{};
                const built = builtin.loadAll(std.heap.page_allocator) catch null;
                if (built) |bskills| {
                    for (bskills) |*bs| reg.registerSkill(bs) catch {};
                }
            } else |_| {
                std.heap.page_allocator.destroy(reg);
            }
        }

        // Long-term BM25 memory (~/.zeepseek/memory.md).
        const mem = std.heap.page_allocator.create(memory_mod.Memory) catch null;
        if (mem) |m| {
            m.* = memory_mod.Memory.init(std.heap.page_allocator);
            var mem_path_buf: [512:0]u8 = undefined;
            if (std.c.getenv("HOME")) |home_z| {
                const home = std.mem.sliceTo(home_z, 0);
                _ = std.fmt.bufPrintSentinel(&mem_path_buf, "{s}/.zeepseek/memory.md", .{home}, 0) catch null;
                m.load(mem_path_buf[0..]);
            }
            self.memory = m;
            self.memory_alloc = std.heap.page_allocator;
        }

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

        // Free tool approval/run state
        if (self.pending_tool) |pt| {
            if (pt.cwd.len > 0) self.alloc.free(pt.cwd);
            self.pending_tool = null;
        }
        if (self.tool_run) |tr| {
            for (tr.calls.items) |c| {
                self.alloc.free(c.name);
                self.alloc.free(c.arguments);
            }
            tr.calls.deinit(self.alloc);
            tr.results.deinit(self.alloc);
            self.alloc.destroy(tr);
            self.tool_run = null;
        }

        // Background threads: join only threads that already finished.
        // A still-running thread may be blocked in a network call with no
        // timeout; the process is exiting so the OS reclaims its arena
        // (page_allocator pages never reach the leak checker).
        while (self.subagent_runs.items.len > 0) {
            const run = self.subagent_runs.items[0];
            if (run.isDone()) {
                run.thread.join();
                run.deinit();
                std.heap.page_allocator.destroy(run);
                _ = self.subagent_runs.orderedRemove(0);
            } else break;
        }
        self.subagent_runs.deinit(self.alloc);

        if (self.compact_run) |cr| {
            if (cr.isDone()) {
                cr.thread.join();
                cr.deinit();
                std.heap.page_allocator.destroy(cr);
            }
            self.compact_run = null;
        }

        if (self.sandbox) |sb| {
            sb.deinit();
            self.sandbox = null;
        }

        if (self.reasonix) |rx| {
            rx.deinit();
            if (self.reasonix_alloc) |a| a.destroy(rx);
            self.reasonix = null;
        }

        // Shut down the git worker: closing stdin makes it read EOF and exit.
        if (self.git_worker) |gw| {
            _ = std.c.close(gw.stdin_fd);
            self.git_worker = null;
        }

        if (self.mcp_session) |*sess| {
            sess.deinit();
            self.mcp_session = null;
        }
        self.mcp_servers.deinit(self.alloc);

        if (self.active_skill.len > 0) self.alloc.free(self.active_skill);
        if (self.skill_registry) |reg| {
            reg.deinit();
            if (self.skill_registry_alloc) |sa| sa.destroy(reg);
            self.skill_registry = null;
        }
        if (self.memory) |mem| {
            mem.deinit();
            if (self.memory_alloc) |ma| ma.destroy(mem);
            self.memory = null;
        }
        if (self.memory) |mem| {
            mem.deinit();
            if (self.memory_alloc) |ma| ma.destroy(mem);
            self.memory = null;
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
            // Sandbox is initialized in App.init (workspace allow-list);
            // if the platform sandbox fails (macOS Seatbelt), tool calls
            // that mutate or execute fall back to explicit user approval
            // (requiresApproval fails closed on null sandbox).
            // NOTE: dispatch/cache subsystems (ContextManager, CacheFirstLoop,
            // reasonix) are experimental and not wired into the streaming
            // path; they are intentionally left uninitialized (see
            // docs/ARCHITECTURE.md for wiring status).
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
            .mouse => |m| return self.onMouse(m),
            .stream_content => |text| self.onStreamContent(text),
            .stream_reasoning => |text| self.onStreamReasoning(text),
            .stream_done => self.onStreamDone(),
            .stream_error => |e| self.onStreamError(e),
            .tool_start => |t| self.onToolStart(t.name, t.args),
            .tool_output => |t| self.onToolOutput(t.name, t.output, t.success),
            .subagent_start => |s| self.onSubAgentStart(s.id, s.role, s.goal),
            .subagent_update => |s| self.onSubAgentUpdate(s.id, s.summary, s.status),
            .save_session => sessions.saveSession(self, self.session_id),
            .load_session => |path| sessions.loadSession(self, path),
            .tick => |t| {
                self.cursor_visible = (t.timestamp / 500_000_000) % 2 == 0; // blink every 500ms
                // Periodic reasonix TTL cleanup (~every 5s at 60fps).
                self.cleanup_tick += 1;
                if (self.cleanup_tick >= 300) {
                    self.cleanup_tick = 0;
                    if (self.reasonix) |rx| rx.cleanupExpired();
                }
                self.pollStream();
                self.pollSubAgents();
                self.pollCompact();
                // Toast auto-dismiss is handled by zz.components.Toast based on timestamps
            },
        }
        return .none;
    }

    // ═════════════════════════════════════════════════════════════════
    // Mouse Handling
    // ═════════════════════════════════════════════════════════════════

    fn onMouse(self: *App, ev: zz.MouseEvent) zz.Cmd(Msg) {
        switch (ev.button) {
            .wheel_up => {
                self.scroll_offset +|= 3;
                self.auto_scroll = false;
            },
            .wheel_down => {
                if (self.scroll_offset > 3) {
                    self.scroll_offset -= 3;
                } else {
                    self.scroll_offset = 0;
                    self.auto_scroll = true;
                }
            },
            else => {},
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
            if (k == .enter or (k == .char and k.char == '1')) { tools_run.approvePendingTool(self); return .none; }
            if (k == .escape or (k == .char and k.char == '2')) { tools_run.rejectPendingTool(self); return .none; }
            return .none;
        }

        // --- Slash output modal
        if (self.slash_output_active) {
            if (k == .escape or k == .enter or (k == .char and k.char == 'q')) {
                slash_commands.closeSlashOutput(self);
            }
            return .none;
        }

        // --- Slash prompt overlay
        if (self.slash_awaiting_cmd != null) {
            if (k == .escape) {
                slash_commands.closeSlashPrompt(self);
                return .none;
            }
            if (k == .enter) {
                const cmd_id = self.alloc.dupe(u8, self.slash_awaiting_cmd orelse "") catch return .none;
                defer self.alloc.free(cmd_id);
                const value = self.alloc.dupe(u8, self.slash_prompt_input.getValue()) catch return .none;
                defer self.alloc.free(value);
                slash_commands.closeSlashPrompt(self);
                slash_commands.executeSlashCommand(self, cmd_id, value);
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
                    slash_commands.executeSlashCommand(self, cmd.id, "");
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
            if (k == .left) { if (self.detail_idx > 0) self.detail_idx -= 1; render_ui.updateDetailModal(self); }
            if (k == .right) { if (self.detail_idx + 1 < self.messages.items.len) self.detail_idx += 1; render_ui.updateDetailModal(self); }
            return .none;
        }

        // --- Search overlay
        if (self.search_active) {
            if (k == .escape) { self.search_active = false; self.search_query.clearRetainingCapacity(); return .none; }
            if (k == .enter) {
                // Jump to first matching message
                if (self.search_query.items.len > 0) {
                    sessions.jumpToMatch(self);
                }
                self.search_active = false;
                return .none;
            }
            if (k == .backspace) { if (self.search_query.items.len > 0) _ = self.search_query.pop(); return .none; }
            if (k == .char) { self.search_query.append(self.alloc, @intCast(k.char)) catch {}; return .none; }
            return .none;
        }

        // --- Global Ctrl shortcuts
        // Ctrl+Tab: cycle tool mode (auto -> plan -> yolo -> auto)
        if (m.ctrl and k == .tab) {
            self.run_mode = switch (self.run_mode) {
                .auto => .plan,
                .plan => .yolo,
                .yolo => .auto,
            };
            const mode_msg = std.fmt.allocPrint(self.alloc, "Mode: {s}", .{@tagName(self.run_mode)}) catch "";
            defer if (mode_msg.len > 0) self.alloc.free(mode_msg);
            self.setNotification(mode_msg);
            return .none;
        }

        if (m.ctrl and k == .char) {
            switch (k.char) {
                'y', 0x19 => {
                    // Copy the last assistant message to the clipboard.
                    var i = self.messages.items.len;
                    while (i > 0) : (i -= 1) {
                        if (self.messages.items[i - 1].role == .assistant and self.messages.items[i - 1].content.len > 0) {
                            if (self.git_worker) |*gw| {
                                if (gw.copy(self.messages.items[i - 1].content)) {
                                    self.setNotification("Copied last reply to clipboard");
                                } else {
                                    self.setNotification("Copy failed");
                                }
                            }
                            return .none;
                        }
                    }
                    return .none;
                },
                'c' => { self.should_quit = true; return .none; },
                'f' => { self.search_active = true; self.search_query.clearRetainingCapacity(); },
                's' => { self.show_subagents = !self.show_subagents; },
                'o' => { if (self.messages.items.len > 0) { self.detail_idx = self.messages.items.len - 1; render_ui.updateDetailModal(self); self.detail_modal.show(); } },
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

        // '/' is typed as a normal character so parameterized commands
        // (/save name, /model x, /apikey sk-...) can be entered directly;
        // Ctrl+P opens the command palette for quick selection.
        // --- F1 / ? for help (when input empty)
        if (k == .f1 or (k == .char and k.char == '?' and self.text_input.getValue().len == 0)) {
            render_ui.updateHelpModal(self);
            self.help_modal.show();
            return .none;
        }

        // --- Scroll keys (when input empty)
        if (self.text_input.getValue().len == 0) {
            // Up recalls/edits the previous user message (auto_scroll stays;
            // PgUp/PgDn and the mouse wheel still scroll).
            if (k == .up) {
                var idx: ?usize = self.history_edit_idx;
                if (idx == null) {
                    var i = self.messages.items.len;
                    while (i > 0) : (i -= 1) {
                        if (self.messages.items[i - 1].role == .user) {
                            idx = i - 1;
                            break;
                        }
                    }
                } else {
                    var i = idx.?;
                    while (i > 0) : (i -= 1) {
                        if (self.messages.items[i - 1].role == .user) {
                            idx = i - 1;
                            break;
                        }
                    }
                }
                if (idx) |found| {
                    self.text_input.setValue(self.messages.items[found].content) catch {};
                    self.text_input.cursor = 0;
                    self.history_edit_idx = found;
                }
                return .none;
            }
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

        // /rewind: go back one turn (drop the trailing user + assistant/tool
        // messages) — a lightweight checkpoint/rewind without a snapshot store.
        // Inline slash commands (/rewind, /skills, /mcp, /memory, /mode, /copy)
        if (slash_commands.handleSlashCommand(self, text_slice)) return;

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
            slash_commands.executeSlashCommand(self, cmd_id, args);
            self.text_input.setValue("") catch {};
            self.text_input.cursor = 0;
            return;
        }

        // Semantic cache hit: self-contained query (>= 15 chars) in a simple
        // conversation (<= 2 messages) with an exact-prompt cached reply is
        // served instantly instead of calling the API.
        if (text_slice.len >= 15 and self.messages.items.len <= 2) {
            if (self.reasonix) |rx| {
                if (rx.get(text_slice)) |cached| {
                    const user_owned = self.alloc.dupe(u8, text_slice) catch null;
                    const asst_owned = std.fmt.allocPrint(self.alloc, "{s} ⚡cached", .{cached}) catch null;
                    if (user_owned != null and asst_owned != null) {
                        self.messages.append(self.alloc, .{
                            .role = .user, .content = user_owned.?, .timestamp = 0, .owns = true,
                        }) catch {
                            self.alloc.free(user_owned.?);
                            self.alloc.free(asst_owned.?);
                            return;
                        };
                        self.messages.append(self.alloc, .{
                            .role = .assistant, .content = asst_owned.?, .timestamp = 0, .owns = true,
                        }) catch {
                            self.alloc.free(asst_owned.?);
                            return;
                        };
                        self.text_input.setValue("") catch {};
                        self.text_input.cursor = 0;
                        self.auto_scroll = true;
                        self.setNotification("⚡ served from semantic cache");
                        return;
                    }
                    if (user_owned) |u| self.alloc.free(u);
                    if (asst_owned) |a| self.alloc.free(a);
                } else if (rx.findSemanticMatch(text_slice, 0.85)) |sm| {
                    // Conservative similar-query hit: mark it so the user can
                    // judge whether the cached reply really matches.
                    const user_owned = self.alloc.dupe(u8, text_slice) catch null;
                    const asst_owned = std.fmt.allocPrint(self.alloc, "{s} ⚡similar ({d:.0}%)", .{ sm.value, sm.similarity * 100.0 }) catch null;
                    if (user_owned != null and asst_owned != null) {
                        self.messages.append(self.alloc, .{
                            .role = .user, .content = user_owned.?, .timestamp = 0, .owns = true,
                        }) catch {
                            self.alloc.free(user_owned.?);
                            self.alloc.free(asst_owned.?);
                            return;
                        };
                        self.messages.append(self.alloc, .{
                            .role = .assistant, .content = asst_owned.?, .timestamp = 0, .owns = true,
                        }) catch {
                            self.alloc.free(asst_owned.?);
                            return;
                        };
                        self.text_input.setValue("") catch {};
                        self.text_input.cursor = 0;
                        self.auto_scroll = true;
                        self.setNotification("⚡ similar cached reply");
                        return;
                    }
                    if (user_owned) |u| self.alloc.free(u);
                    if (asst_owned) |a| self.alloc.free(a);
                }
            }
        }

        // While a response is streaming, accept the input and queue it: it is
        // sent automatically when the current turn (incl. tool calls) finishes.
        if (self.streaming_idx != null) {
            const queued = self.alloc.dupe(u8, text_slice) catch return;
            self.pending_inputs.append(self.alloc, queued) catch {
                self.alloc.free(queued);
                return;
            };
            self.text_input.setValue("") catch {};
            self.text_input.cursor = 0;
            self.history_edit_idx = null;
            self.setNotification("Queued (will send when the current reply finishes)");
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
        self.history_edit_idx = null;
        self.auto_scroll = true;
        self.scroll_offset = 0;
        self.turn += 1;

        // Start streaming if API key is available
        if (self.api_key.len > 0) {
            // Long-term memory footnote: BM25-recall facts relevant to the
            // prompt, appended as low-authority context (bounded).
            var mem_footnote: []const u8 = "";
            if (self.active_skill.len > 0) self.alloc.free(self.active_skill);
        if (self.skill_registry) |reg| {
            reg.deinit();
            if (self.skill_registry_alloc) |sa| sa.destroy(reg);
            self.skill_registry = null;
        }
        if (self.memory) |mem| {
            mem.deinit();
            if (self.memory_alloc) |ma| ma.destroy(mem);
            self.memory = null;
        }
        if (self.memory) |mem| {
                const recalled = mem.recall(text, 2, 800);
                if (recalled.len > 0) {
                    mem_footnote = std.fmt.allocPrint(self.alloc, "\n\nRelevant long-term facts (user-provided, verify before relying):\n{s}", .{recalled}) catch "";
                }
                self.alloc.free(recalled);
            }
            defer if (mem_footnote.len > 0) self.alloc.free(mem_footnote);

            var git_ctx_owned: []const u8 = "";
            if (self.git_worker) |*gw| {
                if (std.c.getenv("PWD")) |pwd_z| {
                    const pwd = std.mem.sliceTo(pwd_z, 0);
                    var dir_buf: [512:0]u8 = undefined;
                    _ = std.fmt.bufPrintSentinel(&dir_buf, "{s}/.git", .{pwd}, 0) catch null;
                    if (std.c.access(&dir_buf, 0) == 0) {
                        if (gw.runGit(self.alloc, pwd, &.{ "status", "--short" })) |out| {
                            defer self.alloc.free(out);
                            // Count changed files for the sidebar indicator.
                            const changes = std.mem.count(u8, out, "\n");
                            if (out.len > 0) self.git_changes = changes;
                            if (out.len > 0 and out.len < 2000) {
                                git_ctx_owned = std.fmt.allocPrint(self.alloc, "Git workspace status (use this when answering code/change questions):\n{s}", .{out}) catch "";
                            }
                        }
                    }
                }
            }
            var combined_ctx = git_ctx_owned;
            defer if (combined_ctx.ptr != git_ctx_owned.ptr and combined_ctx.len > 0) self.alloc.free(combined_ctx);
            if (mem_footnote.len > 0) {
                const c2 = std.fmt.allocPrint(self.alloc, "{s}{s}", .{ git_ctx_owned, mem_footnote }) catch git_ctx_owned;
                combined_ctx = c2;
            }
            if (self.active_skill.len > 0) {
                if (self.skill_registry) |reg| {
                    if (reg.findByName(self.active_skill)) |sk| {
                        const skill_prompt = std.fmt.allocPrint(self.alloc, "You are running the '{s}' skill: {s}\n{s}", .{ sk.name, sk.description, if (sk.prompts.len > 0) sk.prompts[0].template else "" }) catch "";
                        defer if (skill_prompt.len > 0) self.alloc.free(skill_prompt);
                        const c3 = std.fmt.allocPrint(self.alloc, "{s}\n\n{s}", .{ combined_ctx, skill_prompt }) catch combined_ctx;
                        if (c3.ptr != combined_ctx.ptr) {
                            if (combined_ctx.ptr != git_ctx_owned.ptr) self.alloc.free(combined_ctx);
                            combined_ctx = c3;
                        }
                    }
                }
            }
            self.startStreaming(text, combined_ctx);
        } else {
            // No API key — placeholder
            self.messages.append(self.alloc, .{
                .role = .assistant,
                .content = self.i18n.t().msg_no_api_key,
                .status = .complete,
            }) catch {};
        }
    }

    /// Real semantic-cache hit rate from reasonix (falls back to 0).
    pub fn cacheHitRate(self: *const App) f64 {
        if (self.reasonix) |rx| return rx.hitRate();
        return 0;
    }

    /// Keep the tail of the conversation that fits within `budget` tokens.
    fn foldTailBudget(self: *const App, msg_count: usize, budget: usize) usize {
        var start = msg_count;
        var remaining = budget;
        var i = msg_count;
        while (i > 0) : (i -= 1) {
            const t = tokenizer_mod.Tokenizer.count(self.messages.items[i - 1].content);
            if (t > remaining) break;
            remaining -= t;
            start = i - 1;
        }
        return start;
    }

    pub fn startStreaming(self: *App, user_input: []const u8, git_ctx_owned: []const u8) void {
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
        }) catch {
            // OOM: roll back the stream state we just created so no dangling
            // stream_state is left behind.
            ss.deinit();
            self.alloc.destroy(ss);
            self.stream_state = null;
            return;
        };
        self.streaming_idx = idx;

        // Build context from recent messages. Content is duplicated so the
        // background thread fully owns its data: the UI thread can run
        // /clear /new /compact /model /apikey at any time without racing.
        var ctx_items = std.ArrayList(stream_client_mod.CtxItem).empty;
        defer ctx_items.deinit(self.alloc);
        const msg_count = self.messages.items.len - 1; // exclude the empty assistant msg
        // Token-budget aware context window via reasonix's fold decision,
        // instead of a hardcoded last-20-messages slice.
        var start: usize = 0;
        if (msg_count > 0) {
            var total_tokens: usize = 0;
            for (self.messages.items[0..msg_count]) |m| total_tokens += tokenizer_mod.Tokenizer.count(m.content);
            const decision = reasonix_mod.Reasonix.decideAfterUsage(total_tokens, @intCast(self.ctx_max), false);
            switch (decision) {
                .none => start = 0,
                .fold_normal => |fd| start = self.foldTailBudget(msg_count, fd.tail_budget),
                .fold_aggressive => |fd| start = self.foldTailBudget(msg_count, fd.tail_budget),
                .exit_with_summary => start = if (msg_count > 6) msg_count - 6 else 0,
                .emergency_truncate => |et| start = self.foldTailBudget(msg_count, et.target_tokens),
            }
        }
        for (self.messages.items[start..msg_count]) |m| {
            const role_str: []const u8 = switch (m.role) {
                .user => "user", .assistant => "assistant", .system => "system", .tool => "tool",
            };
            const content = self.alloc.dupe(u8, m.content) catch continue;
            // Snip oversized tool outputs (Reasonix compact pipeline borrow):
            // keep a bounded tail so stale command dumps don't burn tokens.
            var final_content = content;
            defer if (final_content.ptr != content.ptr) self.alloc.free(final_content);
            if (m.role == .tool and content.len > 400) {
                final_content = std.fmt.allocPrint(self.alloc, "{s}\n…[tool output truncated ({d} bytes)]", .{ content[0..400], content.len }) catch content;
            }
            ctx_items.append(self.alloc, .{
                .role = role_str,
                .content = final_content,
                .tool_call_id = if (m.role == .tool) m.tool_call_id else "",
            }) catch {
                self.alloc.free(content);
            };
        }

        // Capture values for the thread
        const mgr_key = self.provider_mgr.resolveApiKey(self.provider) orelse "";
        const api_key = if (mgr_key.len > 0) mgr_key else self.api_key;
        const model = self.provider_mgr.resolveModel(self.provider);
        const endpoint = self.provider_mgr.resolveEndpoint(self.provider);

        // Duplicate inputs owned by the UI (prompt, api_key, model) — the
        // thread frees its copies when it finishes.
        const prompt_owned = self.alloc.dupe(u8, user_input) catch return;
        const api_key_owned = self.alloc.dupe(u8, api_key) catch {
            self.alloc.free(prompt_owned);
            return;
        };
        const model_owned = self.alloc.dupe(u8, model) catch {
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
            fn run(prompt: []const u8, ctx: []const stream_client_mod.CtxItem, api_k: []const u8, mdl: []const u8, ep: []const u8, git_ctx: []const u8, a: std.mem.Allocator, state: *StreamState) void {
                defer {
                    for (ctx) |ci| a.free(ci.content);
                    a.free(ctx);
                    a.free(prompt);
                    a.free(api_k);
                    a.free(mdl);
                    if (git_ctx.len > 0) a.free(git_ctx);
                }
                // Dedicated Io so blocking network reads never stall the UI
                // thread's shared std.Io (threaded-io socket hang on macOS).
                var threaded = std.Io.Threaded.init(a, .{ .argv0 = .empty, .environ = .empty });
                const sio_own = threaded.io();
                defer threaded.deinit();
                var client = stream_client_mod.DeepSeekStreamClient.init(a, sio_own, null, null);
                client.endpoint = ep;
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
                    stream_client_mod.streamMessageH2(&client, api_k, prompt, ctx, mdl, CacheDecision.none, git_ctx, null, h2sink) catch break :blk false;
                    break :blk true;
                };
                if (!h2_ok) {
                    // Fallback: buffered (non-streaming) response via std.http.
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
        }.run, .{ prompt_owned, ctx_slice, api_key_owned, model_owned, endpoint, git_ctx_owned, alloc, ss }) catch {
            // Thread failed to spawn: reclaim the data we duplicated for it
            for (ctx_slice) |ci| alloc.free(ci.content);
            alloc.free(ctx_slice);
            alloc.free(prompt_owned);
            alloc.free(api_key_owned);
            alloc.free(model_owned);
            if (git_ctx_owned.len > 0) alloc.free(git_ctx_owned);
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
                tools_run.handleToolCalls(self, tc_json.?);
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


    /// Process the next queued tool call. Pauses at the first call that
    /// requires user approval (pending_tool) and resumes on Enter/Esc.
    /// Execute one tool through the unified tools/ pipeline with extra guards.
    /// Returns a caller-owned string (empty slice on failure).

pub fn isSensitivePath(path: []const u8) bool {
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

pub fn extractJsonString(_: *App, json: []const u8, key: []const u8) ?[]const u8 {
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
        // Cache successful (non-tool) replies for exact-prompt reuse.
        if (self.reasonix) |rx| {
            if (self.streaming_idx) |si| {
                if (si > 0 and si < self.messages.items.len) {
                    const user_msg = self.messages.items[si - 1];
                    const asst_msg = self.messages.items[si];
                    if (user_msg.role == .user and user_msg.content.len >= 15 and asst_msg.content.len > 0) {
                        rx.put(user_msg.content, asst_msg.content) catch {};
                    }
                }
            }
        }
        if (self.streaming_idx) |idx| {
            if (idx < self.messages.items.len) {
                self.messages.items[idx].status = .complete;
            }
        }
        self.streaming_idx = null;
        self.turn += 1;

        // Auto-send the next queued input, if any (streaming/tool loop done).
        if (self.pending_inputs.items.len > 0) {
            const queued = self.pending_inputs.orderedRemove(0);
            self.messages.append(self.alloc, .{
                .role = .user,
                .content = queued,
                .timestamp = 0,
                .owns = true,
            }) catch {
                self.alloc.free(queued);
                return;
            };
            self.history_edit_idx = null;
            self.auto_scroll = true;
            self.turn += 1;
            if (self.api_key.len > 0) {
                self.startStreaming(queued, "");
            }
        }

        // One-shot context water-level hint (aligned with reasonix fold
        // thresholds): suggest /compact once the conversation passes 70%.
        if (!self.compact_hinted) {
            var total: usize = 0;
            for (self.messages.items) |m| total += tokenizer_mod.Tokenizer.count(m.content);
            if (self.ctx_max > 0) {
                const pct = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(self.ctx_max)) * 100.0;
                if (pct > 70) {
                    const hint = std.fmt.allocPrint(self.alloc, "Context at {d:.0}% — run /compact to summarize", .{pct}) catch null;
                    if (hint) |h| {
                        self.setNotification(h);
                        self.alloc.free(h);
                    }
                    self.compact_hinted = true;
                }
            }
        }
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

    pub fn onToolStart(self: *App, name: []const u8, args: []const u8) void {
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

    pub fn onToolOutput(self: *App, name: []const u8, output: []const u8, success: bool) void {
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

    fn cycleTheme(self: *App) void {
        self.theme_manager.cycle();
        self.styles = theme.SemanticStyles.fromPalette(self.theme_manager.getPalette());
        const msg = std.fmt.allocPrint(self.alloc, "Theme: {s}", .{self.theme_manager.getThemeName()}) catch return;
        self.setNotification(msg);
    }

    pub fn setThemeByName(self: *App, name: []const u8) void {
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


    pub fn setApiKey(self: *App, key: []const u8) void {
        if (key.len == 0) {
            self.setNotification("Usage: /apikey <your-api-key>");
            return;
        }
        if (key.len < 8) {
            self.setNotification("Key too short — expected 8+ characters");
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

    pub fn setNotification(self: *App, msg: []const u8) void {
        self.toast.push(msg, .info, 2000, 0) catch {};
    }

    pub fn toggleToolCollapse(self: *App) void {
        for (self.messages.items) |*m| {
            if (m.tool_calls.items.len > 0) {
                m.tool_collapsed = !m.tool_collapsed;
            }
        }
    }

    pub fn clearMessages(self: *App) void {
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
    pub fn compactContext(self: *App) void {
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
        render_ui.renderClaudeHeader(self, &header_buf, a, w);
        const header_text = header_buf.toOwnedSlice(a) catch return "";

        // Build footer — command hint (when typing '/'), separator, input + status
        var footer_buf = std.ArrayList(u8).empty;
        const input_val = self.text_input.getValue();
        if (input_val.len >= 1 and input_val[0] == '/' and self.pending_tool == null) {
            // Show matching slash commands above the input (bounded to 5).
            const commands = [_]struct { []const u8, []const u8 }{
                .{ "/save", "Save session" }, .{ "/load", "Load session" },
                .{ "/sessions", "List sessions" }, .{ "/compact", "Summarize context" },
                .{ "/clear", "Clear chat" }, .{ "/mode", "Tool mode auto|plan|yolo" },
                .{ "/skill", "Activate a skill" }, .{ "/skills", "List skills" },
                .{ "/memory", "Long-term memory" }, .{ "/copy", "Copy conversation" },
                .{ "/rewind", "Go back one turn" }, .{ "/help", "Help" },
                .{ "/model", "Set model" }, .{ "/apikey", "Set API key" },
                .{ "/provider", "Switch provider" }, .{ "/subagent", "Spawn sub-agent" },
                .{ "/quit", "Quit" },
            };
            var shown: usize = 0;
            for (commands) |cmd| {
                if (shown >= 5) break;
                if (std.mem.startsWith(u8, cmd[0], input_val)) {
                    footer_buf.appendSlice(a, D) catch {};
                    footer_buf.appendSlice(a, "│ ") catch {};
                    footer_buf.appendSlice(a, R) catch {};
                    footer_buf.appendSlice(a, Pal.cyan) catch {};
                    footer_buf.appendSlice(a, cmd[0]) catch {};
                    footer_buf.appendSlice(a, R) catch {};
                    footer_buf.appendSlice(a, Pal.fg_dim) catch {};
                    footer_buf.appendSlice(a, "  ") catch {};
                    footer_buf.appendSlice(a, cmd[1]) catch {};
                    footer_buf.appendSlice(a, R) catch {};
                    footer_buf.appendSlice(a, "\n") catch {};
                    shown += 1;
                }
            }
        }
        footer_buf.appendSlice(a, D) catch {};
        footer_buf.appendSlice(a, Pal.fg_dim) catch {};
        footer_buf.appendSlice(a, "├") catch {};
        var sep_i: u16 = 1;
        while (sep_i < w - 1) : (sep_i += 1) { footer_buf.appendSlice(a, "─") catch {}; }
        footer_buf.appendSlice(a, "┤") catch {};
        footer_buf.appendSlice(a, R) catch {};
        footer_buf.appendSlice(a, "\n") catch {};
        render_ui.renderClaudeInput(@constCast(self), &footer_buf, a, w);
        render_ui.renderClaudeSeparator(self, &footer_buf, a, w);
        render_ui.renderClaudeStatus(self, &footer_buf, a, w);
        const footer_text = footer_buf.toOwnedSlice(a) catch "";

        // Build body: chat (left) + sidebar (right) using join.horizontal
        const chat_text = render_ui.renderClaudeChat(self, a, chat_w, body_h);
        defer a.free(chat_text);
        const chat_clipped = render_ui.clipFromBottom(a, chat_text, body_h, self.scroll_offset) catch chat_text;
        defer if (chat_clipped.ptr != chat_text.ptr) a.free(chat_clipped);
        const sidebar_text = render_ui.renderClaudeSidebar(self, a, sidebar_w, body_h);
        defer a.free(sidebar_text);
        const sep_text = render_ui.buildVerticalSeparator(self, a, body_h);
        defer a.free(sep_text);
        const chat_padded = render_ui.enforceWidth(a, chat_clipped, chat_w) catch chat_clipped;
        defer if (chat_padded.ptr != chat_clipped.ptr) a.free(chat_padded);
        const sidebar_padded = render_ui.enforceWidth(a, sidebar_text, sidebar_w) catch sidebar_text;
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
                result = render_ui.ansiOverlay(a, result, palette_view, px, py) catch result;
            }
        }

        // Tool approval modal (centered overlay with numbered options)
        if (self.pending_tool) |pt| {
            if (self.tool_run) |tr| {
                if (pt.idx < tr.calls.items.len) {
                    const call = tr.calls.items[pt.idx];
                    var modal_lines = std.ArrayList(u8).empty;
                    defer modal_lines.deinit(a);
                    modal_lines.appendSlice(a, "┌─ Tool approval ─────────────────┐\n") catch {};
                    modal_lines.appendSlice(a, "│  ") catch {};
                    modal_lines.appendSlice(a, Pal.yellow) catch {};
                    modal_lines.appendSlice(a, call.name) catch {};
                    modal_lines.appendSlice(a, R) catch {};
                    modal_lines.appendSlice(a, "\n") catch {};
                    modal_lines.appendSlice(a, "│  ") catch {};
                    modal_lines.appendSlice(a, Pal.fg_dim) catch {};
                    const arg_view = if (call.arguments.len > 50) call.arguments[0..50] else call.arguments;
                    modal_lines.appendSlice(a, arg_view) catch {};
                    modal_lines.appendSlice(a, R) catch {};
                    modal_lines.appendSlice(a, "\n") catch {};
                    modal_lines.appendSlice(a, "│  [1] Allow   [2] Deny   [Enter/Esc]\n") catch {};
                    modal_lines.appendSlice(a, "└───────────────────────────────┘\n") catch {};
                    const modal_text = modal_lines.toOwnedSlice(a) catch "";
                    defer a.free(modal_text);
                    const mw = zz.layout.measure.maxLineWidth(modal_text);
                    const mh = zz.layout.measure.height(modal_text);
                    const mx = (w -| @as(u16, @intCast(mw))) / 2;
                    const my = (h -| @as(u16, @intCast(mh))) / 2;
                    const overlaid = render_ui.ansiOverlay(a, result, modal_text, mx, my) catch result;
                    if (overlaid.ptr != result.ptr) {
                        a.free(result);
                        result = overlaid;
                    }
                }
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
            result = render_ui.ansiOverlay(a, result, overlay, 0, 0) catch result;
        }

        // Render search overlay (custom; Modal has no built-in input)
        if (self.search_active) {
            var overlay_lines = std.ArrayList([]const u8).empty;
            defer overlay_lines.deinit(a);
            render_ui.renderSearchOverlay(self, &overlay_lines, a, w, h);
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
            const panel_view = render_ui.renderClaudeSubAgentPanel(self, a, w, h);
            defer a.free(panel_view);
            if (panel_view.len > 0) {
                const pw = zz.layout.measure.maxLineWidth(panel_view);
                const px = w -| @as(u16, @intCast(pw));
                const py: usize = 0;
                result = render_ui.ansiOverlay(a, result, panel_view, px, py) catch result;
            }
        }

        // Render notification toasts on top of everything (ANSI-aware overlay)
        const toast_view = self.toast.view(a, ctx.elapsed) catch "";
        defer a.free(toast_view);
        if (toast_view.len > 0) {
            const tw = zz.layout.measure.maxLineWidth(toast_view);
            const tx = w -| @as(u16, @intCast(tw));
            const ty: usize = 0;
            result = render_ui.ansiOverlay(a, result, toast_view, tx, ty) catch result;
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

};

var g_git_worker: ?git_worker_mod.Client = null;

pub fn main(init: std.process.Init, git_worker: ?git_worker_mod.Client) !void {
    g_git_worker = git_worker;
    var program = zz.Program(App).initWithOptions(init.gpa, init.io, init.environ_map, .{
        .mouse = true,
    });
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
    for (SlashDispatcher.Dispatcher.commands()) |cmd| {
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
