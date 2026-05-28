# Zeepseek Architecture

## Five-Layer Model

```
Utils ──────────────────────────────────────────────► UI
  │                                                       ▲
  │                                                       │
 Storage ────────► Network ─────► Dispatch ───────────────┘
```

| Layer | Directory | Imports From | Responsibility |
|-------|-----------|-------------|----------------|
| **Utils** | `src/utils/` | (nothing) | Config, tokenizer, sandbox, validation |
| **Storage** | `src/storage/` | utils | mmap-based KV store, WAL, crash recovery |
| **Network** | `src/net/` | utils, storage | HTTP client, SSE parsing, rate limiter, circuit breaker |
| **Dispatch** | `src/dispatch/` | all below | Cache-first agent loop, context folding |
| **UI** | `src/ui/` | all below | ZigZag (Elm Architecture) TUI rendering |

## Key Modules

### `src/ui/app.zig` — Main Application
- ZigZag Model-Update-View pattern
- Handles keyboard input, streaming, command dispatch
- ~2200 lines (includes rendering + state management)

### `src/cache/reasonix.zig` — Semantic Cache
- Token-based caching with 3-tier TTL (hot/cold/archive)
- LIRS eviction policy
- Similarity-based semantic matching

### `src/dispatch/cache_first_loop.zig` — Agent Loop
- Coordinates cache, context folding, and API calls
- Budget tracking per conversation turn
- Stream state management

### `src/net/stream_client.zig` — DeepSeek API
- SSE streaming client
- Tool call repair pipeline
- JSON request body builder

### `src/agent/subagent.zig` — Multi-Agent
- SubAgent scheduler with state machine (pending→running→completed/failed)
- Result merging (summary, changes, evidence, risks, blockers)

### `src/storage/mmap_store.zig` — TurboDB
- mmap-based key-value storage
- Hot/cold region with WAL
- Crash recovery via WAL replay

## Data Flow

```
User Input → UI (onKey) → dispatch (cache_first_loop) → 
  cache (reasonix) → network (stream_client) → SSE stream →
  dispatch (pollStream) → UI (onStreamContent) → Terminal
```
