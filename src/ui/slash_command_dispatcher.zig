const std = @import("std");
const ProviderManager = @import("../providers/manager.zig").ProviderManager;
const Sandbox = @import("../utils/sandbox.zig").Sandbox;

pub const CommandKind = enum {
    instant,
    prompt,
    output,
    insert, // palette-only shortcut: fill the input box
};

pub const Command = struct {
    id: []const u8,
    label: []const u8,
    desc: []const u8,
    kind: CommandKind = .instant,
};

pub const CommandContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: []const u8,
    model: []const u8,
    subsystems_initialized: bool,
    provider_mgr: *ProviderManager,
    sandbox: ?*Sandbox,
    tokens_used: usize,
    ctx_max: usize,
    cache_hit_rate: f64,
    session_id: []const u8,
};

pub const Prompt = struct {
    title: []const u8,
    placeholder: []const u8,
};

pub const TableData = struct {
    title: []const u8,
    headers: []const []const u8,
    rows: []const []const []const u8,
};

pub const ListData = struct {
    title: []const u8,
    items: []const []const u8,
};

pub const Result = union(enum) {
    none,
    set_input: []const u8,
    notify: []const u8,
    quit,
    clear_chat,
    save_session,
    load_session,
    toggle_thinking,
    toggle_tools,
    toggle_subagents,
    scroll_top,
    scroll_bottom,
    compact_context,
    show_help,
    prompt: Prompt,
    show_table: TableData,
    show_list: ListData,
    set_model: []const u8,
    set_provider: []const u8,
    set_apikey: []const u8,
    set_theme: []const u8,
};

const commands_table = [_]Command{
    .{ .id = "help", .label = "/help", .desc = "Show help information" },
    .{ .id = "clear", .label = "/clear", .desc = "Clear conversation history" },
    .{ .id = "exit", .label = "/exit", .desc = "Quit the application" },
    .{ .id = "model", .label = "/model", .desc = "Switch model", .kind = .prompt },
    .{ .id = "provider", .label = "/provider", .desc = "Switch API provider and set key", .kind = .prompt },
    .{ .id = "models", .label = "/models", .desc = "List available models", .kind = .output },
    .{ .id = "save", .label = "/save", .desc = "Save current session" },
    .{ .id = "load", .label = "/load", .desc = "Load a session from file" },
    .{ .id = "sessions", .label = "/sessions", .desc = "List saved sessions", .kind = .output },
    .{ .id = "workspace", .label = "/workspace", .desc = "Show workspace path", .kind = .output },
    .{ .id = "context", .label = "/context", .desc = "Show context usage statistics", .kind = .output },
    .{ .id = "status", .label = "/status", .desc = "Show system status", .kind = .output },
    .{ .id = "compact", .label = "/compact", .desc = "Compact conversation context" },
    .{ .id = "note", .label = "/note", .desc = "Manage notes", .kind = .insert },
    .{ .id = "memory", .label = "/memory", .desc = "Manage agent memory", .kind = .insert },
    .{ .id = "subagents", .label = "/subagents", .desc = "Show sub-agent panel" },
    .{ .id = "theme", .label = "/theme", .desc = "Switch color theme", .kind = .prompt },
    .{ .id = "think", .label = "/think", .desc = "Toggle reasoning visibility" },
    .{ .id = "tools", .label = "/tools", .desc = "Toggle tool call visibility" },
    .{ .id = "top", .label = "/top", .desc = "Scroll to top" },
    .{ .id = "bottom", .label = "/bottom", .desc = "Scroll to bottom" },
    .{ .id = "new", .label = "/new", .desc = "Start a new session" },
    .{ .id = "apikey", .label = "/apikey", .desc = "Set API key", .kind = .prompt },
    .{ .id = "key", .label = "/key", .desc = "Set API key (alias)", .kind = .prompt },
    .{ .id = "skills", .label = "/skills", .desc = "List available skills", .kind = .output },
    .{ .id = "sandbox", .label = "/sandbox", .desc = "Show sandbox status", .kind = .output },
    .{ .id = "providers", .label = "/providers", .desc = "List configured providers", .kind = .output },
};

