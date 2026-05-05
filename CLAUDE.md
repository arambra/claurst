# claurst — Claude Code Rust Port

Clean-room Rust reimplementation of Anthropic's Claude Code CLI. Built from `spec/` alone (no TypeScript source carried forward). Binary name is `claude`, package is `claude-code`.

## Repository layout

```
.
├── src-rust/           # Cargo workspace — all implementation code lives here
│   └── crates/
│       ├── core/       (cc-core)     Types, errors, config, permissions, history, hooks, system prompt
│       ├── api/        (cc-api)      Anthropic API client + SSE streaming
│       ├── tools/      (cc-tools)    Tool implementations (bash, file_*, grep, glob, web_*, agent, todo, …)
│       ├── query/      (cc-query)    Agentic loop, auto-compact, coordinator, cron scheduler
│       ├── commands/   (cc-commands) Slash command registry
│       ├── mcp/        (cc-mcp)      MCP (Model Context Protocol) client
│       ├── bridge/     (cc-bridge)   Bridge to claude.ai web UI / IDE direct-connect
│       ├── tui/        (cc-tui)      ratatui terminal UI
│       ├── buddy/      (cc-buddy)    Tamagotchi companion subsystem
│       ├── plugins/    (cc-plugins)  Plugin system
│       └── cli/        (claude-code) Binary entry: src/main.rs, [[bin]] name = "claude"
├── spec/               # Behavioral spec extracted from upstream TS (~990 KB, read-only reference)
├── litellm.yaml        # LiteLLM proxy config: routes claude-* model names → DeepSeek
├── test/               # JSON fixtures
└── public/             # Static assets
```

Dependency flow: `cli → query → tools → core`, with `api`, `commands`, `tui`, `mcp`, `bridge` all leaning on `core`.

## Build & run

All cargo commands run from `src-rust/`.

```
cargo build                       # debug build of the whole workspace
cargo build --release             # release build
cargo run --bin claude -- --help  # run the CLI
cargo test                        # run all tests
cargo check -p cc-tools           # fast type-check a single crate
cargo clippy --workspace          # lint
cargo fmt                         # format
```

Edition 2021, resolver 2, MSRV implied by `tokio 1.44` / `clap 4` / `thiserror 2`. All shared deps live in the workspace `Cargo.toml` — when adding a dep used by ≥2 crates, declare it in `[workspace.dependencies]` and reference with `dep = { workspace = true }` in member crates.

## Runtime configuration

Active branch is `deepseek` and is wired to talk to a DeepSeek backend, not Anthropic:

- `litellm.yaml` defines a LiteLLM proxy that aliases `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5` to `deepseek/deepseek-chat`. Master key: `sk-claurst-local`. Reads `DEEPSEEK_API_KEY` from env.
- `.claude/settings.json` points the CLI at `https://api.deepseek.com/anthropic` directly (DeepSeek's Anthropic-compatible endpoint) using `deepseek-v4-flash`.

Two ways to run, pick one — don't mix:
1. **Direct**: rely on `.claude/settings.json` and DeepSeek's Anthropic-compatible endpoint.
2. **Via LiteLLM**: `litellm --config litellm.yaml`, then point the CLI at the proxy with `ANTHROPIC_BASE_URL=http://localhost:4000` and `ANTHROPIC_API_KEY=sk-claurst-local`.

Config precedence (see `cc-core::config`): `Config` struct → `ANTHROPIC_API_KEY` / `ANTHROPIC_BASE_URL` env → built-in defaults. `Settings` is loaded from `.claude/settings.json`.

## Deploy to Azure

Three PowerShell scripts ship code from local to a running Container App. Run in order, with the same versioned tag (`vMAJOR.MINOR.PATCH`):

| Step | Script | What it does |
| --- | --- | --- |
| 1. Build | `deploy/build-image.ps1` | `docker build` once, applies four tags to one digest: `claurst-ask:{latest,$tag}` and `<acr>.azurecr.io/claurst-ask:{latest,$tag}`. Does not push. |
| 2. Push | `deploy/push-image.ps1` | Runs `acr-login.ps1` internally (refreshes the ~3 h ACR token), then `docker push` for both ACR-bound tags. |
| 3. Provision | `deploy/provision-app.ps1` | Creates the Container App on first run; otherwise `az containerapp update --image …` and converges identity, registry, ingress, and revision mode. |

```powershell
$tag = 'v0.2.0'
$acr = 'mapagentacr'

./deploy/build-image.ps1   -AcrName $acr -ImageVersion $tag
./deploy/push-image.ps1    -AcrName $acr -ImageVersion $tag
./deploy/provision-app.ps1 -AcrName $acr -ImageTag $tag
```

Same `$tag` threads through all three. `build` and `push` use `-ImageVersion` (must match `^v\d+\.\d+\.\d+$`); `provision-app` uses `-ImageTag` (any tag, but matching the version is what makes the deploy reproducible).

For routine image-only rolls (no config changes) skip the provision script and use `az containerapp update -n claurst-ask -g <rg> --image <ref>` directly — ~60-90s instead of ~3 min.

Scripts are PowerShell 7+ only; runs on Linux/macOS via `pwsh`, so CI is not Windows-locked. The Bash counterparts that previously sat alongside have been removed.

**One-time prerequisites** (per environment, before the first build): `provision-acr.ps1` → `provision-env.ps1` → `provision-identity.ps1` → `secrets/setup-secrets.ps1`. Detailed auth, ingress, and secret-rotation flows: `deploy/ACR-AUTH.md`, `deploy/RUNTIME-CONFIG.md`, `deploy/secrets/README.md`.

## Working in this codebase

- **`spec/` is the source of truth for behavior.** When implementing or fixing a tool, command, or subsystem, consult the matching numbered spec file (see `spec/INDEX.md`) before reading other crates. The spec describes the upstream TS behavior the Rust port must match.
- **Don't carry TypeScript source into the repo.** This is a clean-room rewrite — only the spec is allowed as upstream input. Rephrase ideas; don't transliterate.
- **Tools live in `cc-tools` and implement the `Tool` async trait** (`name`, `description`, `permission_level`, `input_schema`, `execute`). MCP server tools are wrapped via `McpToolWrapper` in `cli/src/main.rs` so they look like native tools.
- **Permission model** is in `cc-core::permissions`: `PermissionLevel` (Read/Write/Execute), `PermissionMode` (Default/AcceptEdits/BypassPermissions/Plan), and rule-based `PermissionManager`. New tools must declare a `permission_level`.
- **Errors**: return `cc_core::Result<T>` and use `ClaudeError`. `is_retryable()` and `is_context_limit()` drive the query-loop retry/compact behavior — preserve those semantics when adding new error variants.
- **Async everywhere**: Tokio `full` features. Tools are `#[async_trait]`. Don't block the runtime — use `tokio::task::spawn_blocking` for CPU-bound work.
- **Logging**: `tracing` macros, not `println!`. Subscriber is initialized in `cli/src/main.rs` with `EnvFilter` (set `RUST_LOG=debug` to see crate-level traces).

## Conventions

- Workspace package metadata (version 1.0.0, edition 2021, MIT) is inherited via `version.workspace = true`.
- Crate names use the `cc-` prefix everywhere except the binary crate, which is `claude-code` producing `claude`.
- Module organization in `cc-core` is **inline submodules in `lib.rs`** (`error`, `types`, `config`, `permissions`, `cost`, `history`, …). Keep new core types there unless they grow large enough to warrant a sibling file (see `analytics.rs`, `keybindings.rs`, `memdir.rs` for the split-file pattern).
- Schemas use `schemars` for JSON Schema generation on tool inputs.
