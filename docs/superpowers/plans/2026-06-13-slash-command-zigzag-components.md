# Slash-command ZigZag component refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plain `/model` text prompt with a selectable ZigZag `List`, give `/provider` a provider `List`, add confirmation modals for destructive commands (`/clear`, `/new`, `/compact`), and polish the `/apikey` prompt with password echo and consistent styling.

**Architecture:** Add new result variants (`pick_model`, `pick_provider`, `confirm`) to the existing `SlashDispatcher.Result` union. The `App` keeps persistent ZigZag `List`/`Modal` components, opens them when those results are returned, and routes keys to the active overlay. Selections are routed back through `executeSlashCommand` so the existing `set_model`/`set_provider`/`clear_chat` logic is reused.

**Tech Stack:** Zig 0.17.0-dev, ZigZag TUI framework (`zz.components.List`, `zz.components.Modal`, `zz.components.TextInput`).

---

## Files that will change

- `src/ui/slash_command_dispatcher.zig`
  - Add `ConfirmPrompt` struct and `pick_model`, `pick_provider`, `confirm` to `Result`.
  - Return these new variants from `/model`, `/provider`, `/clear`, `/new`, `/compact`.
- `src/ui/app.zig`
  - Add persistent overlay state: `model_picker`, `provider_picker`, `confirm_modal`, plus flags/pending action.
  - Route keys to the new overlays in `onKey`.
  - Render the new overlays in `view`.
  - Handle the new dispatcher results in `executeSlashCommand`.
  - Set `TextInput` echo mode to `.password` for `/apikey` prompts.
- `src/test_runner.zig`
  - Already imports `src/ui/app.zig`; no new import needed.

---

## Task 1: Extend the slash-command dispatcher

**Files:**
- Modify: `src/ui/slash_command_dispatcher.zig:33-71`
- Modify: `src/ui/slash_command_dispatcher.zig:73-101` (command table)
- Modify: `src/ui/slash_command_dispatcher.zig:108-173` (`Dispatcher.execute`)
- Test: inline tests at the bottom of `src/ui/slash_command_dispatcher.zig`

### Step 1.1: Add the new result types

After the existing `ListData` struct, add:

```zig
pub const ConfirmPrompt = struct {
    title: []const u8,
    body: []const u8,
    action: []const u8,
};
```

Extend the `Result` union to include:

```zig
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
    pick_model,
    pick_provider,
    confirm: ConfirmPrompt,
};
```

### Step 1.2: Update the command table

Change the `kind` for `model` and `provider` from `.prompt` to `.instant` (they no longer use the generic text prompt):

```zig
    .{ .id = "model",    .label = "/model",    .desc = "Switch model", .kind = .instant },
    .{ .id = "provider", .label = "/provider", .desc = "Switch API provider and set key", .kind = .instant },
```

### Step 1.3: Update command execution

Replace the `/model` branch:

```zig
        if (std.mem.eql(u8, id, "model")) {
            if (args.len == 0) {
                return .pick_model;
            }
            return .{ .set_model = try ctx.allocator.dupe(u8, args) };
        }
```

Replace the `/provider` branch:

```zig
        if (std.mem.eql(u8, id, "provider")) {
            if (args.len == 0) {
                return .pick_provider;
            }
            return .{ .set_provider = try ctx.allocator.dupe(u8, args) };
        }
```

Replace the `clear`/`new`/`compact` lines with confirmation prompts:

```zig
        if (std.mem.eql(u8, id, "clear") or std.mem.eql(u8, id, "new")) {
            return .{ .confirm = .{
                .title = if (std.mem.eql(u8, id, "new")) "Start new session?" else "Clear chat?",
                .body = "This will remove the current conversation. This cannot be undone.",
                .action = id,
            } };
        }
        if (std.mem.eql(u8, id, "compact")) {
            return .{ .confirm = .{
                .title = "Compact context?",
                .body = "This will summarize older messages to reduce token usage.",
                .action = "compact",
            } };
        }
```

### Step 1.4: Add a dispatcher test

Append to the bottom of `src/ui/slash_command_dispatcher.zig`:

