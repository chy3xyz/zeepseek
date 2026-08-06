//! Sub-agent flow (start/poll/update) — split out of app.zig.

const std = @import("std");
const App = @import("app.zig").App;
const SubAgentRole = @import("app.zig").SubAgentRole;
const MsgStatus = @import("app.zig").MsgStatus;
const SubAgentRun = App.SubAgentRun;
const CacheDecision = @import("app.zig").CacheDecision;
const subagent_mod = @import("../agent/subagent.zig");
const stream_client_mod = @import("../net/stream_client.zig");

pub fn onSubAgentStart(app: *App, id: []const u8, role: SubAgentRole, goal: []const u8) void {
    app.subagents.append(app.alloc, .{
        .id = id,
        .role = role,
        .goal = goal,
        .status = .pending,
    }) catch {};
}

pub fn onSubAgentUpdate(app: *App, id: []const u8, summary: []const u8, status: MsgStatus) void {
    for (app.subagents.items) |*sa| {
        if (std.mem.eql(u8, sa.id, id)) {
            sa.status = status;
            if (summary.len > 0) sa.summary = summary;
            break;
        }
    }
}

pub fn startSubAgent(app: *App, goal: []const u8) void {
    const g = std.mem.trim(u8, goal, " ");
    if (g.len == 0) {
        app.setNotification("Usage: /subagent <goal>");
        return;
    }
    if (app.api_key.len == 0) {
        app.setNotification("Set an API key first (/apikey sk-...)");
        return;
    }
    if (app.subagent_runs.items.len >= 4) {
        app.setNotification("Too many concurrent sub-agents (max 4)");
        return;
    }

    const sa_index = app.subagents.items.len;
    const id = std.fmt.allocPrint(app.alloc, "sa-{d}", .{sa_index}) catch return;
    const goal_owned = app.alloc.dupe(u8, g) catch {
        app.alloc.free(id);
        return;
    };
    // id/goal ownership moves into subagents (released by deinit)
    onSubAgentStart(app, id, .researcher, goal_owned);

    const run = std.heap.page_allocator.create(SubAgentRun) catch return;
    run.* = SubAgentRun.init(std.heap.page_allocator, sa_index);
    const ra = run.allocator();

    const api_key_owned = ra.dupe(u8, app.api_key) catch {
        std.heap.page_allocator.destroy(run);
        return;
    };
    const model_owned = ra.dupe(u8, app.model) catch {
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
        app.setNotification("Failed to start sub-agent thread");
        return;
    };
    run.thread = thread;
    app.subagent_runs.append(app.alloc, run) catch {
        std.heap.page_allocator.destroy(run);
        app.setNotification("Failed to register sub-agent");
        return;
    };
    app.setNotification("Sub-agent started");
}

pub fn pollSubAgents(app: *App) void {
    var i: usize = 0;
    while (i < app.subagent_runs.items.len) {
        const run = app.subagent_runs.items[i];
        if (run.isDone()) {
            run.thread.join();
            const failed = run.failed.load(.acquire);
            const summary = run.drainSummary(app.alloc);
            defer {
                if (summary) |s| app.alloc.free(s);
            }
            if (run.sa_index < app.subagents.items.len) {
                const sa = &app.subagents.items[run.sa_index];
                sa.status = if (failed) .failed else .complete;
                if (summary) |s| {
                    if (s.len > 0) {
                        if (sa.summary.len > 0) app.alloc.free(sa.summary);
                        sa.summary = app.alloc.dupe(u8, s) catch "";
                    }
                }
            }
            run.deinit();
            std.heap.page_allocator.destroy(run);
            _ = app.subagent_runs.orderedRemove(i);
        } else i += 1;
    }
}

