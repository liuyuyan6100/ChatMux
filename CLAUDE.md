# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

ChatMux is a self-hosted SSH/tmux workspace client: one React SPA (web + Tauri desktop + Capacitor mobile) talking to a Go "Gateway" that owns all SSH/tmux/PTY work. Monorepo is a pnpm workspace (`apps/*`, `packages/*`) plus a Go module under `services/gateway`.

## Commands

```bash
pnpm install                       # bootstrap workspace
pnpm dev                           # Vite dev server for @chatmux/web (proxies /api to localhost:19327)
pnpm typecheck                     # tsc -b on the web app
pnpm build                         # tsc -b && vite build
docker-compose up -d --build       # run web + gateway together (host networking)

cd services/gateway
CHATMUX_GATEWAY_TOKEN=dev-token go run ./cmd/chatmux-gateway   # run gateway (token required unless CHATMUX_LOCAL_NO_AUTH=1 on loopback)
go test ./...                                                  # all gateway tests
go test ./internal/api -run TestCreateSSHCredentialTokenAPI    # a single test
go build ./cmd/chatmux-gateway
```

The pre-PR quality gate (see CONTRIBUTING.md) is `pnpm typecheck` + `pnpm build` + `go test ./...`. **There is no JS/TS test runner or linter** — the only frontend checks are `tsc` and the Vite build. Gateway code is Go-stdlib-first with `go test`; there is no golangci/vet step in CI (`.github/workflows/build-artifacts.yml` only builds release artifacts).

Packaging (each shells out to Docker and drops artifacts in `.tmp/artifacts/`): `pnpm desktop:build:{linux,macos,windows}`, `pnpm mobile:build:android-apk`. macOS requires a remote macOS builder (`CHATMUX_MACOS_BUILDER`) — it cannot build in a Linux container. See docs/development.md.

## Architecture

**The Gateway is the security boundary.** Browsers can't open raw SSH, and key handling / host verification / PTY / audit need one trusted process. The SPA never SSHes directly — every SSH/tmux/PTY/AI call goes through the Gateway over HTTP+WebSocket.

### Three distinct tokens (the most important thing to understand)

Do not conflate these — mixing them up is the most common source of auth bugs:

