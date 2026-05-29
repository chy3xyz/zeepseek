//! Zeepseek Test Runner
//! Imports all modules with inline tests and re-exports them for `zig build test`.

const std = @import("std");

// ── Modules with inline tests ──────────────────────────────────────────
const _sse_parser = @import("net/sse_parser.zig");
const _sse = @import("net/sse.zig");
const _circuit_breaker = @import("net/circuit_breaker.zig");
const _rate_limiter = @import("net/rate_limiter.zig");
const _http_client = @import("net/http_client.zig");
const _keyspace = @import("storage/keyspace.zig");
const _store_api = @import("storage/store_api.zig");
const _migrations = @import("storage/migrations.zig");
const _recovery = @import("storage/recovery.zig");
const _dangerous = @import("utils/dangerous.zig");
const _dangerous_patterns = @import("utils/dangerous_patterns.zig");
const _i18n_manager = @import("i18n/manager.zig");
const _i18n_strings = @import("i18n/strings.zig");
const _provider_models = @import("providers/models.zig");
const _provider_manager = @import("providers/manager.zig");
const _acp_mod = @import("acp/mod.zig");
const _acp_zed = @import("acp/zed_adapter.zig");
const _config = @import("utils/config.zig");
const _tool_mod = @import("tools/mod.zig");
const _tool_file = @import("tools/file.zig");
const _tool_shell = @import("tools/shell.zig");
const _manifest = @import("skills/manifest.zig");
const _registry = @import("skills/registry.zig");
const _tokenizer = @import("utils/tokenizer.zig");
const _validation = @import("utils/validation.zig");
const _exec_policy = @import("utils/exec_policy.zig");
const _tool_registry = @import("utils/tool_registry.zig");
const _notifications = @import("utils/notifications.zig");
const _sandbox = @import("utils/sandbox.zig");
const _reasonix = @import("cache/reasonix.zig");
const _context_manager = @import("dispatch/context_manager.zig");
const _cache_first_loop = @import("dispatch/cache_first_loop.zig");
const _store = @import("storage/store.zig");
const _session_manager = @import("storage/session_manager.zig");
const _mmap_store = @import("storage/mmap_store.zig");
const _subagent = @import("agent/subagent.zig");
const _subworker = @import("agent/sub_worker.zig");
const _stream_client = @import("net/stream_client.zig");
const _deepseek_client = @import("net/deepseek_client.zig");
const _app = @import("ui/app.zig");