```zig
test "model/provider without args open pickers" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();
    var sandbox: Sandbox = undefined;
    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = &sandbox,
        .tokens_used = 0,
        .ctx_max = 64000,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    const model_res = try Dispatcher.execute(ctx, "model", "");
    try std.testing.expectEqual(.pick_model, model_res);

    const provider_res = try Dispatcher.execute(ctx, "provider", "");
    try std.testing.expectEqual(.pick_provider, provider_res);
}

test "clear/new/compact return confirmation" {
    const alloc = std.testing.allocator;
    var pm = ProviderManager.init(alloc);
    defer pm.deinit();
    var sandbox: Sandbox = undefined;
    const ctx = CommandContext{
        .allocator = alloc,
        .io = undefined,
        .provider = "deepseek",
        .model = "deepseek-chat",
        .subsystems_initialized = false,
        .provider_mgr = &pm,
        .sandbox = &sandbox,
        .tokens_used = 0,
        .ctx_max = 64000,
        .cache_hit_rate = 0,
        .session_id = "test",
    };

    const clear_res = try Dispatcher.execute(ctx, "clear", "");
    try std.testing.expect(clear_res == .confirm);
    try std.testing.expectEqualStrings("clear", clear_res.confirm.action);

    const new_res = try Dispatcher.execute(ctx, "new", "");
    try std.testing.expect(new_res == .confirm);
    try std.testing.expectEqualStrings("new", new_res.confirm.action);

    const compact_res = try Dispatcher.execute(ctx, "compact", "");
    try std.testing.expect(compact_res == .confirm);
}
```

Run:

```bash
zig build test --summary all
```

Expected: these two tests pass; existing tests still pass.

---

## Task 2: Add overlay state to `App`

**Files:**
- Modify: `src/ui/app.zig` struct definition around line 705
- Modify: `src/ui/app.zig` `init` around line 716
- Modify: `src/ui/app.zig` `deinit` around line 800

### Step 2.1: Add import for the model catalog

At the top of `src/ui/app.zig`, add:

```zig
const models_catalog = @import("../providers/models.zig");
```

### Step 2.2: Define a pending confirm action enum

Inside the `App` struct (after `const OutputData` block, before fields), add:

```zig
    const ConfirmAction = enum {
        clear,
        new,
        compact,
    };
```

### Step 2.3: Add overlay fields

Add these fields near the existing slash-prompt fields (around line 705):

```zig
    // --- Model / provider pickers
    model_picker_active: bool = false,
    provider_picker_active: bool = false,
    model_picker: zz.components.List([]const u8) = undefined,
    provider_picker: zz.components.List([]const u8) = undefined,

    // --- Confirm modal for destructive commands
    confirm_modal: zz.components.Modal = undefined,
    confirm_action: ?ConfirmAction = null,
```

### Step 2.4: Initialize the components

In `App.init`, after `.palette = ...`, add:

```zig
            .model_picker = zz.components.List([]const u8).init(ctx.persistent_allocator),
            .provider_picker = zz.components.List([]const u8).init(ctx.persistent_allocator),
            .confirm_modal = zz.components.Modal.confirm("Confirm", ""),
```

Also initialize the new flags in the struct literal:

```zig
            .model_picker_active = false,
            .provider_picker_active = false,
            .confirm_action = null,
```

### Step 2.5: Deinitialize

In `App.deinit`, before the final `self.* = undefined;` (or wherever other components are deinitialized), add:

```zig
        self.model_picker.deinit();
        self.provider_picker.deinit();
        self.confirm_modal = undefined;
```

---

## Task 3: Wire key routing for the new overlays

**Files:**
- Modify: `src/ui/app.zig` `onKey` around line 980

### Step 3.1: Confirm modal handling

Insert **before** the slash-output block:

```zig
        // --- Confirm modal
        if (self.confirm_modal.isVisible()) {
            const had = self.confirm_modal.isVisible();
            self.confirm_modal.handleKey(key);
            if (had and self.confirm_modal.getResult()) |res| {
                self.confirm_modal.hide();
                switch (res) {
                    .button_pressed => |idx| {
                        if (idx == 0) {
                            if (self.confirm_action) |action| {
                                switch (action) {
                                    .clear => self.executeSlashCommand("clear", ""),
                                    .new => self.executeSlashCommand("new", ""),
                                    .compact => self.executeSlashCommand("compact", ""),
                                }
                            }
                        }
                        self.confirm_action = null;
                    },
                    .dismissed => self.confirm_action = null,
                }
            }
            return .none;
        }
```

### Step 3.2: Model picker handling