1. **Gateway access token** — `Authorization: Bearer <token>`, set via `CHATMUX_GATEWAY_TOKEN`. Authenticates *every* API call. Web stores it locally; mobile uses secure storage + biometric unlock; the desktop/mobile local Gateway can run with `CHATMUX_LOCAL_NO_AUTH=1` (loopback only).
2. **Credential token** (`credentialToken`) — short-lived, minted by `POST /ssh/credentials` from raw SSH password/key (or stored host creds). All tmux/terminal/AI/history endpoints take a `credentialToken`, **never** raw SSH secrets. Bound to host + principal (`services/gateway/internal/api/ssh_credentials.go`, `credential_tokens.go`).
3. **Terminal token** — single-use-ish token from `POST .../terminal-token`, passed as the `?token=` query param on the `GET /api/terminal` WebSocket (query param because browsers can't set WS headers). See `terminal_token.go` / `terminal_ws.go`.

Raw SSH credentials are only ever accepted by `/ssh/probe` and `/ssh/credentials`. Everything downstream uses tokens.

### Gateway (`services/gateway`, Go 1.23)

- `cmd/chatmux-gateway/main.go` — reads all config from env, wires `api.NewServer` via **functional options** (`WithStaticUsers`, `WithCommandPolicy`, `WithCommandDrafter`, `WithTranscriptSummarizer`, …). AI features (drafter/summarizer) are only enabled when `OPENAI_API_KEY` is set.
- `internal/api` — HTTP handlers + WS. `server.go` `Handler()` is the single source of truth for the route table. Auth (`auth.go`), command allowlist/deny policy (`command_policy.go`, `automation*.go`), AI (`command_drafter.go`, `transcript_summarizer.go`, `openai_responses.go`).
- `internal/hoststore` — SQLite persistence (hosts, credentials, session metadata, audit events) via `mattn/go-sqlite3` (CGO; `Dockerfile.dev` sets `CGO_ENABLED=1`).
- `internal/sshclient` — SSH dialing + PTY (`golang.org/x/crypto/ssh`).
- `internal/tmux` — tmux session/window/transcript commands; includes a single-SSH-shell **fallback** when the remote host has no tmux.

### Frontend (`apps/web/src`)

- `App.tsx` is a thin orchestrator: it owns top-level state and composes a large set of `use*` hooks (`useHostWorkspace`, `useSSHCredentialToken`, `useAppSessionWorkflow`, `useTmuxWindowActions`, `useHostTrustPrompt`, …), then hands everything to `AppShell.tsx` for rendering. **Logic lives in the hooks, not in components** — follow that split.
- Terminal-first: the primary surface is a real xterm.js PTY over WebSocket (`NativeTerminal.tsx`, `useTerminalSocket.ts`), not a chat transcript. AI summaries / command drafts / history are side panels only.
- Raw xterm keyboard input intentionally **bypasses** the command-audit path (so passwords/TUI keystrokes are never logged); only the Composer's explicit sends are audited as metadata.
- tmux fallback (`tmux-fallback.ts`): when tmux is missing the UI offers an in-terminal installer.
- API contracts: the web app's source of truth for request/response types is **`apps/web/src/api-types.ts`** (re-exported through `api.ts`). `packages/shared` (`@chatmux/shared`) defines parallel types but **is currently not imported anywhere** — don't assume editing it changes the app; edit `api-types.ts`.

### One SPA, three shells

`runtime-platform.ts` detects the host: `isDesktopShell()` (Tauri globals), `isAndroidShell()` (Capacitor). `usesLocalGateway()` → desktop & Android point at an embedded local Gateway on `127.0.0.1:19327`; the browser build talks to the configured/proxied Gateway. Desktop bundles the Go binary as a Tauri sidecar (`apps/web/src-tauri`); Android bundles it too (`scripts/build-android-gateway.sh`).

## Security invariants (enforced — do not regress)

These are project rules from CONTRIBUTING.md and the security model, not generic advice:

- **No arbitrary shell execution.** Automation is an explicit allowlist (`automation_registry.go`); never add a "run any command" tool.
- **Never log** SSH passwords, private keys, Gateway tokens, or raw terminal input. Never return private keys to the client.
- **AI is opt-in and user-triggered.** Disabled unless `OPENAI_API_KEY` is set; never auto-upload terminal content.
- Command sending through the Composer is an auditable event; the command policy (`CHATMUX_COMMAND_POLICY_MODE`, default `enforce`) can deny via regex patterns.
- Gateway errors should be explicit — no silent degradation.

## Gateway configuration (env)

Set in `.env` (dev: `docker-compose.yml`) or `deploy/web/.env` (prod). Key vars: `CHATMUX_GATEWAY_TOKEN` (required), `CHATMUX_ADDR`/port `19327`, `CHATMUX_DB` (SQLite path), `CHATMUX_USERS_JSON` (extra users), `CHATMUX_COMMAND_POLICY_MODE` + `CHATMUX_COMMAND_DENY_PATTERNS_JSON`, `CHATMUX_AUTOMATION_CAPABILITIES_JSON`, `CHATMUX_LOCAL_NO_AUTH` (loopback only), `OPENAI_API_KEY`/`OPENAI_BASE_URL`/`OPENAI_MODEL`.

## Repository / branch context

This checkout is a **fork**: `origin` is the local fork, `upstream` is `binjie09/ChatMux` (the canonical repo referenced throughout package.json/README). `main` mirrors upstream (fast-forward only); local work lives on **`develop`** (the integration branch — branch new work from here). `scripts/sync-upstream.sh` does the fetch→ff main→rebase develop→redeploy flow. Local-only commits are prefixed `local:`. Production runs from `deploy/web/docker-compose.yml`.
