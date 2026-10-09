# Architecture

AI Monitor Station is a macOS Swift package with one library (`AIMonitorCore`)
and three executable targets: the `aimonitor` CLI, `aimonitor-probe`, and
`aimonitor-app`. The app owns both the menu bar item and the SwiftUI dashboard.
There are no external package dependencies; SQLite comes from the system.

## Layers

```
Collectors ──▶ Normalization ──▶ SyncEngine ──▶ SQLite ──▶ StoreReport ──▶ UI
 (per-tool)    (TokenBreakdown)   (checkpoints)  (events)    (read models)
```

### Collectors

Independent and optional. Each knows one log format and nothing else. A failing
collector throws per file and the file is counted in `filesFailed`; it cannot
break the other collectors. Adding a tool means adding one file that emits
`AIEvent`s — the store, dedup, analytics, and UI need no changes.

### Normalization

`TokenBreakdown` is the single place where provider conventions are reconciled:
Codex's inclusive `input_tokens` vs Claude Code's exclusive one, the two cache
TTL price classes, TTL-less writes, and reasoning-as-subset-of-output. Sums of
mixed-provider raw fields would be meaningless; sums of `TokenBreakdown` are not.

### The event model

`AIEvent` carries accounting only: timestamp, provider, model, session, project,
token breakdown, cost (nullable — never guessed), confidence. `source` is
`local_log` today; `api_proxy`, `browser`, `provider_usage`, `process`, and
`local_model` are reserved so future collectors land in the same pipeline.

### Dedup, enforced by the schema

- Claude Code events key on `requestId` (falling back to message id, then to a
  positional id). Streaming snapshots share the key; the store keeps the largest
  by `billable`, so totals are independent of insertion order.
- Codex events are per-event **deltas** with positional ids
  (`codex:<file>@<byteOffset>`) and `INSERT OR IGNORE` — replaying a log is a
  no-op by construction.

### Checkpoints and restart safety

Per file: `(size, offset, state)` committed in the **same transaction** as the
events it produced. A crash mid-file replays that file, and dedup makes the
replay harmless. Codex's cumulative counters resume from the snapshot stored in
`state`. A file that shrank is re-parsed from zero (rotation).

### Quota history and burn rate

Quota snapshots are appended (consecutive duplicates skipped), giving the
burn-rate engine a time series. A projection requires: ≥2 observations inside
the current window, a minimum observation spread scaled to the window size, a
positive observed burn, and exhaustion before reset. Otherwise silence.
The live dashboard accepts only observations from the last 30 minutes and whose
reset has not passed. History stays in SQLite for verification, but cannot pose
as a current account reading.

### Deviation from the suggested repo layout

The spec sketched a directory-per-concern layout (`macOS/`, `Core/`,
`Collectors/…`). This build uses a single SwiftPM library with one file per
concern instead — the same boundaries at a fraction of the ceremony, and one
`swift build` produces everything. If the proxy and browser extension land, the
extension gets its own top-level `BrowserExtension/` directory (it is not Swift).

## Why local-first

All state is one file: `~/Library/Application Support/AIMonitor/aimonitor.db`.
There is no AI Monitor account, cloud sync, telemetry, listener, or background
upload. Log collection and the Claude desktop-cache quota path are offline.
Three live-quota paths can make a read-only provider request after separate
explicit opt-ins; all are off by default and rate-limited to once per 15 minutes.
Cursor and Kimi Desktop databases are opened read-only; no browser store is read.

Collector accounting versions live in settings. Codex v2 changed inherited
fork/subagent counters from "first usage" to "baseline"; the first v2 sync
deletes only Codex rows and checkpoints under the configured Codex source root,
then reconstructs them from the original logs. Other providers are untouched.

## Lightweight source boundaries

The package stays dependency-free and keeps one core module. Lightweight here
means separating responsibilities without adding protocols, containers, or new
runtime layers:

- `EventStore` remains one public type. Its implementation is grouped into core
  writes, activity queries, pricing, persistence/quota, and analytics extension
  files; the database schema and API are unchanged.
- The app executable keeps only startup code in `main.swift`. Window/menu-bar
  lifecycle, observable state and root-view composition live independently.
- Views and collectors remain direct Swift types so compilation and navigation
  stay simple.