pub const Dispatcher = struct {
    pub fn commands() []const Command {
        return &commands_table;
    }

    pub fn execute(ctx: CommandContext, id: []const u8, args: []const u8)
        error{ UnknownCommand, InvalidArgs, OutOfMemory }!Result
    {
        if (std.mem.eql(u8, id, "help")) return .show_help;
        if (std.mem.eql(u8, id, "exit")) return .quit;
        if (std.mem.eql(u8, id, "clear") or std.mem.eql(u8, id, "new")) return .clear_chat;
        if (std.mem.eql(u8, id, "save")) return .save_session;
        if (std.mem.eql(u8, id, "load")) return .load_session;
        if (std.mem.eql(u8, id, "think")) return .toggle_thinking;
        if (std.mem.eql(u8, id, "tools")) return .toggle_tools;
        if (std.mem.eql(u8, id, "top")) return .scroll_top;
        if (std.mem.eql(u8, id, "bottom")) return .scroll_bottom;
        if (std.mem.eql(u8, id, "subagents")) return .toggle_subagents;
        if (std.mem.eql(u8, id, "compact")) return .compact_context;

        if (std.mem.eql(u8, id, "model")) {
            if (args.len == 0) {
                return .{ .prompt = .{
                    .title = try ctx.allocator.dupe(u8, "Switch model"),
                    .placeholder = try ctx.allocator.dupe(u8, "e.g. deepseek-chat"),
                } };
            }
            return .{ .set_model = try ctx.allocator.dupe(u8, args) };
        }

        if (std.mem.eql(u8, id, "theme")) {
            if (args.len == 0) {
                return .{ .prompt = .{
                    .title = try ctx.allocator.dupe(u8, "Switch theme"),
                    .placeholder = try ctx.allocator.dupe(u8, "e.g. tokyo_night"),
                } };
            }
            return .{ .set_theme = try ctx.allocator.dupe(u8, args) };
        }

        if (std.mem.eql(u8, id, "apikey") or std.mem.eql(u8, id, "key")) {
            if (args.len == 0) {
                const title = try std.fmt.allocPrint(ctx.allocator, "Set API key for {s}", .{ctx.provider});
                return .{ .prompt = .{ .title = title, .placeholder = try ctx.allocator.dupe(u8, "sk-...") } };
            }
            return .{ .set_apikey = try ctx.allocator.dupe(u8, args) };
        }

        if (std.mem.eql(u8, id, "provider")) {
            if (args.len == 0) {
                return .{ .prompt = .{
                    .title = try ctx.allocator.dupe(u8, "Switch provider"),
                    .placeholder = try ctx.allocator.dupe(u8, "deepseek, openai, groq, ollama..."),
                } };
            }
            return .{ .set_provider = try ctx.allocator.dupe(u8, args) };
        }

        if (std.mem.eql(u8, id, "status") or std.mem.eql(u8, id, "context")) return try handleStatus(ctx);
        if (std.mem.eql(u8, id, "workspace")) return try handleWorkspace(ctx);
        if (std.mem.eql(u8, id, "sessions")) return try handleSessions(ctx);
        if (std.mem.eql(u8, id, "models")) return handleModels(ctx);
        if (std.mem.eql(u8, id, "providers")) return try handleProviders(ctx);
        if (std.mem.eql(u8, id, "skills")) return handleSkills(ctx);
        if (std.mem.eql(u8, id, "sandbox")) return try handleSandbox(ctx);

        if (std.mem.eql(u8, id, "note")) return .{ .set_input = try ctx.allocator.dupe(u8, "/note ") };
        if (std.mem.eql(u8, id, "memory")) return .{ .set_input = try ctx.allocator.dupe(u8, "/memory ") };

        return error.UnknownCommand;
    }
};