Insert **after** the confirm modal block and **before** the slash-output block:

```zig
        // --- Model picker
        if (self.model_picker_active) {
            if (k == .escape) {
                self.model_picker_active = false;
                return .none;
            }
            if (k == .enter) {
                if (self.model_picker.selectedValue()) |model_id| {
                    self.model_picker_active = false;
                    self.executeSlashCommand("model", model_id);
                }
                return .none;
            }
            self.model_picker.handleKey(key);
            return .none;
        }
```

### Step 3.3: Provider picker handling

Insert immediately after the model picker block:

```zig
        // --- Provider picker
        if (self.provider_picker_active) {
            if (k == .escape) {
                self.provider_picker_active = false;
                return .none;
            }
            if (k == .enter) {
                if (self.provider_picker.selectedValue()) |provider_id| {
                    self.provider_picker_active = false;
                    self.executeSlashCommand("provider", provider_id);
                }
                return .none;
            }
            self.provider_picker.handleKey(key);
            return .none;
        }
```

---

## Task 4: Render the new overlays

**Files:**
- Modify: `src/ui/app.zig` `view` around line 2179

### Step 4.1: Helper to render a centered list box

Add this helper inside `App` (near `ansiOverlay`):

```zig
    fn renderPicker(
        self: *const App,
        a: std.mem.Allocator,
        w: u16,
        h: u16,
        title: []const u8,
        picker: *const zz.components.List([]const u8),
    ) []const u8 {
        const list_view = picker.view(a) catch "";
        const body = std.fmt.allocPrint(a, "{s}\n\n{s}\n\n[↑/↓] choose  [Enter] select  [Esc] cancel", .{
            title, list_view,
        }) catch "";
        var style = zz.Style{};
        style = style.borderAll(.rounded);
        style = style.width(@min(60, w -| 4));
        style = style.paddingAll(1);
        const boxed = style.render(a, body) catch "";
        return zz.place.place(a, w, h, .center, .middle, boxed) catch "";
    }
```

### Step 4.2: Draw the overlays

Insert these overlay blocks in `view` **before** the slash-output block (around line 2260):

```zig
        // Confirm modal overlay
        if (self.confirm_modal.isVisible()) {
            const modal_view = self.confirm_modal.viewWithBackdrop(a, w, h) catch "";
            if (modal_view.len > 0) {
                a.free(result);
                result = modal_view;
            } else {
                a.free(modal_view);
            }
        }

        // Model picker overlay
        if (self.model_picker_active) {
            const overlay = self.renderPicker(a, w, h, "Select model", &self.model_picker);
            result = ansiOverlay(a, result, overlay, 0, 0) catch result;
        }

        // Provider picker overlay
        if (self.provider_picker_active) {
            const overlay = self.renderPicker(a, w, h, "Select provider", &self.provider_picker);
            result = ansiOverlay(a, result, overlay, 0, 0) catch result;
        }
```

---

## Task 5: Handle the new dispatcher results

**Files:**
- Modify: `src/ui/app.zig` `executeSlashCommand` result switch around line 1830

### Step 5.1: Add `.confirm`, `.pick_model`, `.pick_provider` arms

Add these arms to the `switch (res)` block, after `.show_help` and before `.set_model`:

```zig
            .confirm => |c| {
                self.confirm_action = if (std.mem.eql(u8, c.action, "new"))
                    .new
                else if (std.mem.eql(u8, c.action, "compact"))
                    .compact
                else
                    .clear;
                self.confirm_modal = zz.components.Modal.confirm(c.title, c.body);
                self.confirm_modal.show();
            },

            .pick_model => {
                self.model_picker.clear();
                const models = models_catalog.listModelsByProvider(self.provider);
                if (models.len == 0) {
                    self.setNotification("No models available for this provider");
                    return;
                }
                for (models) |m| {
                    const item = zz.components.List([]const u8).Item.init(m.id, m.name);
                    self.model_picker.addItem(item) catch {};
                }
                // Pre-select the current model if it exists in the list
                const current = self.model;
                for (self.model_picker.items.items, 0..) |it, i| {
                    if (std.mem.eql(u8, it.value, current)) {
                        self.model_picker.cursor = @intCast(i);
                        self.model_picker.y_offset = 0;
                        break;
                    }
                }
                self.model_picker_active = true;
            },

            .pick_provider => {
                self.provider_picker.clear();
                const providers = @import("../providers/mod.zig").listProviders();
                for (providers) |p| {
                    const item = zz.components.List([]const u8).Item.withDescription(p.id, p.name, p.endpoint);
                    self.provider_picker.addItem(item) catch {};
                }
                // Pre-select current provider
                const current = self.provider;
                for (self.provider_picker.items.items, 0..) |it, i| {
                    if (std.mem.eql(u8, it.value, current)) {
                        self.provider_picker.cursor = @intCast(i);
                        self.provider_picker.y_offset = 0;
                        break;
                    }
                }
                self.provider_picker_active = true;
            },
```

