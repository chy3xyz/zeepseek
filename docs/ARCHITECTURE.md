# Zeepseek Architecture

## Runtime data flow (as actually wired)

```
User input ──► App.update(.key) ──► onKey ──► submit()
                                        │
                                        ▼
                    startStreaming() spawns background thread:
                      ┌─ Fast path: streamMessageH2 (own h2-over-TLS
                      │   client, read timeouts, SSE delta extraction)
                      │   → ChunkSink callbacks → StreamState queues
                      │   (content / reasoning / tool_calls)
                      └─ Fallback: streamMessage (buffered std.http)
                                        │
                                        ▼
                    tick (.every 16ms) ──► pollStream ──► onStreamContent
                                        ▼
                                App.view() renders (ZigZag Elm)
```

- **No dispatch layer in the hot path.** `App.submit()` calls
  `stream_client` directly. `cache/reasonix` **is** used: context folding
  (token-budget window in `startStreaming`) and exact-prompt semantic
  cache (hit served instantly, `⚡cached`; conservative: >=15 chars,
  <=2 messages). `dispatch/cache_first_loop` is not invoked.
- Threading: one background thread per streaming turn (dedicated
  `std.Io.Threaded`), one per `/subagent` run, one per `/compact` run.
  All push into mutex-protected state objects; the UI polls them from
  the 60fps `.tick` message.

## Module wiring status (production truth)

| Status | Modules |
|---|---|
| **Wired & used** | `net/stream_client` + `net/h2_client` (+ vendor TLS/HPACK), `net/http_client2`, `tools/` (shell/file/git/web), `utils/sandbox`, `utils/dangerous_patterns`, `storage/session_format`, `providers/manager`, `cache/reasonix` (context folding in `startStreaming` + exact-prompt semantic cache), `ui/` (app, slash dispatcher, theme) |
| **Half-wired (init only)** | `dispatch/cache_first_loop`, `dispatch/context_manager` (not invoked by the streaming path), `i18n/manager` (only one string used) |
| **Isolated / experimental** | `agent/subagent` scheduler (app uses its own threads), `skills/` (registry exists; `/skills` hardcodes 3 names), `acp/` (Agent Client Protocol, test-only), `storage/session_manager` + `mmap_store` + `store*` (TurboDB not wired), `providers/mod` + `models` (test-only) |

These isolated modules compile and have unit tests but do **not** affect
runtime behavior. Treat them as experimental until wired.

## Key modules

### `src/ui/app.zig` — Main application (~4000 lines)
- ZigZag Model-Update-View; owns all state
- Tool execution pipeline: `runTool` (dangerous-command blacklist +
  sensitive-path checks + workspace validation) → `tools_mod.executeTool`
  → per-call approval overlay (`pending_tool`, Enter allow / Esc deny)
- Session persistence: length-prefixed format, **atomic write**
  (tmp + fsync + rename)
- Sub-agents (`/subagent`) and `/compact` run on background threads with
  arena allocators (page_allocator); finished runs are joined in deinit,
  still-running ones are reclaimed by process exit

### `src/net/stream_client.zig` + `h2_client.zig` — DeepSeek streaming
- `streamMessageH2`: synchronous h2-over-TLS request delivering extracted
  content/reasoning/tool_calls deltas via `ChunkSink` callback
- Vendored `tls_client` (std TLS, + ALPN h2) and `h2_frames`/`hpack`
  (from zigmodu); raw POSIX sockets with SO_RCVTIMEO read timeouts
- `streamMessage`: buffered std.http fallback (captures HTTP status/body)
- Path fix: request path appends `/chat/completions` to provider base URLs

### `src/tools/` — Unified tool execution
- `shell`, `file`, `git`, `web` (web_search/web_scrape are stubs that
  report "not implemented")
- `requiresApproval` **fails closed**: if the platform sandbox is null
  (e.g. macOS Seatbelt failed), shell/file_write/file_edit/git_commit
  always require explicit user approval

### `src/providers/manager.zig` — Multi-provider
- Resolves api_key/model/endpoint per provider id; defaults to deepseek

## Safety model
1. Platform sandbox (Seatbelt/Landlock) with workspace allow-list
2. Static dangerous-command blacklist + sensitive-path rejection
3. Per-call user approval overlay (fail-closed when sandbox is absent)
4. 64KB tool output cap

## Known limitations
- No request cancellation: a blocked network read waits for the 60s
  read timeout; exiting the app during a blocked call relies on process
  exit to reclaim the thread's arena
- `web_search`/`web_scrape` tools are stubs (use `shell` + curl)
- i18n: only the "no API key" string is localized