pub fn dupeRow(allocator: std.mem.Allocator, cells: []const []const u8) ![]const []const u8 {
    var row: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (row.items) |c| allocator.free(c);
        row.deinit(allocator);
    }
    for (cells) |c| {
        try row.append(allocator, try allocator.dupe(u8, c));
    }
    return row.toOwnedSlice(allocator);
}

pub fn freeRow(allocator: std.mem.Allocator, row: []const []const u8) void {
    for (row) |c| allocator.free(c);
    allocator.free(row);
}

fn handleStatus(ctx: CommandContext) !Result {
    const pct: f64 = if (ctx.ctx_max > 0)
        @as(f64, @floatFromInt(ctx.tokens_used)) / @as(f64, @floatFromInt(ctx.ctx_max)) * 100.0
    else
        0.0;

    var rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (rows.items) |row| freeRow(ctx.allocator, row);
        rows.deinit(ctx.allocator);
    }

    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Model", ctx.model }));
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Provider", ctx.provider }));

    const tokens_str = try std.fmt.allocPrint(ctx.allocator, "{d}/{d}K", .{ ctx.tokens_used / 1000, ctx.ctx_max / 1000 });
    defer ctx.allocator.free(tokens_str);
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Tokens", tokens_str }));

    const usage_str = try std.fmt.allocPrint(ctx.allocator, "{d:.0}%", .{pct});
    defer ctx.allocator.free(usage_str);
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Usage", usage_str }));

    const cache_str = try std.fmt.allocPrint(ctx.allocator, "{d:.0}%", .{ctx.cache_hit_rate * 100.0});
    defer ctx.allocator.free(cache_str);
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Cache hit", cache_str }));

    return .{ .show_table = .{
        .title = "Status",
        .headers = &.{ "Key", "Value" },
        .rows = try rows.toOwnedSlice(ctx.allocator),
    } };
}

fn handleWorkspace(ctx: CommandContext) !Result {
    const cwd_ptr = std.c.getenv("PWD") orelse ".";
    const cwd = std.mem.sliceTo(cwd_ptr, 0);

    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |it| ctx.allocator.free(it);
        items.deinit(ctx.allocator);
    }
    try items.append(ctx.allocator, try ctx.allocator.dupe(u8, cwd));

    return .{ .show_list = .{
        .title = "Workspace",
        .items = try items.toOwnedSlice(ctx.allocator),
    } };
}

fn handleModels(ctx: CommandContext) !Result {
    var rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (rows.items) |row| freeRow(ctx.allocator, row);
        rows.deinit(ctx.allocator);
    }

    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "deepseek-chat", "V4 Flash (default)" }));
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "deepseek-v4-pro", "V4 Pro" }));
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "deepseek-reasoner", "Reasoning model" }));

    return .{ .show_table = .{
        .title = "Available models",
        .headers = &.{ "Model", "Description" },
        .rows = try rows.toOwnedSlice(ctx.allocator),
    } };
}

fn handleSkills(ctx: CommandContext) !Result {
    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |it| ctx.allocator.free(it);
        items.deinit(ctx.allocator);
    }

    const names = [_][]const u8{ "health", "investigate", "design-review" };
    for (names) |name| {
        try items.append(ctx.allocator, try ctx.allocator.dupe(u8, name));
    }

    return .{ .show_list = .{
        .title = "Registered skills",
        .items = try items.toOwnedSlice(ctx.allocator),
    } };
}