### Step 5.2: Polish the `/apikey` prompt

Change the `.prompt` handler so that `/apikey` uses password echo:

```zig
            .prompt => |p| {
                const title = self.alloc.dupe(u8, p.title) catch return;
                const placeholder = self.alloc.dupe(u8, p.placeholder) catch {
                    self.alloc.free(title);
                    return;
                };
                self.alloc.free(p.title);
                self.alloc.free(p.placeholder);
                const echo_mode: zz.components.TextInput.EchoMode = if (std.mem.eql(u8, id, "apikey") or std.mem.eql(u8, id, "key"))
                    .password
                else
                    .normal;
                self.slash_prompt_input.setEchoMode(echo_mode);
                self.openSlashPrompt(id, title, placeholder);
                self.alloc.free(title);
                self.alloc.free(placeholder);
            },
```

---

## Task 6: Update tests and verify

### Step 6.1: Add an `App`-level test

Append to the test section at the bottom of `src/ui/app.zig`:

```zig
test "/model opens model picker" {
    const alloc = std.testing.allocator;
    var app = try App.testInit(alloc);
    defer app.deinit();

    app.executeSlashCommand("model", "");
    try std.testing.expect(app.model_picker_active);
}

test "/clear opens confirm modal" {
    const alloc = std.testing.allocator;
    var app = try App.testInit(alloc);
    defer app.deinit();

    app.executeSlashCommand("clear", "");
    try std.testing.expect(app.confirm_modal.isVisible());
    try std.testing.expectEqual(.clear, app.confirm_action.?);
}
```

(If `App.testInit` does not exist, use the same construction pattern already used by the existing tests in `src/ui/app.zig`.)

### Step 6.2: Build and test

Run the full test suite:

```bash
zig build test --summary all
```

Expected: all tests pass.

### Step 6.3: Build the binary

```bash
zig build -Doptimize=ReleaseFast
```

Expected: `./zig-out/bin/zeepseek` is produced with no errors.

### Step 6.4: Manual TUI smoke test

Run:

```bash
./zig-out/bin/zeepseek
```

Inside the TUI:
1. Type `/` or `Ctrl+K` to open the command palette, select `/model`, press `Enter`.
2. Verify a centered list appears with DeepSeek models; use arrow keys, press `Enter` to select.
3. Verify the footer/toast updates to the new model name.
4. Open `/provider`, select a provider, verify it switches and prompts for API key with hidden characters.
5. Type `/clear`, verify a confirmation modal appears; cancel with `Esc` and accept with `Enter`.
6. Run `zig build test` once more after any manual tweaks.

---

## Spec coverage self-review

| User requirement | Task |
|---|---|
| `/model` should be a dropdown/selectable list of models | Tasks 1.3, 2.3, 3.2, 4, 5.1 |
| Other commands should use ZigZag components appropriately | `/provider` list (1.3, 2.3, 3.3, 4, 5.1); `/clear`, `/new`, `/compact` confirm modal (1.3, 3.1, 5.1); `/apikey` password prompt (5.2) |
| Keep existing direct-argument behavior (`/model deepseek-chat`) | Preserved in 1.3 |
| Existing slash output (`/status`, `/models`) keeps working | Not touched; still uses `slash_output_active` path |

## Placeholder scan

No `TODO`, `TBD`, or vague "handle edge cases" steps remain. Every code block is concrete and maps to an exact file/location.

## Type consistency check

- `zz.components.List([]const u8).Item.init(value, title)` and `withDescription(value, title, desc)` are used consistently.
- `ConfirmAction` enum values (`clear`, `new`, `compact`) match the action strings returned by the dispatcher.
- `Dispatcher.execute` still returns `error{ UnknownCommand, InvalidArgs, OutOfMemory }!Result`.
