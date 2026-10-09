# Open-source research

What similar tools exist, what they do well, and what AI Monitor Station does
differently. Licenses as published on each repository at review time (Aug 2026)
— re-check before reusing any code. No code was copied from any of these.

## Reviewed

### steipete/CodexBar — MIT
Native macOS quota monitor with provider adapters for Codex, Claude, Cursor,
Gemini/Antigravity, Kimi, and others.
- **Useful ideas adopted**: Cursor.app's state database can be opened read-only
  and its current JWT converted to the session cookie used for
  `/api/usage-summary`; Kimi Desktop's own cookie DB is a safer fallback than
  browser-cookie import; expired app credentials must remain unavailable.
- **Boundaries retained**: AIMonitor does not import browser cookies, refresh
  OAuth tokens, persist provider sessions, or attach to local language servers.
- **Implementation**: the small AIMonitor providers were independently written
  against the documented endpoints and response shapes; no CodexBar dependency
  or source file was copied into this package.

### timmyagentic/quota-monitor — MIT
Native macOS Codex/Claude quota and token monitor.
- **Useful ideas**: compare local accounting against provider quota, and keep
  quota health distinct from token totals.
- **Limitations here**: a narrower provider set and no replacement for
  Kimi/Cursor/Gemini source validation.

### MoonshotAI/kimi-code — official upstream
The official Kimi Code project confirms OAuth token ownership and the coding
usage endpoint. Its credential lifecycle remains owned by Kimi Code; AIMonitor
never refreshes or rewrites that file.

### soulduse/ai-token-monitor — MIT
Lightweight tray app (Tauri, Rust) reading the same Claude Code / Codex JSONL
paths, with per-model pricing, 5h/weekly plan bars, webhooks, and an opt-in
leaderboard.
- **Useful ideas**: zero-config log discovery; tray-first design; cache-hit
  ratio visualisation.
- **Limitations**: documents only "deduplicates entries" with no specifics; no
  1h/5m cache-write price split; Rust/Tauri, not native macOS.
- **Reusable code**: MIT, but no code was taken — the collectors were written
  independently against the documented formats.
- **We do differently**: schema-enforced dedup with order-independent fold;
  cache TTL price split; confidence labels on every number.

### juliantanx/aiusage — see repo for license
Node.js local-first tracker covering 20+ tools with a local web dashboard and
optional sync/leaderboard.
- **Useful ideas**: broad parser coverage; project-level breakdown; local web
  UI served on demand.
- **Limitations**: requires Node and a browser tab; quota pressure is derived,
  not read from provider data.
- **We do differently**: native SwiftUI, no runtime dependencies, quota read
  from provider-written `rate_limits`.

### niederme/ai-quota — MIT with Commons Clause (no commercial use)
Polished native macOS menu-bar app with dual-arc gauges, widgets, notifications,
and Claude usage-credit handling. Gets quota via OAuth/web sessions rather than
logs.
- **Useful ideas**: dual-window gauge language; honest "unavailable" states;
  adaptive refresh that backs off when idle.
- **Limitations**: requires signing into provider accounts (OAuth or WebKit
  sessions); Commons Clause blocks commercial reuse.
- **We do differently**: read-only, credential-free quota from logs; no sign-in
  flow at all.

### yagcioglutoprak/AIQuotaBar — see repo
Menu-bar quota app that auto-detects Claude/ChatGPT/Cursor/Copilot sessions
from installed browsers.
- **Useful ideas**: multi-browser session detection; compact menu-bar language.
- **Limitations**: reading browser cookies/sessions is brittle and invasive;
  no token accounting, only quota.
- **We do differently**: never touch browser state.

### ccusage — (web research, earlier pass)
The most-used token tracker; LiteLLM-sourced pricing, Codex support.
- **Useful ideas**: pricing registry discipline; daily bucketing.
- **Limitations**: tracks cache creation/read separately; CLI/TUI only.

### tokcat — (earlier pass)
Swift menu-bar app covering 10 clients including Cursor.
- **Useful ideas**: Cursor coverage is genuinely ahead of this build.
- **Limitations**: no documented requestId dedup or cache-TTL pricing.

### TokenEater, hamed-elfayome/Claude-Usage-Tracker, rjwalters/claude-monitor
— (earlier pass) Single-provider Claude menu-bar/CLI trackers. Useful as UI
references; none address cross-provider normalization.

## Spec-listed but not located/reviewed

`headroomlabs-ai/tokview`, `I-N-SILVA/NOTCHYLIMIT`, `658jjh/claude-usage-tracker`,
`she-llac/claude-counter` — not found in searches run for this document. If they
resurface, evaluate: dedup strategy, cache-TTL pricing, license.

## Design decisions

The project gives special treatment to two format details: Claude Code's
progressive snapshots are folded by `requestId`, and 1-hour versus 5-minute
cache writes use separate price multipliers. These are implementation choices
based on the formats documented during development, not claims that other
projects handle every provider or version incorrectly.
