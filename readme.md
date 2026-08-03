# Zeepseek

**A minimal, high-performance terminal AI client for DeepSeek API, built in Zig.**

Zeepseek is a TUI (terminal UI) application that lets you chat with DeepSeek's language models directly from your terminal. It's written in pure Zig with the ZigZag Elm Architecture framework.

## Features

- **Streaming responses** — Real-time SSE streaming with token-by-token rendering
- **Markdown rendering** — Headings, code blocks, lists, inline formatting in terminal
- **Command palette** — Ctrl+P for quick commands (`/model`, `/apikey`, `/clear`, etc.)
- **Thinking display** — Collapsible reasoning content from DeepSeek models
- **Tool call support** — Shell/file/git tools executed through a sandboxed
  pipeline with **per-call user approval** (`Enter` allow / `Esc` deny)
- **Session management** — Multi-session save/load (`/save <name>`, `/load <name>`, `/sessions`)
- **Context compaction** — `/compact` summarizes older messages in the background via the LLM
- **Right sidebar** — Live metrics: model, turn, estimated context %
- **Sub-agent panel** — `/subagent <goal>` spawns a background research sub-agent
- **Single static binary** — No runtime dependencies

## Requirements

| Dependency | Version |
|------------|---------|
| Zig compiler | ≥ 0.17.0 |
| DeepSeek API key | Required for streaming |

## Quick Start

```bash
# Build (ReleaseFast for minimal binary)
zig build -Doptimize=ReleaseFast

# Set your API key and run
export DEEPSEEK_API_KEY=sk-xxxxxxxxxxxxxxxx
./zig-out/bin/zeepseek

# Or set API key from within the app:
#   /apikey sk-xxxxxxxxxxxxxxxx
```

## Usage

### Key Bindings

| Key | Action |
|-----|--------|
| `Ctrl+P` | Command palette |
| `Ctrl+F` | Search messages |
| `Ctrl+N` | Toggle thinking display |
| `Ctrl+S` | Sub-agent panel |
| `Ctrl+O` | Message detail view |
| `Ctrl+C` | Quit |
| `Enter` | Send message |
| `Shift+Enter` | Newline in input |
| `↑/↓` | Scroll (when input empty) |
| `F1` / `?` | Help overlay |

### Commands

| Command | Description |
|---------|-------------|
| `/model <name>` | Switch model (e.g. `/model deepseek-chat`) |
| `/apikey <key>` | Set API key |
| `/save [name]` | Save current session (defaults to current name) |
| `/load <name>` | Load a saved session |
| `/sessions` | List saved sessions |
| `/compact` | LLM-summarize older messages in the background |
| `/subagent <goal>` | Start a background research sub-agent |
| `/subagents` | Toggle the sub-agent panel |
| `/clear` / `/new` | Clear conversation / start fresh |
| `/think` | Toggle reasoning visibility |
| `/tools` | Toggle tool-call visibility |
| `/models` | List available models |
| `/status` / `/context` | Show model, provider, estimated context usage |
| `/top` / `/bottom` | Scroll to top / bottom |
| `/exit` | Quit |

### Tool approval

Shell commands, file writes/edits and git commits require confirmation:
a preview line (`[Approve tool?] ...`) appears with `Enter` = allow, `Esc` = deny.
Denied tools are reported back to the model. Sensitive paths (`.ssh`, `id_rsa`,
`/etc/...`) and known-dangerous commands are blocked outright.

### Configuration

API key is resolved in this order:
1. `/apikey` command within the session
2. `DEEPSEEK_API_KEY` environment variable
3. `~/.zeepseek/apikey` file (created by `/apikey` command)

Session data is stored in `~/.zeepseek/sessions/`.

## Architecture

```
src/
├── ui/          — ZigZag TUI (Elm Architecture)
│   ├── app.zig  — Main model, update, view (ZigZag-native, self-rendering)
├── cache/       — Reasonix semantic caching
├── dispatch/    — Cache-first agent loop, context manager
├── net/         — HTTP client, SSE parser, rate limiter, circuit breaker
├── storage/     — TurboDB mmap-based persistence
├── agent/       — SubAgent scheduler and worker pool
├── providers/   — LLM provider abstraction
├── tools/       — Shell, file, git tool execution
├── skills/      — Skill system (registry, manifest, installer)
├── i18n/        — Internationalization (en, ja, zh-Hans, pt-BR)
└── utils/       — Config, sandbox, tokenizer, validation
```

## License

MIT