fn handleSandbox(ctx: CommandContext) !Result {
    const status: []const u8 = if (ctx.sandbox != null) "active (Seatbelt)" else "not initialized";

    var rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (rows.items) |row| freeRow(ctx.allocator, row);
        rows.deinit(ctx.allocator);
    }

    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Sandbox", status }));
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "Shell", "prompt" }));
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "File read", "auto_allow" }));
    try rows.append(ctx.allocator, try dupeRow(ctx.allocator, &.{ "File write", "prompt" }));

    return .{ .show_table = .{
        .title = "Sandbox",
        .headers = &.{ "Policy", "Mode" },
        .rows = try rows.toOwnedSlice(ctx.allocator),
    } };
}

fn handleProviders(ctx: CommandContext) !Result {
    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |it| ctx.allocator.free(it);
        items.deinit(ctx.allocator);
    }

    if (ctx.subsystems_initialized) {
        const active = ctx.provider_mgr.active;
        const list = try ctx.provider_mgr.listProviders();
        for (list) |pid| {
            const marker: []const u8 = if (std.mem.eql(u8, pid, active)) "◄ " else "  ";
            const line = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ marker, pid });
            try items.append(ctx.allocator, line);
        }
    } else {
        try items.append(ctx.allocator, try ctx.allocator.dupe(u8, "deepseek (default)"));
    }

    return .{ .show_list = .{
        .title = "Providers",
        .items = try items.toOwnedSlice(ctx.allocator),
    } };
}

fn handleSessions(ctx: CommandContext) !Result {
    const home_ptr = std.c.getenv("HOME") orelse {
        return .{ .notify = try ctx.allocator.dupe(u8, "HOME not set") };
    };
    const home = std.mem.sliceTo(home_ptr, 0);
    const dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/.zeepseek/sessions", .{home});
    defer ctx.allocator.free(dir_path);

    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |it| ctx.allocator.free(it);
        items.deinit(ctx.allocator);
    }

    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch {
        return .{ .show_list = .{
            .title = "Saved sessions",
            .items = try items.toOwnedSlice(ctx.allocator),
        } };
    };
    defer dir.close(ctx.io);

    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind == .file or entry.kind == .unknown) {
            try items.append(ctx.allocator, try ctx.allocator.dupe(u8, entry.name));
        }
    }

    return .{ .show_list = .{
        .title = "Saved sessions",
        .items = try items.toOwnedSlice(ctx.allocator),
    } };
}

test "instant commands return direct results" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    try std.testing.expectEqual(Result.show_help, try Dispatcher.execute(ctx, "help", ""));
    try std.testing.expectEqual(Result.quit, try Dispatcher.execute(ctx, "exit", ""));
    try std.testing.expectEqual(Result.clear_chat, try Dispatcher.execute(ctx, "clear", ""));
}

test "model with args returns set_model" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    const result = try Dispatcher.execute(ctx, "model", "deepseek-v4");
    try std.testing.expectEqualStrings("deepseek-v4", result.set_model);
    alloc.free(result.set_model);
}

test "model without args returns prompt" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    const result = try Dispatcher.execute(ctx, "model", "");
    try std.testing.expectEqualStrings("Switch model", result.prompt.title);
    try std.testing.expectEqualStrings("e.g. deepseek-chat", result.prompt.placeholder);
    alloc.free(result.prompt.title);
    alloc.free(result.prompt.placeholder);
}

test "provider without args returns prompt" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    const result = try Dispatcher.execute(ctx, "provider", "");
    try std.testing.expectEqualStrings("Switch provider", result.prompt.title);
    try std.testing.expectEqualStrings("deepseek, openai, groq, ollama...", result.prompt.placeholder);
    alloc.free(result.prompt.title);
    alloc.free(result.prompt.placeholder);
}

test "provider with args returns set_provider" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    const result = try Dispatcher.execute(ctx, "provider", "openai");
    try std.testing.expectEqualStrings("openai", result.set_provider);
    alloc.free(result.set_provider);
}

test "unknown command returns error" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();

    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = null,
        .tokens_used = 0,
        .ctx_max = 0,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    try std.testing.expectError(error.UnknownCommand, Dispatcher.execute(ctx, "nope", ""));
}
